###############################################################################
# module: sys/crypto
# layer: sys
# description: Random values, for the things a build has to invent: a
#              password, a key, an identifier.
#
#              Everything here comes from /dev/urandom and nothing here needs
#              openssl. A node that has to install a cryptography toolkit
#              before it can make a password is a node carrying a dependency
#              for one line of work, and the kernel already has the only
#              source worth using.
#
#              A password is drawn by throwing away the bytes that are not
#              letters or digits, rather than by folding every byte into the
#              alphabet. Folding makes the first few characters of the
#              alphabet more likely than the last few, which is a smaller
#              password than the one the caller asked for.
#
#              Nothing here takes a secret as an argument. A key is written
#              to a file, and the file is never readable by anyone else, not
#              even for the moment between being made and being filled.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_CRYPTO:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_CRYPTO=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where randomness comes from. urandom and random draw on the same pool once
# the kernel has seeded it, and urandom does not block.
declare -g STEALTH_CRYPTO_SOURCE='/dev/urandom'

# Where the kernel hands out identifiers. Reading it costs no fork.
declare -g STEALTH_CRYPTO_UUID_SOURCE='/proc/sys/kernel/random/uuid'

# What a password is drawn from.
declare -gr _STEALTH_SYS_CRYPTO_ALPHABET='A-Za-z0-9'

# How long a password is when the caller does not say, and how big a key file
# is. Both are what the thing asking for them usually wants.
declare -gri _STEALTH_SYS_CRYPTO_PASSWORD_LENGTH=24
declare -gri _STEALTH_SYS_CRYPTO_KEY_SIZE=4096

# The mode a key file is made with and kept at.
declare -gr _STEALTH_SYS_CRYPTO_KEY_MODE='0600'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Refuses a count that is not a whole number above zero.
#
# Usage:
#   stealth::sys::crypto::_count 32 'a number of bytes'
#
# Arguments:
#   $1 (String) - The count
#   $2 (String) - What it counts, for the message
# Returns:
#   0 - It is usable
#   Exits 1 when it is not
#######################################
stealth::sys::crypto::_count() {
    stealth::util::assert::is_int "${1}" "${2} is a whole number, not ${1}"

    if (( ${1} <= 0 )); then
        stealth::util::assert::fail "${2} is above zero, not ${1}"
    fi
    return 0
}

#######################################
# Refuses a value that came back shorter than it should have.
#
# A command reading the random source inside a process substitution can fail
# without the command consuming it failing: base64 given nothing succeeds and
# prints nothing. An empty secret that nobody notices is worse than no secret
# at all, so the length is counted before the value goes back.
#
# Usage:
#   stealth::sys::crypto::_full "${value}" 32 'random bytes'
#
# Arguments:
#   $1 (String)  - The value
#   $2 (Integer) - How many characters it should have
#   $3 (String)  - What it is, for the message
# Returns:
#   0 - It is that long
#   Exits 1 when it is not
#######################################
stealth::sys::crypto::_full() {
    if (( ${#1} != ${2} )); then
        stealth::util::assert::fail \
            "${3} came back ${#1} characters long, and should have been ${2}"
    fi
    return 0
}

#######################################
# Writes random bytes into a file, which is how a key file is filled. This
# is the callback sys/io/fs::atomic runs.
#
# Usage:
#   stealth::sys::io::fs::atomic "${path}" -- stealth::sys::crypto::_fill 4096
#
# Arguments:
#   $1 (String)  - The staged file
#   $2 (Integer) - How many bytes
# Globals:
#   STEALTH_CRYPTO_SOURCE (Read)
# Returns:
#   0 - Filled
#   1 - Nothing could be read
#######################################
stealth::sys::crypto::_fill() {
    head --bytes "${2}" "${STEALTH_CRYPTO_SOURCE}" > "${1}"
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says a number of random bytes as hexadecimal, which is two characters for
# every byte. Thirty-two characters is sixteen bytes of randomness.
#
# Usage:
#   stealth::sys::crypto::hex token 16
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - How many bytes
# Globals:
#   STEALTH_CRYPTO_SOURCE (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, the count is not a whole number
#   above zero, or nothing could be read
#######################################
stealth::sys::crypto::hex() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::sys::crypto::_count "${2:-}" 'a number of bytes'
    local -n _crypto_hex_out="${1}"

    local _crypto_hex_raw
    stealth::sys::cmd::capture _crypto_hex_raw od --address-radix=n \
        --read-bytes="${2}" --format=x1 "${STEALTH_CRYPTO_SOURCE}"

    _crypto_hex_out="${_crypto_hex_raw//[^0-9a-f]/}"
    stealth::sys::crypto::_full "${_crypto_hex_out}" "$(( ${2} * 2 ))" \
        'a run of hexadecimal'
    return 0
}

#######################################
# Says a number of random bytes in base64, which is four characters for
# every three bytes and none of them a line break.
#
# Usage:
#   stealth::sys::crypto::base64 secret 24
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - How many bytes
# Globals:
#   STEALTH_CRYPTO_SOURCE (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, the count is not a whole number
#   above zero, or nothing could be read
#######################################
stealth::sys::crypto::base64() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::sys::crypto::_count "${2:-}" 'a number of bytes'
    local -n _crypto_b64_out="${1}"

    # shellcheck disable=SC2312
    # head failing here would leave base64 with nothing to read and nothing
    # to say, which is what the length check below is for.
    stealth::sys::cmd::capture "${1}" base64 --wrap=0 \
        <(head --bytes "${2}" "${STEALTH_CRYPTO_SOURCE}")

    stealth::sys::crypto::_full "${_crypto_b64_out}" \
        "$(( (( ${2} + 2 ) / 3 ) * 4 ))" 'a run of base64'
    return 0
}

#######################################
# Makes a password of letters and digits, and nothing else. A password that
# has to survive being typed, pasted through a web form and written into a
# configuration file is one with no punctuation in it.
#
# Bytes that are not letters or digits are thrown away rather than folded
# into the alphabet. Folding would make some characters likelier than others
# and quietly make the password smaller than its length suggests.
#
# Usage:
#   stealth::sys::crypto::password secret
#   stealth::sys::crypto::password secret 32
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - How many characters. Default: 24
# Globals:
#   STEALTH_CRYPTO_SOURCE (Read)
#   _STEALTH_SYS_CRYPTO_ALPHABET (Read)
#   _STEALTH_SYS_CRYPTO_PASSWORD_LENGTH (Read)
# Returns:
#   0 - Made
#   Exits 1 when no output variable is given, the length is not a whole
#   number above zero, or nothing could be read
#######################################
stealth::sys::crypto::password() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -r _crypto_pw_length="${2:-${_STEALTH_SYS_CRYPTO_PASSWORD_LENGTH}}"
    stealth::sys::crypto::_count "${_crypto_pw_length}" 'a length'

    local -n _crypto_pw_out="${1}"

    # shellcheck disable=SC2312
    # tr failing here would leave head with nothing to read and a password of
    # nothing to hand back, which is what the length check below is for.
    stealth::sys::cmd::capture "${1}" head --bytes "${_crypto_pw_length}" \
        <(LC_ALL=C tr --delete --complement "${_STEALTH_SYS_CRYPTO_ALPHABET}" \
            < "${STEALTH_CRYPTO_SOURCE}")

    stealth::sys::crypto::_full "${_crypto_pw_out}" "${_crypto_pw_length}" \
        'a password'
    return 0
}

#######################################
# Says a random identifier, in the shape everything reads as one. The kernel
# makes it, so reading one costs no fork.
#
# Usage:
#   stealth::sys::crypto::uuid name
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   STEALTH_CRYPTO_UUID_SOURCE (Read)
# Returns:
#   0 - Said
#   1 - The kernel here does not hand them out
#   Exits 1 when no output variable is given
#######################################
stealth::sys::crypto::uuid() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _crypto_uuid_out="${1}"

    if [[ ! -r "${STEALTH_CRYPTO_UUID_SOURCE}" ]]; then
        _crypto_uuid_out=''
        stealth::util::log::debug 'no identifiers at %s' \
            "${STEALTH_CRYPTO_UUID_SOURCE}"
        return 1
    fi

    _crypto_uuid_out="$(< "${STEALTH_CRYPTO_UUID_SOURCE}")"
    return 0
}

#######################################
# Writes a file of random bytes for something else to unlock a disk with.
#
# The file is never readable by anyone else, not for a moment. It is written
# somewhere else and renamed into place with its mode already set, so there
# is no point at which a file with a key in it can be opened by the wrong
# person.
#
# Usage:
#   stealth::sys::crypto::keyfile /etc/cryptsetup-keys.d/root.key
#   stealth::sys::crypto::keyfile "${path}" --size 8192
#
# Arguments:
#   $1 (String) - Where to write it
#   $@ (String) - --size N, how many bytes. Default: 4096
# Globals:
#   _STEALTH_SYS_CRYPTO_KEY_SIZE (Read)
#   _STEALTH_SYS_CRYPTO_KEY_MODE (Read)
# Returns:
#   0 - Written
#   1 - It could not be put in place
#   Exits 1 when no path is given, or --size is given something that is not a
#   whole number above zero
#######################################
stealth::sys::crypto::keyfile() {
    stealth::util::assert::not_empty "${1:-}" 'somewhere to write the key is required'
    local -r _crypto_key_path="${1}"
    shift

    local _crypto_key_size="${_STEALTH_SYS_CRYPTO_KEY_SIZE}"
    while (( $# > 0 )); do
        case "${1}" in
            --size)
                stealth::sys::crypto::_count "${2:-}" 'a number of bytes'
                _crypto_key_size="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "keyfile does not take ${1}"
                ;;
        esac
    done

    stealth::util::log::info 'writing a key of %d bytes to %s' \
        "${_crypto_key_size}" "${_crypto_key_path}"

    stealth::sys::io::fs::atomic "${_crypto_key_path}" \
        --mode "${_STEALTH_SYS_CRYPTO_KEY_MODE}" -- \
        stealth::sys::crypto::_fill "${_crypto_key_size}"
}
