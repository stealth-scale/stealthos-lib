###############################################################################
# module: util/semver
# layer: util
# description: Reading and ordering versions that follow Semantic Versioning
#              2.0.0, and testing one against a constraint.
#
#              A version that does not follow the grammar ends the process.
#              The old module read what it could out of anything, so it
#              treated banana as 0.0.0 and answered a comparison against it,
#              which is how a build picks the wrong toolchain and says
#              nothing.
#
#              Alphanumeric identifiers are ordered by byte, as the
#              specification requires. A shell compares strings by the rules
#              of the locale, where a sorts before B, so this module reads the
#              bytes itself.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_SEMVER:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_SEMVER=1

stealth::util::import "util/assert"

# =============================================================================
# CONSTANTS
# =============================================================================

# The grammar of semver.org 2.0.0, as one extended regular expression. Bash
# has no group that does not capture, so the parts are numbered: 1 major,
# 2 minor, 3 patch, 5 pre-release, 10 build.
declare -gr _STEALTH_UTIL_SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*)(\.(0|[1-9][0-9]*|[0-9]*[a-zA-Z-][0-9a-zA-Z-]*))*))?(\+([0-9a-zA-Z-]+(\.[0-9a-zA-Z-]+)*))?$'

declare -gri _STEALTH_UTIL_SEMVER_GROUP_MAJOR=1
declare -gri _STEALTH_UTIL_SEMVER_GROUP_MINOR=2
declare -gri _STEALTH_UTIL_SEMVER_GROUP_PATCH=3
declare -gri _STEALTH_UTIL_SEMVER_GROUP_PRE=5
declare -gri _STEALTH_UTIL_SEMVER_GROUP_BUILD=10

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Splits a version into its five parts. A version that does not follow the
# grammar ends the process, so every function above this one reads parts that
# are known to be good.
#
# Usage:
#   stealth::util::semver::_split maj min pat pre bld '1.2.3-rc.1+build'
#
# Arguments:
#   $1 (Nameref) - The output variable for the major number
#   $2 (Nameref) - The output variable for the minor number
#   $3 (Nameref) - The output variable for the patch number
#   $4 (Nameref) - The output variable for the pre-release, empty when none
#   $5 (Nameref) - The output variable for the build metadata, empty when none
#   $6 (String)  - The version
# Globals:
#   _STEALTH_UTIL_SEMVER_RE (Read)
#   _STEALTH_UTIL_SEMVER_GROUP_MAJOR (Read)
#   _STEALTH_UTIL_SEMVER_GROUP_MINOR (Read)
#   _STEALTH_UTIL_SEMVER_GROUP_PATCH (Read)
#   _STEALTH_UTIL_SEMVER_GROUP_PRE (Read)
#   _STEALTH_UTIL_SEMVER_GROUP_BUILD (Read)
# Returns:
#   0 - Split
#   Exits 1 when the version does not follow the grammar
#######################################
stealth::util::semver::_split() {
    local -n _semver_split_major="${1}"
    local -n _semver_split_minor="${2}"
    local -n _semver_split_patch="${3}"
    local -n _semver_split_pre="${4}"
    local -n _semver_split_build="${5}"
    local -r _semver_split_version="${6:-}"

    if [[ ! "${_semver_split_version}" =~ ${_STEALTH_UTIL_SEMVER_RE} ]]; then
        stealth::util::assert::fail \
            "a version follows semver 2.0.0, and ${_semver_split_version} does not"
    fi

    _semver_split_major="${BASH_REMATCH[_STEALTH_UTIL_SEMVER_GROUP_MAJOR]}"
    _semver_split_minor="${BASH_REMATCH[_STEALTH_UTIL_SEMVER_GROUP_MINOR]}"
    _semver_split_patch="${BASH_REMATCH[_STEALTH_UTIL_SEMVER_GROUP_PATCH]}"
    _semver_split_pre="${BASH_REMATCH[_STEALTH_UTIL_SEMVER_GROUP_PRE]}"
    _semver_split_build="${BASH_REMATCH[_STEALTH_UTIL_SEMVER_GROUP_BUILD]}"
    return 0
}

#######################################
# Orders two strings by the bytes they are made of, which is what the
# specification asks for and what a shell comparison does not do.
#
# Usage:
#   stealth::util::semver::_compare_text order alpha beta
#
# Arguments:
#   $1 (Nameref) - The output variable: -1, 0 or 1
#   $2 (String)  - The first string
#   $3 (String)  - The second string
# Returns:
#   0 - Ordered
#######################################
stealth::util::semver::_compare_text() {
    local -n _semver_ctext_out="${1}"
    local -r _semver_ctext_a="${2}"
    local -r _semver_ctext_b="${3}"
    local -i _semver_ctext_i _semver_ctext_byte_a _semver_ctext_byte_b

    for (( _semver_ctext_i = 0; ; _semver_ctext_i++ )); do
        if (( _semver_ctext_i >= ${#_semver_ctext_a} )); then
            if (( _semver_ctext_i >= ${#_semver_ctext_b} )); then
                _semver_ctext_out=0
            else
                _semver_ctext_out=-1
            fi
            return 0
        fi
        if (( _semver_ctext_i >= ${#_semver_ctext_b} )); then
            _semver_ctext_out=1
            return 0
        fi

        printf -v _semver_ctext_byte_a '%d' "'${_semver_ctext_a:_semver_ctext_i:1}"
        printf -v _semver_ctext_byte_b '%d' "'${_semver_ctext_b:_semver_ctext_i:1}"

        if (( _semver_ctext_byte_a < _semver_ctext_byte_b )); then
            _semver_ctext_out=-1
            return 0
        fi
        if (( _semver_ctext_byte_a > _semver_ctext_byte_b )); then
            _semver_ctext_out=1
            return 0
        fi
    done
}

#######################################
# Orders two numbers written as text. Each one is read in base ten, so a
# leading zero cannot turn it into an octal number.
#
# Usage:
#   stealth::util::semver::_compare_number order 11 2
#
# Arguments:
#   $1 (Nameref) - The output variable: -1, 0 or 1
#   $2 (String)  - The first number
#   $3 (String)  - The second number
# Returns:
#   0 - Ordered
#######################################
stealth::util::semver::_compare_number() {
    local -n _semver_cnum_out="${1}"
    local -ri _semver_cnum_a="10#${2}"
    local -ri _semver_cnum_b="10#${3}"

    if (( _semver_cnum_a < _semver_cnum_b )); then
        _semver_cnum_out=-1
    elif (( _semver_cnum_a > _semver_cnum_b )); then
        _semver_cnum_out=1
    else
        _semver_cnum_out=0
    fi
    return 0
}

#######################################
# Orders two pre-release identifiers. A number is worth less than a word, two
# numbers go by value, and two words go by byte.
#
# Usage:
#   stealth::util::semver::_compare_part order 1 alpha
#
# Arguments:
#   $1 (Nameref) - The output variable: -1, 0 or 1
#   $2 (String)  - The first identifier
#   $3 (String)  - The second identifier
# Returns:
#   0 - Ordered
#######################################
stealth::util::semver::_compare_part() {
    local -n _semver_cpart_out="${1}"
    local -r _semver_cpart_a="${2}"
    local -r _semver_cpart_b="${3}"

    local -i _semver_cpart_num_a=0 _semver_cpart_num_b=0
    if [[ "${_semver_cpart_a}" =~ ^[0-9]+$ ]]; then _semver_cpart_num_a=1; fi
    if [[ "${_semver_cpart_b}" =~ ^[0-9]+$ ]]; then _semver_cpart_num_b=1; fi

    if (( _semver_cpart_num_a == 1 && _semver_cpart_num_b == 1 )); then
        stealth::util::semver::_compare_number _semver_cpart_out \
            "${_semver_cpart_a}" "${_semver_cpart_b}"
        return 0
    fi

    if (( _semver_cpart_num_a == 1 )); then
        _semver_cpart_out=-1
        return 0
    fi
    if (( _semver_cpart_num_b == 1 )); then
        _semver_cpart_out=1
        return 0
    fi

    stealth::util::semver::_compare_text _semver_cpart_out \
        "${_semver_cpart_a}" "${_semver_cpart_b}"
    return 0
}

#######################################
# Orders two pre-release strings, one dotted identifier at a time. When one
# runs out of identifiers first and everything before matched, it is the
# smaller of the two.
#
# Usage:
#   stealth::util::semver::_compare_pre order 'rc.1' 'rc.2'
#
# Arguments:
#   $1 (Nameref) - The output variable: -1, 0 or 1
#   $2 (String)  - The first pre-release
#   $3 (String)  - The second pre-release
# Returns:
#   0 - Ordered
#######################################
stealth::util::semver::_compare_pre() {
    local -n _semver_cpre_out="${1}"
    local -a _semver_cpre_parts_a=() _semver_cpre_parts_b=()
    local _semver_cpre_rest

    _semver_cpre_rest="${2}"
    while [[ "${_semver_cpre_rest}" == *.* ]]; do
        _semver_cpre_parts_a+=("${_semver_cpre_rest%%.*}")
        _semver_cpre_rest="${_semver_cpre_rest#*.}"
    done
    _semver_cpre_parts_a+=("${_semver_cpre_rest}")

    _semver_cpre_rest="${3}"
    while [[ "${_semver_cpre_rest}" == *.* ]]; do
        _semver_cpre_parts_b+=("${_semver_cpre_rest%%.*}")
        _semver_cpre_rest="${_semver_cpre_rest#*.}"
    done
    _semver_cpre_parts_b+=("${_semver_cpre_rest}")

    local -i _semver_cpre_i
    for (( _semver_cpre_i = 0; ; _semver_cpre_i++ )); do
        if (( _semver_cpre_i >= ${#_semver_cpre_parts_a[@]} )); then
            if (( _semver_cpre_i >= ${#_semver_cpre_parts_b[@]} )); then
                _semver_cpre_out=0
            else
                _semver_cpre_out=-1
            fi
            return 0
        fi
        if (( _semver_cpre_i >= ${#_semver_cpre_parts_b[@]} )); then
            _semver_cpre_out=1
            return 0
        fi

        stealth::util::semver::_compare_part _semver_cpre_out \
            "${_semver_cpre_parts_a[_semver_cpre_i]}" \
            "${_semver_cpre_parts_b[_semver_cpre_i]}"
        if (( _semver_cpre_out != 0 )); then
            return 0
        fi
    done
}

# =============================================================================
# READING A VERSION
# =============================================================================

#######################################
# Reports whether a value follows the grammar. It answers rather than ends the
# process, so a caller can test a value it did not choose.
#
# Usage:
#   if ! stealth::util::semver::is_valid "${tag}"; then continue; fi
#
# Arguments:
#   $1 (String) - The value
# Globals:
#   _STEALTH_UTIL_SEMVER_RE (Read)
# Returns:
#   0 - It follows the grammar
#   1 - It does not
#######################################
stealth::util::semver::is_valid() {
    [[ "${1:-}" =~ ${_STEALTH_UTIL_SEMVER_RE} ]]
}

#######################################
# Reads the major number of a version.
#
# Usage:
#   stealth::util::semver::major api "${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The version
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the version is not valid
#######################################
stealth::util::semver::major() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_major_out="${1}"
    local _semver_major_minor _semver_major_patch
    local _semver_major_pre _semver_major_build

    stealth::util::semver::_split _semver_major_out _semver_major_minor \
        _semver_major_patch _semver_major_pre _semver_major_build "${2:-}"
    return 0
}

#######################################
# Reads the minor number of a version.
#
# Usage:
#   stealth::util::semver::minor level "${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The version
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the version is not valid
#######################################
stealth::util::semver::minor() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_minor_out="${1}"
    local _semver_minor_major _semver_minor_patch
    local _semver_minor_pre _semver_minor_build

    stealth::util::semver::_split _semver_minor_major _semver_minor_out \
        _semver_minor_patch _semver_minor_pre _semver_minor_build "${2:-}"
    return 0
}

#######################################
# Reads the patch number of a version.
#
# Usage:
#   stealth::util::semver::patch fix "${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The version
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the version is not valid
#######################################
stealth::util::semver::patch() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_patch_out="${1}"
    local _semver_patch_major _semver_patch_minor
    local _semver_patch_pre _semver_patch_build

    stealth::util::semver::_split _semver_patch_major _semver_patch_minor \
        _semver_patch_out _semver_patch_pre _semver_patch_build "${2:-}"
    return 0
}

#######################################
# Reads the pre-release of a version, and empty when it has none.
#
# Usage:
#   stealth::util::semver::prerelease stage "${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The version
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the version is not valid
#######################################
stealth::util::semver::prerelease() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_pre_out="${1}"
    local _semver_pre_major _semver_pre_minor _semver_pre_patch _semver_pre_build

    stealth::util::semver::_split _semver_pre_major _semver_pre_minor \
        _semver_pre_patch _semver_pre_out _semver_pre_build "${2:-}"
    return 0
}

#######################################
# Reads the build metadata of a version, and empty when it has none. Build
# metadata takes no part in ordering.
#
# Usage:
#   stealth::util::semver::build commit "${version}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The version
# Returns:
#   0 - Read
#   Exits 1 when no output variable is given, or the version is not valid
#######################################
stealth::util::semver::build() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_build_out="${1}"
    local _semver_build_major _semver_build_minor
    local _semver_build_patch _semver_build_pre

    stealth::util::semver::_split _semver_build_major _semver_build_minor \
        _semver_build_patch _semver_build_pre _semver_build_out "${2:-}"
    return 0
}

#######################################
# Reports whether a version carries a pre-release.
#
# Usage:
#   if stealth::util::semver::is_prerelease "${version}"; then ...
#
# Arguments:
#   $1 (String) - The version
# Returns:
#   0 - It carries one
#   1 - It does not
#   Exits 1 when the version is not valid
#######################################
stealth::util::semver::is_prerelease() {
    local _semver_ispre_value

    stealth::util::semver::prerelease _semver_ispre_value "${1:-}"
    [[ -n "${_semver_ispre_value}" ]]
}

#######################################
# Reports whether a version is a release rather than a pre-release.
#
# Usage:
#   if stealth::util::semver::is_stable "${version}"; then ...
#
# Arguments:
#   $1 (String) - The version
# Returns:
#   0 - It is a release
#   1 - It carries a pre-release
#   Exits 1 when the version is not valid
#######################################
stealth::util::semver::is_stable() {
    local _semver_stable_value

    stealth::util::semver::prerelease _semver_stable_value "${1:-}"
    [[ -z "${_semver_stable_value}" ]]
}

# =============================================================================
# ORDERING
# =============================================================================

#######################################
# Orders two versions. Build metadata is left out, so 1.0.0+a and 1.0.0+b are
# the same version, and a pre-release comes before the release it leads to.
#
# Usage:
#   stealth::util::semver::compare order "${have}" "${want}"
#   if (( order < 0 )); then ...
#
# Arguments:
#   $1 (Nameref) - The output variable: -1 when the first is lower, 0 when
#                  they are the same, 1 when the first is higher
#   $2 (String)  - The first version
#   $3 (String)  - The second version
# Returns:
#   0 - Ordered
#   Exits 1 when no output variable is given, or a version is not valid
#######################################
stealth::util::semver::compare() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_cmp_out="${1}"

    local _semver_cmp_major_a _semver_cmp_minor_a _semver_cmp_patch_a
    local _semver_cmp_pre_a _semver_cmp_build_a
    local _semver_cmp_major_b _semver_cmp_minor_b _semver_cmp_patch_b
    local _semver_cmp_pre_b _semver_cmp_build_b

    stealth::util::semver::_split _semver_cmp_major_a _semver_cmp_minor_a \
        _semver_cmp_patch_a _semver_cmp_pre_a _semver_cmp_build_a "${2:-}"
    stealth::util::semver::_split _semver_cmp_major_b _semver_cmp_minor_b \
        _semver_cmp_patch_b _semver_cmp_pre_b _semver_cmp_build_b "${3:-}"

    stealth::util::semver::_compare_number _semver_cmp_out \
        "${_semver_cmp_major_a}" "${_semver_cmp_major_b}"
    if (( _semver_cmp_out != 0 )); then return 0; fi

    stealth::util::semver::_compare_number _semver_cmp_out \
        "${_semver_cmp_minor_a}" "${_semver_cmp_minor_b}"
    if (( _semver_cmp_out != 0 )); then return 0; fi

    stealth::util::semver::_compare_number _semver_cmp_out \
        "${_semver_cmp_patch_a}" "${_semver_cmp_patch_b}"
    if (( _semver_cmp_out != 0 )); then return 0; fi

    if [[ -z "${_semver_cmp_pre_a}" && -z "${_semver_cmp_pre_b}" ]]; then
        _semver_cmp_out=0
        return 0
    fi
    if [[ -z "${_semver_cmp_pre_a}" ]]; then
        _semver_cmp_out=1
        return 0
    fi
    if [[ -z "${_semver_cmp_pre_b}" ]]; then
        _semver_cmp_out=-1
        return 0
    fi

    stealth::util::semver::_compare_pre _semver_cmp_out \
        "${_semver_cmp_pre_a}" "${_semver_cmp_pre_b}"
    return 0
}

#######################################
# Reports whether two versions are the same, build metadata left out.
#
# Usage:
#   if stealth::util::semver::eq "${have}" "${want}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - The same
#   1 - Not the same
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::eq() {
    local -i _semver_eq_order

    stealth::util::semver::compare _semver_eq_order "${1:-}" "${2:-}"
    (( _semver_eq_order == 0 ))
}

#######################################
# Reports whether two versions differ, build metadata left out.
#
# Usage:
#   if stealth::util::semver::ne "${have}" "${pinned}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - They differ
#   1 - They are the same
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::ne() {
    local -i _semver_ne_order

    stealth::util::semver::compare _semver_ne_order "${1:-}" "${2:-}"
    (( _semver_ne_order != 0 ))
}

#######################################
# Reports whether the first version is lower than the second.
#
# Usage:
#   if stealth::util::semver::lt "${have}" "${minimum}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - It is lower
#   1 - It is not
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::lt() {
    local -i _semver_lt_order

    stealth::util::semver::compare _semver_lt_order "${1:-}" "${2:-}"
    (( _semver_lt_order < 0 ))
}

#######################################
# Reports whether the first version is lower than the second or the same.
#
# Usage:
#   if stealth::util::semver::lte "${have}" "${highest}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - It is lower or the same
#   1 - It is higher
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::lte() {
    local -i _semver_lte_order

    stealth::util::semver::compare _semver_lte_order "${1:-}" "${2:-}"
    (( _semver_lte_order <= 0 ))
}

#######################################
# Reports whether the first version is higher than the second.
#
# Usage:
#   if stealth::util::semver::gt "${have}" "${previous}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - It is higher
#   1 - It is not
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::gt() {
    local -i _semver_gt_order

    stealth::util::semver::compare _semver_gt_order "${1:-}" "${2:-}"
    (( _semver_gt_order > 0 ))
}

#######################################
# Reports whether the first version is higher than the second or the same.
#
# Usage:
#   if stealth::util::semver::gte "${have}" "${minimum}"; then ...
#
# Arguments:
#   $1 (String) - The first version
#   $2 (String) - The second version
# Returns:
#   0 - It is higher or the same
#   1 - It is lower
#   Exits 1 when a version is not valid
#######################################
stealth::util::semver::gte() {
    local -i _semver_gte_order

    stealth::util::semver::compare _semver_gte_order "${1:-}" "${2:-}"
    (( _semver_gte_order >= 0 ))
}

#######################################
# Finds the highest of the versions.
#
# Usage:
#   stealth::util::semver::newest latest "${tags[@]}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - The versions, at least one
# Returns:
#   0 - Found
#   Exits 1 when no output variable or no version is given, or a version is
#   not valid
#######################################
stealth::util::semver::newest() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _semver_new_out="${1}"
    shift

    stealth::util::assert::not_empty "${1:-}" 'at least one version is required'

    _semver_new_out="${1}"
    local _semver_new_candidate
    local -i _semver_new_order
    for _semver_new_candidate in "$@"; do
        stealth::util::semver::compare _semver_new_order \
            "${_semver_new_candidate}" "${_semver_new_out}"
        if (( _semver_new_order > 0 )); then
            _semver_new_out="${_semver_new_candidate}"
        fi
    done
    return 0
}

# =============================================================================
# CONSTRAINTS
# =============================================================================

#######################################
# Tests a version against a constraint. A constraint is a comparison sign and
# a version: >=1.2.0, >1.2.0, <=1.2.0, <1.2.0, =1.2.0, !=1.2.0. A constraint
# with no sign asks for that version exactly.
#
# A range and the caret and tilde shorthands are not read. A host requirement
# is a floor, and a floor is what this answers.
#
# Usage:
#   if ! stealth::util::semver::satisfies "${gcc}" '>=13.0.0'; then
#       stealth::util::log::error 'gcc 13 or newer is required, found %s' "${gcc}"
#   fi
#
# Arguments:
#   $1 (String) - The version
#   $2 (String) - The constraint
# Returns:
#   0 - The version satisfies the constraint
#   1 - It does not
#   Exits 1 when the version or the constraint is not valid
#######################################
stealth::util::semver::satisfies() {
    stealth::util::assert::not_empty "${2:-}" 'a constraint is required'

    local -r _semver_sat_version="${1:-}"
    local _semver_sat_rest="${2}"
    local _semver_sat_sign='='

    if [[ "${_semver_sat_rest}" =~ ^(\>=|\<=|!=|==|\>|\<|=) ]]; then
        _semver_sat_sign="${BASH_REMATCH[1]}"
        _semver_sat_rest="${_semver_sat_rest#"${_semver_sat_sign}"}"
    fi
    if [[ "${_semver_sat_sign}" == '==' ]]; then
        _semver_sat_sign='='
    fi

    local -i _semver_sat_order
    stealth::util::semver::compare _semver_sat_order \
        "${_semver_sat_version}" "${_semver_sat_rest}"

    # An equals sign, and a constraint with no sign at all, end up here.
    if [[ "${_semver_sat_sign}" == '!=' ]]; then
        (( _semver_sat_order != 0 ))
    elif [[ "${_semver_sat_sign}" == '>' ]]; then
        (( _semver_sat_order > 0 ))
    elif [[ "${_semver_sat_sign}" == '>=' ]]; then
        (( _semver_sat_order >= 0 ))
    elif [[ "${_semver_sat_sign}" == '<' ]]; then
        (( _semver_sat_order < 0 ))
    elif [[ "${_semver_sat_sign}" == '<=' ]]; then
        (( _semver_sat_order <= 0 ))
    else
        (( _semver_sat_order == 0 ))
    fi
}
