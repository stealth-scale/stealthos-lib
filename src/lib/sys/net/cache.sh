###############################################################################
# module: sys/net/cache
# layer: sys
# description: A store of downloaded files, kept under the digest of what is
#              in them rather than the address they came from.
#
#              An entry is named by its own contents, so a hit is verified by
#              having been found. A cache keyed by URL has to answer a
#              question it cannot: whether what it kept is still what that
#              address serves. A cache keyed by digest never has to, because
#              a caller asking for a digest is asking for bytes it can check,
#              and the check is the lookup.
#
#              What falls out of that is worth having. Two addresses serving
#              the same tarball share one entry. A mirror list costs nothing.
#              An entry can never go stale, only be absent. Two builds
#              writing the same entry at the same time write the same bytes,
#              so no lock is needed: the rename into place is idempotent.
#
#              get reads what it hands over and refuses an entry that does
#              not match its name. That costs a pass over the file, which is
#              what a copy costs anyway, and it means a truncated or tampered
#              entry is removed the first time it is asked for rather than
#              served for the rest of the machine's life.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_NET_CACHE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_CACHE=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs" "sys/runtime/hash"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where the store lives. Empty means there is no store, and every function
# here says so quietly rather than failing, so a caller never has to ask
# whether caching is on before it asks for something.
declare -g STEALTH_NET_CACHE_DIR="${STEALTH_NET_CACHE_DIR:-}"

# How many characters of a digest name the directory an entry sits in.
# Spreading entries over 256 directories keeps any one of them small enough
# that reading it stays cheap.
declare -gri _STEALTH_SYS_NET_CACHE_FANOUT=2

# The mode the store and its entries are made with. An entry is something
# that has been verified, and anyone able to rewrite one could hand a build
# something else under a name it trusts.
declare -gr _STEALTH_SYS_NET_CACHE_DIR_MODE='0755'
declare -gr _STEALTH_SYS_NET_CACHE_FILE_MODE='0444'

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says where the store is, and makes it.
#
# Usage:
#   stealth::sys::net::cache::configure /var/cache/stealth
#
# Arguments:
#   $1 (String) - The directory
# Globals:
#   STEALTH_NET_CACHE_DIR (Write)
# Returns:
#   0 - It is there
#   Exits 1 when no directory is given, or it could not be made
#######################################
stealth::sys::net::cache::configure() {
    stealth::util::assert::not_empty "${1:-}" 'a directory is required'

    stealth::sys::io::fs::mkdir "${1}" --mode "${_STEALTH_SYS_NET_CACHE_DIR_MODE}"
    STEALTH_NET_CACHE_DIR="${1%/}"

    stealth::util::log::debug 'the store is at %s' "${STEALTH_NET_CACHE_DIR}"
    return 0
}

#######################################
# Reports whether there is a store at all. Nothing else here needs asking
# first, because everything else answers for itself when there is none.
#
# Usage:
#   if stealth::sys::net::cache::is_on; then ...
#
# Arguments:
#   None
# Globals:
#   STEALTH_NET_CACHE_DIR (Read)
# Returns:
#   0 - There is
#   1 - There is not
#######################################
stealth::sys::net::cache::is_on() {
    [[ -n "${STEALTH_NET_CACHE_DIR}" ]]
}

#######################################
# Says where the entry for a digest would be, whether or not it is there.
#
# Usage:
#   stealth::sys::net::cache::path where "sha256:2cf24d..."
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The digest, with its algorithm in front
# Globals:
#   STEALTH_NET_CACHE_DIR (Read)
#   _STEALTH_SYS_NET_CACHE_FANOUT (Read)
# Returns:
#   0 - Said
#   1 - There is no store
#   Exits 1 when no output variable or no digest is given, or the algorithm
#   is not one sys/runtime/hash computes
#######################################
stealth::sys::net::cache::path() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a digest is required'
    local -n _cache_path_out="${1}"

    _cache_path_out=''
    if ! stealth::sys::net::cache::is_on; then
        return 1
    fi

    local _cache_path_algo _cache_path_sum
    stealth::sys::runtime::hash::split _cache_path_algo _cache_path_sum "${2}"

    local -r _cache_path_head="${_cache_path_sum:0:${_STEALTH_SYS_NET_CACHE_FANOUT}}"
    local -r _cache_path_tail="${_cache_path_sum:${_STEALTH_SYS_NET_CACHE_FANOUT}}"

    _cache_path_out="${STEALTH_NET_CACHE_DIR}/${_cache_path_algo}/${_cache_path_head}/${_cache_path_tail}"
    return 0
}

#######################################
# Reports whether an entry is there, without reading it. get is what checks
# that an entry is what it says it is, so a yes here is a yes about the name
# and not about the bytes.
#
# Usage:
#   if stealth::sys::net::cache::has "${digest}"; then ...
#
# Arguments:
#   $1 (String) - The digest
# Returns:
#   0 - It is there
#   1 - It is not, or there is no store
#   Exits 1 when no digest is given
#######################################
stealth::sys::net::cache::has() {
    local _cache_has_path
    if ! stealth::sys::net::cache::path _cache_has_path "${1:-}"; then
        return 1
    fi

    [[ -f "${_cache_has_path}" ]]
}

#######################################
# Puts a copy of an entry where the caller asked for it, after reading it
# through and checking that it is what its name says.
#
# An entry that does not match is removed rather than served. It got there by
# a bug or by somebody editing the store, and either way it is the one thing
# a store like this must never hand back.
#
# Usage:
#   if ! stealth::sys::net::cache::get "${digest}" "${dest}"; then
#       # download it
#   fi
#
# Arguments:
#   $1 (String) - The digest
#   $2 (String) - Where to put the copy
# Returns:
#   0 - The copy is there and is what was asked for
#   1 - There is no such entry, no store, the entry was not what it said, or
#       the copy could not be put where it was asked for
#   Exits 1 when a digest or a destination is missing
#######################################
stealth::sys::net::cache::get() {
    stealth::util::assert::not_empty "${2:-}" 'somewhere to put it is required'

    local _cache_get_path
    if ! stealth::sys::net::cache::path _cache_get_path "${1:-}"; then
        return 1
    fi
    if [[ ! -f "${_cache_get_path}" ]]; then
        stealth::util::log::debug 'nothing stored under %s' "${1}"
        return 1
    fi

    if ! stealth::sys::runtime::hash::verify "${_cache_get_path}" "${1}"; then
        stealth::util::log::warn 'what is stored under %s is not that, removing it' "${1}"
        stealth::sys::io::fs::rm "${_cache_get_path}"
        return 1
    fi

    # A caller told the entry was taken when the copy failed goes on to open
    # something that is not there.
    if ! stealth::sys::io::fs::cp "${_cache_get_path}" "${2}"; then
        stealth::util::log::warn '%s is in the store but could not be put at %s' \
            "${1}" "${2}"
        return 1
    fi

    stealth::util::log::debug 'took %s from the store' "${1}"
    return 0
}

#######################################
# Keeps a file under a digest. The caller is the one that verified it, which
# is why this does not read it again: the file has just been checked, and
# reading a tarball twice to learn the same thing costs the build time.
#
# get checks anyway, so an entry stored under the wrong name is found out the
# first time it is asked for. That is the place where being wrong does harm.
#
# Storing something already stored is not an error and does no work. Two
# builds storing the same digest store the same bytes, so neither has to wait
# for the other.
#
# Usage:
#   stealth::sys::net::cache::put "${digest}" "${downloaded}"
#
# Arguments:
#   $1 (String) - The digest
#   $2 (String) - The file, already verified against that digest
# Globals:
#   _STEALTH_SYS_NET_CACHE_FILE_MODE (Read)
#   _STEALTH_SYS_NET_CACHE_DIR_MODE (Read)
# Returns:
#   0 - It is in the store, now or already
#   1 - There is no store
#   Exits 1 when a digest or a file is missing, or the file is not there
#######################################
stealth::sys::net::cache::put() {
    stealth::util::assert::is_file "${2:-}" "no file to store at ${2:-}"

    local _cache_put_path
    if ! stealth::sys::net::cache::path _cache_put_path "${1:-}"; then
        return 1
    fi
    if [[ -f "${_cache_put_path}" ]]; then
        stealth::util::log::trace '%s is in the store already' "${1}"
        return 0
    fi

    stealth::sys::io::fs::mkdir "${_cache_put_path%/*}" \
        --mode "${_STEALTH_SYS_NET_CACHE_DIR_MODE}"
    stealth::sys::io::fs::cp "${2}" "${_cache_put_path}" \
        --mode "${_STEALTH_SYS_NET_CACHE_FILE_MODE}"

    stealth::util::log::debug 'put %s in the store' "${1}"
    return 0
}

#######################################
# Takes one entry out of the store. An entry that was not there is no
# trouble.
#
# Usage:
#   stealth::sys::net::cache::forget "${digest}"
#
# Arguments:
#   $1 (String) - The digest
# Returns:
#   0 - It is not in the store
#   1 - There is no store
#   Exits 1 when no digest is given
#######################################
stealth::sys::net::cache::forget() {
    local _cache_forget_path
    if ! stealth::sys::net::cache::path _cache_forget_path "${1:-}"; then
        return 1
    fi

    stealth::sys::io::fs::rm "${_cache_forget_path}"
    stealth::util::log::debug 'took %s out of the store' "${1}"
    return 0
}

#######################################
# Fills an array with the digests the store holds, each with its algorithm in
# front, the way they went in.
#
# Usage:
#   stealth::sys::net::cache::entries held
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   STEALTH_NET_CACHE_DIR (Read)
# Returns:
#   0 - Filled
#   1 - There is no store
#   Exits 1 when no output array is given
#######################################
stealth::sys::net::cache::entries() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    local -n _cache_ent_out="${1}"

    _cache_ent_out=()
    if ! stealth::sys::net::cache::is_on; then
        return 1
    fi
    if [[ ! -d "${STEALTH_NET_CACHE_DIR}" ]]; then
        return 0
    fi

    # %P is the path below the store, which is exactly algorithm, first
    # characters, rest. A digest holds no line breaks, so a line is a name.
    local _cache_ent_text
    if ! stealth::sys::cmd::capture _cache_ent_text find \
        "${STEALTH_NET_CACHE_DIR}" -mindepth 3 -maxdepth 3 -type f \
        -printf '%P\n'; then
        return 1
    fi
    if [[ -z "${_cache_ent_text}" ]]; then
        return 0
    fi

    local -a _cache_ent_lines=()
    mapfile -t _cache_ent_lines <<< "${_cache_ent_text}"

    local _cache_ent_line _cache_ent_rest _cache_ent_head _cache_ent_algo
    for _cache_ent_line in "${_cache_ent_lines[@]}"; do
        _cache_ent_algo="${_cache_ent_line%%/*}"
        _cache_ent_rest="${_cache_ent_line#*/}"
        _cache_ent_head="${_cache_ent_rest%%/*}"
        _cache_ent_rest="${_cache_ent_rest#*/}"
        _cache_ent_out+=("${_cache_ent_algo}:${_cache_ent_head}${_cache_ent_rest}")
    done
    return 0
}

#######################################
# Says how many bytes the store is holding, so that something above can
# decide it has grown too big.
#
# Usage:
#   stealth::sys::net::cache::size bytes
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   STEALTH_NET_CACHE_DIR (Read)
# Returns:
#   0 - Said
#   1 - There is no store
#   Exits 1 when no output variable is given
#######################################
stealth::sys::net::cache::size() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _cache_size_out="${1}"

    _cache_size_out=0
    if ! stealth::sys::net::cache::is_on; then
        return 1
    fi
    if [[ ! -d "${STEALTH_NET_CACHE_DIR}" ]]; then
        return 0
    fi

    local _cache_size_text
    if ! stealth::sys::cmd::capture _cache_size_text find \
        "${STEALTH_NET_CACHE_DIR}" -mindepth 3 -maxdepth 3 -type f \
        -printf '%s\n'; then
        return 1
    fi
    if [[ -z "${_cache_size_text}" ]]; then
        return 0
    fi

    local -a _cache_size_each=()
    mapfile -t _cache_size_each <<< "${_cache_size_text}"

    local -i _cache_size_total=0
    local _cache_size_one
    for _cache_size_one in "${_cache_size_each[@]}"; do
        _cache_size_total=$(( _cache_size_total + _cache_size_one ))
    done

    _cache_size_out="${_cache_size_total}"
    return 0
}

#######################################
# Empties the store, leaving the store itself.
#
# Usage:
#   stealth::sys::net::cache::clear
#
# Arguments:
#   None
# Globals:
#   STEALTH_NET_CACHE_DIR (Read)
# Returns:
#   0 - It is empty
#   1 - There is no store
#######################################
stealth::sys::net::cache::clear() {
    if ! stealth::sys::net::cache::is_on; then
        return 1
    fi

    local -a _cache_clear_held=()
    stealth::sys::net::cache::entries _cache_clear_held

    local _cache_clear_digest
    for _cache_clear_digest in "${_cache_clear_held[@]}"; do
        stealth::sys::net::cache::forget "${_cache_clear_digest}"
    done

    stealth::util::log::info 'emptied the store of %d entries' \
        "${#_cache_clear_held[@]}"
    return 0
}
