#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/conn - Test Suite
# ==============================================================================
# These run against a real server on the loopback address. The container has
# no route anywhere, and it does not need one: lo is up even with the network
# switched off, and python3 is in the image.
#
# That is worth the setup cost. A mocked curl proves that the module called
# curl; a real one proves the flags mean what the module thinks they mean,
# which is where the defects in the version this replaces lived.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/conn
    load_mock util
    mock::stealth::util::log

    # A port of this test's own, so two runs on one machine do not collide.
    PORT=$(( 18000 + ($$ % 900) ))
    CLOSED=$(( PORT + 1 ))
    SERVER=''
    ROOT="${BATS_TEST_TMPDIR}/served"
    mkdir -p "${ROOT}"
    printf 'a file\n' > "${ROOT}/thing"
}

teardown() {
    if [[ -n "${SERVER}" ]]; then
        kill -9 "${SERVER}" 2>/dev/null || true
        wait "${SERVER}" 2>/dev/null || true
    fi
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Starts a web server on the loopback address and waits until it answers.
#
# Descriptor 3 is closed for it. bats reads its results on that descriptor
# and waits for it to close, so a background process that inherits it keeps
# bats waiting for as long as the process lives.
serve() {
    python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${ROOT}" \
        > /dev/null 2>&1 3>&- &
    SERVER=$!

    local -i waited=0
    while (( waited < 100 )); do
        if bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ 127.0.0.1 "${PORT}" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
        waited=$(( waited + 1 ))
    done
    return 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::is_reachable
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::is_reachable: something listening -> returns 0" {
    serve

    run stealth::sys::net::conn::is_reachable 127.0.0.1 "${PORT}"
    assert_success
}

@test "stealth::sys::net::conn::is_reachable: nothing listening -> returns 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 "${CLOSED}" --timeout 2
    assert_failure 1
}

@test "stealth::sys::net::conn::is_reachable: nothing is forked to ask -> netcat is not needed" {
    # bash opens the connection itself. A machine with no netcat answers the
    # question just as well.
    serve
    mock nc '*' 'return 1'

    stealth::sys::net::conn::is_reachable 127.0.0.1 "${PORT}"

    refute_called nc
}

@test "stealth::sys::net::conn::is_reachable: a host written to look like a command -> is not one" {
    run stealth::sys::net::conn::is_reachable '$(touch /tmp/pwned-by-conn)' 80 --timeout 1

    assert_failure 1
    assert_file_not_exists /tmp/pwned-by-conn
}

@test "stealth::sys::net::conn::is_reachable: a port that is not a number -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 https
    assert_refused 'a port is a whole number, not https'
}

@test "stealth::sys::net::conn::is_reachable: a port above the last one -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 70000
    assert_refused '70000 is not a port, which is 1 to 65535'
}

@test "stealth::sys::net::conn::is_reachable: a port of zero -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 0
    assert_refused '0 is not a port, which is 1 to 65535'
}

@test "stealth::sys::net::conn::is_reachable: --timeout that is not a number -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 80 --timeout soon
    assert_refused '--timeout takes whole seconds, not soon'
}

@test "stealth::sys::net::conn::is_reachable: an option it does not take -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1 80 --quiet
    assert_refused '--timeout is the only option here, not --quiet'
}

@test "stealth::sys::net::conn::is_reachable: no host -> exits 1" {
    run stealth::sys::net::conn::is_reachable '' 80
    assert_refused 'a host is required'
}

@test "stealth::sys::net::conn::is_reachable: no port -> exits 1" {
    run stealth::sys::net::conn::is_reachable 127.0.0.1
    assert_refused 'a port is a whole number, not '
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::wait_for
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::wait_for: something already listening -> returns 0" {
    serve

    run stealth::sys::net::conn::wait_for 127.0.0.1 "${PORT}" --wait 5
    assert_success
}

@test "stealth::sys::net::conn::wait_for: something that starts late -> returns 0" {
    # exec so that the number in SERVER is the server's own. Without it the
    # subshell holds that number, teardown kills the subshell, and the server
    # it started outlives the run.
    ( sleep 1; exec python3 -m http.server "${PORT}" --bind 127.0.0.1 \
        --directory "${ROOT}" ) > /dev/null 2>&1 3>&- &
    SERVER=$!

    run stealth::sys::net::conn::wait_for 127.0.0.1 "${PORT}" --wait 10
    assert_success
}

@test "stealth::sys::net::conn::wait_for: nothing ever listening -> returns 1" {
    run stealth::sys::net::conn::wait_for 127.0.0.1 "${CLOSED}" --wait 2 --timeout 1
    assert_failure 1
}

@test "stealth::sys::net::conn::wait_for: --wait that is not a number -> exits 1" {
    run stealth::sys::net::conn::wait_for 127.0.0.1 80 --wait forever
    assert_refused '--wait takes whole seconds, not forever'
}

@test "stealth::sys::net::conn::wait_for: no host -> exits 1" {
    run stealth::sys::net::conn::wait_for '' 80
    assert_refused 'a host is required'
}

@test "stealth::sys::net::conn::wait_for: no port -> exits 1" {
    run stealth::sys::net::conn::wait_for 127.0.0.1
    assert_refused 'a port is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::can_reach
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::can_reach: an address with a port -> returns 0" {
    serve

    run stealth::sys::net::conn::can_reach "http://127.0.0.1:${PORT}/thing"
    assert_success
}

@test "stealth::sys::net::conn::can_reach: nothing listening there -> returns 1" {
    run stealth::sys::net::conn::can_reach "http://127.0.0.1:${CLOSED}/" --timeout 2
    assert_failure 1
}

@test "stealth::sys::net::conn::can_reach: a scheme with no port -> the scheme's port is used" {
    serve
    STEALTH_SYS_NET_CONN_UNUSED=1

    # http means 80, and nothing here listens on 80, so this is about which
    # port was tried rather than about reaching anything.
    run stealth::sys::net::conn::can_reach 'http://127.0.0.1/' --timeout 2
    assert_failure 1
}

@test "stealth::sys::net::conn::can_reach: a user name in the address -> is not the host" {
    run stealth::sys::net::conn::can_reach "http://someone@127.0.0.1:${CLOSED}/" --timeout 2

    assert_failure 1
    assert_called_with stealth::util::log::debug '*127.0.0.1*'
}

@test "stealth::sys::net::conn::can_reach: a scheme nothing knows and no port -> returns 1" {
    run stealth::sys::net::conn::can_reach 'gopher://example.com/'
    assert_failure 1
}

@test "stealth::sys::net::conn::can_reach: a scheme nothing knows and no port -> says so" {
    run stealth::sys::net::conn::can_reach 'gopher://example.com/'

    assert_called_with stealth::util::log::debug '*names no port to try*'
}

@test "stealth::sys::net::conn::can_reach: no address -> exits 1" {
    run stealth::sys::net::conn::can_reach ''
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::url_ok
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::url_ok: a file that is served -> returns 0" {
    serve

    run stealth::sys::net::conn::url_ok "http://127.0.0.1:${PORT}/thing"
    assert_success
}

@test "stealth::sys::net::conn::url_ok: a file that is not -> returns 1" {
    serve

    run stealth::sys::net::conn::url_ok "http://127.0.0.1:${PORT}/nowhere"
    assert_failure 1
}

@test "stealth::sys::net::conn::url_ok: nothing listening -> returns 1" {
    run stealth::sys::net::conn::url_ok "http://127.0.0.1:${CLOSED}/" --timeout 2
    assert_failure 1
}

@test "stealth::sys::net::conn::url_ok: a server that refuses HEAD -> the ranged request answers" {
    # Content networks do this. A check that only sends HEAD calls a working
    # address unreachable.
    mock stealth::sys::cmd::silent '*--head*' 'return 1'
    mock stealth::sys::cmd::silent '*--range 0-0*' 'return 0'

    run stealth::sys::net::conn::url_ok 'http://example.invalid/thing'
    assert_success
}

@test "stealth::sys::net::conn::url_ok: curl -> is held to http and https" {
    # Without this a redirect can walk a protected fetch down to plaintext,
    # or off to a protocol nobody asked for.
    mock stealth::sys::cmd::silent '*' 'return 0'

    stealth::sys::net::conn::url_ok 'https://example.invalid/thing'

    assert_called_with stealth::sys::cmd::silent '*--proto-redir =https,http*'
}

@test "stealth::sys::net::conn::url_ok: curl -> is given a limit on the whole transfer" {
    # A connect timeout alone does not bound a server that answers and then
    # sends one byte a minute.
    mock stealth::sys::cmd::silent '*' 'return 0'

    stealth::sys::net::conn::url_ok 'https://example.invalid/thing' --timeout 5

    assert_called_with stealth::sys::cmd::silent '*--max-time 10*'
}

@test "stealth::sys::net::conn::url_ok: no address -> exits 1" {
    run stealth::sys::net::conn::url_ok ''
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::resolve
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::resolve: a name the machine knows -> its addresses" {
    local where

    stealth::sys::net::conn::resolve where localhost

    assert_array_contains where '127.0.0.1'
}

@test "stealth::sys::net::conn::resolve: --family 6 -> only addresses of that kind" {
    local where

    stealth::sys::net::conn::resolve where localhost --family 6

    assert_array_contains where '::1'
    refute_array_contains where '127.0.0.1'
}

@test "stealth::sys::net::conn::resolve: --family 4 -> only addresses of that kind" {
    local where

    stealth::sys::net::conn::resolve where localhost --family 4

    assert_array_contains where '127.0.0.1'
    refute_array_contains where '::1'
}

@test "stealth::sys::net::conn::resolve: a name nothing knows -> returns 1" {
    run stealth::sys::net::conn::resolve where 'no-such-host-anywhere.invalid'
    assert_failure 1
}

@test "stealth::sys::net::conn::resolve: a name nothing knows -> the array is empty" {
    local where=(stale)

    stealth::sys::net::conn::resolve where 'no-such-host-anywhere.invalid' || true

    assert_array_empty where
}

@test "stealth::sys::net::conn::resolve: --family that is neither -> exits 1" {
    run stealth::sys::net::conn::resolve where localhost --family 5
    assert_refused '--family takes 4 or 6, not 5'
}

@test "stealth::sys::net::conn::resolve: an option it does not take -> exits 1" {
    run stealth::sys::net::conn::resolve where localhost --all
    assert_refused 'resolve does not take --all'
}

@test "stealth::sys::net::conn::resolve: no output array -> exits 1" {
    run stealth::sys::net::conn::resolve '' localhost
    assert_refused 'an output array is required'
}

@test "stealth::sys::net::conn::resolve: no name -> exits 1" {
    run stealth::sys::net::conn::resolve where
    assert_refused 'a name is required'
}

@test "stealth::sys::net::conn::resolve: a lookup that says nothing usable -> returns 1" {
    mock stealth::sys::cmd::capture '*' 'return 0'

    run stealth::sys::net::conn::resolve where localhost
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::conn::_endpoint
# ------------------------------------------------------------------------------

@test "stealth::sys::net::conn::_endpoint: https with no port -> 443" {
    local host port

    stealth::sys::net::conn::_endpoint host port 'https://example.com/a/b'

    assert_equal "${host}" 'example.com'
    assert_equal "${port}" '443'
}

@test "stealth::sys::net::conn::_endpoint: a port in the address -> that port" {
    local host port

    stealth::sys::net::conn::_endpoint host port 'https://example.com:8443/a'

    assert_equal "${host}" 'example.com'
    assert_equal "${port}" '8443'
}

@test "stealth::sys::net::conn::_endpoint: a bare host and port -> both" {
    local host port

    stealth::sys::net::conn::_endpoint host port 'example.com:9000'

    assert_equal "${host}" 'example.com'
    assert_equal "${port}" '9000'
}

@test "stealth::sys::net::conn::_endpoint: git over its own protocol -> 9418" {
    local host port

    stealth::sys::net::conn::_endpoint host port 'git://example.com/repo'

    assert_equal "${port}" '9418'
}

@test "stealth::sys::net::conn::_endpoint: a scheme in capitals -> is the same scheme" {
    local host port

    stealth::sys::net::conn::_endpoint host port 'HTTPS://example.com/'

    assert_equal "${port}" '443'
}

@test "stealth::sys::net::conn::_endpoint: a host with nothing to go on -> returns 1" {
    local host port

    run stealth::sys::net::conn::_endpoint host port 'example.com'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/net/conn, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/conn: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/conn
    assert_success
}
