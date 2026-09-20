###############################################################################
# module: util/math
# layer: util
# description: Whole-number arithmetic, and the two conversions that read and
#              write a number for a person: a size in bytes and a duration in
#              seconds.
#
#              Everything here is the shell's own arithmetic, so no function
#              runs a command. The old module ran awk for every operation and
#              numfmt for every conversion, which put two programs between the
#              library and a sum.
#
#              There is no floating point. A build counts bytes, seconds,
#              jobs and layers, and a fraction of one of those is a rounding
#              decision the caller should make. div_ceil, div_round and
#              percent make it once, in the open.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_MATH:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_MATH=1

stealth::util::import "util/assert"

# =============================================================================
# CONSTANTS
# =============================================================================

# The units of a size, each one 1024 of the one before it. The list stops at
# EiB, because 1024 of those is past what the shell counts to.
declare -gra _STEALTH_UTIL_MATH_UNITS=(B KiB MiB GiB TiB PiB EiB)

# How many steps up the units go, counted from B.
declare -gri _STEALTH_UTIL_MATH_UNIT_MAX=6

declare -gri _STEALTH_UTIL_MATH_MINUTE=60
declare -gri _STEALTH_UTIL_MATH_HOUR=3600

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Asserts that every value is a whole number.
#
# Usage:
#   stealth::util::math::_all_int "$@"
#
# Arguments:
#   $@ (String) - The values
# Returns:
#   0 - Every value is a whole number
#   Exits 1 otherwise
#######################################
stealth::util::math::_all_int() {
    local _math_allint_value

    for _math_allint_value in "$@"; do
        stealth::util::assert::is_int "${_math_allint_value}" \
            "a value is a whole number, not ${_math_allint_value}"
    done
    return 0
}

# =============================================================================
# ARITHMETIC
# =============================================================================

#######################################
# Finds the smallest of the values.
#
# Usage:
#   stealth::util::math::min jobs "${requested}" "${cpus}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (Integer) - The values, at least one
# Returns:
#   0 - Found
#   Exits 1 when no output variable or no value is given, or a value is not a
#   whole number
#######################################
stealth::util::math::min() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _math_min_out="${1}"
    shift

    stealth::util::assert::not_empty "${1:-}" 'at least one value is required'
    stealth::util::math::_all_int "$@"

    _math_min_out="${1}"
    local _math_min_value
    for _math_min_value in "$@"; do
        if (( _math_min_value < _math_min_out )); then
            _math_min_out="${_math_min_value}"
        fi
    done
    return 0
}

#######################################
# Finds the largest of the values.
#
# Usage:
#   stealth::util::math::max width "${longest}" 30
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (Integer) - The values, at least one
# Returns:
#   0 - Found
#   Exits 1 when no output variable or no value is given, or a value is not a
#   whole number
#######################################
stealth::util::math::max() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _math_max_out="${1}"
    shift

    stealth::util::assert::not_empty "${1:-}" 'at least one value is required'
    stealth::util::math::_all_int "$@"

    _math_max_out="${1}"
    local _math_max_value
    for _math_max_value in "$@"; do
        if (( _math_max_value > _math_max_out )); then
            _math_max_out="${_math_max_value}"
        fi
    done
    return 0
}

#######################################
# Adds the values. No value adds up to zero.
#
# Usage:
#   stealth::util::math::sum total "${sizes[@]}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (Integer) - The values
# Returns:
#   0 - Added
#   Exits 1 when no output variable is given, or a value is not a whole number
#######################################
stealth::util::math::sum() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _math_sum_out="${1}"
    shift

    stealth::util::math::_all_int "$@"

    _math_sum_out=0
    local _math_sum_value
    for _math_sum_value in "$@"; do
        _math_sum_out=$(( _math_sum_out + _math_sum_value ))
    done
    return 0
}

#######################################
# Takes the sign off a value.
#
# Usage:
#   stealth::util::math::abs drift "${difference}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The value
# Returns:
#   0 - Taken
#   Exits 1 when no output variable is given, or the value is not a whole number
#######################################
stealth::util::math::abs() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::math::_all_int "${2:-}"
    local -n _math_abs_out="${1}"
    local -ri _math_abs_value="${2}"

    if (( _math_abs_value < 0 )); then
        _math_abs_out=$(( -_math_abs_value ))
    else
        _math_abs_out="${_math_abs_value}"
    fi
    return 0
}

#######################################
# Holds a value between a low and a high bound, both of them allowed.
#
# Usage:
#   stealth::util::math::clamp jobs "${requested}" 1 64
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The value
#   $3 (Integer) - The lowest allowed value
#   $4 (Integer) - The highest allowed value
# Returns:
#   0 - Held
#   Exits 1 when no output variable is given, a value is not a whole number,
#   or the low bound is above the high one
#######################################
stealth::util::math::clamp() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::math::_all_int "${2:-}" "${3:-}" "${4:-}"
    local -n _math_clamp_out="${1}"
    local -ri _math_clamp_value="${2}"
    local -ri _math_clamp_low="${3}"
    local -ri _math_clamp_high="${4}"

    if (( _math_clamp_low > _math_clamp_high )); then
        stealth::util::assert::fail \
            "a low bound of ${_math_clamp_low} is above the high bound of ${_math_clamp_high}"
    fi

    if (( _math_clamp_value < _math_clamp_low )); then
        _math_clamp_out="${_math_clamp_low}"
    elif (( _math_clamp_value > _math_clamp_high )); then
        _math_clamp_out="${_math_clamp_high}"
    else
        _math_clamp_out="${_math_clamp_value}"
    fi
    return 0
}

#######################################
# Divides and rounds away from zero when the division leaves a remainder, so
# nine items in pages of four give three pages rather than two.
#
# Usage:
#   stealth::util::math::div_ceil pages "${items}" "${per_page}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The dividend
#   $3 (Integer) - The divisor
# Returns:
#   0 - Divided
#   Exits 1 when no output variable is given, a value is not a whole number,
#   or the divisor is zero
#######################################
stealth::util::math::div_ceil() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::math::_all_int "${2:-}" "${3:-}"
    local -n _math_dceil_out="${1}"
    local -ri _math_dceil_a="${2}"
    local -ri _math_dceil_b="${3}"

    stealth::util::math::_deny_zero "${_math_dceil_b}"

    _math_dceil_out=$(( _math_dceil_a / _math_dceil_b ))
    if (( _math_dceil_a % _math_dceil_b != 0 )); then
        if (( (_math_dceil_a < 0) == (_math_dceil_b < 0) )); then
            _math_dceil_out=$(( _math_dceil_out + 1 ))
        fi
    fi
    return 0
}

#######################################
# Divides and rounds to the nearest whole number, with a half going away from
# zero.
#
# Usage:
#   stealth::util::math::div_round average "${total}" "${count}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The dividend
#   $3 (Integer) - The divisor
# Returns:
#   0 - Divided
#   Exits 1 when no output variable is given, a value is not a whole number,
#   or the divisor is zero
#######################################
stealth::util::math::div_round() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::math::_all_int "${2:-}" "${3:-}"
    local -n _math_dround_out="${1}"
    local -ri _math_dround_a="${2}"
    local -ri _math_dround_b="${3}"

    stealth::util::math::_deny_zero "${_math_dround_b}"

    local -ri _math_dround_rest=$(( _math_dround_a % _math_dround_b ))
    local _math_dround_far _math_dround_step
    stealth::util::math::abs _math_dround_far "${_math_dround_rest}"
    stealth::util::math::abs _math_dround_step "${_math_dround_b}"

    _math_dround_out=$(( _math_dround_a / _math_dround_b ))
    if (( _math_dround_far * 2 >= _math_dround_step )); then
        if (( (_math_dround_a < 0) == (_math_dround_b < 0) )); then
            _math_dround_out=$(( _math_dround_out + 1 ))
        else
            _math_dround_out=$(( _math_dround_out - 1 ))
        fi
    fi
    return 0
}

#######################################
# Works out what share of a whole a part is, as a percentage rounded to the
# nearest whole number. A part above the whole gives more than 100.
#
# Usage:
#   stealth::util::math::percent done "${built}" "${total}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The part
#   $3 (Integer) - The whole, above zero
# Returns:
#   0 - Worked out
#   Exits 1 when no output variable is given, a value is not a whole number,
#   or the whole is zero or below
#######################################
stealth::util::math::percent() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::math::_all_int "${2:-}" "${3:-}"
    local -ri _math_pct_whole="${3}"

    if (( _math_pct_whole <= 0 )); then
        stealth::util::assert::fail "a whole is above zero, not ${_math_pct_whole}"
    fi

    stealth::util::math::div_round "${1}" "$(( ${2} * 100 ))" "${_math_pct_whole}"
    return 0
}

#######################################
# Refuses a divisor of zero, which the shell reports as a syntax error rather
# than as the caller's mistake.
#
# Usage:
#   stealth::util::math::_deny_zero "${divisor}"
#
# Arguments:
#   $1 (Integer) - The divisor
# Returns:
#   0 - It is not zero
#   Exits 1 when it is
#######################################
stealth::util::math::_deny_zero() {
    if (( ${1} == 0 )); then
        stealth::util::assert::fail 'a divisor is never zero'
    fi
    return 0
}

# =============================================================================
# SIZES
# =============================================================================

#######################################
# Reads a size written for a person and gives the number of bytes. A unit
# letter counts in steps of 1024, so 1G is 1073741824, and the i and the B are
# optional: 1G, 1Gi and 1GiB are the same size.
#
# Usage:
#   stealth::util::math::to_bytes bytes '512M'
#   stealth::util::math::to_bytes bytes '1.5G'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The size
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the size cannot be read
#######################################
stealth::util::math::to_bytes() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _math_tob_out="${1}"
    local -r _math_tob_input="${2:-}"
    local -r _math_tob_upper="${_math_tob_input^^}"

    if [[ ! "${_math_tob_upper}" =~ ^([0-9]+)(\.([0-9]+))?[[:space:]]*(B|[KMGTPE]I?B?)?$ ]]; then
        stealth::util::assert::fail \
            "a size is a number and an optional unit, not ${_math_tob_input}"
    fi

    local -r _math_tob_whole="${BASH_REMATCH[1]}"
    local -r _math_tob_frac="${BASH_REMATCH[3]}"
    local -r _math_tob_unit="${BASH_REMATCH[4]}"

    local -i _math_tob_mult=1
    case "${_math_tob_unit:0:1}" in
        K) _math_tob_mult=$(( 1024 )) ;;
        M) _math_tob_mult=$(( 1024 ** 2 )) ;;
        G) _math_tob_mult=$(( 1024 ** 3 )) ;;
        T) _math_tob_mult=$(( 1024 ** 4 )) ;;
        P) _math_tob_mult=$(( 1024 ** 5 )) ;;
        E) _math_tob_mult=$(( 1024 ** 6 )) ;;
        *) _math_tob_mult=1 ;;
    esac

    _math_tob_out=$(( 10#${_math_tob_whole} * _math_tob_mult ))

    if [[ -n "${_math_tob_frac}" ]]; then
        local -i _math_tob_scale=1 _math_tob_i
        for (( _math_tob_i = 0; _math_tob_i < ${#_math_tob_frac}; _math_tob_i++ )); do
            _math_tob_scale=$(( _math_tob_scale * 10 ))
        done
        _math_tob_out=$(( _math_tob_out +
            (10#${_math_tob_frac} * _math_tob_mult) / _math_tob_scale ))
    fi
    return 0
}

#######################################
# Writes a number of bytes the way a person reads it, with one decimal from
# KiB upward. 1536 gives 1.5 KiB, and 900 gives 900 B.
#
# Usage:
#   stealth::util::math::human_size size "${bytes}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The number of bytes, zero or above
# Returns:
#   0 - Written
#   Exits 1 when no output variable is given, or the value is not a size
#######################################
stealth::util::math::human_size() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::match "${2:-}" '^[0-9]+$' \
        "a size in bytes is a whole number, zero or above, not ${2:-}"
    local -n _math_hs_out="${1}"
    local -ri _math_hs_bytes="${2}"

    local -ri _math_hs_top="${_STEALTH_UTIL_MATH_UNIT_MAX}"
    local -i _math_hs_step=1 _math_hs_unit=0
    while (( _math_hs_unit < _math_hs_top && _math_hs_bytes >= _math_hs_step * 1024 )); do
        _math_hs_step=$(( _math_hs_step * 1024 ))
        _math_hs_unit=$(( _math_hs_unit + 1 ))
    done

    if (( _math_hs_unit == 0 )); then
        _math_hs_out="${_math_hs_bytes} ${_STEALTH_UTIL_MATH_UNITS[0]}"
        return 0
    fi

    # Multiplying the remainder by ten is exact up to PiB. At EiB the step is
    # divided first, because ten times a remainder that size is past the range.
    local -i _math_hs_tenths
    if (( _math_hs_unit < _STEALTH_UTIL_MATH_UNIT_MAX )); then
        _math_hs_tenths=$(( (_math_hs_bytes % _math_hs_step) * 10 / _math_hs_step ))
    else
        _math_hs_tenths=$(( (_math_hs_bytes % _math_hs_step) / (_math_hs_step / 10) ))
    fi

    printf -v _math_hs_out '%d.%d %s' \
        "$(( _math_hs_bytes / _math_hs_step ))" \
        "${_math_hs_tenths}" \
        "${_STEALTH_UTIL_MATH_UNITS[_math_hs_unit]}"
    return 0
}

# =============================================================================
# TIME
# =============================================================================

#######################################
# Writes a number of seconds the way a person reads it. Under a minute it is
# seconds alone, under an hour it is minutes and seconds, and above that it is
# hours, minutes and seconds.
#
# Usage:
#   stealth::util::math::duration took "${SECONDS}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The number of seconds, zero or above
# Returns:
#   0 - Written
#   Exits 1 when no output variable is given, or the value is not a duration
#######################################
stealth::util::math::duration() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::match "${2:-}" '^[0-9]+$' \
        "a duration in seconds is a whole number, zero or above, not ${2:-}"
    local -n _math_dur_out="${1}"
    local -ri _math_dur_total="${2}"

    local -ri _math_dur_hours=$(( _math_dur_total / _STEALTH_UTIL_MATH_HOUR ))
    local -ri _math_dur_minutes=$((
        (_math_dur_total % _STEALTH_UTIL_MATH_HOUR) / _STEALTH_UTIL_MATH_MINUTE ))
    local -ri _math_dur_seconds=$(( _math_dur_total % _STEALTH_UTIL_MATH_MINUTE ))

    if (( _math_dur_hours > 0 )); then
        printf -v _math_dur_out '%dh %dm %ds' \
            "${_math_dur_hours}" "${_math_dur_minutes}" "${_math_dur_seconds}"
    elif (( _math_dur_minutes > 0 )); then
        printf -v _math_dur_out '%dm %ds' "${_math_dur_minutes}" "${_math_dur_seconds}"
    else
        printf -v _math_dur_out '%ds' "${_math_dur_seconds}"
    fi
    return 0
}
