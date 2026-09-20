###############################################################################
# module: sys/net/fetch
# layer: sys
# description: Getting a file from somewhere else, and knowing it arrived
#              whole.
#
#              A download with a digest never reaches the network twice. The
#              digest is looked for in the store first, and a hit is a hit
#              because the bytes match, not because an address matched. What
#              is downloaded is verified before it is put where the caller
#              asked, so a caller never sees a file that failed its check,
#              not even for a moment.
#
#              Mirrors follow from that. Several addresses serving one digest
#              are interchangeable, so they are tried in turn until one gives
#              the right bytes. A mirror serving the wrong bytes is skipped
#              like one that is down.
#
#              curl is held to http and https, on the first request and on
#              every redirect, so a protected transfer cannot be walked down
#              to plaintext or off to a protocol nobody asked for. Every
#              transfer has a limit on the whole of it and not only on the
#              connection, because a server that answers and then sends one
#              byte a minute is the shape a build hangs on.
#
#              A password never appears in a command line. curl reads
#              credentials from a netrc file, which is a file this module
#              will write with nobody else able to read it.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_NET_FETCH:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_FETCH=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs" "sys/io/tmp"
stealth::util::import "sys/runtime/hash" "sys/data/json"
stealth::util::import "sys/net/cache"

# =============================================================================
# CONSTANTS
# =============================================================================

# What curl is told every time.
#
# --fail             an error page is not the file that was asked for
# --location         follow a redirect, which every forge uses
# --proto            only these, so an address cannot name something else
# --proto-redir      and only these after a redirect, so it cannot become one
# --max-redirs       a redirect that goes round for ever is not followed
# --retry-connrefused  curl does not retry a refused connection without this
# --no-progress-meter  the log is the progress report
#
# On one line because kcov counts the lines of a declaration that spans
# several as never run.
declare -gra _STEALTH_SYS_NET_FETCH_FLAGS=(--fail --location --proto '=https,http' --proto-redir '=https,http' --max-redirs 10 --retry-connrefused --no-progress-meter)

# How long to wait for a connection, how long to allow the whole transfer,
# and how many times to try again. The transfer limit is the one that matters:
# a connection timeout alone does not bound a server that answers and then
# stops sending.
declare -gri _STEALTH_SYS_NET_FETCH_CONNECT=15
declare -gri _STEALTH_SYS_NET_FETCH_TIME=1800
declare -gri _STEALTH_SYS_NET_FETCH_RETRIES=3

# How long to leave between attempts. curl doubles the delay on its own, and
# doubling makes the time spent failing hard to predict: three retries of a
# refused connection take seven seconds rather than the three the setting
# suggests. A fixed delay makes the budget exactly the retries times this,
# which matters when a build asks about twenty packages and the forge is
# unreachable.
declare -gri _STEALTH_SYS_NET_FETCH_RETRY_DELAY=2

# A transfer slower than this many bytes a second for this many seconds has
# stopped, whatever the socket says.
declare -gri _STEALTH_SYS_NET_FETCH_SLOW_BYTES=512
declare -gri _STEALTH_SYS_NET_FETCH_SLOW_SECONDS=60

# Where curl reads credentials. Empty means it reads none: curl looks in
# ~/.netrc on its own otherwise, and a build should use what it was told to
# use and nothing else.
declare -g STEALTH_NET_NETRC="${STEALTH_NET_NETRC:-}"

# The mode a file of credentials is kept at.
declare -gr _STEALTH_SYS_NET_FETCH_NETRC_MODE='0600'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Builds the arguments curl is given, from the settings and the options a
# caller passed.
#
# Usage:
#   stealth::sys::net::fetch::_flags args 600 3
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (Integer) - How long the whole transfer may take
#   $3 (Integer) - How many times to try again
#   $@ (String)  - Headers to send, one per argument
# Globals:
#   _STEALTH_SYS_NET_FETCH_FLAGS (Read)
#   _STEALTH_SYS_NET_FETCH_CONNECT (Read)
#   _STEALTH_SYS_NET_FETCH_RETRY_DELAY (Read)
#   STEALTH_NET_NETRC (Read)
# Returns:
#   0 - Built
#######################################
stealth::sys::net::fetch::_flags() {
    local -n _fetch_flags_out="${1}"
    local -r _fetch_flags_time="${2}"
    local -r _fetch_flags_retries="${3}"
    shift 3

    _fetch_flags_out=("${_STEALTH_SYS_NET_FETCH_FLAGS[@]}")
    _fetch_flags_out+=(--connect-timeout "${_STEALTH_SYS_NET_FETCH_CONNECT}")
    _fetch_flags_out+=(--max-time "${_fetch_flags_time}")
    _fetch_flags_out+=(--retry "${_fetch_flags_retries}")
    _fetch_flags_out+=(--retry-delay "${_STEALTH_SYS_NET_FETCH_RETRY_DELAY}")
    _fetch_flags_out+=(--speed-limit "${_STEALTH_SYS_NET_FETCH_SLOW_BYTES}")
    _fetch_flags_out+=(--speed-time "${_STEALTH_SYS_NET_FETCH_SLOW_SECONDS}")

    if [[ -n "${STEALTH_NET_NETRC}" ]]; then
        _fetch_flags_out+=(--netrc-file "${STEALTH_NET_NETRC}")
    fi

    local _fetch_flags_header
    for _fetch_flags_header in "$@"; do
        _fetch_flags_out+=(--header "${_fetch_flags_header}")
    done
    return 0
}

#######################################
# Takes the options every function here understands off the arguments, and
# gives back whatever was left.
#
# Each setting has an output of its own rather than a place in one array,
# because a nameref to an associative array is something neither shellcheck
# nor a reader can follow.
#
# Usage:
#   stealth::sys::net::fetch::_take_options digest time retries cache \
#       mirrors headers rest "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for --digest
#   $2 (Nameref) - The output variable for --timeout, in seconds
#   $3 (Nameref) - The output variable for --retries
#   $4 (Nameref) - The output variable set to 0 by --no-cache
#   $5 (Nameref) - The output array for the mirrors
#   $6 (Nameref) - The output array for the headers
#   $7 (Nameref) - The output array for everything that was not an option
#   $@ (String)  - The arguments
# Globals:
#   _STEALTH_SYS_NET_FETCH_TIME (Read)
#   _STEALTH_SYS_NET_FETCH_RETRIES (Read)
# Returns:
#   0 - Taken
#   Exits 1 when an option is given nothing, or is one nothing here takes
#######################################
stealth::sys::net::fetch::_take_options() {
    local -n _fetch_opt_digest="${1}"
    local -n _fetch_opt_time="${2}"
    local -n _fetch_opt_retries="${3}"
    local -n _fetch_opt_cache="${4}"
    local -n _fetch_opt_mirrors="${5}"
    local -n _fetch_opt_headers="${6}"
    local -n _fetch_opt_rest="${7}"
    shift 7

    _fetch_opt_digest=''
    _fetch_opt_time="${_STEALTH_SYS_NET_FETCH_TIME}"
    _fetch_opt_retries="${_STEALTH_SYS_NET_FETCH_RETRIES}"
    _fetch_opt_cache=1
    _fetch_opt_mirrors=()
    _fetch_opt_headers=()
    _fetch_opt_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --digest)
                stealth::util::assert::not_empty "${2:-}" '--digest takes a digest'
                _fetch_opt_digest="${2}"
                shift 2
                ;;
            --mirror)
                stealth::util::assert::not_empty "${2:-}" '--mirror takes an address'
                _fetch_opt_mirrors+=("${2}")
                shift 2
                ;;
            --header)
                stealth::util::assert::not_empty "${2:-}" '--header takes a header'
                _fetch_opt_headers+=("${2}")
                shift 2
                ;;
            --timeout)
                stealth::util::assert::is_int "${2:-}" \
                    "--timeout takes whole seconds, not ${2:-}"
                _fetch_opt_time="${2}"
                shift 2
                ;;
            --retries)
                stealth::util::assert::is_int "${2:-}" \
                    "--retries takes a whole number, not ${2:-}"
                _fetch_opt_retries="${2}"
                shift 2
                ;;
            --no-cache)
                _fetch_opt_cache=0
                shift
                ;;
            --*)
                stealth::util::assert::fail "fetch does not take ${1}"
                ;;
            *)
                _fetch_opt_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

#######################################
# Pulls one address into a file that is not yet the caller's, and says
# whether what arrived is what was asked for.
#
# Usage:
#   stealth::sys::net::fetch::_try "${url}" "${staged}" "${digest}" flags
#
# Arguments:
#   $1 (String)  - The address
#   $2 (String)  - The file to write
#   $3 (String)  - The digest to check against, or empty for none
#   $4 (Nameref) - The array of arguments for curl
# Returns:
#   0 - It arrived, and matches the digest when there is one
#   1 - It did not arrive, or is not what was asked for
#######################################
stealth::sys::net::fetch::_try() {
    local -n _fetch_try_flags="${4}"

    if ! stealth::sys::cmd::try curl "${_fetch_try_flags[@]}" \
        --output "${2}" "${1}"; then
        stealth::util::log::debug '%s did not give up a file' "${1}"
        return 1
    fi

    if [[ -z "${3}" ]]; then
        return 0
    fi

    if ! stealth::sys::runtime::hash::verify "${2}" "${3}"; then
        stealth::util::log::warn '%s gave something other than %s' "${1}" "${3}"
        return 1
    fi
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says where curl reads credentials, and makes the file when it is not there.
#
# Nothing else here sends a password, and curl is never given one as an
# argument. A command line is readable by anyone who can list processes for
# as long as the command runs.
#
# Usage:
#   stealth::sys::net::fetch::authorize api.github.com "${user}" "${token}"
#
# Arguments:
#   $1 (String) - The host the credentials are for
#   $2 (String) - The login
#   $3 (String) - The password or token
#   $4 (String) - The file to keep them in. Default: what STEALTH_NET_NETRC
#                 already says, or a file in the run's temporary directory
# Globals:
#   STEALTH_NET_NETRC (Read/Write)
#   _STEALTH_SYS_NET_FETCH_NETRC_MODE (Read)
# Returns:
#   0 - Written, and curl will read it
#   Exits 1 when a host, a login or a password is missing
#######################################
stealth::sys::net::fetch::authorize() {
    stealth::util::assert::not_empty "${1:-}" 'a host is required'
    stealth::util::assert::not_empty "${2:-}" 'a login is required'
    stealth::util::assert::not_empty "${3:-}" 'a password is required'

    local _fetch_auth_file="${4:-${STEALTH_NET_NETRC}}"
    if [[ -z "${_fetch_auth_file}" ]]; then
        stealth::sys::io::tmp::file _fetch_auth_file 'netrc.XXXXXXXX'
    fi

    stealth::sys::io::fs::write "${_fetch_auth_file}" \
        "machine ${1} login ${2} password ${3}" \
        --mode "${_STEALTH_SYS_NET_FETCH_NETRC_MODE}"

    STEALTH_NET_NETRC="${_fetch_auth_file}"
    stealth::util::log::debug 'credentials for %s are in %s' "${1}" "${_fetch_auth_file}"
    return 0
}

#######################################
# Gets a file and puts it where the caller asked, whole or not at all.
#
# With --digest the store is asked first, and a hit means nothing is
# downloaded. What is downloaded is checked before it becomes the file the
# caller named, so a caller never opens a half a file or a wrong one.
#
# Without --digest nothing can be checked and nothing is stored. That is not
# an oversight: a file nobody can verify is one that should be fetched again
# next time rather than trusted twice.
#
# Usage:
#   stealth::sys::net::fetch::download "${url}" "${dest}" --digest "${sum}"
#   stealth::sys::net::fetch::download "${url}" "${dest}" \
#       --digest "${sum}" --mirror "${other}" --mirror "${another}"
#
# Arguments:
#   $1 (String) - The address
#   $2 (String) - Where to put it
#   $@ (String) - --digest D, --mirror URL any number of times, --header H,
#                 --timeout SECONDS, --retries N, --no-cache
# Returns:
#   0 - The file is there and is what was asked for
#   1 - No address gave it up, or none gave the right bytes
#   Exits 1 when an address or a destination is missing
#######################################
stealth::sys::net::fetch::download() {
    stealth::util::assert::not_empty "${1:-}" 'an address is required'
    stealth::util::assert::not_empty "${2:-}" 'somewhere to put it is required'
    local -r _fetch_dl_url="${1}"
    local -r _fetch_dl_dest="${2}"
    shift 2

    local _fetch_dl_digest
    local -i _fetch_dl_time _fetch_dl_retries _fetch_dl_cache
    local -a _fetch_dl_mirrors=() _fetch_dl_headers=() _fetch_dl_rest=()
    stealth::sys::net::fetch::_take_options _fetch_dl_digest _fetch_dl_time \
        _fetch_dl_retries _fetch_dl_cache _fetch_dl_mirrors \
        _fetch_dl_headers _fetch_dl_rest "$@"

    if (( ${#_fetch_dl_rest[@]} > 0 )); then
        stealth::util::assert::fail "download does not take ${_fetch_dl_rest[0]}"
    fi

    if [[ -n "${_fetch_dl_digest}" ]] && (( _fetch_dl_cache == 1 )); then
        if stealth::sys::net::cache::get "${_fetch_dl_digest}" "${_fetch_dl_dest}"; then
            stealth::util::log::info 'took %s from the store' "${_fetch_dl_digest}"
            return 0
        fi
    fi

    local -a _fetch_dl_flags=()
    stealth::sys::net::fetch::_flags _fetch_dl_flags "${_fetch_dl_time}" \
        "${_fetch_dl_retries}" "${_fetch_dl_headers[@]}"

    local _fetch_dl_dir="${_fetch_dl_dest%/*}"
    if [[ "${_fetch_dl_dir}" == "${_fetch_dl_dest}" ]]; then
        _fetch_dl_dir='.'
    fi
    stealth::sys::io::fs::mkdir "${_fetch_dl_dir}"

    local _fetch_dl_staged
    stealth::sys::io::tmp::file_in _fetch_dl_staged "${_fetch_dl_dir}" \
        'fetch.XXXXXXXX'

    local _fetch_dl_from
    for _fetch_dl_from in "${_fetch_dl_url}" "${_fetch_dl_mirrors[@]}"; do
        stealth::util::log::info 'getting %s' "${_fetch_dl_from}"
        if stealth::sys::net::fetch::_try "${_fetch_dl_from}" \
            "${_fetch_dl_staged}" "${_fetch_dl_digest}" _fetch_dl_flags; then
            stealth::sys::net::fetch::_keep "${_fetch_dl_staged}" \
                "${_fetch_dl_dest}" "${_fetch_dl_digest}" "${_fetch_dl_cache}"
            return
        fi
    done

    stealth::sys::io::tmp::remove "${_fetch_dl_staged}"
    stealth::util::log::warn 'nowhere gave up %s' "${_fetch_dl_url}"
    return 1
}

#######################################
# Puts a verified download where the caller asked and keeps a copy in the
# store.
#
# Usage:
#   stealth::sys::net::fetch::_keep "${staged}" "${dest}" "${digest}" 1
#
# Arguments:
#   $1 (String)  - The file that was downloaded
#   $2 (String)  - Where it goes
#   $3 (String)  - Its digest, or empty when there is none
#   $4 (Integer) - 1 to keep a copy in the store
# Returns:
#   0 - It is in place
#   1 - It could not be put there
#######################################
stealth::sys::net::fetch::_keep() {
    if [[ -n "${3}" && "${4}" -eq 1 ]]; then
        stealth::sys::net::cache::put "${3}" "${1}" || true
    fi

    # The copy is the step that puts the file where the caller asked. A
    # caller told the download succeeded when this failed goes on to open
    # something that is not there.
    if ! stealth::sys::io::fs::cp "${1}" "${2}"; then
        stealth::util::log::warn '%s arrived but could not be put at %s' \
            "${1}" "${2}"
        stealth::sys::io::tmp::remove "${1}"
        return 1
    fi

    stealth::sys::io::tmp::remove "${1}"
    return 0
}

#######################################
# Gets what an address answers with and puts it in a variable, for an answer
# small enough to hold. A file goes to download instead.
#
# Usage:
#   stealth::sys::net::fetch::text body "${url}"
#   stealth::sys::net::fetch::text body "${url}" --header 'Accept: application/json'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The address
#   $@ (String)  - --header H, --timeout SECONDS, --retries N
# Returns:
#   0 - It answered
#   1 - It did not
#   Exits 1 when an output variable or an address is missing
#######################################
stealth::sys::net::fetch::text() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an address is required'
    local -r _fetch_text_var="${1}"
    local -r _fetch_text_url="${2}"
    shift 2

    local _fetch_text_digest
    local -i _fetch_text_time _fetch_text_retries _fetch_text_cache
    local -a _fetch_text_mirrors=() _fetch_text_headers=() _fetch_text_rest=()
    stealth::sys::net::fetch::_take_options _fetch_text_digest \
        _fetch_text_time _fetch_text_retries _fetch_text_cache \
        _fetch_text_mirrors _fetch_text_headers _fetch_text_rest "$@"

    if (( ${#_fetch_text_rest[@]} > 0 )); then
        stealth::util::assert::fail "text does not take ${_fetch_text_rest[0]}"
    fi

    local -a _fetch_text_flags=()
    stealth::sys::net::fetch::_flags _fetch_text_flags \
        "${_fetch_text_time}" "${_fetch_text_retries}" \
        "${_fetch_text_headers[@]}"

    stealth::util::log::debug 'asking %s' "${_fetch_text_url}"
    if ! stealth::sys::cmd::capture "${_fetch_text_var}" curl \
        "${_fetch_text_flags[@]}" "${_fetch_text_url}"; then
        stealth::util::log::debug '%s did not answer' "${_fetch_text_url}"
        return 1
    fi
    return 0
}

#######################################
# Asks an address for JSON and reads one place out of the answer. The path is
# handed to sys/data/json, which passes it to jq as data, so a key is never
# part of a program.
#
# Usage:
#   stealth::sys::net::fetch::json tag "${url}" tag_name
#   stealth::sys::net::fetch::json url "${url}" assets 0 browser_download_url
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The address
#   $@ (String)  - --header H, --timeout SECONDS, --retries N, then the path,
#                  one step per argument
# Returns:
#   0 - It answered and the path is there
#   1 - It did not answer, did not answer with JSON, or has no such path
#   Exits 1 when an output variable, an address or a path is missing
#######################################
stealth::sys::net::fetch::json() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an address is required'
    local -r _fetch_json_var="${1}"
    local -r _fetch_json_url="${2}"
    shift 2

    local _fetch_json_digest
    local -i _fetch_json_time _fetch_json_retries _fetch_json_cache
    local -a _fetch_json_mirrors=() _fetch_json_headers=() _fetch_json_path=()
    stealth::sys::net::fetch::_take_options _fetch_json_digest \
        _fetch_json_time _fetch_json_retries _fetch_json_cache \
        _fetch_json_mirrors _fetch_json_headers _fetch_json_path "$@"

    stealth::util::assert::not_empty "${_fetch_json_path[0]:-}" 'a path is required'

    local -a _fetch_json_flags=()
    stealth::sys::net::fetch::_flags _fetch_json_flags \
        "${_fetch_json_time}" "${_fetch_json_retries}" \
        "${_fetch_json_headers[@]}"

    local _fetch_json_file
    stealth::sys::io::tmp::file _fetch_json_file 'answer.XXXXXXXX.json'

    stealth::util::log::debug 'asking %s' "${_fetch_json_url}"
    if ! stealth::sys::cmd::try curl "${_fetch_json_flags[@]}" \
        --output "${_fetch_json_file}" "${_fetch_json_url}"; then
        stealth::sys::io::tmp::remove "${_fetch_json_file}"
        stealth::util::log::debug '%s did not answer' "${_fetch_json_url}"
        return 1
    fi

    local -i _fetch_json_status=0
    stealth::sys::data::json::read "${_fetch_json_var}" "${_fetch_json_file}" \
        "${_fetch_json_path[@]}" || _fetch_json_status=$?

    stealth::sys::io::tmp::remove "${_fetch_json_file}"
    return "${_fetch_json_status}"
}
