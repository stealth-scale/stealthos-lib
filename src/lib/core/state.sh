###############################################################################
# module: core/state
# layer: core
# description: The registry every part of a run reads from: settings, the
#              stage, the modules that are loaded and the order they loaded
#              in, where each one came from, and the dependencies between
#              them.
#
#              A setting is looked up in three places, in this order: the
#              registry, STEALTH_<KEY> in the environment, and KEY itself. A
#              caller that has a sensible default passes it, and then the
#              lookup always succeeds. Without one the lookup returns 1, which
#              under set -e ends the process unless the caller handles it.
#
#              The four stage names live here, in one list, and the engine
#              asks for that list rather than keeping a second copy.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_CORE_STATE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_CORE_STATE=1

stealth::util::import "util/assert" "util/log" "util/text" "util/list"

# =============================================================================
# CONSTANTS
# =============================================================================

# The stages a run can be in. The engine reads this list through
# stealth::core::state::get_stages, so there is one copy of it.
declare -gra _STEALTH_CORE_STATE_STAGES=(build setup root user)

# What separates the dependencies of one module in the registry. A module path
# holds no space, so a space is enough to tell them apart.
declare -gr _STEALTH_CORE_STATE_DEP_SEPARATOR=' '

# =============================================================================
# STATE
# =============================================================================

# Setting key -> value.
declare -gA _STEALTH_CORE_STATE_VARS=()

# The stage of this run, worked out once. It is a variable of its own rather
# than a key of the registry, so a setting can never collide with it.
declare -g _STEALTH_CORE_STATE_STAGE=""

# The directories a module is looked for in, in the order they were added.
declare -ga _STEALTH_CORE_STATE_SEARCH_PATHS=()

# Module path -> 1, for the modules that are loaded.
declare -gA _STEALTH_CORE_STATE_LOADED=()

# The module paths in load order. An associative array has no order, and the
# order is what the start and end passes walk.
declare -ga _STEALTH_CORE_STATE_ORDER=()

# Module path -> the directory it was found in.
declare -gA _STEALTH_CORE_STATE_PATHS=()

# Module path -> its dependencies, separated by a space.
declare -gA _STEALTH_CORE_STATE_DEPS=()

# The module paths that have declared a dependency, in the order they declared
# one, so the graph comes out the same on every machine.
declare -ga _STEALTH_CORE_STATE_DEPS_ORDER=()

# =============================================================================
# SETTINGS
# =============================================================================

#######################################
# Records a setting, replacing whatever was there.
#
# Usage:
#   stealth::core::state::set 'dry_run' 'true'
#
# Arguments:
#   $1 (String) - The key
#   $2 (String) - The value. Default: empty
# Globals:
#   _STEALTH_CORE_STATE_VARS (Write)
# Returns:
#   0 - Recorded
#   Exits 1 when no key is given
#######################################
stealth::core::state::set() {
    stealth::util::assert::not_empty "${1:-}" 'a setting key is required'

    _STEALTH_CORE_STATE_VARS["${1}"]="${2:-}"
    stealth::util::log::trace 'state: %s = %s' "${1}" "${2:-}"
    return 0
}

#######################################
# Reads a setting: the registry first, then STEALTH_<KEY> in the environment,
# then KEY itself.
#
# Giving a default is the safe form. Without one a key that is not set returns
# 1, and under set -e that ends the process unless the caller says otherwise.
#
# Usage:
#   stealth::core::state::get jobs 'concurrency' 4
#   if ! stealth::core::state::get file 'log_file'; then ...
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The key
#   $3 (String)  - The value to use when the key is not set anywhere
# Globals:
#   _STEALTH_CORE_STATE_VARS (Read)
# Returns:
#   0 - Read, or the default was used
#   1 - Not set anywhere, and no default was given
#   Exits 1 when no output variable or no key is given
#######################################
stealth::core::state::get() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a setting key is required'
    local -n _state_get_out="${1}"
    local -r _state_get_key="${2}"

    if [[ -v _STEALTH_CORE_STATE_VARS["${_state_get_key}"] ]]; then
        _state_get_out="${_STEALTH_CORE_STATE_VARS[${_state_get_key}]}"
        return 0
    fi

    local _state_get_env
    stealth::util::text::to_const _state_get_env "STEALTH_${_state_get_key}"
    if [[ -n "${!_state_get_env:-}" ]]; then
        _state_get_out="${!_state_get_env}"
        return 0
    fi

    if [[ -n "${!_state_get_key:-}" ]]; then
        _state_get_out="${!_state_get_key}"
        return 0
    fi

    if (( $# >= 3 )); then
        _state_get_out="${3}"
        return 0
    fi
    return 1
}

#######################################
# Reports whether a setting is set in any of the three places.
#
# Usage:
#   if stealth::core::state::has 'log_file'; then ...
#
# Arguments:
#   $1 (String) - The key
# Returns:
#   0 - Set
#   1 - Not set
#   Exits 1 when no key is given
#######################################
stealth::core::state::has() {
    local _state_has_value

    stealth::core::state::get _state_has_value "${1:-}"
}

# =============================================================================
# THE STAGE
# =============================================================================

#######################################
# Reports whether this run is root. It is a function rather than a test of
# EUID at each call site so that a test can answer for it, because a shell
# will not let EUID be set.
#
# Usage:
#   if stealth::core::state::is_root; then ...
#
# Arguments:
#   None
# Globals:
#   EUID (Read)
# Returns:
#   0 - Root
#   1 - Anyone else
#######################################
stealth::core::state::is_root() {
    (( EUID == 0 ))
}

#######################################
# Fills an array with the stage names a run may be in.
#
# Usage:
#   stealth::core::state::get_stages stages
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_CORE_STATE_STAGES (Read)
# Returns:
#   0 - Filled
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_stages() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_stages_out="${1}"

    _state_stages_out=("${_STEALTH_CORE_STATE_STAGES[@]}")
    return 0
}

#######################################
# Reports whether a name is one of the stages.
#
# Usage:
#   if stealth::core::state::is_stage "${name}"; then ...
#
# Arguments:
#   $1 (String) - The name
# Globals:
#   _STEALTH_CORE_STATE_STAGES (Read)
# Returns:
#   0 - It is a stage
#   1 - It is not
#######################################
stealth::core::state::is_stage() {
    stealth::util::list::contains _STEALTH_CORE_STATE_STAGES "${1:-}"
}

#######################################
# Works out the stage of this run and remembers it. The stage setting decides
# it when there is one, and the user this runs as decides it otherwise: root
# gets the root stage and anyone else gets the user stage.
#
# It is worked out once. Everything after the first call reads the answer, so
# a stage cannot change halfway through a run.
#
# Usage:
#   stealth::core::state::detect_stage stage
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   _STEALTH_CORE_STATE_STAGE (Read/Write)
# Returns:
#   0 - Worked out
#   Exits 1 when no output variable is given, or the stage is not one of the
#   four
#######################################
stealth::core::state::detect_stage() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_detect_out="${1}"

    if [[ -n "${_STEALTH_CORE_STATE_STAGE}" ]]; then
        _state_detect_out="${_STEALTH_CORE_STATE_STAGE}"
        return 0
    fi

    local _state_detect_stage=''
    if ! stealth::core::state::get _state_detect_stage 'stage'; then
        if stealth::core::state::is_root; then
            _state_detect_stage='root'
        else
            _state_detect_stage='user'
        fi
    fi

    if ! stealth::core::state::is_stage "${_state_detect_stage}"; then
        local _state_detect_list
        stealth::util::text::join _state_detect_list ', ' \
            "${_STEALTH_CORE_STATE_STAGES[@]}"
        stealth::util::assert::fail \
            "a stage is one of ${_state_detect_list}, not ${_state_detect_stage}"
    fi

    _STEALTH_CORE_STATE_STAGE="${_state_detect_stage}"
    _state_detect_out="${_state_detect_stage}"
    stealth::util::log::debug 'stage: %s' "${_state_detect_stage}"
    return 0
}

# =============================================================================
# WHERE MODULES COME FROM
# =============================================================================

#######################################
# Adds a directory to look for modules in, and to the importer's own search
# path, so the two lists never differ.
#
# Usage:
#   stealth::core::state::add_search_path /srv/stealthos/modules
#
# Arguments:
#   $1 (String) - An absolute directory path
# Globals:
#   _STEALTH_CORE_STATE_SEARCH_PATHS (Write)
# Returns:
#   0 - Added
#   1 - The path is not absolute, or is not a directory
#   Exits 1 when no path is given
#######################################
stealth::core::state::add_search_path() {
    stealth::util::assert::not_empty "${1:-}" 'a search path is required'

    if [[ "${1}" != /* ]]; then
        stealth::util::log::warn 'a module search path is absolute, and %s is not' "${1}"
        return 1
    fi

    if [[ ! -d "${1}" ]]; then
        stealth::util::log::warn 'no module search path at %s' "${1}"
        return 1
    fi

    if stealth::util::list::contains _STEALTH_CORE_STATE_SEARCH_PATHS "${1}"; then
        return 0
    fi

    _STEALTH_CORE_STATE_SEARCH_PATHS+=("${1}")
    stealth::util::import::add_path "${1}"
    stealth::util::log::trace 'module search path: %s' "${1}"
    return 0
}

#######################################
# Adds several directories to look for modules in. A path that cannot be added
# is reported and the rest are still added.
#
# Usage:
#   stealth::core::state::add_search_paths /srv/modules /usr/share/stealth
#
# Arguments:
#   $@ (String) - Absolute directory paths
# Returns:
#   0 - Every path was added
#   1 - At least one path was not
#   Exits 1 when no path is given
#######################################
stealth::core::state::add_search_paths() {
    stealth::util::assert::not_empty "${1:-}" 'a search path is required'

    local _state_addp_path
    local -i _state_addp_status=0
    for _state_addp_path in "$@"; do
        if ! stealth::core::state::add_search_path "${_state_addp_path}"; then
            _state_addp_status=1
        fi
    done
    return "${_state_addp_status}"
}

#######################################
# Fills an array with the module search paths, in the order they were added.
#
# Usage:
#   stealth::core::state::get_search_paths paths
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_CORE_STATE_SEARCH_PATHS (Read)
# Returns:
#   0 - Filled
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_search_paths() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_paths_out="${1}"

    _state_paths_out=("${_STEALTH_CORE_STATE_SEARCH_PATHS[@]}")
    return 0
}

# =============================================================================
# THE MODULES OF A RUN
# =============================================================================

#######################################
# Records a module as loaded, and where it comes in the order.
#
# Usage:
#   stealth::core::state::register_module 'pkg/zlib' '/srv/modules/pkg/zlib'
#
# Arguments:
#   $1 (String) - The module path
#   $2 (String) - The directory it was found in. Default: not recorded
# Globals:
#   _STEALTH_CORE_STATE_LOADED (Write)
#   _STEALTH_CORE_STATE_ORDER (Write)
#   _STEALTH_CORE_STATE_PATHS (Write)
# Returns:
#   0 - Recorded, or it was already
#   Exits 1 when no module path is given
#######################################
stealth::core::state::register_module() {
    stealth::util::assert::not_empty "${1:-}" 'a module path is required'

    if [[ -n "${_STEALTH_CORE_STATE_LOADED[${1}]:-}" ]]; then
        return 0
    fi

    _STEALTH_CORE_STATE_LOADED["${1}"]=1
    _STEALTH_CORE_STATE_ORDER+=("${1}")

    if [[ -n "${2:-}" ]]; then
        _STEALTH_CORE_STATE_PATHS["${1}"]="${2}"
    fi

    stealth::util::log::trace 'module: %s' "${1}"
    return 0
}

#######################################
# Reports whether a module is loaded.
#
# Usage:
#   if stealth::core::state::is_module_loaded 'pkg/zlib'; then ...
#
# Arguments:
#   $1 (String) - The module path
# Globals:
#   _STEALTH_CORE_STATE_LOADED (Read)
# Returns:
#   0 - Loaded
#   1 - Not loaded
#######################################
stealth::core::state::is_module_loaded() {
    [[ -n "${_STEALTH_CORE_STATE_LOADED[${1:-}]:-}" ]]
}

#######################################
# Fills an array with the loaded modules, in load order. The start pass walks
# it forward and the end pass walks it back.
#
# Usage:
#   stealth::core::state::get_module_order modules
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_CORE_STATE_ORDER (Read)
# Returns:
#   0 - Filled
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_module_order() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_order_out="${1}"

    _state_order_out=("${_STEALTH_CORE_STATE_ORDER[@]}")
    return 0
}

#######################################
# Reads the directory a module was found in.
#
# Usage:
#   stealth::core::state::get_path dir 'pkg/zlib'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The module path
# Globals:
#   _STEALTH_CORE_STATE_PATHS (Read)
# Returns:
#   0 - Read
#   1 - The module has no recorded directory
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_path() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_getpath_out="${1}"

    if [[ ! -v _STEALTH_CORE_STATE_PATHS["${2:-}"] ]]; then
        return 1
    fi

    _state_getpath_out="${_STEALTH_CORE_STATE_PATHS[${2}]}"
    return 0
}

# =============================================================================
# THE GRAPH
# =============================================================================

#######################################
# Records that a module needs other modules before it. A module declares this
# in its init hook, so loading the whole list builds the whole graph, and
# loading one module for a job tells that job what to take from the store.
#
# Declaring the same dependency twice records it once.
#
# Usage:
#   stealth::core::state::depends 'pkg/zlib' 'toolchain/final' 'pkg/musl'
#
# Arguments:
#   $1 (String) - The module path
#   $@ (String) - The module paths it needs first
# Globals:
#   _STEALTH_CORE_STATE_DEPS (Read/Write)
#   _STEALTH_CORE_STATE_DEPS_ORDER (Write)
#   _STEALTH_CORE_STATE_DEP_SEPARATOR (Read)
# Returns:
#   0 - Recorded
#   Exits 1 when no module path is given, or a module depends on itself
#######################################
stealth::core::state::depends() {
    stealth::util::assert::not_empty "${1:-}" 'a module path is required'
    local -r _state_dep_module="${1}"
    shift

    if (( $# == 0 )); then
        return 0
    fi

    local -a _state_dep_current=()
    if [[ -v _STEALTH_CORE_STATE_DEPS["${_state_dep_module}"] ]]; then
        stealth::util::text::split _state_dep_current \
            "${_STEALTH_CORE_STATE_DEPS[${_state_dep_module}]}" \
            "${_STEALTH_CORE_STATE_DEP_SEPARATOR}"
    else
        _STEALTH_CORE_STATE_DEPS_ORDER+=("${_state_dep_module}")
    fi

    local _state_dep_one
    for _state_dep_one in "$@"; do
        if [[ "${_state_dep_one}" == "${_state_dep_module}" ]]; then
            stealth::util::assert::fail \
                "a module does not depend on itself, and ${_state_dep_module} does"
        fi
        stealth::util::list::add_unique _state_dep_current "${_state_dep_one}"
    done

    stealth::util::text::join \
        "_STEALTH_CORE_STATE_DEPS[${_state_dep_module}]" \
        "${_STEALTH_CORE_STATE_DEP_SEPARATOR}" "${_state_dep_current[@]}"
    stealth::util::log::trace 'depends: %s needs %s' "${_state_dep_module}" "$*"
    return 0
}

#######################################
# Fills an array with what one module needs before it, in the order it
# declared them. A module that declared nothing gives an empty array.
#
# Usage:
#   stealth::core::state::get_deps deps 'pkg/zlib'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The module path
# Globals:
#   _STEALTH_CORE_STATE_DEPS (Read)
#   _STEALTH_CORE_STATE_DEP_SEPARATOR (Read)
# Returns:
#   0 - Filled
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_deps() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_getdeps_out="${1}"

    _state_getdeps_out=()
    if [[ ! -v _STEALTH_CORE_STATE_DEPS["${2:-}"] ]]; then
        return 0
    fi

    stealth::util::text::split _state_getdeps_out \
        "${_STEALTH_CORE_STATE_DEPS[${2}]}" "${_STEALTH_CORE_STATE_DEP_SEPARATOR}"
    return 0
}

#######################################
# Fills an array with every edge of the graph, one edge per element, written
# as the module and then what it needs. It is the input tsort reads.
#
# The order is the order the dependencies were declared in, so the same run
# produces the same graph and the same plan.
#
# Usage:
#   stealth::core::state::get_graph edges
#   printf '%s\n' "${edges[@]}" | tsort
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_CORE_STATE_DEPS_ORDER (Read)
# Returns:
#   0 - Filled
#   Exits 1 when no output variable is given
#######################################
stealth::core::state::get_graph() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _state_graph_out="${1}"

    _state_graph_out=()
    local _state_graph_module _state_graph_dep
    local -a _state_graph_deps=()
    for _state_graph_module in "${_STEALTH_CORE_STATE_DEPS_ORDER[@]}"; do
        stealth::core::state::get_deps _state_graph_deps "${_state_graph_module}"
        for _state_graph_dep in "${_state_graph_deps[@]}"; do
            _state_graph_out+=("${_state_graph_module} ${_state_graph_dep}")
        done
    done
    return 0
}

# =============================================================================
# READING THE WHOLE THING
# =============================================================================

#######################################
# Writes the registry to the log at DEBUG, for working out why a run behaved
# the way it did.
#
# Usage:
#   stealth::core::state::dump
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_STATE_VARS (Read)
#   _STEALTH_CORE_STATE_SEARCH_PATHS (Read)
#   _STEALTH_CORE_STATE_ORDER (Read)
# Outputs:
#   A line per entry, to the sinks of util/log
# Returns:
#   0 - Written
#######################################
stealth::core::state::dump() {
    local _state_dump_key

    stealth::util::log::debug 'state: %d settings' "${#_STEALTH_CORE_STATE_VARS[@]}"
    for _state_dump_key in "${!_STEALTH_CORE_STATE_VARS[@]}"; do
        stealth::util::log::debug '  %s = %s' \
            "${_state_dump_key}" "${_STEALTH_CORE_STATE_VARS[${_state_dump_key}]}"
    done

    stealth::util::log::debug 'state: %d search paths' \
        "${#_STEALTH_CORE_STATE_SEARCH_PATHS[@]}"
    for _state_dump_key in "${_STEALTH_CORE_STATE_SEARCH_PATHS[@]}"; do
        stealth::util::log::debug '  %s' "${_state_dump_key}"
    done

    stealth::util::log::debug 'state: %d modules' "${#_STEALTH_CORE_STATE_ORDER[@]}"
    for _state_dump_key in "${_STEALTH_CORE_STATE_ORDER[@]}"; do
        stealth::util::log::debug '  %s' "${_state_dump_key}"
    done
    return 0
}
