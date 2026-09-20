###############################################################################
# module: sys/env
# layer: sys
# description: The environment variables that hold a list of directories:
#              PATH, LD_LIBRARY_PATH, PKG_CONFIG_PATH and the rest a toolchain
#              is built with.
#
#              Every function names the variable, so one set of them serves
#              all of those rather than PATH alone. A value already in the
#              list is not added twice, which is what makes a module safe to
#              run again.
#
#              Reading and writing a plain variable is not here. That is
#              ${VAR:-default}, export and unset, and a function wrapping one
#              of those one to one earns nothing. The old module had four of
#              them and nothing called any.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_ENV:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_ENV=1

stealth::util::import "util/assert" "util/log" "util/text" "util/list"

# =============================================================================
# CONSTANTS
# =============================================================================

# What separates the entries of a list held in an environment variable.
declare -gr _STEALTH_SYS_ENV_SEPARATOR=':'

# A line of an environment file: a name, an equals sign, and the rest.
declare -gr _STEALTH_SYS_ENV_LINE_RE='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads a list variable into an array, and gives an empty array when the
# variable holds nothing. Splitting an empty value would otherwise give one
# empty entry, and that entry means the current directory to everything that
# reads a PATH.
#
# Usage:
#   stealth::sys::env::_to_array entries PATH
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name of the variable
# Globals:
#   _STEALTH_SYS_ENV_SEPARATOR (Read)
# Returns:
#   0 - Read
#######################################
stealth::sys::env::_to_array() {
    local -n _env_arr_out="${1}"
    local -r _env_arr_value="${!2:-}"

    _env_arr_out=()
    if [[ -z "${_env_arr_value}" ]]; then
        return 0
    fi

    stealth::util::text::split _env_arr_out "${_env_arr_value}" \
        "${_STEALTH_SYS_ENV_SEPARATOR}"
    return 0
}

#######################################
# Writes an array back to a list variable and exports it, so a command the run
# starts sees it.
#
# Usage:
#   stealth::sys::env::_from_array PATH entries
#
# Arguments:
#   $1 (String) - The name of the variable
#   $2 (String) - The name of the array
# Globals:
#   _STEALTH_SYS_ENV_SEPARATOR (Read)
# Returns:
#   0 - Written
#######################################
stealth::sys::env::_from_array() {
    local -n _env_from_ref="${2}"
    local _env_from_value=''

    stealth::util::text::join _env_from_value "${_STEALTH_SYS_ENV_SEPARATOR}" \
        "${_env_from_ref[@]}"

    printf -v "${1}" '%s' "${_env_from_value}"
    export "${1?}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether a list variable already holds an entry. The comparison is
# exact, so /usr/local/bin is not found inside /usr/local/bin/extra.
#
# Usage:
#   if stealth::sys::env::contains PATH /usr/local/bin; then ...
#
# Arguments:
#   $1 (String) - The name of the variable
#   $2 (String) - The entry
# Returns:
#   0 - It holds it
#   1 - It does not
#   Exits 1 when no variable or no entry is named
#######################################
stealth::sys::env::contains() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an entry is required'

    local -a _env_has_entries=()
    stealth::sys::env::_to_array _env_has_entries "${1}"

    stealth::util::list::contains _env_has_entries "${2}"
}

#######################################
# Puts entries at the front of a list variable, so they are looked in first.
# An entry the variable already holds is moved to the front rather than added
# again, which is what a caller asking for it first means.
#
# Whether the directory exists is not checked. A build makes its directories
# as it goes, and a PATH entry that is not there yet costs nothing.
#
# Usage:
#   stealth::sys::env::prepend PATH "${toolchain}/bin"
#   stealth::sys::env::prepend PKG_CONFIG_PATH "${root}/usr/lib/pkgconfig"
#
# Arguments:
#   $1 (String) - The name of the variable
#   $@ (String) - The entries, in the order they should come
# Returns:
#   0 - Put there
#   Exits 1 when no variable or no entry is named
#######################################
stealth::sys::env::prepend() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a variable is required'
    local -r _env_pre_name="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'an entry is required'

    local -a _env_pre_entries=()
    stealth::sys::env::_to_array _env_pre_entries "${_env_pre_name}"

    stealth::util::list::remove _env_pre_entries "$@"
    stealth::util::list::prepend _env_pre_entries "$@"
    stealth::sys::env::_from_array "${_env_pre_name}" _env_pre_entries

    stealth::util::log::trace '%s now starts with %s' "${_env_pre_name}" "${1}"
    return 0
}

#######################################
# Puts entries at the end of a list variable, so they are looked in last. An
# entry the variable already holds stays where it is.
#
# Usage:
#   stealth::sys::env::append PATH /usr/local/bin
#
# Arguments:
#   $1 (String) - The name of the variable
#   $@ (String) - The entries
# Returns:
#   0 - Put there
#   Exits 1 when no variable or no entry is named
#######################################
stealth::sys::env::append() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a variable is required'
    local -r _env_app_name="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'an entry is required'

    local -a _env_app_entries=()
    stealth::sys::env::_to_array _env_app_entries "${_env_app_name}"

    stealth::util::list::add_unique _env_app_entries "$@"
    stealth::sys::env::_from_array "${_env_app_name}" _env_app_entries
    return 0
}

#######################################
# Takes entries out of a list variable, wherever they are in it. An entry that
# is not there is no trouble.
#
# Usage:
#   stealth::sys::env::remove PATH /usr/local/bin
#
# Arguments:
#   $1 (String) - The name of the variable
#   $@ (String) - The entries to take out
# Returns:
#   0 - Taken out
#   Exits 1 when no variable or no entry is named
#######################################
stealth::sys::env::remove() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a variable is required'
    local -r _env_rm_name="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'an entry is required'

    local -a _env_rm_entries=()
    stealth::sys::env::_to_array _env_rm_entries "${_env_rm_name}"

    stealth::util::list::remove _env_rm_entries "$@"
    stealth::sys::env::_from_array "${_env_rm_name}" _env_rm_entries
    return 0
}

#######################################
# Fills an array with what a list variable holds, in order.
#
# Usage:
#   stealth::sys::env::entries dirs PATH
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name of the variable
# Returns:
#   0 - Filled
#   Exits 1 when no output variable or no variable is named
#######################################
stealth::sys::env::entries() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'the name of a variable is required'

    stealth::sys::env::_to_array "${1}" "${2}"
    return 0
}

#######################################
# Reads a file of name and value pairs and exports each one. A line is a name,
# an equals sign and the rest, with an optional export in front. Comments and
# blank lines are skipped, and a line that is neither is reported and skipped.
#
# The old module exported whatever a line held without looking at it, so a
# line that was not a setting either failed or set something nothing reads.
#
# Usage:
#   stealth::sys::env::load /usr/share/stealthos/toolchain.env
#
# Arguments:
#   $1 (String) - The file
# Globals:
#   _STEALTH_SYS_ENV_LINE_RE (Read)
# Outputs:
#   A line per line it could not read, to the sinks of util/log
# Returns:
#   0 - Read
#   1 - There is no such file, or it cannot be read
#   Exits 1 when no file is named
#######################################
stealth::sys::env::load() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'

    if [[ ! -f "${1}" || ! -r "${1}" ]]; then
        stealth::util::log::warn 'no environment file to read at %s' "${1}"
        return 1
    fi

    local -a _env_load_lines=()
    mapfile -t _env_load_lines < "${1}"

    local _env_load_line _env_load_value
    local -i _env_load_no=0
    for _env_load_line in "${_env_load_lines[@]}"; do
        _env_load_no=$(( _env_load_no + 1 ))
        stealth::util::text::trim _env_load_line "${_env_load_line}"

        if [[ -z "${_env_load_line}" || "${_env_load_line}" == '#'* ]]; then
            continue
        fi

        if [[ ! "${_env_load_line}" =~ ${_STEALTH_SYS_ENV_LINE_RE} ]]; then
            stealth::util::log::warn '%s line %d is not a setting: %s' \
                "${1}" "${_env_load_no}" "${_env_load_line}"
            continue
        fi

        _env_load_value="${BASH_REMATCH[3]}"
        if [[ "${_env_load_value}" == \"*\" || "${_env_load_value}" == \'*\' ]]; then
            _env_load_value="${_env_load_value:1:${#_env_load_value} - 2}"
        fi

        printf -v "${BASH_REMATCH[2]}" '%s' "${_env_load_value}"
        export "${BASH_REMATCH[2]?}"
    done

    stealth::util::log::debug 'read the environment file %s' "${1}"
    return 0
}
