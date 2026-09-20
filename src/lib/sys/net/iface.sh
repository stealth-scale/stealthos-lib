###############################################################################
# module: sys/net/iface
# layer: sys
# description: What the network interfaces of a machine are and what they
#              are set to.
#
#              Addresses come from ip asked for JSON and read with
#              sys/data/json. The version this replaces matched a regular
#              expression against ip's output for people, which is a format
#              with no promise attached to it, and took the first inet6 it
#              found. The first inet6 on almost every interface is the
#              link-local address, which is never the one a caller wanted.
#
#              An address and the size of its network are two answers, and
#              this gives them separately. A caller asking for an address and
#              writing 192.168.1.5/24 into a configuration file has written
#              something that is not an address.
#
#              Everything a machine keeps in sysfs is read from sysfs: the
#              names, the hardware address, the size of a packet, whether the
#              link is up, whether anything is plugged in. None of those
#              costs a fork.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_NET_IFACE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_IFACE=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/tmp" "sys/data/json"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where the kernel says what the interfaces are. A test points this somewhere
# else.
declare -g STEALTH_IFACE_DIR='/sys/class/net'

# The states that count as up. A loopback and a good many virtual interfaces
# report unknown for ever, because nothing about them can go down.
declare -gra _STEALTH_SYS_NET_IFACE_UP=(up unknown)

# What ip calls each family, and which one a caller means by 4 and 6.
declare -grA _STEALTH_SYS_NET_IFACE_FAMILY=([4]=inet [6]=inet6)

# The scope an address has to have to be worth giving back. A link-local
# address is the first inet6 on nearly every interface and is of no use to
# anything outside that link.
declare -gr _STEALTH_SYS_NET_IFACE_SCOPE='global'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads one of the files the kernel keeps about an interface.
#
# Usage:
#   stealth::sys::net::iface::_sysfs value eth0 address
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
#   $3 (String)  - Which file
# Globals:
#   STEALTH_IFACE_DIR (Read)
# Returns:
#   0 - Read something
#   1 - There is nothing there to read
#######################################
stealth::sys::net::iface::_sysfs() {
    local -n _iface_sys_out="${1}"

    _iface_sys_out=''
    local -r _iface_sys_path="${STEALTH_IFACE_DIR}/${2}/${3}"
    if [[ ! -r "${_iface_sys_path}" ]]; then
        return 1
    fi

    read -r _iface_sys_out < "${_iface_sys_path}" || true
    [[ -n "${_iface_sys_out}" ]]
}

#######################################
# Asks ip about something and leaves the answer in a file sys/data/json can
# read.
#
# Usage:
#   stealth::sys::net::iface::_ask file addr show eth0
#
# Arguments:
#   $1 (Nameref) - The output variable for the path of the file
#   $@ (String)  - What to ask ip
# Returns:
#   0 - It answered
#   1 - It did not
#######################################
stealth::sys::net::iface::_ask() {
    local -n _iface_ask_out="${1}"
    shift

    stealth::sys::io::tmp::file _iface_ask_out 'iface.XXXXXXXX.json'

    local _iface_ask_text
    if ! stealth::sys::cmd::capture _iface_ask_text ip -json "$@"; then
        stealth::sys::io::tmp::remove "${_iface_ask_out}"
        return 1
    fi

    printf '%s\n' "${_iface_ask_text}" > "${_iface_ask_out}"
    return 0
}

#######################################
# Reads --family off the arguments and gives back what ip calls it.
#
# Usage:
#   stealth::sys::net::iface::_take_family family "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable, empty when no family was asked for
#   $@ (String)  - The arguments
# Globals:
#   _STEALTH_SYS_NET_IFACE_FAMILY (Read)
# Returns:
#   0 - Read
#   Exits 1 when --family is given anything but 4 or 6, or anything else is
#   given at all
#######################################
stealth::sys::net::iface::_take_family() {
    local -n _iface_fam_out="${1}"
    shift

    _iface_fam_out=''
    while (( $# > 0 )); do
        case "${1}" in
            --family)
                if [[ ! -v _STEALTH_SYS_NET_IFACE_FAMILY["${2:-}"] ]]; then
                    stealth::util::assert::fail \
                        "--family takes 4 or 6, not ${2:-}"
                fi
                _iface_fam_out="${_STEALTH_SYS_NET_IFACE_FAMILY[${2}]}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail \
                    "--family is the only option here, not ${1}"
                ;;
        esac
    done
    return 0
}

#######################################
# Finds the address of an interface, and how big its network is.
#
# An address of global scope is taken in preference to anything else, because
# the link-local address is the first one on nearly every interface and is of
# no use off that link.
#
# Usage:
#   stealth::sys::net::iface::_address addr size eth0 inet
#
# Arguments:
#   $1 (Nameref) - The output variable for the address
#   $2 (Nameref) - The output variable for the size of the network
#   $3 (String)  - The interface
#   $4 (String)  - inet, inet6, or empty for whichever comes first
# Globals:
#   _STEALTH_SYS_NET_IFACE_SCOPE (Read)
# Returns:
#   0 - Found
#   1 - It has none of that kind
#######################################
stealth::sys::net::iface::_address() {
    local -n _iface_addr_out="${1}"
    local -n _iface_addr_size="${2}"

    _iface_addr_out=''
    _iface_addr_size=''

    local _iface_addr_file
    if ! stealth::sys::net::iface::_ask _iface_addr_file addr show "${3}"; then
        return 1
    fi

    local _iface_addr_count
    if ! stealth::sys::data::json::length _iface_addr_count \
        "${_iface_addr_file}" 0 addr_info; then
        stealth::sys::io::tmp::remove "${_iface_addr_file}"
        return 1
    fi

    local _iface_addr_family _iface_addr_scope _iface_addr_one _iface_addr_len
    local _iface_addr_first='' _iface_addr_first_len=''
    local -i _iface_addr_at=0

    while (( _iface_addr_at < _iface_addr_count )); do
        stealth::sys::data::json::read _iface_addr_family \
            "${_iface_addr_file}" 0 addr_info "${_iface_addr_at}" family
        stealth::sys::data::json::read _iface_addr_one \
            "${_iface_addr_file}" 0 addr_info "${_iface_addr_at}" local
        stealth::sys::data::json::read _iface_addr_len \
            "${_iface_addr_file}" 0 addr_info "${_iface_addr_at}" prefixlen
        stealth::sys::data::json::read _iface_addr_scope \
            "${_iface_addr_file}" 0 addr_info "${_iface_addr_at}" scope

        _iface_addr_at=$(( _iface_addr_at + 1 ))

        if [[ -n "${4}" && "${_iface_addr_family}" != "${4}" ]]; then
            continue
        fi
        if [[ -z "${_iface_addr_first}" ]]; then
            _iface_addr_first="${_iface_addr_one}"
            _iface_addr_first_len="${_iface_addr_len}"
        fi
        if [[ "${_iface_addr_scope}" == "${_STEALTH_SYS_NET_IFACE_SCOPE}" ]]; then
            _iface_addr_out="${_iface_addr_one}"
            _iface_addr_size="${_iface_addr_len}"
            break
        fi
    done

    stealth::sys::io::tmp::remove "${_iface_addr_file}"

    if [[ -z "${_iface_addr_out}" ]]; then
        _iface_addr_out="${_iface_addr_first}"
        _iface_addr_size="${_iface_addr_first_len}"
    fi

    [[ -n "${_iface_addr_out}" ]]
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Fills an array with the interfaces a machine has.
#
# Usage:
#   stealth::sys::net::iface::list names
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   STEALTH_IFACE_DIR (Read)
# Returns:
#   0 - Filled
#   1 - The machine says it has none
#   Exits 1 when no output array is given
#######################################
stealth::sys::net::iface::list() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    local -n _iface_list_out="${1}"

    _iface_list_out=()
    if [[ ! -d "${STEALTH_IFACE_DIR}" ]]; then
        return 1
    fi

    local _iface_list_path
    for _iface_list_path in "${STEALTH_IFACE_DIR}"/*; do
        if [[ ! -e "${_iface_list_path}" ]]; then
            continue
        fi
        _iface_list_out+=("${_iface_list_path##*/}")
    done

    (( ${#_iface_list_out[@]} > 0 ))
}

#######################################
# Reports whether a machine has an interface of that name.
#
# Usage:
#   if ! stealth::sys::net::iface::exists eth0; then ...
#
# Arguments:
#   $1 (String) - The interface
# Globals:
#   STEALTH_IFACE_DIR (Read)
# Returns:
#   0 - It has
#   1 - It has not
#   Exits 1 when no interface is given
#######################################
stealth::sys::net::iface::exists() {
    stealth::util::assert::not_empty "${1:-}" 'an interface is required'

    [[ -d "${STEALTH_IFACE_DIR}/${1}" ]]
}

#######################################
# Says the address of an interface, and nothing else. The size of the network
# is what cidr gives.
#
# Usage:
#   stealth::sys::net::iface::address where eth0
#   stealth::sys::net::iface::address where eth0 --family 6
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
#   $@ (String)  - --family 4 or --family 6
# Returns:
#   0 - Said
#   1 - It has no address of that kind
#   Exits 1 when an output variable or an interface is missing
#######################################
stealth::sys::net::iface::address() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an interface is required'
    local -r _iface_a_var="${1}"
    local -r _iface_a_name="${2}"
    shift 2

    local _iface_a_family
    stealth::sys::net::iface::_take_family _iface_a_family "$@"

    local _iface_a_size
    stealth::sys::net::iface::_address "${_iface_a_var}" _iface_a_size \
        "${_iface_a_name}" "${_iface_a_family}"
}

#######################################
# Says the address of an interface with the size of its network after it,
# which is what a configuration file asking for a network wants.
#
# Usage:
#   stealth::sys::net::iface::cidr where eth0
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
#   $@ (String)  - --family 4 or --family 6
# Returns:
#   0 - Said
#   1 - It has no address of that kind
#   Exits 1 when an output variable or an interface is missing
#######################################
stealth::sys::net::iface::cidr() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an interface is required'
    local -n _iface_c_out="${1}"
    local -r _iface_c_name="${2}"
    shift 2

    local _iface_c_family
    stealth::sys::net::iface::_take_family _iface_c_family "$@"

    local _iface_c_address _iface_c_size
    if ! stealth::sys::net::iface::_address _iface_c_address _iface_c_size \
        "${_iface_c_name}" "${_iface_c_family}"; then
        _iface_c_out=''
        return 1
    fi

    _iface_c_out="${_iface_c_address}/${_iface_c_size}"
    return 0
}

#######################################
# Says the hardware address of an interface.
#
# Usage:
#   stealth::sys::net::iface::mac address eth0
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
# Returns:
#   0 - Said
#   1 - There is no such interface, or it has none
#   Exits 1 when an output variable or an interface is missing
#######################################
stealth::sys::net::iface::mac() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an interface is required'

    stealth::sys::net::iface::_sysfs "${1}" "${2}" address
}

#######################################
# Says the largest packet an interface will carry.
#
# Usage:
#   stealth::sys::net::iface::mtu size eth0
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
# Returns:
#   0 - Said
#   1 - There is no such interface
#   Exits 1 when an output variable or an interface is missing
#######################################
stealth::sys::net::iface::mtu() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an interface is required'

    stealth::sys::net::iface::_sysfs "${1}" "${2}" mtu
}

#######################################
# Says what state an interface is in: up, down, or unknown for the ones that
# cannot be either.
#
# Usage:
#   stealth::sys::net::iface::state how eth0
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The interface
# Returns:
#   0 - Said
#   1 - There is no such interface
#   Exits 1 when an output variable or an interface is missing
#######################################
stealth::sys::net::iface::state() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an interface is required'

    stealth::sys::net::iface::_sysfs "${1}" "${2}" operstate
}

#######################################
# Reports whether an interface is up.
#
# Unknown counts as up. A loopback and a great many virtual interfaces report
# unknown for ever, and treating that as down makes them all unusable.
#
# Usage:
#   if ! stealth::sys::net::iface::is_up eth0; then ...
#
# Arguments:
#   $1 (String) - The interface
# Globals:
#   _STEALTH_SYS_NET_IFACE_UP (Read)
# Returns:
#   0 - It is
#   1 - It is not, or there is no such interface
#   Exits 1 when no interface is given
#######################################
stealth::sys::net::iface::is_up() {
    local _iface_up_state
    if ! stealth::sys::net::iface::state _iface_up_state "${1:-}"; then
        return 1
    fi

    local _iface_up_one
    for _iface_up_one in "${_STEALTH_SYS_NET_IFACE_UP[@]}"; do
        if [[ "${_iface_up_state}" == "${_iface_up_one}" ]]; then
            return 0
        fi
    done
    return 1
}

#######################################
# Reports whether anything is plugged into an interface.
#
# Usage:
#   if ! stealth::sys::net::iface::has_carrier eth0; then ...
#
# Arguments:
#   $1 (String) - The interface
# Returns:
#   0 - Something is
#   1 - Nothing is, or there is no such interface
#   Exits 1 when no interface is given
#######################################
stealth::sys::net::iface::has_carrier() {
    stealth::util::assert::not_empty "${1:-}" 'an interface is required'

    local _iface_carr_value
    if ! stealth::sys::net::iface::_sysfs _iface_carr_value "${1}" carrier; then
        return 1
    fi

    [[ "${_iface_carr_value}" == '1' ]]
}

#######################################
# Says which interface a machine reaches the rest of the world through, which
# is the one the default route goes out of.
#
# This is what a caller asking "what is my address" almost always means, and
# working it out by picking the first interface that is not the loopback is
# how a machine with a bridge and three virtual interfaces gets the wrong
# answer.
#
# Usage:
#   stealth::sys::net::iface::primary name
#   stealth::sys::net::iface::primary name --family 6
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - --family 4 or --family 6
# Returns:
#   0 - Said
#   1 - There is no default route
#   Exits 1 when no output variable is given
#######################################
stealth::sys::net::iface::primary() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -r _iface_p_var="${1}"
    shift

    local _iface_p_family
    stealth::sys::net::iface::_take_family _iface_p_family "$@"

    stealth::sys::net::iface::_route "${_iface_p_var}" dev "${_iface_p_family}"
}

#######################################
# Says the address a machine sends what it cannot reach directly to.
#
# Usage:
#   stealth::sys::net::iface::gateway where
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - --family 4 or --family 6
# Returns:
#   0 - Said
#   1 - There is no default route, or it has no gateway
#   Exits 1 when no output variable is given
#######################################
stealth::sys::net::iface::gateway() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -r _iface_g_var="${1}"
    shift

    local _iface_g_family
    stealth::sys::net::iface::_take_family _iface_g_family "$@"

    stealth::sys::net::iface::_route "${_iface_g_var}" gateway "${_iface_g_family}"
}

#######################################
# Reads one field of the default route.
#
# Usage:
#   stealth::sys::net::iface::_route name dev inet
#
# Arguments:
#   $1 (String) - The output variable
#   $2 (String) - Which field: dev or gateway
#   $3 (String) - inet, inet6, or empty for whichever the machine prefers
# Returns:
#   0 - Read
#   1 - There is no default route, or it has no such field
#######################################
stealth::sys::net::iface::_route() {
    local -a _iface_r_ask=(route show default)
    if [[ "${3}" == 'inet6' ]]; then
        _iface_r_ask=(-6 route show default)
    elif [[ "${3}" == 'inet' ]]; then
        _iface_r_ask=(-4 route show default)
    fi

    local _iface_r_file
    if ! stealth::sys::net::iface::_ask _iface_r_file "${_iface_r_ask[@]}"; then
        return 1
    fi

    local -i _iface_r_status=0
    stealth::sys::data::json::read "${1}" "${_iface_r_file}" 0 "${2}" \
        || _iface_r_status=$?

    stealth::sys::io::tmp::remove "${_iface_r_file}"

    if (( _iface_r_status != 0 )); then
        stealth::util::log::debug 'nothing here says what the default %s is' "${2}"
        return 1
    fi
    return 0
}
