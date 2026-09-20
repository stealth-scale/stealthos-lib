#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/fetch - Test Suite
# ==============================================================================
# These run against a real server on the loopback address, with a real curl.
# The container has no route anywhere and does not need one.
#
# Two tests are the ones that matter. One kills the server and then asks for
# the same digest again, which can only be answered from the store. The other
# serves the wrong bytes and checks that nothing is written where the caller
# asked, because a caller must never be able to open a file that failed its
# check.
#
# Anything backgrounded here closes descriptor 3. bats waits for that
# descriptor to close, so a server that inherits it hangs the run.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/fetch
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    PORT=$(( 19000 + ($$ % 900) ))
    SERVER=''
    WORK="${BATS_TEST_TMPDIR}/work"
    ROOT="${WORK}/served"
    STORE="${WORK}/store"
    mkdir -p "${ROOT}"

    printf 'the real tarball\n' > "${ROOT}/good.tar"
    printf 'not the tarball\n'  > "${ROOT}/bad.tar"
    printf '%s' '{"tag_name":"v1.2.3","assets":[{"name":"tool-linux-amd64.tar.gz","url":"u1"},{"name":"tool-linux-arm64.tar.gz","url":"u2"}]}' \
        > "${ROOT}/release.json"

    stealth::sys::runtime::hash::digest GOOD "${ROOT}/good.tar"
    BASE="http://127.0.0.1:${PORT}"
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

# Stops the server, for the tests about what happens without one.
unserve() {
    kill -9 "${SERVER}" 2>/dev/null || true
    wait "${SERVER}" 2>/dev/null || true
    SERVER=''
}

# ------------------------------------------------------------------------------
# stealth::sys::net::fetch::download
# ------------------------------------------------------------------------------

@test "stealth::sys::net::fetch::download: a file -> arrives" {
    serve

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out"

    assert_files_equal "${WORK}/out" "${ROOT}/good.tar"
}

@test "stealth::sys::net::fetch::download: a digest that matches -> arrives" {
    serve

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" \
        --digest "${GOOD}"

    assert_files_equal "${WORK}/out" "${ROOT}/good.tar"
}

@test "stealth::sys::net::fetch::download: a digest that does not match -> returns 1" {
    serve

    run stealth::sys::net::fetch::download "${BASE}/bad.tar" "${WORK}/out" \
        --digest "${GOOD}" --no-cache
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: a digest that does not match -> writes nothing" {
    # The caller must never be able to open a file that failed its check.
    serve

    stealth::sys::net::fetch::download "${BASE}/bad.tar" "${WORK}/out" \
        --digest "${GOOD}" --no-cache || true

    assert_file_not_exists "${WORK}/out"
}

@test "stealth::sys::net::fetch::download: a digest already in the store -> no server is needed" {
    # The whole reason the store is keyed by digest.
    serve
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/first" \
        --digest "${GOOD}"
    unserve

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/second" \
        --digest "${GOOD}"

    assert_files_equal "${WORK}/second" "${ROOT}/good.tar"
}

@test "stealth::sys::net::fetch::download: --no-cache -> the store is not asked" {
    serve
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/first" \
        --digest "${GOOD}"
    unserve

    run stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/second" \
        --digest "${GOOD}" --no-cache --retries 0 --timeout 5
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: no digest -> nothing is stored" {
    # Nothing can be checked, so nothing should be trusted twice.
    serve
    stealth::sys::net::cache::configure "${STORE}"

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out"
    local held

    stealth::sys::net::cache::entries held

    assert_array_empty held
}

@test "stealth::sys::net::fetch::download: a mirror -> is tried when the first fails" {
    serve

    stealth::sys::net::fetch::download "${BASE}/bad.tar" "${WORK}/out" \
        --digest "${GOOD}" --no-cache --mirror "${BASE}/good.tar"

    assert_files_equal "${WORK}/out" "${ROOT}/good.tar"
}

@test "stealth::sys::net::fetch::download: several mirrors -> the first that gives the bytes wins" {
    serve

    stealth::sys::net::fetch::download "${BASE}/nowhere" "${WORK}/out" \
        --digest "${GOOD}" --no-cache \
        --mirror "${BASE}/bad.tar" --mirror "${BASE}/good.tar"

    assert_files_equal "${WORK}/out" "${ROOT}/good.tar"
}

@test "stealth::sys::net::fetch::download: no mirror gives the bytes -> returns 1" {
    serve

    run stealth::sys::net::fetch::download "${BASE}/bad.tar" "${WORK}/out" \
        --digest "${GOOD}" --no-cache --mirror "${BASE}/nowhere"
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: an answer that is an error page -> returns 1" {
    serve

    run stealth::sys::net::fetch::download "${BASE}/nowhere" "${WORK}/out" --retries 0
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: an answer that is an error page -> writes nothing" {
    serve

    stealth::sys::net::fetch::download "${BASE}/nowhere" "${WORK}/out" --retries 0 || true

    assert_file_not_exists "${WORK}/out"
}

@test "stealth::sys::net::fetch::download: nothing listening -> returns 1" {
    run stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" \
        --retries 0 --timeout 5
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: a directory that is not there -> is made" {
    serve

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/deep/down/out"

    assert_file_exists "${WORK}/deep/down/out"
}

@test "stealth::sys::net::fetch::download: a destination with no directory in it -> lands in this one" {
    serve
    cd "${WORK}"

    stealth::sys::net::fetch::download "${BASE}/good.tar" out

    assert_file_exists "${WORK}/out"
}

@test "stealth::sys::net::fetch::download: nothing is left behind when it fails" {
    serve

    stealth::sys::net::fetch::download "${BASE}/bad.tar" "${WORK}/out" \
        --digest "${GOOD}" --no-cache || true

    run bash -c 'ls "${1}"/fetch.* 2>/dev/null | wc -l' _ "${WORK}"
    assert_output '0'
}

@test "stealth::sys::net::fetch::download: a file that cannot be put in place -> returns 1" {
    # It arrived and it was whole. A caller told the download succeeded goes
    # on to open a file that was never written.
    serve
    mkdir -p "${WORK}/out/in the way"

    run stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::fetch::download: a file that cannot be put in place -> says so" {
    serve
    mkdir -p "${WORK}/out/in the way"

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" || true

    assert_called_with stealth::util::log::warn '*could not be put at*'
}

@test "stealth::sys::net::fetch::download: a file that cannot be put in place -> leaves nothing behind" {
    serve
    mkdir -p "${WORK}/out/in the way"

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" || true

    run bash -c 'ls "${1}"/fetch.* 2>/dev/null | wc -l' _ "${WORK}"
    assert_output '0'
}

@test "stealth::sys::net::fetch::download: curl -> is held to http and https" {
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" || true

    assert_called_with stealth::sys::cmd::try '*--proto =https,http*'
    assert_called_with stealth::sys::cmd::try '*--proto-redir =https,http*'
}

@test "stealth::sys::net::fetch::download: curl -> is given a limit on the whole transfer" {
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" \
        --timeout 42 || true

    assert_called_with stealth::sys::cmd::try '*--max-time 42*'
}

@test "stealth::sys::net::fetch::download: curl -> is told to retry a refused connection" {
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" || true

    assert_called_with stealth::sys::cmd::try '*--retry-connrefused*'
}

@test "stealth::sys::net::fetch::download: a redirect that goes round for ever -> is not followed" {
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" || true

    assert_called_with stealth::sys::cmd::try '*--max-redirs*'
}

@test "stealth::sys::net::fetch::download: --header -> is sent" {
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/good.tar" "${WORK}/out" \
        --header 'Accept: application/json' || true

    assert_called_with stealth::sys::cmd::try '*--header Accept: application/json*'
}

@test "stealth::sys::net::fetch::download: --digest with nothing after it -> exits 1" {
    run stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" --digest
    assert_refused '--digest takes a digest'
}

@test "stealth::sys::net::fetch::download: --timeout that is not a number -> exits 1" {
    run stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" --timeout soon
    assert_refused '--timeout takes whole seconds, not soon'
}

@test "stealth::sys::net::fetch::download: an option it does not take -> exits 1" {
    run stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" --insecure
    assert_refused 'fetch does not take --insecure'
}

@test "stealth::sys::net::fetch::download: something that is not an option -> exits 1" {
    run stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" stray
    assert_refused 'download does not take stray'
}

@test "stealth::sys::net::fetch::download: no address -> exits 1" {
    run stealth::sys::net::fetch::download '' "${WORK}/out"
    assert_refused 'an address is required'
}

@test "stealth::sys::net::fetch::download: nowhere to put it -> exits 1" {
    run stealth::sys::net::fetch::download "${BASE}/x" ''
    assert_refused 'somewhere to put it is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::fetch::text
# ------------------------------------------------------------------------------

@test "stealth::sys::net::fetch::text: an answer -> is in the variable" {
    serve
    local body

    stealth::sys::net::fetch::text body "${BASE}/good.tar"

    assert_equal "${body}" 'the real tarball'
}

@test "stealth::sys::net::fetch::text: an error page -> returns 1" {
    serve

    run stealth::sys::net::fetch::text body "${BASE}/nowhere" --retries 0
    assert_failure 1
}

@test "stealth::sys::net::fetch::text: nothing listening -> returns 1" {
    run stealth::sys::net::fetch::text body "${BASE}/good.tar" --retries 0 --timeout 5
    assert_failure 1
}

@test "stealth::sys::net::fetch::text: something that is not an option -> exits 1" {
    run stealth::sys::net::fetch::text body "${BASE}/x" stray
    assert_refused 'text does not take stray'
}

@test "stealth::sys::net::fetch::text: no output variable -> exits 1" {
    run stealth::sys::net::fetch::text '' "${BASE}/x"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::fetch::text: no address -> exits 1" {
    run stealth::sys::net::fetch::text body
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::fetch::json
# ------------------------------------------------------------------------------

@test "stealth::sys::net::fetch::json: a path -> the value at it" {
    serve
    local tag

    stealth::sys::net::fetch::json tag "${BASE}/release.json" tag_name

    assert_equal "${tag}" 'v1.2.3'
}

@test "stealth::sys::net::fetch::json: a step into an array -> is an index" {
    serve
    local name

    stealth::sys::net::fetch::json name "${BASE}/release.json" assets 1 name

    assert_equal "${name}" 'tool-linux-arm64.tar.gz'
}

@test "stealth::sys::net::fetch::json: a path that is not there -> returns 1" {
    serve

    run stealth::sys::net::fetch::json value "${BASE}/release.json" nowhere
    assert_failure 1
}

@test "stealth::sys::net::fetch::json: an answer that is not JSON -> returns 1" {
    serve

    run stealth::sys::net::fetch::json value "${BASE}/good.tar" tag_name
    assert_failure 1
}

@test "stealth::sys::net::fetch::json: an error page -> returns 1" {
    serve

    run stealth::sys::net::fetch::json value "${BASE}/nowhere" tag_name --retries 0
    assert_failure 1
}

@test "stealth::sys::net::fetch::json: an option before the path -> is not part of it" {
    serve
    local tag

    stealth::sys::net::fetch::json tag "${BASE}/release.json" --timeout 30 tag_name

    assert_equal "${tag}" 'v1.2.3'
}

@test "stealth::sys::net::fetch::json: nothing is left behind" {
    serve
    local tag

    stealth::sys::net::fetch::json tag "${BASE}/release.json" tag_name

    run bash -c 'ls "${1}"/answer.* 2>/dev/null | wc -l' _ "${TMPDIR}"
    assert_output '0'
}

@test "stealth::sys::net::fetch::json: no path -> exits 1" {
    run stealth::sys::net::fetch::json value "${BASE}/x"
    assert_refused 'a path is required'
}

@test "stealth::sys::net::fetch::json: no output variable -> exits 1" {
    run stealth::sys::net::fetch::json '' "${BASE}/x" tag
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::fetch::json: no address -> exits 1" {
    run stealth::sys::net::fetch::json value
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::fetch::authorize
# ------------------------------------------------------------------------------

@test "stealth::sys::net::fetch::authorize: credentials -> are written where curl reads them" {
    stealth::sys::net::fetch::authorize api.example.com someone 's3cr3t' \
        "${WORK}/netrc"

    assert_file_contains "${WORK}/netrc" 'machine api.example.com login someone'
}

@test "stealth::sys::net::fetch::authorize: the file -> is nobody else's to read" {
    stealth::sys::net::fetch::authorize api.example.com someone 's3cr3t' \
        "${WORK}/netrc"

    assert_file_permission 0600 "${WORK}/netrc"
}

@test "stealth::sys::net::fetch::authorize: afterwards -> curl is told to read it" {
    stealth::sys::net::fetch::authorize api.example.com someone 's3cr3t' \
        "${WORK}/netrc"
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" || true

    assert_called_with stealth::sys::cmd::try "*--netrc-file ${WORK}/netrc*"
}

@test "stealth::sys::net::fetch::authorize: the password -> is not in the command line" {
    # A command line is readable by anyone who can list processes.
    stealth::sys::net::fetch::authorize api.example.com someone 's3cr3t' \
        "${WORK}/netrc"
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" || true

    refute_called_with stealth::sys::cmd::try '*s3cr3t*'
}

@test "stealth::sys::net::fetch::authorize: nothing said about where -> a temporary file is used" {
    stealth::sys::net::fetch::authorize api.example.com someone 's3cr3t'

    assert_file_exists "${STEALTH_NET_NETRC}"
    assert_file_permission 0600 "${STEALTH_NET_NETRC}"
}

@test "stealth::sys::net::fetch::authorize: no host -> exits 1" {
    run stealth::sys::net::fetch::authorize '' someone secret
    assert_refused 'a host is required'
}

@test "stealth::sys::net::fetch::authorize: no login -> exits 1" {
    run stealth::sys::net::fetch::authorize api.example.com '' secret
    assert_refused 'a login is required'
}

@test "stealth::sys::net::fetch::authorize: no password -> exits 1" {
    run stealth::sys::net::fetch::authorize api.example.com someone ''
    assert_refused 'a password is required'
}

# ------------------------------------------------------------------------------
# sys/net/fetch, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/fetch: no credentials configured -> curl is not told to read any" {
    # curl reads ~/.netrc on its own otherwise, which is not something a
    # build should pick up by accident.
    mock stealth::sys::cmd::try '*' 'return 1'

    stealth::sys::net::fetch::download "${BASE}/x" "${WORK}/out" || true

    refute_called_with stealth::sys::cmd::try '*--netrc*'
}

@test "sys/net/fetch: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/fetch
    assert_success
}
