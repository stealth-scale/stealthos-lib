###############################################################################
# module: util/fmt
# layer: util
# description: Laying text out for a terminal: repeating, padding, cutting and
#              wrapping to a column, and the width of a value that carries
#              colour.
#
#              util/ui draws with these. They return a value rather than write
#              it, so the caller decides which sink receives it and a test
#              reads it without a terminal.
#
#              Manipulating a string belongs to util/text, and formatting a
#              number belongs to util/math.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_FMT:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_FMT=1

stealth::util::import "util/assert" "util/text"

# =============================================================================
# COLOUR
# =============================================================================

#######################################
# Removes the terminal escape sequences, so what is left is what a reader
# sees. It removes a control sequence, which starts with ESC [ and ends at the
# first letter, and that is every sequence this library and the commands it
# runs emit.
#
# Usage:
#   stealth::util::fmt::strip_ansi plain "${line}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Stripped
#   Exits 1 when no output variable is given
#######################################
stealth::util::fmt::strip_ansi() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _fmt_strip_out="${1}"
    local _fmt_strip_rest="${2:-}"
    local _fmt_strip_plain=""

    while [[ "${_fmt_strip_rest}" == *$'\033['* ]]; do
        _fmt_strip_plain+="${_fmt_strip_rest%%$'\033['*}"
        _fmt_strip_rest="${_fmt_strip_rest#*$'\033['}"

        # The parameters run to the letter that ends the sequence.
        while [[ -n "${_fmt_strip_rest}" && "${_fmt_strip_rest:0:1}" != [a-zA-Z] ]]; do
            _fmt_strip_rest="${_fmt_strip_rest:1}"
        done
        _fmt_strip_rest="${_fmt_strip_rest:1}"
    done

    _fmt_strip_out="${_fmt_strip_plain}${_fmt_strip_rest}"
    return 0
}

#######################################
# Counts the characters a reader sees, with the escape sequences left out.
# A character that a terminal draws two columns wide still counts as one, so
# a caller that aligns a column of Han or emoji measures it another way.
#
# Usage:
#   stealth::util::fmt::width columns "${badge}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Returns:
#   0 - Counted
#   Exits 1 when no output variable is given
#######################################
stealth::util::fmt::width() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _fmt_width_out="${1}"
    local _fmt_width_plain

    stealth::util::fmt::strip_ansi _fmt_width_plain "${2:-}"
    _fmt_width_out="${#_fmt_width_plain}"
    return 0
}

# =============================================================================
# LAYOUT
# =============================================================================

#######################################
# Repeats a value a number of times. A count of zero or less gives an empty
# value, which is what a rule of no width should be.
#
# Usage:
#   stealth::util::fmt::repeat rule '-' 72
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value to repeat
#   $3 (Integer) - How many times
# Returns:
#   0 - Repeated
#   Exits 1 when no output variable is given, or the count is not a number
#######################################
stealth::util::fmt::repeat() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_int "${3:-}" "a count is a whole number, not ${3:-}"
    local -n _fmt_rep_out="${1}"
    local -r _fmt_rep_value="${2:-}"
    local -ri _fmt_rep_count="${3}"

    _fmt_rep_out=""
    local -i _fmt_rep_i
    for (( _fmt_rep_i = 0; _fmt_rep_i < _fmt_rep_count; _fmt_rep_i++ )); do
        _fmt_rep_out+="${_fmt_rep_value}"
    done
    return 0
}

#######################################
# Pads a value on the right until it is as wide as a column. A value that is
# already as wide, or wider, is returned as it is, so padding never truncates.
#
# Usage:
#   stealth::util::fmt::pad_right cell "${key}" 20
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (Integer) - The width of the column
#   $4 (String)  - The character to pad with. Default: a space
# Returns:
#   0 - Padded
#   Exits 1 when no output variable is given, or the width is not a number
#######################################
stealth::util::fmt::pad_right() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_int "${3:-}" "a width is a whole number, not ${3:-}"
    local -n _fmt_padr_out="${1}"
    local -r _fmt_padr_value="${2:-}"
    local _fmt_padr_fill

    stealth::util::fmt::_filler _fmt_padr_fill "${_fmt_padr_value}" "${3}" "${4- }"
    _fmt_padr_out="${_fmt_padr_value}${_fmt_padr_fill}"
    return 0
}

#######################################
# Pads a value on the left until it is as wide as a column, for a number or
# anything else that reads better against the right edge.
#
# Usage:
#   stealth::util::fmt::pad_left cell "${count}" 6
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (Integer) - The width of the column
#   $4 (String)  - The character to pad with. Default: a space
# Returns:
#   0 - Padded
#   Exits 1 when no output variable is given, or the width is not a number
#######################################
stealth::util::fmt::pad_left() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_int "${3:-}" "a width is a whole number, not ${3:-}"
    local -n _fmt_padl_out="${1}"
    local -r _fmt_padl_value="${2:-}"
    local _fmt_padl_fill

    stealth::util::fmt::_filler _fmt_padl_fill "${_fmt_padl_value}" "${3}" "${4- }"
    _fmt_padl_out="${_fmt_padl_fill}${_fmt_padl_value}"
    return 0
}

#######################################
# Builds the padding one value needs to fill a column. It is a function of its
# own because both padding directions need the same measurement.
#
# Usage:
#   stealth::util::fmt::_filler fill "${value}" 20 ' '
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value to measure
#   $3 (Integer) - The width of the column
#   $4 (String)  - The character to pad with
# Returns:
#   0 - Built, and empty when the value already fills the column
#######################################
stealth::util::fmt::_filler() {
    local -n _fmt_fill_out="${1}"
    local -i _fmt_fill_width

    stealth::util::fmt::width _fmt_fill_width "${2}"
    stealth::util::fmt::repeat _fmt_fill_out "${4}" "$(( ${3} - _fmt_fill_width ))"
    return 0
}

#######################################
# Cuts a value to a column and marks that it was cut. A value that fits is
# returned as it is. When the column has no room for the marker, the value is
# cut to the column and the marker is left out.
#
# The value is measured as it is, so cutting a value that carries colour can
# remove the sequence that resets it.
#
# Usage:
#   stealth::util::fmt::truncate cell "${module}" 30
#   stealth::util::fmt::truncate cell "${module}" 30 '>'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (Integer) - The width of the column
#   $4 (String)  - The marker. Default: three dots
# Returns:
#   0 - Cut, or it already fitted
#   Exits 1 when no output variable is given, or the width is not a number
#######################################
stealth::util::fmt::truncate() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_int "${3:-}" "a width is a whole number, not ${3:-}"
    local -n _fmt_trunc_out="${1}"
    local -r _fmt_trunc_value="${2:-}"
    local -ri _fmt_trunc_width="${3}"
    local -r _fmt_trunc_mark="${4-...}"

    if (( ${#_fmt_trunc_value} <= _fmt_trunc_width )); then
        _fmt_trunc_out="${_fmt_trunc_value}"
        return 0
    fi

    if (( _fmt_trunc_width <= ${#_fmt_trunc_mark} )); then
        _fmt_trunc_out="${_fmt_trunc_value:0:_fmt_trunc_width}"
        return 0
    fi

    _fmt_trunc_out="${_fmt_trunc_value:0:_fmt_trunc_width - ${#_fmt_trunc_mark}}${_fmt_trunc_mark}"
    return 0
}

#######################################
# Wraps a value to a column, breaking between words. A line break in the value
# stays a line break. A word longer than the column keeps its own line rather
# than being cut, because a path or a digest is worth more whole.
#
# Usage:
#   stealth::util::fmt::wrap body "${reason}" 72
#   stealth::util::fmt::wrap body "${reason}" 72 '  '
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (Integer) - The width of the column, the prefix included
#   $4 (String)  - A prefix for every line. Default: empty
# Returns:
#   0 - Wrapped
#   Exits 1 when no output variable is given, or the width is not a number
#######################################
stealth::util::fmt::wrap() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_int "${3:-}" "a width is a whole number, not ${3:-}"
    local -n _fmt_wrap_out="${1}"
    local -r _fmt_wrap_prefix="${4-}"
    local -ri _fmt_wrap_room="$(( ${3} - ${#_fmt_wrap_prefix} ))"

    local -a _fmt_wrap_paragraphs=() _fmt_wrap_words=() _fmt_wrap_lines=()
    local _fmt_wrap_para _fmt_wrap_word _fmt_wrap_line=""

    stealth::util::text::split _fmt_wrap_paragraphs "${2:-}" $'\n'
    for _fmt_wrap_para in "${_fmt_wrap_paragraphs[@]}"; do
        stealth::util::text::squeeze _fmt_wrap_para "${_fmt_wrap_para}"
        stealth::util::text::split _fmt_wrap_words "${_fmt_wrap_para}" ' '

        _fmt_wrap_line=""
        for _fmt_wrap_word in "${_fmt_wrap_words[@]}"; do
            if [[ -z "${_fmt_wrap_line}" ]]; then
                _fmt_wrap_line="${_fmt_wrap_word}"
            elif (( ${#_fmt_wrap_line} + 1 + ${#_fmt_wrap_word} <= _fmt_wrap_room )); then
                _fmt_wrap_line+=" ${_fmt_wrap_word}"
            else
                _fmt_wrap_lines+=("${_fmt_wrap_prefix}${_fmt_wrap_line}")
                _fmt_wrap_line="${_fmt_wrap_word}"
            fi
        done
        _fmt_wrap_lines+=("${_fmt_wrap_prefix}${_fmt_wrap_line}")
    done

    stealth::util::text::join _fmt_wrap_out $'\n' "${_fmt_wrap_lines[@]}"
    return 0
}
