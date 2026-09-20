###############################################################################
# module: core/loader
# layer: core
# description: Turning a module path into loaded shell functions. A module is
#              a directory on a search path holding an optional common.sh and
#              an optional file named after the stage.
#
#              A module file is read from the directory the module was found
#              in, by its full path. It does not go through util/import, which
#              looks in the library root before the search paths and would
#              load a library file of the same name instead.
#
#              The namespace of a module is its path: pkg/zlib defines
#              mod::pkg::zlib::init and mod::pkg::zlib::build::start.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_CORE_LOADER:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_CORE_LOADER=1

stealth::util::import "util/assert" "util/log" "util/text" "core/state"

# =============================================================================
# CONSTANTS
# =============================================================================

# The namespace every module function sits under.
declare -gr _STEALTH_CORE_LOADER_PREFIX='mod'

# The file every module may have, whatever the stage.
declare -gr _STEALTH_CORE_LOADER_COMMON='common'

# What a module path may be made of. It is the same shape util/import accepts,
# so a module path can never climb out of a search directory.
declare -gr _STEALTH_CORE_LOADER_RE='^[a-zA-Z0-9][a-zA-Z0-9/_-]*$'

# =============================================================================
# STATE
# =============================================================================

# Module path -> 1 while its files are being read, so a module whose common.sh
# loads it again is caught instead of looping.
declare -gA _STEALTH_CORE_LOADER_LOADING=()

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Finds the directory a module lives in, looking through the search paths in
# the order they were added.
#
# Usage:
#   stealth::core::loader::_resolve dir 'pkg/zlib'
#
# Arguments:
#   $1 (Nameref) - The output variable for the directory
#   $2 (String)  - The module path
# Returns:
#   0 - Found
#   1 - No search path holds it
#######################################
stealth::core::loader::_resolve() {
    local -n _loader_res_out="${1}"
    local -r _loader_res_path="${2}"

    local -a _loader_res_dirs=()
    stealth::core::state::get_search_paths _loader_res_dirs

    local _loader_res_dir
    for _loader_res_dir in "${_loader_res_dirs[@]}"; do
        if [[ -d "${_loader_res_dir}/${_loader_res_path}" ]]; then
            _loader_res_out="${_loader_res_dir}/${_loader_res_path}"
            return 0
        fi
    done
    return 1
}

#######################################
# Reads one file of a module, if it is there.
#
# Usage:
#   stealth::core::loader::_source '/srv/modules/pkg/zlib/common.sh'
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - Read, or there was no such file
#######################################
stealth::core::loader::_source() {
    if [[ ! -f "${1}" ]]; then
        return 0
    fi

    stealth::util::log::trace 'reading %s' "${1}"
    # shellcheck source=/dev/null
    source "${1}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Converts a module path to the namespace its functions sit under. pkg/zlib
# gives mod::pkg::zlib, and a hyphen becomes an underscore because a hyphen
# cannot be part of a function name.
#
# Usage:
#   stealth::core::loader::to_namespace ns 'pkg/zlib'
#   stealth::core::loader::to_namespace ns 'util/log' 'stealth'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The module path
#   $3 (String)  - The namespace to sit under. Default: mod
# Globals:
#   _STEALTH_CORE_LOADER_PREFIX (Read)
# Returns:
#   0 - Converted
#   Exits 1 when no output variable or no path is given
#######################################
stealth::core::loader::to_namespace() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a module path is required'
    local -n _loader_ns_out="${1}"
    local _loader_ns_body

    stealth::util::text::replace _loader_ns_body "${2}" '/' '::'
    stealth::util::text::replace _loader_ns_body "${_loader_ns_body}" '-' '_'

    _loader_ns_out="${3:-${_STEALTH_CORE_LOADER_PREFIX}}::${_loader_ns_body}"
    return 0
}

#######################################
# Loads modules by their path under a search directory. Each one contributes
# its common.sh, and the file named after the stage of this run when it has
# one. A module that is already loaded is left alone.
#
# The stage is worked out here, so the configuration that sets it has to be
# read before the first module is loaded. core/engine::configure does that.
#
# Usage:
#   stealth::core::loader::module 'toolchain/final' 'pkg/zlib'
#
# Arguments:
#   $@ (String) - Module paths
# Globals:
#   _STEALTH_CORE_LOADER_LOADING (Read/Write)
#   _STEALTH_CORE_LOADER_RE (Read)
#   _STEALTH_CORE_LOADER_COMMON (Read)
# Returns:
#   0 - Every module is loaded
#   Exits 1 on a path that is not a module path, a module no search path
#   holds, or a module that loads itself
#######################################
stealth::core::loader::module() {
    local _loader_mod_path _loader_mod_dir _loader_mod_stage

    for _loader_mod_path in "$@"; do
        stealth::util::assert::match "${_loader_mod_path}" \
            "${_STEALTH_CORE_LOADER_RE}" \
            "a module path is a name and slashes, not ${_loader_mod_path}"

        if stealth::core::state::is_module_loaded "${_loader_mod_path}"; then
            continue
        fi

        if [[ -n "${_STEALTH_CORE_LOADER_LOADING[${_loader_mod_path}]:-}" ]]; then
            stealth::util::assert::fail \
                "the module ${_loader_mod_path} loads itself"
        fi

        if ! stealth::core::loader::_resolve _loader_mod_dir "${_loader_mod_path}"; then
            stealth::util::log::error 'no module %s on any search path' \
                "${_loader_mod_path}"
        fi

        stealth::util::log::debug 'loading module %s from %s' \
            "${_loader_mod_path}" "${_loader_mod_dir}"

        _STEALTH_CORE_LOADER_LOADING["${_loader_mod_path}"]=1

        stealth::core::loader::_source \
            "${_loader_mod_dir}/${_STEALTH_CORE_LOADER_COMMON}.sh"

        stealth::core::state::detect_stage _loader_mod_stage
        stealth::core::loader::_source "${_loader_mod_dir}/${_loader_mod_stage}.sh"

        unset "_STEALTH_CORE_LOADER_LOADING[${_loader_mod_path}]"
        stealth::core::state::register_module "${_loader_mod_path}" "${_loader_mod_dir}"
    done
    return 0
}

#######################################
# Loads the modules a list names. The list is a shell file that sets MODULES
# to an array of module paths, so it is code the run trusts, not configuration
# it parses.
#
# Usage:
#   stealth::core::loader::load_manifest /srv/stealthos/stage0.list
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - Every module the list names is loaded
#   Exits 1 when there is no such file, or it names no module
#######################################
stealth::core::loader::load_manifest() {
    stealth::util::assert::is_file "${1:-}" "no module list at ${1:-}"

    stealth::util::log::debug 'reading the module list %s' "${1}"

    local -a MODULES=()
    # shellcheck source=/dev/null
    source "${1}"

    if (( ${#MODULES[@]} == 0 )); then
        stealth::util::log::error 'the module list %s names no module' "${1}"
    fi

    stealth::core::loader::module "${MODULES[@]}"
    return 0
}
