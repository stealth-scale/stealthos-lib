###############################################################################
# module: util/import
# layer: util
# description: The linker of the library. Resolves a logical module path to a
#              file, sources it once, and refuses a cycle. It imports nothing
#              itself, so every other module may depend on it.
#
#              Shell options are the entry point's. A module of this library
#              never sets them, so a test or a host script keeps its own.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_IMPORT:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_IMPORT=1

# =============================================================================
# STATE
# =============================================================================

# Where a module is resolved from first. bin/stealth exports STEALTH_LIB; a
# test or a direct source falls back to the directory above this file.
declare -g _STEALTH_UTIL_IMPORT_ROOT="${STEALTH_LIB:-}"
if [[ -z "${_STEALTH_UTIL_IMPORT_ROOT}" ]]; then
    _STEALTH_UTIL_IMPORT_ROOT="$(readlink -f -- "${BASH_SOURCE[0]%/*}/..")"
fi

# Module path -> 1, for the modules that are sourced.
declare -gA _STEALTH_UTIL_IMPORT_LOADED=()

# Module path -> 1, for the modules that are being sourced right now.
declare -gA _STEALTH_UTIL_IMPORT_LOADING=()

# The module paths in load order. An associative array has no order.
declare -ga _STEALTH_UTIL_IMPORT_ORDER=()

# The directories searched after the root, in the order they were added.
if [[ ! -v _STEALTH_UTIL_IMPORT_PATHS ]]; then
    declare -ga _STEALTH_UTIL_IMPORT_PATHS=()
fi

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Logs through util/log when it is loaded, and to stderr before it is.
# Only an error or a warning reaches stderr in the fallback.
#
# Usage:
#   stealth::util::import::_log ERROR 'no module %s' "${name}"
#
# Arguments:
#   $1 (String) - Level: ERROR, WARN, INFO, DEBUG or TRACE
#   $@ (String) - The printf format and its arguments
# Outputs:
#   The line, to the logger or to stderr
# Returns:
#   0 - Logged
#######################################
stealth::util::import::_log() {
    local -r _imp_log_level="${1}"
    shift

    local -r _imp_log_fn="stealth::util::log::${_imp_log_level,,}"
    if declare -F "${_imp_log_fn}" >/dev/null 2>&1; then
        "${_imp_log_fn}" "$@"
        return 0
    fi

    if [[ "${_imp_log_level}" == "ERROR" || "${_imp_log_level}" == "WARN" ]]; then
        local _imp_log_msg
        # shellcheck disable=SC2059  # the format is this library's, never data
        printf -v _imp_log_msg -- "$@"
        printf '[bootstrap] [%s] %s\n' "${_imp_log_level}" "${_imp_log_msg}" >&2
    fi
    return 0
}

#######################################
# Converts a module path to the name of its sourcing guard.
# util/log becomes _STEALTH_LIB_UTIL_LOG.
#
# Usage:
#   stealth::util::import::_to_guard_var _guard util/log
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The module path
# Returns:
#   0 - Converted
#######################################
stealth::util::import::_to_guard_var() {
    local -n _imp_guard_out="${1}"
    local _imp_guard_clean="${2^^}"

    _imp_guard_clean="${_imp_guard_clean//\//_}"
    _imp_guard_clean="${_imp_guard_clean//-/_}"

    _imp_guard_out="_STEALTH_LIB_${_imp_guard_clean}"
    return 0
}

#######################################
# Resolves a module path to a file, the root first and the search paths after
# it, in the order they were added.
#
# Usage:
#   stealth::util::import::_resolve _file util/log
#
# Arguments:
#   $1 (Nameref) - The output variable for the absolute file path
#   $2 (String)  - The module path
# Globals:
#   _STEALTH_UTIL_IMPORT_ROOT (Read)
#   _STEALTH_UTIL_IMPORT_PATHS (Read)
# Returns:
#   0 - Resolved
#   1 - No file for the module path
#######################################
stealth::util::import::_resolve() {
    local -n _imp_res_out="${1}"
    local -r _imp_res_req="${2}"
    local _imp_res_dir

    if [[ -f "${_STEALTH_UTIL_IMPORT_ROOT}/${_imp_res_req}.sh" ]]; then
        _imp_res_out="${_STEALTH_UTIL_IMPORT_ROOT}/${_imp_res_req}.sh"
        return 0
    fi

    for _imp_res_dir in "${_STEALTH_UTIL_IMPORT_PATHS[@]}"; do
        if [[ -f "${_imp_res_dir}/${_imp_res_req}.sh" ]]; then
            _imp_res_out="${_imp_res_dir}/${_imp_res_req}.sh"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Adds directories to the module search path. A path must be absolute.
# A path that does not exist is registered with a warning, because a caller
# may create it later.
#
# Usage:
#   stealth::util::import::add_path /srv/stealthos/modules
#
# Arguments:
#   $@ (String) - Absolute directory paths
# Globals:
#   _STEALTH_UTIL_IMPORT_PATHS (Write)
# Returns:
#   0 - Every path was added
#   1 - A path was empty or relative, and the rest were added
#######################################
stealth::util::import::add_path() {
    if (( $# == 0 )); then
        stealth::util::import::_log "ERROR" "Adding a search path failed: no path given"
        return 1
    fi

    local _imp_add_path
    local -i _imp_add_status=0

    for _imp_add_path in "$@"; do
        if [[ -z "${_imp_add_path}" ]]; then
            stealth::util::import::_log "ERROR" "Adding a search path failed: the path is empty"
            _imp_add_status=1
            continue
        fi

        if [[ "${_imp_add_path}" != /* ]]; then
            stealth::util::import::_log "ERROR" \
                "Adding a search path failed: %s is not absolute" "${_imp_add_path}"
            _imp_add_status=1
            continue
        fi

        if [[ ! -d "${_imp_add_path}" ]]; then
            stealth::util::import::_log "WARN" \
                "Adding a search path that does not exist: %s" "${_imp_add_path}"
        fi

        _STEALTH_UTIL_IMPORT_PATHS+=("${_imp_add_path}")
    done

    return "${_imp_add_status}"
}

#######################################
# Fills an array with the search paths, in the order they were added.
#
# Usage:
#   stealth::util::import::paths _dirs
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_UTIL_IMPORT_PATHS (Read)
# Returns:
#   0 - Filled
#######################################
stealth::util::import::paths() {
    local -n _imp_paths_out="${1}"
    _imp_paths_out=("${_STEALTH_UTIL_IMPORT_PATHS[@]}")
    return 0
}

#######################################
# Fills an array with the loaded module paths, in load order.
#
# Usage:
#   stealth::util::import::loaded _modules
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_UTIL_IMPORT_ORDER (Read)
# Returns:
#   0 - Filled
#######################################
stealth::util::import::loaded() {
    local -n _imp_loaded_out="${1}"
    _imp_loaded_out=("${_STEALTH_UTIL_IMPORT_ORDER[@]}")
    return 0
}

#######################################
# Reports whether a module is loaded.
#
# Usage:
#   if stealth::util::import::is_loaded util/log; then ...
#
# Arguments:
#   $1 (String) - The module path
# Globals:
#   _STEALTH_UTIL_IMPORT_LOADED (Read)
# Returns:
#   0 - Loaded
#   1 - Not loaded
#######################################
stealth::util::import::is_loaded() {
    [[ -n "${_STEALTH_UTIL_IMPORT_LOADED[${1:-}]:-}" ]]
}

#######################################
# Imports modules by their path under the library root, without the extension.
# A module is sourced once. A module whose guard is already set counts as
# loaded, so a concatenated bundle of modules imports without a file.
#
# Usage:
#   stealth::util::import "util/log" "sys/cmd"
#
# Arguments:
#   $@ (String) - Module paths, such as util/log or sys/io/fs
# Globals:
#   _STEALTH_UTIL_IMPORT_ROOT (Read)
#   _STEALTH_UTIL_IMPORT_PATHS (Read)
# Globals:
#   _STEALTH_UTIL_IMPORT_LOADED (Read/Write)
#   _STEALTH_UTIL_IMPORT_LOADING (Read/Write)
#   _STEALTH_UTIL_IMPORT_ORDER (Write)
# Returns:
#   0 - Every module is loaded
#   Exits 1 on an invalid name, a cycle, or a module that does not resolve
#######################################
stealth::util::import() {
    local _imp_req _imp_guard _imp_file

    for _imp_req in "$@"; do
        if [[ ! "${_imp_req}" =~ ^[a-zA-Z0-9][a-zA-Z0-9/_-]*$ ]]; then
            stealth::util::import::_log "ERROR" \
                "Importing failed: %s is not a module path" "${_imp_req}"
            exit 1
        fi

        if [[ -n "${_STEALTH_UTIL_IMPORT_LOADED[${_imp_req}]:-}" ]]; then
            continue
        fi

        stealth::util::import::_to_guard_var _imp_guard "${_imp_req}"
        if [[ -n "${!_imp_guard:-}" ]]; then
            _STEALTH_UTIL_IMPORT_LOADED["${_imp_req}"]=1
            _STEALTH_UTIL_IMPORT_ORDER+=("${_imp_req}")
            continue
        fi

        if [[ -n "${_STEALTH_UTIL_IMPORT_LOADING[${_imp_req}]:-}" ]]; then
            stealth::util::import::_log "ERROR" \
                "Importing failed: %s imports itself through its dependencies" "${_imp_req}"
            exit 1
        fi

        if ! stealth::util::import::_resolve _imp_file "${_imp_req}"; then
            stealth::util::import::_log "DEBUG" "Searched %s and %s" \
                "${_STEALTH_UTIL_IMPORT_ROOT}" "${_STEALTH_UTIL_IMPORT_PATHS[*]}"
            stealth::util::import::_log "ERROR" "Importing failed: no module %s" "${_imp_req}"
            exit 1
        fi

        _STEALTH_UTIL_IMPORT_LOADING["${_imp_req}"]=1
        # shellcheck source=/dev/null
        source "${_imp_file}"
        unset "_STEALTH_UTIL_IMPORT_LOADING[${_imp_req}]"

        _STEALTH_UTIL_IMPORT_LOADED["${_imp_req}"]=1
        _STEALTH_UTIL_IMPORT_ORDER+=("${_imp_req}")
    done

    return 0
}
