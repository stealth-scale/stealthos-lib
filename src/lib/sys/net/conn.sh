###############################################################################
# module: sys/net/conn
# layer: sys
# description: Whether something out there answers.
#
#              Reachability is asked by opening a connection, never by
#              pinging. ICMP is dropped by a great many networks that carry
#              traffic perfectly well, so a build that decides it is offline
#              because a ping went unanswered is a build that refuses to work
#              on a network that works.
#
#              What a caller wants to know is never "is the internet up". It
#              is whether the one host it is about to fetch from answers.
#              Asking that question directly is both more useful and less
#              rude than sending packets to somebody else's name server to
#              find out something about our own network.
#
#              A connection is opened by bash itself through /dev/tcp, with
#              the host and the port passed as arguments rather than pasted
#              into a command. A host name is something a configuration file
#              handed us, and one written to look like a command must not
#              become one.
# copyright: Stealth Scale B.V.
###############################################################################

# shellcheck disable=SC2016
# The single quotes below are the point. $1 and $2 are the positional
# parameters of the bash that opens the connection, so the host and the port
# reach it as arguments rather than as part of the text it runs.

if [[ -n "${_STEALTH_LIB_SYS_NET_CONN:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_CONN=1

stealth::util::import "util/assert" "util/log" "util/retry"
stealth::util::import "sys/cmd"

# =============================================================================
# CONSTANTS
# =============================================================================

# How long a single attempt is given, and how long a wait keeps trying.
declare -gri _STEALTH_SYS_NET_CONN_TIMEOUT=5
declare -gri _STEALTH_SYS_NET_CONN_WAIT=60

# How long to leave between attempts while waiting.
declare -gri _STEALTH_SYS_NET_CONN_INTERVAL=1

# The script bash runs to open a connection. The host and the port arrive as
# arguments, so neither is ever read as anything but a host and a port.
declare -gr _STEALTH_SYS_NET_CONN_OPEN='exec 3<>/dev/tcp/"$1"/"$2"'

# What a port is allowed to be.
declare -gri _STEALTH_SYS_NET_CONN_PORT_MAX=65535

# The ports a scheme is reached on when an address does not say.
declare -grA _STEALTH_SYS_NET_CONN_PORTS=([http]=80 [https]=443 [ftp]=21 [git]=9418 [ssh]=22)

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads --timeout off the arguments, which is the only option the functions
# that call this take.
#
# Usage:
#   stealth::sys::net::conn::_take_timeout seconds 60 "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for the number of seconds
#   $2 (Integer) - How long to allow when the caller does not say
#   $@ (String)  - The arguments
# Returns:
#   0 - Read
#   Exits 1 when --timeout is given something that is not a whole number, or
#   anything else is given at all
#######################################
stealth::sys::net::conn::_take_timeout() {
    local -n _conn_tt_out="${1}"
    _conn_tt_out="${2}"
    shift 2

    while (( $# > 0 )); do
        case "${1}" in
            --timeout)
                stealth::util::assert::is_int "${2:-}" \
                    "--timeout takes whole seconds, not ${2:-}"
                _conn_tt_out="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "--timeout is the only option here, not ${1}"
                ;;
        esac
    done
    return 0
}

#######################################
# Takes an address apart into the host and the port to try. A scheme with no
# port gets the port that scheme is reached on.
#
# Usage:
#   stealth::sys::net::conn::_endpoint host port 'https://example.com/a/b'
#
# Arguments:
#   $1 (Nameref) - The output variable for the host
#   $2 (Nameref) - The output variable for the port
#   $3 (String)  - The address
# Globals:
#   _STEALTH_SYS_NET_CONN_PORTS (Read)
# Returns:
#   0 - Taken apart
#   1 - There is no port to be had from it
#######################################
stealth::sys::net::conn::_endpoint() {
    local -n _conn_ep_host="${1}"
    local -n _conn_ep_port="${2}"

    local _conn_ep_rest="${3}"
    local _conn_ep_scheme=''

    if [[ "${_conn_ep_rest}" == *'://'* ]]; then
        _conn_ep_scheme="${_conn_ep_rest%%://*}"
        _conn_ep_rest="${_conn_ep_rest#*://}"
    fi

    _conn_ep_rest="${_conn_ep_rest#*@}"
    _conn_ep_rest="${_conn_ep_rest%%/*}"

    if [[ "${_conn_ep_rest}" == *:* ]]; then
        _conn_ep_host="${_conn_ep_rest%:*}"
        _conn_ep_port="${_conn_ep_rest##*:}"
        return 0
    fi

    _conn_ep_host="${_conn_ep_rest}"
    if [[ -v _STEALTH_SYS_NET_CONN_PORTS["${_conn_ep_scheme,,}"] ]]; then
        _conn_ep_port="${_STEALTH_SYS_NET_CONN_PORTS[${_conn_ep_scheme,,}]}"
        return 0
    fi

    _conn_ep_port=''
    return 1
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether a host answers on a port.
#
# The connection is opened by bash, so nothing is forked to ask and nothing
# has to be installed. netcat is not needed and is not looked for.
#
# Usage:
#   if stealth::sys::net::conn::is_reachable mirror.example.com 443; then ...
#   stealth::sys::net::conn::is_reachable "${host}" 443 --timeout 2
#
# Arguments:
#   $1 (String) - The host
#   $2 (Integer) - The port
#   $@ (String) - --timeout SECONDS. Default: 5
# Globals:
#   _STEALTH_SYS_NET_CONN_TIMEOUT (Read)
#   _STEALTH_SYS_NET_CONN_OPEN (Read)
#   _STEALTH_SYS_NET_CONN_PORT_MAX (Read)
# Returns:
#   0 - It answers
#   1 - It does not, or nothing answered in time
#   Exits 1 when a host or a port is missing, the port is not a port, or
#   --timeout is given something that is not a whole number
#######################################
stealth::sys::net::conn::is_reachable() {
    stealth::util::assert::not_empty "${1:-}" 'a host is required'
    local -r _conn_reach_host="${1}"
    stealth::util::assert::is_int "${2:-}" "a port is a whole number, not ${2:-}"
    local -r _conn_reach_port="${2}"
    shift 2

    if (( _conn_reach_port < 1 || _conn_reach_port > _STEALTH_SYS_NET_CONN_PORT_MAX )); then
        stealth::util::assert::fail \
            "${_conn_reach_port} is not a port, which is 1 to ${_STEALTH_SYS_NET_CONN_PORT_MAX}"
    fi

    local -i _conn_reach_seconds
    stealth::sys::net::conn::_take_timeout _conn_reach_seconds \
        "${_STEALTH_SYS_NET_CONN_TIMEOUT}" "$@"

    if stealth::sys::cmd::timeout "${_conn_reach_seconds}" bash -c \
        "${_STEALTH_SYS_NET_CONN_OPEN}" _ "${_conn_reach_host}" "${_conn_reach_port}"; then
        stealth::util::log::trace '%s answers on %s' \
            "${_conn_reach_host}" "${_conn_reach_port}"
        return 0
    fi

    stealth::util::log::debug '%s does not answer on %s' \
        "${_conn_reach_host}" "${_conn_reach_port}"
    return 1
}

#######################################
# Waits for a host to answer on a port, and says whether it ever did.
#
# Usage:
#   stealth::sys::net::conn::wait_for mirror.example.com 443
#   stealth::sys::net::conn::wait_for "${host}" 443 --wait 300
#
# Arguments:
#   $1 (String)  - The host
#   $2 (Integer) - The port
#   $@ (String)  - --wait SECONDS to keep trying for, --timeout SECONDS for
#                  one attempt
# Globals:
#   _STEALTH_SYS_NET_CONN_WAIT (Read)
#   _STEALTH_SYS_NET_CONN_INTERVAL (Read)
# Returns:
#   0 - It answers
#   1 - It never did
#   Exits 1 when a host or a port is missing, or an option is given something
#   that is not a whole number
#######################################
stealth::sys::net::conn::wait_for() {
    stealth::util::assert::not_empty "${1:-}" 'a host is required'
    stealth::util::assert::not_empty "${2:-}" 'a port is required'
    local -r _conn_wait_host="${1}"
    local -r _conn_wait_port="${2}"
    shift 2

    local -i _conn_wait_for="${_STEALTH_SYS_NET_CONN_WAIT}"
    local -a _conn_wait_rest=()
    while (( $# > 0 )); do
        case "${1}" in
            --wait)
                stealth::util::assert::is_int "${2:-}" \
                    "--wait takes whole seconds, not ${2:-}"
                _conn_wait_for="${2}"
                shift 2
                ;;
            *)
                _conn_wait_rest+=("${1}")
                shift
                ;;
        esac
    done

    stealth::util::log::info 'waiting up to %ds for %s to answer on %s' \
        "${_conn_wait_for}" "${_conn_wait_host}" "${_conn_wait_port}"

    if stealth::util::retry::until "${_conn_wait_for}" \
        "${_STEALTH_SYS_NET_CONN_INTERVAL}" \
        stealth::sys::net::conn::is_reachable "${_conn_wait_host}" \
        "${_conn_wait_port}" "${_conn_wait_rest[@]}"; then
        return 0
    fi
    return 1
}

#######################################
# Reports whether an address can be reached at all, by opening a connection
# to the host and port it names. A scheme with no port gets the port that
# scheme is reached on.
#
# This says nothing about what the server would answer. url_ok asks that.
#
# Usage:
#   if stealth::sys::net::conn::can_reach 'https://example.com/a'; then ...
#
# Arguments:
#   $1 (String) - The address
#   $@ (String) - --timeout SECONDS
# Returns:
#   0 - The host answers
#   1 - It does not, or the address names no port
#   Exits 1 when no address is given
#######################################
stealth::sys::net::conn::can_reach() {
    stealth::util::assert::not_empty "${1:-}" 'an address is required'
    local -r _conn_cr_url="${1}"
    shift

    local _conn_cr_host _conn_cr_port
    if ! stealth::sys::net::conn::_endpoint _conn_cr_host _conn_cr_port \
        "${_conn_cr_url}"; then
        stealth::util::log::debug '%s names no port to try' "${_conn_cr_url}"
        return 1
    fi

    stealth::sys::net::conn::is_reachable "${_conn_cr_host}" "${_conn_cr_port}" "$@"
}

#######################################
# Reports whether an address answers with something other than an error.
#
# A HEAD request is tried first because it costs nothing to answer. Some
# servers and a good many content networks refuse HEAD or answer it
# differently, so a refusal is followed by a request for the first byte,
# which every server that serves anything will answer.
#
# Usage:
#   if ! stealth::sys::net::conn::url_ok "${url}"; then ...
#
# Arguments:
#   $1 (String) - The address
#   $@ (String) - --timeout SECONDS
# Returns:
#   0 - It answers with a success
#   1 - It does not
#   Exits 1 when no address is given
#######################################
stealth::sys::net::conn::url_ok() {
    stealth::util::assert::not_empty "${1:-}" 'an address is required'
    local -r _conn_ok_url="${1}"
    shift

    local -i _conn_ok_seconds
    stealth::sys::net::conn::_take_timeout _conn_ok_seconds \
        "${_STEALTH_SYS_NET_CONN_TIMEOUT}" "$@"

    if stealth::sys::cmd::silent curl --silent --fail --location --head \
        --proto '=https,http' --proto-redir '=https,http' \
        --connect-timeout "${_conn_ok_seconds}" \
        --max-time "$(( _conn_ok_seconds * 2 ))" \
        --output /dev/null "${_conn_ok_url}"; then
        return 0
    fi

    if stealth::sys::cmd::silent curl --silent --fail --location \
        --range 0-0 --proto '=https,http' --proto-redir '=https,http' \
        --connect-timeout "${_conn_ok_seconds}" \
        --max-time "$(( _conn_ok_seconds * 2 ))" \
        --output /dev/null "${_conn_ok_url}"; then
        return 0
    fi

    stealth::util::log::debug '%s does not answer with a success' "${_conn_ok_url}"
    return 1
}

#######################################
# Fills an array with the addresses a name resolves to, in the order the
# resolver puts them.
#
# getent is asked rather than a DNS tool, because getent answers the question
# the machine will actually answer: it reads /etc/hosts and whatever else the
# name service is set up with, which is what a connection will use.
#
# Usage:
#   stealth::sys::net::conn::resolve where mirror.example.com
#   stealth::sys::net::conn::resolve where "${host}" --family 4
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name
#   $@ (String)  - --family 4 or --family 6 to ask for one kind only
# Returns:
#   0 - It resolves
#   1 - It does not
#   Exits 1 when an output array or a name is missing, or --family is given
#   something other than 4 or 6
#######################################
stealth::sys::net::conn::resolve() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::not_empty "${2:-}" 'a name is required'
    local -n _conn_res_out="${1}"
    local -r _conn_res_name="${2}"
    shift 2

    local _conn_res_what='ahosts'
    while (( $# > 0 )); do
        case "${1}" in
            --family)
                case "${2:-}" in
                    4) _conn_res_what='ahostsv4' ;;
                    6) _conn_res_what='ahostsv6' ;;
                    *) stealth::util::assert::fail \
                        "--family takes 4 or 6, not ${2:-}" ;;
                esac
                shift 2
                ;;
            *)
                stealth::util::assert::fail "resolve does not take ${1}"
                ;;
        esac
    done

    _conn_res_out=()

    local _conn_res_text
    if ! stealth::sys::cmd::capture _conn_res_text getent \
        "${_conn_res_what}" "${_conn_res_name}"; then
        stealth::util::log::debug '%s resolves to nothing' "${_conn_res_name}"
        return 1
    fi

    local -a _conn_res_lines=()
    mapfile -t _conn_res_lines <<< "${_conn_res_text}"

    # getent prints a line per address and socket type. Keeping the stream
    # lines gives one line per address, which is the list a caller wants to
    # try in order.
    local _conn_res_line _conn_res_address _conn_res_kind
    for _conn_res_line in "${_conn_res_lines[@]}"; do
        read -r _conn_res_address _conn_res_kind _ <<< "${_conn_res_line}"
        if [[ "${_conn_res_kind}" != 'STREAM' ]]; then
            continue
        fi
        _conn_res_out+=("${_conn_res_address}")
    done

    (( ${#_conn_res_out[@]} > 0 ))
}
