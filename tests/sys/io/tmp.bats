#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/io/tmp - Test Suite
# ==============================================================================
# TMPDIR points at the test's own directory, so nothing this suite makes
# lands where the machine keeps its temporary files.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/io/tmp
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::file
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::file: a file -> is made" {
    local path

    stealth::sys::io::tmp::file path

    assert_file_exists "${path}"
}

@test "stealth::sys::io::tmp::file: a file -> is written down" {
    local path

    stealth::sys::io::tmp::file path

    run stealth::sys::io::tmp::is_kept "${path}"
    assert_success
}

@test "stealth::sys::io::tmp::file: a template -> names the file" {
    local path

    stealth::sys::io::tmp::file path 'layer.XXXXXXXX.tar'

    assert_regex "${path##*/}" '^layer\.[A-Za-z0-9]{8}\.tar$'
}

@test "stealth::sys::io::tmp::file: two files -> have names of their own" {
    local one two

    stealth::sys::io::tmp::file one
    stealth::sys::io::tmp::file two

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::io::tmp::file: no output variable -> exits 1" {
    run stealth::sys::io::tmp::file ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::file_in
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::file_in: a directory -> the file is in it" {
    mkdir -p "${BATS_TEST_TMPDIR}/here"
    local path

    stealth::sys::io::tmp::file_in path "${BATS_TEST_TMPDIR}/here"

    assert_starts_with "${path}" "${BATS_TEST_TMPDIR}/here/"
    assert_file_exists "${path}"
}

@test "stealth::sys::io::tmp::file_in: a file there -> is written down" {
    mkdir -p "${BATS_TEST_TMPDIR}/here"
    local path

    stealth::sys::io::tmp::file_in path "${BATS_TEST_TMPDIR}/here"

    run stealth::sys::io::tmp::is_kept "${path}"
    assert_success
}

@test "stealth::sys::io::tmp::file_in: no such directory -> exits 1" {
    run stealth::sys::io::tmp::file_in path "${BATS_TEST_TMPDIR}/nowhere"
    assert_refused "no directory to make a file in at ${BATS_TEST_TMPDIR}/nowhere"
}

@test "stealth::sys::io::tmp::file_in: no output variable -> exits 1" {
    run stealth::sys::io::tmp::file_in ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::dir
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::dir: a directory -> is made" {
    local path

    stealth::sys::io::tmp::dir path

    assert_dir_exists "${path}"
}

@test "stealth::sys::io::tmp::dir: a directory -> is written down" {
    local path

    stealth::sys::io::tmp::dir path

    run stealth::sys::io::tmp::is_kept "${path}"
    assert_success
}

@test "stealth::sys::io::tmp::dir: a template -> names the directory" {
    local path

    stealth::sys::io::tmp::dir path 'work.XXXXXXXX'

    assert_starts_with "${path##*/}" 'work.'
}

@test "stealth::sys::io::tmp::dir: no output variable -> exits 1" {
    run stealth::sys::io::tmp::dir ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::keep
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::keep: a path of the caller's -> is written down" {
    : > "${BATS_TEST_TMPDIR}/mine"

    stealth::sys::io::tmp::keep "${BATS_TEST_TMPDIR}/mine"

    run stealth::sys::io::tmp::is_kept "${BATS_TEST_TMPDIR}/mine"
    assert_success
}

@test "stealth::sys::io::tmp::keep: no path -> exits 1" {
    run stealth::sys::io::tmp::keep ''
    assert_refused 'a path is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::forget
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::forget: a path -> comes off the list" {
    local path
    stealth::sys::io::tmp::file path

    stealth::sys::io::tmp::forget "${path}"

    run stealth::sys::io::tmp::is_kept "${path}"
    assert_failure 1
}

@test "stealth::sys::io::tmp::forget: a path -> stays where it is" {
    local path
    stealth::sys::io::tmp::file path

    stealth::sys::io::tmp::forget "${path}"

    assert_file_exists "${path}"
}

@test "stealth::sys::io::tmp::forget: a path that was never on the list -> is no trouble" {
    run stealth::sys::io::tmp::forget "${BATS_TEST_TMPDIR}/never"
    assert_success
}

@test "stealth::sys::io::tmp::forget: no path -> exits 1" {
    run stealth::sys::io::tmp::forget ''
    assert_refused 'a path is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::remove
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::remove: a file -> is gone and off the list" {
    local path
    stealth::sys::io::tmp::file path

    stealth::sys::io::tmp::remove "${path}"

    assert_file_not_exists "${path}"
    run stealth::sys::io::tmp::is_kept "${path}"
    assert_failure 1
}

@test "stealth::sys::io::tmp::remove: a directory -> takes what is in it" {
    local path
    stealth::sys::io::tmp::dir path
    : > "${path}/inside"

    stealth::sys::io::tmp::remove "${path}"

    assert_dir_not_exists "${path}"
}

@test "stealth::sys::io::tmp::remove: several -> go together" {
    local one two
    stealth::sys::io::tmp::file one
    stealth::sys::io::tmp::file two

    stealth::sys::io::tmp::remove "${one}" "${two}"

    assert_file_not_exists "${one}"
    assert_file_not_exists "${two}"
}

@test "stealth::sys::io::tmp::remove: a path that is already gone -> is no trouble" {
    run stealth::sys::io::tmp::remove "${BATS_TEST_TMPDIR}/never"
    assert_success
}

@test "stealth::sys::io::tmp::remove: no path -> exits 1" {
    run stealth::sys::io::tmp::remove ''
    assert_refused 'a path is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::is_kept
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::is_kept: a path that is not on the list -> returns 1" {
    run stealth::sys::io::tmp::is_kept "${BATS_TEST_TMPDIR}/never"
    assert_failure 1
}

@test "stealth::sys::io::tmp::is_kept: nothing -> returns 1" {
    run stealth::sys::io::tmp::is_kept
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::cleanup
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::cleanup: everything on the list -> is gone" {
    local one two three
    stealth::sys::io::tmp::file one
    stealth::sys::io::tmp::file two
    stealth::sys::io::tmp::dir three

    stealth::sys::io::tmp::cleanup

    assert_file_not_exists "${one}"
    assert_file_not_exists "${two}"
    assert_dir_not_exists "${three}"
}

@test "stealth::sys::io::tmp::cleanup: a path that was forgotten -> stays" {
    local kept forgotten
    stealth::sys::io::tmp::file kept
    stealth::sys::io::tmp::file forgotten
    stealth::sys::io::tmp::forget "${forgotten}"

    stealth::sys::io::tmp::cleanup

    assert_file_not_exists "${kept}"
    assert_file_exists "${forgotten}"
}

@test "stealth::sys::io::tmp::cleanup: the list -> is empty afterwards" {
    local path
    stealth::sys::io::tmp::file path

    stealth::sys::io::tmp::cleanup

    assert_array_empty _STEALTH_SYS_IO_TMP_MADE
}

@test "stealth::sys::io::tmp::cleanup: nothing on the list -> returns 0" {
    run stealth::sys::io::tmp::cleanup
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::io::tmp::_make
# ------------------------------------------------------------------------------

@test "stealth::sys::io::tmp::_make: nothing can be made -> ends the run" {
    mock mktemp '*' 'return 1'

    run stealth::sys::io::tmp::file path

    assert_failure 1
    assert_called_with stealth::util::log::error '*nothing temporary could be made*'
}

# ------------------------------------------------------------------------------
# sys/io/tmp, the module itself
# ------------------------------------------------------------------------------

@test "sys/io/tmp: the cleanup the engine looks for -> is here by that name" {
    # core/engine registers <namespace>::cleanup for every library it loaded,
    # because sys may not import core to register it itself.
    run declare -F stealth::sys::io::tmp::cleanup
    assert_success
}

@test "sys/io/tmp: sourced twice -> returns before it declares anything" {
    local path
    stealth::sys::io::tmp::file path

    load_lib sys/io/tmp

    run stealth::sys::io::tmp::is_kept "${path}"
    assert_success
}
