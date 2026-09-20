#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/iface - Test Suite
# ==============================================================================
# The container has one interface, so a tree that looks like sysfs is built
# instead and the module is pointed at it. What ip would say is mocked, which
# is the only way to ask about an interface with two addresses of the same
# family on a machine that has none.
#
# The test that earns its place is the one where an interface has a
# link-local address and a global one. The first inet6 on nearly every real
# interface is the link-local, and giving that back is the defect in the
# version this replaces.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/iface
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    ADDRESSES=''
    STEALTH_IFACE_DIR="${BATS_TEST_TMPDIR}/net"
    make_iface lo   00:00:00:00:00:00 65536 unknown 1
    make_iface eth0 52:54:00:12:34:56 1500  up      1
    make_iface eth1 52:54:00:65:43:21 9000  down    0
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Builds the files the kernel would keep about an interface.
make_iface() {
    local -r dir="${STEALTH_IFACE_DIR}/${1}"
    mkdir -p "${dir}"
    printf '%s\n' "${2}" > "${dir}/address"
    printf '%s\n' "${3}" > "${dir}/mtu"
    printf '%s\n' "${4}" > "${dir}/operstate"
    printf '%s\n' "${5}" > "${dir}/carrier"
}

# What ip would say about an interface with one address of each family, the
# sixth of them link-local and listed first, as a real interface lists them.
addresses_json() {
    ADDRESSES='[{"ifname":"eth0","addr_info":[
      {"family":"inet","local":"192.168.1.5","prefixlen":24,"scope":"global"},
      {"family":"inet6","local":"fe80::5054:ff:fe12:3456","prefixlen":64,"scope":"link"},
      {"family":"inet6","local":"2001:db8::5","prefixlen":64,"scope":"global"}]}]'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::list
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::list: a machine -> its interfaces, as an array" {
    local names

    stealth::sys::net::iface::list names

    assert_array_length names 3
    assert_array_contains names eth0
    assert_array_contains names lo
}

@test "stealth::sys::net::iface::list: nowhere to look -> returns 1" {
    STEALTH_IFACE_DIR="${BATS_TEST_TMPDIR}/nowhere"

    run stealth::sys::net::iface::list names
    assert_failure 1
}

@test "stealth::sys::net::iface::list: nothing there -> returns 1" {
    STEALTH_IFACE_DIR="${BATS_TEST_TMPDIR}/empty"
    mkdir -p "${STEALTH_IFACE_DIR}"

    run stealth::sys::net::iface::list names
    assert_failure 1
}

@test "stealth::sys::net::iface::list: no output array -> exits 1" {
    run stealth::sys::net::iface::list ''
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::exists
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::exists: an interface that is there -> returns 0" {
    run stealth::sys::net::iface::exists eth0
    assert_success
}

@test "stealth::sys::net::iface::exists: one that is not -> returns 1" {
    run stealth::sys::net::iface::exists eth9
    assert_failure 1
}

@test "stealth::sys::net::iface::exists: no interface -> exits 1" {
    run stealth::sys::net::iface::exists ''
    assert_refused 'an interface is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::address
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::address: an interface -> the address and nothing else" {
    # Not 192.168.1.5/24. A caller writing that into a configuration file
    # has written something that is not an address.
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::address where eth0 --family 4

    assert_equal "${where}" '192.168.1.5'
}

@test "stealth::sys::net::iface::address: --family 6 -> the global one, not the link-local" {
    # The link-local address comes first on nearly every real interface and
    # is of no use off that link.
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::address where eth0 --family 6

    assert_equal "${where}" '2001:db8::5'
}

@test "stealth::sys::net::iface::address: nothing but a link-local one -> that one" {
    mock ip '*' 'printf %s "[{\"addr_info\":[{\"family\":\"inet6\",\"local\":\"fe80::1\",\"prefixlen\":64,\"scope\":\"link\"}]}]"'
    local where

    stealth::sys::net::iface::address where eth0 --family 6

    assert_equal "${where}" 'fe80::1'
}

@test "stealth::sys::net::iface::address: no family said -> whichever is global" {
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::address where eth0

    assert_equal "${where}" '192.168.1.5'
}

@test "stealth::sys::net::iface::address: an interface with none -> returns 1" {
    mock ip '*' 'printf %s "[{\"addr_info\":[]}]"'

    run stealth::sys::net::iface::address where eth0
    assert_failure 1
}

@test "stealth::sys::net::iface::address: no address of that family -> returns 1" {
    mock ip '*' 'printf %s "[{\"addr_info\":[{\"family\":\"inet\",\"local\":\"10.0.0.1\",\"prefixlen\":8,\"scope\":\"global\"}]}]"'

    run stealth::sys::net::iface::address where eth0 --family 6
    assert_failure 1
}

@test "stealth::sys::net::iface::address: ip answers about no interface at all -> returns 1" {
    mock ip '*' 'printf %s "[]"'

    run stealth::sys::net::iface::address where eth0
    assert_failure 1
}

@test "stealth::sys::net::iface::address: ip says nothing -> returns 1" {
    mock ip '*' 'return 1'

    run stealth::sys::net::iface::address where eth0
    assert_failure 1
}

@test "stealth::sys::net::iface::address: --family that is neither -> exits 1" {
    run stealth::sys::net::iface::address where eth0 --family 5
    assert_refused '--family takes 4 or 6, not 5'
}

@test "stealth::sys::net::iface::address: an option it does not take -> exits 1" {
    run stealth::sys::net::iface::address where eth0 --scope global
    assert_refused '--family is the only option here, not --scope'
}

@test "stealth::sys::net::iface::address: no output variable -> exits 1" {
    run stealth::sys::net::iface::address '' eth0
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::iface::address: no interface -> exits 1" {
    run stealth::sys::net::iface::address where
    assert_refused 'an interface is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::cidr
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::cidr: an interface -> the address and its network" {
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::cidr where eth0 --family 4

    assert_equal "${where}" '192.168.1.5/24'
}

@test "stealth::sys::net::iface::cidr: --family 6 -> the global one with its network" {
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::cidr where eth0 --family 6

    assert_equal "${where}" '2001:db8::5/64'
}

@test "stealth::sys::net::iface::cidr: an interface with none -> returns 1" {
    mock ip '*' 'printf %s "[{\"addr_info\":[]}]"'

    run stealth::sys::net::iface::cidr where eth0
    assert_failure 1
}

@test "stealth::sys::net::iface::cidr: no output variable -> exits 1" {
    run stealth::sys::net::iface::cidr '' eth0
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::mac
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::mac: an interface -> its hardware address" {
    local value

    stealth::sys::net::iface::mac value eth0

    assert_equal "${value}" '52:54:00:12:34:56'
}

@test "stealth::sys::net::iface::mac: an interface that is not there -> returns 1" {
    run stealth::sys::net::iface::mac value eth9
    assert_failure 1
}

@test "stealth::sys::net::iface::mac: no output variable -> exits 1" {
    run stealth::sys::net::iface::mac '' eth0
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::mtu
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::mtu: an interface -> the largest packet it carries" {
    local value

    stealth::sys::net::iface::mtu value eth1

    assert_equal "${value}" '9000'
}

@test "stealth::sys::net::iface::mtu: an interface that is not there -> returns 1" {
    run stealth::sys::net::iface::mtu value eth9
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::state
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::state: an interface that is up -> up" {
    local value

    stealth::sys::net::iface::state value eth0

    assert_equal "${value}" 'up'
}

@test "stealth::sys::net::iface::state: an interface that is down -> down" {
    local value

    stealth::sys::net::iface::state value eth1

    assert_equal "${value}" 'down'
}

@test "stealth::sys::net::iface::state: an interface that is not there -> returns 1" {
    run stealth::sys::net::iface::state value eth9
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::is_up
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::is_up: an interface that is up -> returns 0" {
    run stealth::sys::net::iface::is_up eth0
    assert_success
}

@test "stealth::sys::net::iface::is_up: an interface that is down -> returns 1" {
    run stealth::sys::net::iface::is_up eth1
    assert_failure 1
}

@test "stealth::sys::net::iface::is_up: one that says unknown -> returns 0" {
    # A loopback says unknown for ever, and so do most virtual interfaces.
    # Reading that as down makes all of them unusable.
    run stealth::sys::net::iface::is_up lo
    assert_success
}

@test "stealth::sys::net::iface::is_up: an interface that is not there -> returns 1" {
    run stealth::sys::net::iface::is_up eth9
    assert_failure 1
}

@test "stealth::sys::net::iface::is_up: no interface -> exits 1" {
    run stealth::sys::net::iface::is_up ''
    assert_refused 'an interface is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::has_carrier
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::has_carrier: something plugged in -> returns 0" {
    run stealth::sys::net::iface::has_carrier eth0
    assert_success
}

@test "stealth::sys::net::iface::has_carrier: nothing plugged in -> returns 1" {
    run stealth::sys::net::iface::has_carrier eth1
    assert_failure 1
}

@test "stealth::sys::net::iface::has_carrier: an interface that is not there -> returns 1" {
    run stealth::sys::net::iface::has_carrier eth9
    assert_failure 1
}

@test "stealth::sys::net::iface::has_carrier: no interface -> exits 1" {
    run stealth::sys::net::iface::has_carrier ''
    assert_refused 'an interface is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::primary
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::primary: a default route -> the interface it goes out of" {
    mock ip '*' 'printf %s "[{\"dst\":\"default\",\"gateway\":\"192.168.1.1\",\"dev\":\"eth0\"}]"'
    local name

    stealth::sys::net::iface::primary name

    assert_equal "${name}" 'eth0'
}

@test "stealth::sys::net::iface::primary: --family 6 -> ip is asked about that family" {
    mock ip '*' 'printf %s "[{\"dst\":\"default\",\"dev\":\"eth0\"}]"'
    local name

    stealth::sys::net::iface::primary name --family 6

    assert_called_with ip '*-6 route show default*'
}

@test "stealth::sys::net::iface::primary: no default route -> returns 1" {
    mock ip '*' 'printf %s "[]"'

    run stealth::sys::net::iface::primary name
    assert_failure 1
}

@test "stealth::sys::net::iface::primary: no default route -> says so" {
    mock ip '*' 'printf %s "[]"'

    run stealth::sys::net::iface::primary name

    assert_called_with stealth::util::log::debug '*says what the default*'
}

@test "stealth::sys::net::iface::primary: ip says nothing -> returns 1" {
    mock ip '*' 'return 1'

    run stealth::sys::net::iface::primary name
    assert_failure 1
}

@test "stealth::sys::net::iface::primary: no output variable -> exits 1" {
    run stealth::sys::net::iface::primary ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::iface::gateway
# ------------------------------------------------------------------------------

@test "stealth::sys::net::iface::gateway: a default route -> where it points" {
    mock ip '*' 'printf %s "[{\"dst\":\"default\",\"gateway\":\"192.168.1.1\",\"dev\":\"eth0\"}]"'
    local where

    stealth::sys::net::iface::gateway where

    assert_equal "${where}" '192.168.1.1'
}

@test "stealth::sys::net::iface::gateway: a route with no gateway -> returns 1" {
    mock ip '*' 'printf %s "[{\"dst\":\"default\",\"dev\":\"eth0\"}]"'

    run stealth::sys::net::iface::gateway where
    assert_failure 1
}

@test "stealth::sys::net::iface::gateway: --family 4 -> ip is asked about that family" {
    mock ip '*' 'printf %s "[{\"dst\":\"default\",\"gateway\":\"10.0.0.1\"}]"'
    local where

    stealth::sys::net::iface::gateway where --family 4

    assert_called_with ip '*-4 route show default*'
}

@test "stealth::sys::net::iface::gateway: no output variable -> exits 1" {
    run stealth::sys::net::iface::gateway ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# sys/net/iface, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/iface: what the kernel keeps -> is read without a fork" {
    mock ip '*' 'return 1'
    local mac mtu state

    stealth::sys::net::iface::mac mac eth0
    stealth::sys::net::iface::mtu mtu eth0
    stealth::sys::net::iface::state state eth0
    stealth::sys::net::iface::is_up eth0
    stealth::sys::net::iface::has_carrier eth0

    refute_called ip
}

@test "sys/net/iface: nothing is left behind after asking ip" {
    addresses_json
    mock ip '*' "printf '%s' '${ADDRESSES}'"
    local where

    stealth::sys::net::iface::address where eth0

    # shellcheck disable=SC2312  # the count is the answer, not the status
    run bash -c 'ls "${1}"/iface.* 2>/dev/null | wc -l' _ "${TMPDIR}"
    assert_output '0'
}

@test "sys/net/iface: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/iface
    assert_success
}
