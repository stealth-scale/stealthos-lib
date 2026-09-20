###############################################################################
# module: sys/runtime/hash
# layer: sys
# description: Digests of files and of strings.
#
#              A digest is how this library names a thing it did not make. A
#              downloaded tarball is trusted because its digest is the one the
#              upstream published, and a layer is stored under the digest of
#              its tar. Both readings have to agree with the tool at the other
#              end, which is what the two rules here are for.
#
#              The first rule is that the algorithm is never guessed. A digest
#              of 64 characters is a sha256, and it is also the front half of
#              a sha512 someone truncated. An expected value carries its
#              algorithm in front of it, as sha256:, the way an image manifest
#              writes it, or the caller says which one it means.
#
#              The second is that a string is hashed as the caller wrote it.
#              Reading a string into a command with a here-string appends a
#              newline to it, so the digest comes back as the digest of
#              something the caller never passed.
#
#              md5 is here because Linux From Scratch publishes md5sums for
#              its sources and nothing better. Nothing this library makes
#              itself is named by one.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_HASH:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_HASH=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd"

# =============================================================================
# CONSTANTS
# =============================================================================

# Each algorithm against the coreutils program that computes it. There is no
# fallback to openssl or to shasum: this library runs on a Linux with
# coreutils, and a fallback no test can reach is a fallback that does not
# work. Written on one line because kcov counts the lines of a declaration
# that spans several as never run.
declare -grA _STEALTH_SYS_RUNTIME_HASH_TOOL=([md5]=md5sum [sha256]=sha256sum [sha512]=sha512sum)

# The algorithm used when the caller does not say.
declare -gr _STEALTH_SYS_RUNTIME_HASH_DEFAULT='sha256'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Runs the program for an algorithm and keeps the digest it printed, which is
# the first field of a line whose second field names what was read.
#
# Usage:
#   stealth::sys::runtime::hash::_run sum sha256 "${path}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The algorithm
#   $3 (String)  - What to read, as a path the program can open
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_TOOL (Read)
# Returns:
#   0 - Computed
#   Exits 1 when the algorithm is not one of the three, or the program failed
#######################################
stealth::sys::runtime::hash::_run() {
    local -n _hash_run_out="${1}"

    if ! stealth::sys::runtime::hash::is_algo "${2}"; then
        stealth::util::assert::fail "nothing here computes a ${2} digest"
    fi

    local _hash_run_line
    if ! stealth::sys::cmd::capture _hash_run_line \
        "${_STEALTH_SYS_RUNTIME_HASH_TOOL[${2}]}" "${3}"; then
        stealth::util::log::error 'no %s digest could be computed for %s' "${2}" "${3}"
    fi

    _hash_run_out="${_hash_run_line%% *}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether an algorithm is one this module computes.
#
# Usage:
#   if ! stealth::sys::runtime::hash::is_algo "${named}"; then ...
#
# Arguments:
#   $1 (String) - The algorithm
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_TOOL (Read)
# Returns:
#   0 - It is
#   1 - It is not
#######################################
stealth::sys::runtime::hash::is_algo() {
    [[ -v _STEALTH_SYS_RUNTIME_HASH_TOOL["${1:-}"] ]]
}

#######################################
# Computes the digest of a file.
#
# Usage:
#   stealth::sys::runtime::hash::file sum "${tarball}"
#   stealth::sys::runtime::hash::file sum "${tarball}" sha512
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The algorithm. Default: sha256
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_DEFAULT (Read)
# Returns:
#   0 - Computed
#   Exits 1 when no output variable is given, the file is not there, or the
#   algorithm is not one of the three
#######################################
stealth::sys::runtime::hash::file() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to hash at ${2:-}"

    stealth::sys::runtime::hash::_run "${1}" \
        "${3:-${_STEALTH_SYS_RUNTIME_HASH_DEFAULT}}" "${2}"
    return 0
}

#######################################
# Computes the digest of a string, of exactly the bytes the caller passed.
#
# The string reaches the program down a pipe named as a file, rather than on
# standard input through a here-string. A here-string appends a newline, and
# the digest of a string with a newline after it agrees with nothing.
#
# Usage:
#   stealth::sys::runtime::hash::string key "${url}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The string. An empty one is a string too
#   $3 (String)  - The algorithm. Default: sha256
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_DEFAULT (Read)
# Returns:
#   0 - Computed
#   Exits 1 when no output variable is given, or the algorithm is not one of
#   the three
#######################################
stealth::sys::runtime::hash::string() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    stealth::sys::runtime::hash::_run "${1}" \
        "${3:-${_STEALTH_SYS_RUNTIME_HASH_DEFAULT}}" \
        <(printf '%s' "${2:-}")
    return 0
}

#######################################
# Computes the digest of a file and gives it back with its algorithm in
# front, which is how an image manifest and this module's own verify both
# want to read it.
#
# Usage:
#   stealth::sys::runtime::hash::digest name "${layer}"   # sha256:2cf24d...
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The algorithm. Default: sha256
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_DEFAULT (Read)
# Returns:
#   0 - Computed
#   Exits 1 when no output variable is given, the file is not there, or the
#   algorithm is not one of the three
#######################################
stealth::sys::runtime::hash::digest() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _hash_dig_out="${1}"

    local -r _hash_dig_algo="${3:-${_STEALTH_SYS_RUNTIME_HASH_DEFAULT}}"
    local _hash_dig_sum
    stealth::sys::runtime::hash::file _hash_dig_sum "${2:-}" "${_hash_dig_algo}"

    _hash_dig_out="${_hash_dig_algo}:${_hash_dig_sum}"
    return 0
}

#######################################
# Takes an expected value apart into the algorithm it names and the digest
# itself. A value with nothing in front of it is read as the algorithm the
# caller gives, and sha256 when the caller gives none.
#
# Nothing is inferred from how long the value is. A value of 64 characters is
# a sha256 and is also the first half of a sha512, and a module that guesses
# between them reports a file as verified against half of its own digest.
#
# Usage:
#   stealth::sys::runtime::hash::split algo sum 'sha512:9b71d2...'
#   stealth::sys::runtime::hash::split algo sum "${bare}" md5
#
# Arguments:
#   $1 (Nameref) - The output variable for the algorithm
#   $2 (Nameref) - The output variable for the digest
#   $3 (String)  - The expected value, with or without an algorithm in front
#   $4 (String)  - The algorithm to assume when it carries none. Default:
#                  sha256
# Globals:
#   _STEALTH_SYS_RUNTIME_HASH_DEFAULT (Read)
# Returns:
#   0 - Taken apart
#   Exits 1 when an output variable or the value is missing, or the algorithm
#   is not one of the three
#######################################
stealth::sys::runtime::hash::split() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a second output variable is required'
    stealth::util::assert::not_empty "${3:-}" 'a digest to take apart is required'
    local -n _hash_spl_algo="${1}"
    local -n _hash_spl_sum="${2}"

    if [[ "${3}" == *:* ]]; then
        _hash_spl_algo="${3%%:*}"
        _hash_spl_sum="${3#*:}"
    else
        _hash_spl_algo="${4:-${_STEALTH_SYS_RUNTIME_HASH_DEFAULT}}"
        _hash_spl_sum="${3}"
    fi

    if ! stealth::sys::runtime::hash::is_algo "${_hash_spl_algo}"; then
        stealth::util::assert::fail \
            "nothing here computes a ${_hash_spl_algo} digest"
    fi
    return 0
}

#######################################
# Reports whether a file has the digest it is expected to have. This is the
# check a download passes before anything is done with it.
#
# The comparison ignores the case of the expected value, because an upstream
# that publishes its digests in capitals means the same digest.
#
# Usage:
#   if ! stealth::sys::runtime::hash::verify "${file}" "${wanted}"; then ...
#   stealth::sys::runtime::hash::verify "${file}" "${bare}" md5
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The expected value, with or without an algorithm in front
#   $3 (String) - The algorithm to assume when it carries none. Default:
#                 sha256
# Returns:
#   0 - It has that digest
#   1 - It has another one
#   Exits 1 when the file or the expected value is missing, the file is not
#   there, or the algorithm is not one of the three
#######################################
stealth::sys::runtime::hash::verify() {
    stealth::util::assert::is_file "${1:-}" "no file to verify at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a digest to verify against is required'

    local _hash_ver_algo _hash_ver_want
    stealth::sys::runtime::hash::split _hash_ver_algo _hash_ver_want \
        "${2}" "${3:-}"

    local _hash_ver_got
    stealth::sys::runtime::hash::file _hash_ver_got "${1}" "${_hash_ver_algo}"

    if [[ "${_hash_ver_got}" == "${_hash_ver_want,,}" ]]; then
        stealth::util::log::trace '%s has the %s digest it should' \
            "${1}" "${_hash_ver_algo}"
        return 0
    fi

    stealth::util::log::debug '%s has %s digest %s, not %s' \
        "${1}" "${_hash_ver_algo}" "${_hash_ver_got}" "${_hash_ver_want,,}"
    return 1
}
