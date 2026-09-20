###############################################################################
# module: util/list
# layer: util
# description: Operations on an array: membership, adding and removing, order
#              and set arithmetic.
#
#              An array cannot be passed by value, so every function takes the
#              name of one. A function that changes an array names it first
#              and edits it in place. A function that answers a question about
#              an array writes the answer through an output variable, also
#              first, and reads the arrays after it.
#
#              A list held as one delimited string, such as PATH, becomes an
#              array with stealth::util::text::split and goes back with
#              stealth::util::text::join.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_LIST:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_LIST=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# QUESTIONS
# =============================================================================

#######################################
# Reports whether an array holds a value. The comparison is exact, so an
# element is never matched by a part of it.
#
# Usage:
#   if stealth::util::list::contains packages zlib; then ...
#
# Arguments:
#   $1 (String) - The name of the array
#   $2 (String) - The value
# Returns:
#   0 - It holds it
#   1 - It does not
#   Exits 1 when no array is named
#######################################
stealth::util::list::contains() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_has_ref="${1}"
    local -r _list_has_value="${2:-}"
    local _list_has_item

    for _list_has_item in "${_list_has_ref[@]}"; do
        if [[ "${_list_has_item}" == "${_list_has_value}" ]]; then
            return 0
        fi
    done
    return 1
}

#######################################
# Finds where a value sits in an array. The answer is the index of the first
# element that equals it, and -1 when no element does, so a caller tests the
# answer rather than a status.
#
# Usage:
#   stealth::util::list::index_of at packages zlib
#   if (( at >= 0 )); then ...
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The name of the array
#   $3 (String)  - The value
# Returns:
#   0 - Searched
#   Exits 1 when no output variable or no array is named
#######################################
stealth::util::list::index_of() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'the name of an array is required'
    local -n _list_idx_out="${1}"
    local -n _list_idx_ref="${2}"
    local -r _list_idx_value="${3:-}"
    local -i _list_idx_i

    _list_idx_out=-1
    for (( _list_idx_i = 0; _list_idx_i < ${#_list_idx_ref[@]}; _list_idx_i++ )); do
        if [[ "${_list_idx_ref[_list_idx_i]}" == "${_list_idx_value}" ]]; then
            _list_idx_out="${_list_idx_i}"
            return 0
        fi
    done
    return 0
}

# =============================================================================
# CHANGING AN ARRAY
# =============================================================================

#######################################
# Adds values to the end of an array.
#
# Usage:
#   stealth::util::list::append packages zlib gcc
#
# Arguments:
#   $1 (String) - The name of the array
#   $@ (String) - The values
# Returns:
#   0 - Added
#   Exits 1 when no array is named
#######################################
stealth::util::list::append() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_app_ref="${1}"
    shift

    if (( $# > 0 )); then
        _list_app_ref+=("$@")
    fi
    return 0
}

#######################################
# Adds values to the front of an array, in the order they are given.
#
# Usage:
#   stealth::util::list::prepend search_paths /srv/modules
#
# Arguments:
#   $1 (String) - The name of the array
#   $@ (String) - The values
# Returns:
#   0 - Added
#   Exits 1 when no array is named
#######################################
stealth::util::list::prepend() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_pre_ref="${1}"
    shift

    if (( $# > 0 )); then
        _list_pre_ref=("$@" "${_list_pre_ref[@]}")
    fi
    return 0
}

#######################################
# Adds values to the end of an array, leaving out any the array already holds.
# Calling it twice with the same value changes nothing the second time, which
# is what a search path and a dependency list need.
#
# Usage:
#   stealth::util::list::add_unique deps zlib gcc zlib
#
# Arguments:
#   $1 (String) - The name of the array
#   $@ (String) - The values
# Returns:
#   0 - Added
#   Exits 1 when no array is named
#######################################
stealth::util::list::add_unique() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -r _list_addu_name="${1}"
    local -n _list_addu_ref="${1}"
    shift

    local _list_addu_value
    for _list_addu_value in "$@"; do
        if ! stealth::util::list::contains "${_list_addu_name}" "${_list_addu_value}"; then
            _list_addu_ref+=("${_list_addu_value}")
        fi
    done
    return 0
}

#######################################
# Removes every element that equals one of the values, and closes the gaps so
# the indices stay consecutive.
#
# Usage:
#   stealth::util::list::remove packages gcc
#
# Arguments:
#   $1 (String) - The name of the array
#   $@ (String) - The values to remove
# Returns:
#   0 - Removed
#   Exits 1 when no array is named
#######################################
stealth::util::list::remove() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_rm_ref="${1}"
    shift

    local -a _list_rm_kept=()
    local _list_rm_item _list_rm_drop
    for _list_rm_item in "${_list_rm_ref[@]}"; do
        for _list_rm_drop in "$@"; do
            if [[ "${_list_rm_item}" == "${_list_rm_drop}" ]]; then
                continue 2
            fi
        done
        _list_rm_kept+=("${_list_rm_item}")
    done

    _list_rm_ref=("${_list_rm_kept[@]}")
    return 0
}

#######################################
# Removes the element at an index and closes the gap. An index outside the
# array leaves it as it is, so a caller that searched and found nothing does
# not have to check again.
#
# Usage:
#   stealth::util::list::remove_at packages 0
#
# Arguments:
#   $1 (String)  - The name of the array
#   $2 (Integer) - The index
# Returns:
#   0 - Removed, or the index was outside the array
#   Exits 1 when no array is named, or the index is not a number
#######################################
stealth::util::list::remove_at() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    stealth::util::assert::is_int "${2:-}" "an index is a whole number, not ${2:-}"
    local -n _list_rmat_ref="${1}"
    local -ri _list_rmat_index="${2}"

    if (( _list_rmat_index < 0 || _list_rmat_index >= ${#_list_rmat_ref[@]} )); then
        return 0
    fi

    local -a _list_rmat_kept=("${_list_rmat_ref[@]:0:_list_rmat_index}")
    _list_rmat_kept+=("${_list_rmat_ref[@]:_list_rmat_index + 1}")
    _list_rmat_ref=("${_list_rmat_kept[@]}")
    return 0
}

# =============================================================================
# ORDER
# =============================================================================

#######################################
# Removes the elements that appear more than once, keeping the first of each.
# The order of what is left does not change, because a load order and a search
# path mean nothing sorted.
#
# Usage:
#   stealth::util::list::unique deps
#
# Arguments:
#   $1 (String) - The name of the array
# Returns:
#   0 - Deduplicated
#   Exits 1 when no array is named
#######################################
stealth::util::list::unique() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_uniq_ref="${1}"

    local -A _list_uniq_seen=()
    local -a _list_uniq_kept=()
    local _list_uniq_item
    for _list_uniq_item in "${_list_uniq_ref[@]}"; do
        if [[ -z "${_list_uniq_seen[${_list_uniq_item}]:-}" ]]; then
            _list_uniq_seen["${_list_uniq_item}"]=1
            _list_uniq_kept+=("${_list_uniq_item}")
        fi
    done

    _list_uniq_ref=("${_list_uniq_kept[@]}")
    return 0
}

#######################################
# Reverses the order of an array.
#
# Usage:
#   stealth::util::list::reverse loaded
#
# Arguments:
#   $1 (String) - The name of the array
# Returns:
#   0 - Reversed
#   Exits 1 when no array is named
#######################################
stealth::util::list::reverse() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_rev_ref="${1}"

    local -a _list_rev_out=()
    local -i _list_rev_i
    for (( _list_rev_i = ${#_list_rev_ref[@]} - 1; _list_rev_i >= 0; _list_rev_i-- )); do
        _list_rev_out+=("${_list_rev_ref[_list_rev_i]}")
    done

    _list_rev_ref=("${_list_rev_out[@]}")
    return 0
}

#######################################
# Sorts an array by byte value, so the order is the same on every machine and
# in every locale. A build that writes a sorted list produces the same bytes
# for the same input.
#
# An element that holds a line break is refused, because the sort reads one
# element per line.
#
# Usage:
#   stealth::util::list::sort files
#
# Arguments:
#   $1 (String) - The name of the array
# Returns:
#   0 - Sorted
#   Exits 1 when no array is named, an element holds a line break, or the
#   sort itself failed
#######################################
stealth::util::list::sort() {
    stealth::util::assert::not_empty "${1:-}" 'the name of an array is required'
    local -n _list_sort_ref="${1}"

    if (( ${#_list_sort_ref[@]} < 2 )); then
        return 0
    fi

    local _list_sort_item
    for _list_sort_item in "${_list_sort_ref[@]}"; do
        stealth::util::assert::match "${_list_sort_item}" '^[^'$'\n'']*$' \
            "an element to sort holds a line break: ${_list_sort_item}"
    done

    local _list_sort_lines _list_sort_sorted
    printf -v _list_sort_lines '%s\n' "${_list_sort_ref[@]}"

    # The status is read here rather than lost inside a process substitution.
    if ! _list_sort_sorted="$(LC_ALL=C sort <<< "${_list_sort_lines%$'\n'}")"; then
        stealth::util::log::error 'sorting %d elements failed' "${#_list_sort_ref[@]}"
    fi

    mapfile -t _list_sort_ref <<< "${_list_sort_sorted}"
    return 0
}

# =============================================================================
# SETS
# =============================================================================

#######################################
# Collects the elements of the first array that the second does not hold, in
# the order of the first. It answers which dependencies are still missing.
#
# Usage:
#   stealth::util::list::difference missing required built
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name of the array to take from
#   $3 (String)  - The name of the array to take away
# Returns:
#   0 - Collected
#   Exits 1 when an output variable or an array is not named
#######################################
stealth::util::list::difference() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'the name of an array is required'
    stealth::util::assert::not_empty "${3:-}" 'the name of a second array is required'
    local -n _list_diff_out="${1}"
    local -n _list_diff_from="${2}"
    local -r _list_diff_without="${3}"

    local -a _list_diff_kept=()
    local _list_diff_item
    for _list_diff_item in "${_list_diff_from[@]}"; do
        if ! stealth::util::list::contains "${_list_diff_without}" "${_list_diff_item}"; then
            _list_diff_kept+=("${_list_diff_item}")
        fi
    done

    _list_diff_out=("${_list_diff_kept[@]}")
    return 0
}

#######################################
# Collects the elements both arrays hold, in the order of the first.
#
# Usage:
#   stealth::util::list::intersection shared required available
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name of the first array
#   $3 (String)  - The name of the second array
# Returns:
#   0 - Collected
#   Exits 1 when an output variable or an array is not named
#######################################
stealth::util::list::intersection() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'the name of an array is required'
    stealth::util::assert::not_empty "${3:-}" 'the name of a second array is required'
    local -n _list_int_out="${1}"
    local -n _list_int_first="${2}"
    local -r _list_int_second="${3}"

    local -a _list_int_kept=()
    local _list_int_item
    for _list_int_item in "${_list_int_first[@]}"; do
        if stealth::util::list::contains "${_list_int_second}" "${_list_int_item}"; then
            _list_int_kept+=("${_list_int_item}")
        fi
    done

    _list_int_out=("${_list_int_kept[@]}")
    return 0
}
