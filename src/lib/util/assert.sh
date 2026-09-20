###############################################################################
# module: util/assert
# layer: util
# description: Argument and state assertions. An assertion that does not hold
#              is a defect in the caller, so it ends the process through
#              util/log rather than returning a status. A function that a
#              caller is meant to test returns one instead, and its name
#              starts with is_, has_ or verify_.
#
#              The entry names the code that asserted, not this module, so a
#              failure points at the call site.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_ASSERT:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_ASSERT=1

stealth::util::import "util/log"

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Ends the process with the reason. Two frames are skipped, this one and the
# assertion that called it, so the entry names the caller of the assertion.
#
# Usage:
#   stealth::util::assert::_fail 'a module path is required'
#
# Arguments:
#   $1 (String) - The reason
# Outputs:
#   The entry, to the sinks of util/log
# Returns:
#   Exits 1
#######################################
stealth::util::assert::_fail() {
    stealth::util::log::error --frame 2 'assertion failed: %s' "${1}"
}

# =============================================================================
# VALUES
# =============================================================================

#######################################
# Ends the process with the reason, for a condition this module has no
# assertion for. It passes through _fail, so the entry names the caller and
# not this module.
#
# Usage:
#   if (( low > high )); then
#       stealth::util::assert::fail "a low bound of ${low} is above ${high}"
#   fi
#
# Arguments:
#   $1 (String) - The reason
# Outputs:
#   The entry, to the sinks of util/log
# Returns:
#   Exits 1
#######################################
stealth::util::assert::fail() {
    stealth::util::assert::_fail "${1:-an assertion did not hold}"
}

#######################################
# Asserts that a value is not empty.
#
# Usage:
#   stealth::util::assert::not_empty "${1:-}" "a module path is required"
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The reason. Default: a value is required
# Returns:
#   0 - Not empty
#   Exits 1 when it is empty
#######################################
stealth::util::assert::not_empty() {
    if [[ -z "${1:-}" ]]; then
        stealth::util::assert::_fail "${2:-a value is required}"
    fi
    return 0
}

#######################################
# Asserts that a value is a whole number, with an optional sign.
#
# Usage:
#   stealth::util::assert::is_int "${count}" 'a count is a whole number'
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The reason. Default: names the value
# Returns:
#   0 - A whole number
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_int() {
    if [[ ! "${1:-}" =~ ^[+-]?[0-9]+$ ]]; then
        stealth::util::assert::_fail "${2:-${1:-} is not a whole number}"
    fi
    return 0
}

#######################################
# Asserts that a value is a decimal number, with an optional sign and an
# optional fraction.
#
# Usage:
#   stealth::util::assert::is_number "${size}"
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The reason. Default: names the value
# Returns:
#   0 - A number
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_number() {
    if [[ ! "${1:-}" =~ ^[+-]?[0-9]+(\.[0-9]+)?$ ]]; then
        stealth::util::assert::_fail "${2:-${1:-} is not a number}"
    fi
    return 0
}

#######################################
# Asserts that a value is true or false.
#
# Usage:
#   stealth::util::assert::is_bool "${enabled}"
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The reason. Default: names the value
# Returns:
#   0 - true or false
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_bool() {
    case "${1:-}" in
        true|false) return 0 ;;
        *) stealth::util::assert::_fail "${2:-${1:-} is not true or false}" ;;
    esac
}

#######################################
# Asserts that a value compiles as an extended regular expression.
#
# Usage:
#   stealth::util::assert::is_regex "${pattern}"
#
# Arguments:
#   $1 (String) - The expression
#   $2 (String) - The reason. Default: names the expression
# Returns:
#   0 - It compiles
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_regex() {
    local -i _assert_re_status=0
    # shellcheck disable=SC2319  # the status of [[ =~ ]] is what tells a bad
    # expression (2) from no match (1)
    [[ '' =~ ${1:-} ]] 2>/dev/null || _assert_re_status=$?

    # A match returns 0 and no match returns 1. Anything above is the compiler
    # refusing the expression.
    if (( _assert_re_status > 1 )); then
        stealth::util::assert::_fail "${2:-${1:-} is not a regular expression}"
    fi
    return 0
}

#######################################
# Asserts that a value matches an extended regular expression.
#
# Usage:
#   stealth::util::assert::match "${stage}" '^[a-z0-9]+$' "a stage is lowercase"
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The expression
#   $3 (String) - The reason. Default: names both
# Returns:
#   0 - It matches
#   Exits 1 otherwise
#######################################
stealth::util::assert::match() {
    local -r _assert_match_value="${1:-}"
    local -r _assert_match_regex="${2:-}"

    if [[ ! "${_assert_match_value}" =~ ${_assert_match_regex} ]]; then
        stealth::util::assert::_fail \
            "${3:-${_assert_match_value} does not match ${_assert_match_regex}}"
    fi
    return 0
}

#######################################
# Asserts that a value is one of the values that follow it.
#
# Usage:
#   stealth::util::assert::enum "${stage}" build setup root user
#
# Arguments:
#   $1 (String) - The value
#   $@ (String) - The values it may take
# Returns:
#   0 - It is one of them
#   Exits 1 when it is not, or when no value was allowed
#######################################
stealth::util::assert::enum() {
    local -r _assert_enum_value="${1:-}"

    if (( $# < 2 )); then
        stealth::util::assert::_fail 'an enum needs at least one allowed value'
    fi
    shift

    local _assert_enum_item
    for _assert_enum_item in "$@"; do
        if [[ "${_assert_enum_value}" == "${_assert_enum_item}" ]]; then
            return 0
        fi
    done

    local _assert_enum_list
    printf -v _assert_enum_list '%s, ' "$@"
    stealth::util::assert::_fail \
        "${_assert_enum_value} is not one of ${_assert_enum_list%, }"
}

# =============================================================================
# THE SYSTEM
# =============================================================================

#######################################
# Asserts that a command is on the path. The logger cannot depend on sys/cmd,
# because sys/cmd depends on this module, so the lookup is here.
#
# Usage:
#   stealth::util::assert::is_command podman
#
# Arguments:
#   $1 (String) - The command name
#   $2 (String) - The reason. Default: names the command
# Returns:
#   0 - Found
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_command() {
    if ! command -v "${1:-}" >/dev/null 2>&1; then
        stealth::util::assert::_fail "${2:-${1:-} is not installed}"
    fi
    return 0
}

#######################################
# Asserts that a path is a regular file.
#
# Usage:
#   stealth::util::assert::is_file "${spec}"
#
# Arguments:
#   $1 (String) - The path
#   $2 (String) - The reason. Default: names the path
# Returns:
#   0 - A regular file
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_file() {
    if [[ ! -f "${1:-}" ]]; then
        stealth::util::assert::_fail "${2:-${1:-} is not a file}"
    fi
    return 0
}

#######################################
# Asserts that a path is a directory.
#
# Usage:
#   stealth::util::assert::is_dir "${vault}"
#
# Arguments:
#   $1 (String) - The path
#   $2 (String) - The reason. Default: names the path
# Returns:
#   0 - A directory
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_dir() {
    if [[ ! -d "${1:-}" ]]; then
        stealth::util::assert::_fail "${2:-${1:-} is not a directory}"
    fi
    return 0
}

#######################################
# Asserts that a path is safe to remove with its contents. A path is safe when
# it is absolute, has no parent component, and lies at least two levels below
# the root, so a variable that expanded to nothing cannot take out /usr.
#
# Usage:
#   stealth::util::assert::is_safe_path "${dir}"
#
# Arguments:
#   $1 (String) - The path
#   $2 (String) - The reason. Default: names the path
# Returns:
#   0 - Safe
#   Exits 1 otherwise
#######################################
stealth::util::assert::is_safe_path() {
    local _assert_safe_path="${1:-}"
    local -r _assert_safe_why="${2:-${1:-} is not a path that may be removed}"

    if [[ "${_assert_safe_path}" != /* ]]; then
        stealth::util::assert::_fail "${_assert_safe_why}"
    fi

    # A trailing slash changes the depth without changing the target.
    while [[ "${_assert_safe_path}" != "/" && "${_assert_safe_path}" == */ ]]; do
        _assert_safe_path="${_assert_safe_path%/}"
    done

    if [[ "${_assert_safe_path}" == *"/../"* || "${_assert_safe_path}" == *"/.." ]]; then
        stealth::util::assert::_fail "${_assert_safe_why}"
    fi

    # /usr has one component and /usr/lib has two. One is a directory of the
    # system, and no caller of this library removes one.
    local -r _assert_safe_parent="${_assert_safe_path%/*}"
    if [[ -z "${_assert_safe_parent}" || "${_assert_safe_parent}" == "/" ]]; then
        stealth::util::assert::_fail "${_assert_safe_why}"
    fi
    return 0
}
