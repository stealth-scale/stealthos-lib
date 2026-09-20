###############################################################################
# module: util/text
# layer: util
# description: Operations on one string: whitespace, case, substrings, names
#              and the conversions between a string and an array.
#
#              Every function writes through a nameref in its first argument
#              and reads the value from the second, so a caller edits in place
#              with stealth::util::text::trim line "${line}" and derives a new
#              value with stealth::util::text::slug tag "${name}".
#
#              Presentation belongs to util/fmt: padding, wrapping, widths and
#              terminal escapes. Operations on an array belong to util/list.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_TEXT:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_TEXT=1

stealth::util::import "util/assert"

# =============================================================================
# CONSTANTS
# =============================================================================

# The longest single component a Linux filesystem accepts, in bytes.
declare -gri _STEALTH_UTIL_TEXT_NAME_MAX=255

# =============================================================================
# WHITESPACE
# =============================================================================

#######################################
# Removes the whitespace at both ends.
#
# Usage:
#   stealth::util::text::trim line "${line}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Trimmed
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::trim() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_trim_out="${1}"
    local _text_trim_value="${2:-}"

    _text_trim_value="${_text_trim_value#"${_text_trim_value%%[![:space:]]*}"}"
    _text_trim_out="${_text_trim_value%"${_text_trim_value##*[![:space:]]}"}"
    return 0
}

#######################################
# Removes the whitespace at the start.
#
# Usage:
#   stealth::util::text::trim_start body "${body}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Trimmed
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::trim_start() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_tstart_out="${1}"
    local -r _text_tstart_value="${2:-}"

    _text_tstart_out="${_text_tstart_value#"${_text_tstart_value%%[![:space:]]*}"}"
    return 0
}

#######################################
# Removes the whitespace at the end.
#
# Usage:
#   stealth::util::text::trim_end body "${body}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Trimmed
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::trim_end() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_tend_out="${1}"
    local -r _text_tend_value="${2:-}"

    _text_tend_out="${_text_tend_value%"${_text_tend_value##*[![:space:]]}"}"
    return 0
}

#######################################
# Removes the whitespace at both ends and replaces every run inside with one
# space. A tab, a newline and a run of spaces all become one space.
#
# Usage:
#   stealth::util::text::squeeze summary "${output}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Squeezed
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::squeeze() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_sq_out="${1}"
    local _text_sq_value="${2:-}"
    local _text_sq_char

    # A character class cannot be a replacement, so each kind of whitespace
    # becomes a space first, and the runs of spaces collapse after that.
    for _text_sq_char in $'\t' $'\n' $'\r' $'\f' $'\v'; do
        _text_sq_value="${_text_sq_value//${_text_sq_char}/ }"
    done
    while [[ "${_text_sq_value}" == *"  "* ]]; do
        _text_sq_value="${_text_sq_value//  / }"
    done

    stealth::util::text::trim _text_sq_out "${_text_sq_value}"
    return 0
}

# =============================================================================
# CASE
# =============================================================================

#######################################
# Converts every letter to lower case.
#
# Usage:
#   stealth::util::text::to_lower stage "${STAGE}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Converted
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::to_lower() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_lower_out="${1}"

    _text_lower_out="${2:-}"
    _text_lower_out="${_text_lower_out,,}"
    return 0
}

#######################################
# Converts every letter to upper case.
#
# Usage:
#   stealth::util::text::to_upper label "${level}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Converted
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::to_upper() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_upper_out="${1}"

    _text_upper_out="${2:-}"
    _text_upper_out="${_text_upper_out^^}"
    return 0
}

#######################################
# Converts a name to the shape of a shell constant: upper case, with every
# character that is not a letter or a digit replaced by an underscore.
# sys/io/fs gives SYS_IO_FS, and log-level gives LOG_LEVEL.
#
# Usage:
#   stealth::util::text::to_const var "${key}"
#   printf -v value '%s' "${!var}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The name
# Returns:
#   0 - Converted
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::to_const() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_const_out="${1}"

    _text_const_out="${2:-}"
    _text_const_out="${_text_const_out^^}"
    _text_const_out="${_text_const_out//[^A-Z0-9]/_}"
    return 0
}

# =============================================================================
# SUBSTRINGS
# =============================================================================

#######################################
# Replaces every occurrence of a pattern. The pattern is a glob, so * and ?
# match as they do in a case statement.
#
# Usage:
#   stealth::util::text::replace ref "${ref}" ':' '-'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - The pattern
#   $4 (String)  - The replacement. Default: empty, which removes the match
# Returns:
#   0 - Replaced
#   Exits 1 when no output variable or no pattern is given
#######################################
stealth::util::text::replace() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${3:-}" 'a pattern is required'
    local -n _text_rep_out="${1}"
    local -r _text_rep_pattern="${3}"
    local -r _text_rep_with="${4:-}"

    _text_rep_out="${2:-}"
    _text_rep_out="${_text_rep_out//${_text_rep_pattern}/${_text_rep_with}}"
    return 0
}

#######################################
# Removes a prefix when the value starts with it, and returns the value
# unchanged when it does not.
#
# Usage:
#   stealth::util::text::remove_prefix path "${path}" "${STEALTH_ROOT}/"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - The prefix
# Returns:
#   0 - Removed, or the prefix was not there
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::remove_prefix() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_rmpre_out="${1}"

    _text_rmpre_out="${2:-}"
    _text_rmpre_out="${_text_rmpre_out#"${3:-}"}"
    return 0
}

#######################################
# Removes a suffix when the value ends with it, and returns the value
# unchanged when it does not.
#
# Usage:
#   stealth::util::text::remove_suffix name "${file}" '.tar'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - The suffix
# Returns:
#   0 - Removed, or the suffix was not there
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::remove_suffix() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_rmsuf_out="${1}"

    _text_rmsuf_out="${2:-}"
    _text_rmsuf_out="${_text_rmsuf_out%"${3:-}"}"
    return 0
}

#######################################
# Puts a prefix in front of every line, the first one included. An empty value
# stays empty, so an indented block never starts with a stray prefix.
#
# Usage:
#   stealth::util::text::indent reason "${stderr}" '    '
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - The prefix. Default: two spaces
# Returns:
#   0 - Indented
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::indent() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_ind_out="${1}"
    local -r _text_ind_value="${2:-}"
    local -r _text_ind_prefix="${3-  }"

    if [[ -z "${_text_ind_value}" ]]; then
        _text_ind_out=""
        return 0
    fi

    _text_ind_out="${_text_ind_prefix}${_text_ind_value//$'\n'/$'\n'${_text_ind_prefix}}"
    return 0
}

# =============================================================================
# NAMES
# =============================================================================

#######################################
# Converts a value to a slug: lower case, with every other character replaced
# by a hyphen, runs of hyphens collapsed, and no hyphen at either end. It is
# what an image tag and a job name are built from.
#
# Usage:
#   stealth::util::text::slug tag "${package} ${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Converted
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::slug() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_slug_out="${1}"
    local _text_slug_value="${2:-}"

    _text_slug_value="${_text_slug_value,,}"
    _text_slug_value="${_text_slug_value//[^a-z0-9]/-}"

    # Every pass halves the longest run, so a run of n hyphens costs log2(n).
    while [[ "${_text_slug_value}" == *--* ]]; do
        _text_slug_value="${_text_slug_value//--/-}"
    done

    _text_slug_value="${_text_slug_value#-}"
    _text_slug_out="${_text_slug_value%-}"
    return 0
}

#######################################
# Converts a value to a name a filesystem accepts: every character other than
# a letter, a digit, a dot, a hyphen or an underscore becomes an underscore.
# The leading dots and hyphens go, so the result is neither a hidden file nor
# something a command reads as an option, and a name longer than the limit is
# cut to it.
#
# Usage:
#   stealth::util::text::filename file "${package}.tar"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Converted
#   Exits 1 when no output variable is given, or when nothing is left
#######################################
stealth::util::text::filename() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_file_out="${1}"
    local _text_file_value="${2:-}"

    _text_file_value="${_text_file_value//[^a-zA-Z0-9._-]/_}"
    _text_file_value="${_text_file_value#"${_text_file_value%%[!.-]*}"}"

    # A name of dots alone is the current or the parent directory.
    stealth::util::assert::not_empty "${_text_file_value}" \
        "no filename can be built from ${2:-}"

    _text_file_out="${_text_file_value:0:_STEALTH_UTIL_TEXT_NAME_MAX}"
    return 0
}

#######################################
# Quotes a value so the shell reads it back as one word. Use it to build a
# command line for a plan, a Makefile or a message.
#
# Usage:
#   stealth::util::text::quote arg "${path}"
#   printf 'podman run %s\n' "${arg}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Quoted
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::quote() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_quote_out="${1}"

    printf -v _text_quote_out '%q' "${2:-}"
    return 0
}

# =============================================================================
# ARRAYS
# =============================================================================

#######################################
# Splits a value on a delimiter into an array. The delimiter is a literal
# string of any length, an empty field is kept, and splitting a value that
# does not hold the delimiter gives one element.
#
# Usage:
#   stealth::util::text::split parts "${line}" '='
#   stealth::util::text::split names "${deps}" ', '
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The value
#   $3 (String)  - The delimiter
# Returns:
#   0 - Split
#   Exits 1 when no output variable or no delimiter is given
#######################################
stealth::util::text::split() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${3:-}" 'a delimiter is required'
    local -n _text_split_out="${1}"
    local _text_split_rest="${2:-}"
    local -r _text_split_delim="${3}"

    _text_split_out=()
    while [[ "${_text_split_rest}" == *"${_text_split_delim}"* ]]; do
        _text_split_out+=("${_text_split_rest%%"${_text_split_delim}"*}")
        _text_split_rest="${_text_split_rest#*"${_text_split_delim}"}"
    done
    _text_split_out+=("${_text_split_rest}")
    return 0
}

#######################################
# Joins elements into one value with a delimiter between them. No element
# gives an empty value, and one element gives that element.
#
# Usage:
#   stealth::util::text::join list ', ' "${packages[@]}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The delimiter
#   $@ (String)  - The elements
# Returns:
#   0 - Joined
#   Exits 1 when no output variable is given
#######################################
stealth::util::text::join() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _text_join_out="${1}"
    local -r _text_join_delim="${2:-}"

    # A shift past the end ends the process under set -e, so the count is
    # checked before the arguments move.
    if (( $# < 3 )); then
        _text_join_out=""
        return 0
    fi
    shift 2

    local _text_join_result="${1}"
    shift
    local _text_join_item
    for _text_join_item in "$@"; do
        _text_join_result+="${_text_join_delim}${_text_join_item}"
    done

    _text_join_out="${_text_join_result}"
    return 0
}

# =============================================================================
# QUESTIONS
# =============================================================================

#######################################
# Reports whether a value holds a substring.
#
# Usage:
#   if stealth::util::text::contains "${line}" '='; then ...
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The substring
# Returns:
#   0 - It holds it
#   1 - It does not
#######################################
stealth::util::text::contains() {
    [[ "${1:-}" == *"${2:-}"* ]]
}

#######################################
# Reports whether a value starts with a prefix.
#
# Usage:
#   if stealth::util::text::starts_with "${ref}" 'sha256:'; then ...
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The prefix
# Returns:
#   0 - It starts with it
#   1 - It does not
#######################################
stealth::util::text::starts_with() {
    [[ "${1:-}" == "${2:-}"* ]]
}

#######################################
# Reports whether a value ends with a suffix.
#
# Usage:
#   if stealth::util::text::ends_with "${file}" '.tar.zst'; then ...
#
# Arguments:
#   $1 (String) - The value
#   $2 (String) - The suffix
# Returns:
#   0 - It ends with it
#   1 - It does not
#######################################
stealth::util::text::ends_with() {
    [[ "${1:-}" == *"${2:-}" ]]
}

#######################################
# Reports whether a value is empty or holds nothing but whitespace.
#
# Usage:
#   if stealth::util::text::is_blank "${line}"; then continue; fi
#
# Arguments:
#   $1 (String) - The value
# Returns:
#   0 - Blank
#   1 - It holds something
#######################################
stealth::util::text::is_blank() {
    # A substitution and a default cannot be written as one expansion, and an
    # argument that is absent is unbound under set -u.
    local -r _text_blank_value="${1:-}"

    [[ -z "${_text_blank_value//[[:space:]]/}" ]]
}
