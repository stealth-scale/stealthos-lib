#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/cache - Test Suite
# ==============================================================================
# The promise this module makes is that what comes out of the store is what
# its name says. The test that matters is the one that edits an entry behind
# the store's back and checks that get refuses it and removes it.
#
# Digests are computed with sys/runtime/hash rather than written out, because
# the file they name is made in setup and a written digest would have to be
# kept in step with it by hand.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/cache
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    WORK="${BATS_TEST_TMPDIR}/work"
    STORE="${BATS_TEST_TMPDIR}/store"
    mkdir -p "${WORK}"

    SOURCE="${WORK}/tarball"
    printf 'the contents of a release\n' > "${SOURCE}"
    stealth::sys::runtime::hash::digest DIGEST "${SOURCE}"

    OTHER="${WORK}/other"
    printf 'something else entirely\n' > "${OTHER}"
    stealth::sys::runtime::hash::digest OTHER_DIGEST "${OTHER}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::configure
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::configure: a directory -> is made" {
    stealth::sys::net::cache::configure "${STORE}"

    assert_dir_exists "${STORE}"
}

@test "stealth::sys::net::cache::configure: a directory -> the store is on afterwards" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::is_on
    assert_success
}

@test "stealth::sys::net::cache::configure: a slash at the end -> is not part of the path" {
    stealth::sys::net::cache::configure "${STORE}/"
    local where

    stealth::sys::net::cache::path where "${DIGEST}"

    refute_contains "${where}" '//'
}

@test "stealth::sys::net::cache::configure: no directory -> exits 1" {
    run stealth::sys::net::cache::configure ''
    assert_refused 'a directory is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::is_on
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::is_on: nothing configured -> returns 1" {
    run stealth::sys::net::cache::is_on
    assert_failure 1
}

@test "stealth::sys::net::cache::is_on: a store configured -> returns 0" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::is_on
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::path
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::path: a digest -> a path under the algorithm" {
    stealth::sys::net::cache::configure "${STORE}"
    local where

    stealth::sys::net::cache::path where 'sha256:abcdef0123456789'

    assert_equal "${where}" "${STORE}/sha256/ab/cdef0123456789"
}

@test "stealth::sys::net::cache::path: another algorithm -> its own part of the store" {
    stealth::sys::net::cache::configure "${STORE}"
    local where

    stealth::sys::net::cache::path where 'sha512:abcdef0123456789'

    assert_starts_with "${where}" "${STORE}/sha512/"
}

@test "stealth::sys::net::cache::path: a bare digest -> is read as sha256" {
    stealth::sys::net::cache::configure "${STORE}"
    local where

    stealth::sys::net::cache::path where 'abcdef0123456789'

    assert_equal "${where}" "${STORE}/sha256/ab/cdef0123456789"
}

@test "stealth::sys::net::cache::path: no store -> returns 1" {
    run stealth::sys::net::cache::path where "${DIGEST}"
    assert_failure 1
}

@test "stealth::sys::net::cache::path: an algorithm nothing computes -> exits 1" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::path where 'sha1:abcdef'
    assert_refused 'nothing here computes a sha1 digest'
}

@test "stealth::sys::net::cache::path: no output variable -> exits 1" {
    run stealth::sys::net::cache::path '' "${DIGEST}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::cache::path: no digest -> exits 1" {
    run stealth::sys::net::cache::path where
    assert_refused 'a digest is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::has
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::has: an entry that was put in -> returns 0" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    run stealth::sys::net::cache::has "${DIGEST}"
    assert_success
}

@test "stealth::sys::net::cache::has: an entry that was not -> returns 1" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::has "${DIGEST}"
    assert_failure 1
}

@test "stealth::sys::net::cache::has: no store -> returns 1" {
    run stealth::sys::net::cache::has "${DIGEST}"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::put
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::put: a file -> is in the store" {
    stealth::sys::net::cache::configure "${STORE}"

    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    run stealth::sys::net::cache::has "${DIGEST}"
    assert_success
}

@test "stealth::sys::net::cache::put: the entry -> holds what went in" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where

    stealth::sys::net::cache::path where "${DIGEST}"

    assert_files_equal "${where}" "${SOURCE}"
}

@test "stealth::sys::net::cache::put: the entry -> is nobody's to rewrite" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where

    stealth::sys::net::cache::path where "${DIGEST}"

    assert_file_permission 0444 "${where}"
}

@test "stealth::sys::net::cache::put: the same digest twice -> is no trouble" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    run stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    assert_success
}

@test "stealth::sys::net::cache::put: no store -> returns 1" {
    run stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    assert_failure 1
}

@test "stealth::sys::net::cache::put: no such file -> exits 1" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::put "${DIGEST}" "${WORK}/nowhere"
    assert_refused "no file to store at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::get
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::get: an entry that is there -> is copied out" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"

    assert_files_equal "${WORK}/out" "${SOURCE}"
}

@test "stealth::sys::net::cache::get: an entry that is not -> returns 1" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::cache::get: an entry that is not -> writes nothing" {
    stealth::sys::net::cache::configure "${STORE}"

    stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out" || true

    assert_file_not_exists "${WORK}/out"
}

@test "stealth::sys::net::cache::get: an entry that is not what it says -> returns 1" {
    # The whole point of naming an entry by its contents. A store that hands
    # back something else under a name a build trusts is worse than no store.
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where
    stealth::sys::net::cache::path where "${DIGEST}"
    chmod 0644 "${where}"
    printf 'tampered with\n' > "${where}"

    run stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::cache::get: an entry that is not what it says -> is removed" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where
    stealth::sys::net::cache::path where "${DIGEST}"
    chmod 0644 "${where}"
    printf 'tampered with\n' > "${where}"

    stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out" || true

    assert_file_not_exists "${where}"
}

@test "stealth::sys::net::cache::get: an entry that is not what it says -> says so" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where
    stealth::sys::net::cache::path where "${DIGEST}"
    chmod 0644 "${where}"
    printf 'tampered with\n' > "${where}"

    stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out" || true

    assert_called_with stealth::util::log::warn '*is not that, removing it*'
}

@test "stealth::sys::net::cache::get: a truncated entry -> is refused" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local where
    stealth::sys::net::cache::path where "${DIGEST}"
    chmod 0644 "${where}"
    truncate --size 3 "${where}"

    run stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::cache::get: a copy that cannot be made -> returns 1" {
    # The entry was there and was what it said. A caller told the copy
    # succeeded goes on to open a file that was never written.
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    mkdir -p "${WORK}/out/in the way"

    run stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::cache::get: a copy that cannot be made -> says so" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    mkdir -p "${WORK}/out/in the way"

    stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out" || true

    assert_called_with stealth::util::log::warn '*could not be put at*'
}

@test "stealth::sys::net::cache::get: no store -> returns 1" {
    run stealth::sys::net::cache::get "${DIGEST}" "${WORK}/out"
    assert_failure 1
}

@test "stealth::sys::net::cache::get: nowhere to put it -> exits 1" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::get "${DIGEST}" ''
    assert_refused 'somewhere to put it is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::forget
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::forget: an entry -> is gone" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    stealth::sys::net::cache::forget "${DIGEST}"

    run stealth::sys::net::cache::has "${DIGEST}"
    assert_failure 1
}

@test "stealth::sys::net::cache::forget: another entry -> stays" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    stealth::sys::net::cache::put "${OTHER_DIGEST}" "${OTHER}"

    stealth::sys::net::cache::forget "${DIGEST}"

    run stealth::sys::net::cache::has "${OTHER_DIGEST}"
    assert_success
}

@test "stealth::sys::net::cache::forget: an entry that was never there -> is no trouble" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::forget "${DIGEST}"
    assert_success
}

@test "stealth::sys::net::cache::forget: no store -> returns 1" {
    run stealth::sys::net::cache::forget "${DIGEST}"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::entries
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::entries: what was put in -> comes back" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    stealth::sys::net::cache::put "${OTHER_DIGEST}" "${OTHER}"
    local held

    stealth::sys::net::cache::entries held

    assert_array_length held 2
    assert_array_contains held "${DIGEST}"
    assert_array_contains held "${OTHER_DIGEST}"
}

@test "stealth::sys::net::cache::entries: a digest that comes back -> can be asked for" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    local held

    stealth::sys::net::cache::entries held

    run stealth::sys::net::cache::get "${held[0]}" "${WORK}/out"
    assert_success
}

@test "stealth::sys::net::cache::entries: an empty store -> an empty array" {
    stealth::sys::net::cache::configure "${STORE}"
    local held

    stealth::sys::net::cache::entries held

    assert_array_empty held
}

@test "stealth::sys::net::cache::entries: a store not made yet -> an empty array" {
    STEALTH_NET_CACHE_DIR="${WORK}/never-made"
    local held

    stealth::sys::net::cache::entries held

    assert_array_empty held
}

@test "stealth::sys::net::cache::entries: the store cannot be read -> returns 1" {
    stealth::sys::net::cache::configure "${STORE}"
    mock find '*' 'return 1'

    run stealth::sys::net::cache::entries held
    assert_failure 1
}

@test "stealth::sys::net::cache::entries: no store -> returns 1" {
    run stealth::sys::net::cache::entries held
    assert_failure 1
}

@test "stealth::sys::net::cache::entries: no output array -> exits 1" {
    run stealth::sys::net::cache::entries ''
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::size
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::size: what is in the store -> how many bytes" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    stealth::sys::net::cache::put "${OTHER_DIGEST}" "${OTHER}"
    local bytes one two
    one="$(stat -c %s "${SOURCE}")"
    two="$(stat -c %s "${OTHER}")"
    local -ri expected=$(( one + two ))

    stealth::sys::net::cache::size bytes

    assert_equal "${bytes}" "${expected}"
}

@test "stealth::sys::net::cache::size: an empty store -> zero" {
    stealth::sys::net::cache::configure "${STORE}"
    local bytes

    stealth::sys::net::cache::size bytes

    assert_equal "${bytes}" '0'
}

@test "stealth::sys::net::cache::size: a store not made yet -> zero" {
    STEALTH_NET_CACHE_DIR="${WORK}/never-made"
    local bytes

    stealth::sys::net::cache::size bytes

    assert_equal "${bytes}" '0'
}

@test "stealth::sys::net::cache::size: the store cannot be read -> returns 1" {
    stealth::sys::net::cache::configure "${STORE}"
    mock find '*' 'return 1'

    run stealth::sys::net::cache::size bytes
    assert_failure 1
}

@test "stealth::sys::net::cache::size: no store -> returns 1" {
    run stealth::sys::net::cache::size bytes
    assert_failure 1
}

@test "stealth::sys::net::cache::size: no output variable -> exits 1" {
    run stealth::sys::net::cache::size ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::cache::clear
# ------------------------------------------------------------------------------

@test "stealth::sys::net::cache::clear: everything in the store -> is gone" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    stealth::sys::net::cache::put "${OTHER_DIGEST}" "${OTHER}"

    stealth::sys::net::cache::clear
    local held

    stealth::sys::net::cache::entries held

    assert_array_empty held
}

@test "stealth::sys::net::cache::clear: the store itself -> stays" {
    stealth::sys::net::cache::configure "${STORE}"
    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"

    stealth::sys::net::cache::clear

    assert_dir_exists "${STORE}"
}

@test "stealth::sys::net::cache::clear: an empty store -> returns 0" {
    stealth::sys::net::cache::configure "${STORE}"

    run stealth::sys::net::cache::clear
    assert_success
}

@test "stealth::sys::net::cache::clear: no store -> returns 1" {
    run stealth::sys::net::cache::clear
    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/net/cache, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/cache: two digests of the same bytes -> are one entry" {
    # This is what naming by contents buys. Two addresses serving the same
    # tarball do not cost two copies.
    stealth::sys::net::cache::configure "${STORE}"
    cp "${SOURCE}" "${WORK}/same-bytes-other-name"

    stealth::sys::net::cache::put "${DIGEST}" "${SOURCE}"
    stealth::sys::net::cache::put "${DIGEST}" "${WORK}/same-bytes-other-name"
    local held

    stealth::sys::net::cache::entries held

    assert_array_length held 1
}

@test "sys/net/cache: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/cache
    assert_success
}
