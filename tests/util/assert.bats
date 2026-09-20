#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/assert - Test Suite
# ==============================================================================
# An assertion that does not hold ends the process through util/log, so the
# logger is mocked and every failing case reads two things: the status, and the
# call the assertion made. The frame count is part of that call, because it is
# what makes the entry name the caller.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/assert
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Reads what the console sink received. One test restores the real logger, and
# this is how it reads the entry.
console() {
    printf '%s' "$(< "${BATS_TEST_TMPDIR}/console.log")"
}

# A namespaced caller, so a test can check which code the entry names.
stealth::api::make::pkg::build() {
    stealth::util::assert::not_empty "${1:-}" 'a package name is required'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::fail
# ------------------------------------------------------------------------------

@test "stealth::util::assert::fail: a reason -> exits 1 with it" {
    run stealth::util::assert::fail 'a low bound is above the high bound'

    assert_failure 1
    assert_called_once_with stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'a low bound is above the high bound'
}

@test "stealth::util::assert::fail: no reason -> exits 1 with the default" {
    run stealth::util::assert::fail

    assert_failure 1
    assert_called_once_with stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'an assertion did not hold'
}

@test "stealth::util::assert::fail: a caller of its own -> the entry names that caller" {
    # The frame it passes has to name the caller of fail, not fail itself, so
    # the real logger runs here as it does for the assertions.
    unmock stealth::util::log::error
    exec {STEALTH_LOG_FD_CONSOLE}>"${BATS_TEST_TMPDIR}/console.log"
    stealth::util::log::init

    stealth::api::oci::store::put() { stealth::util::assert::fail 'the store is not a directory'; }

    run stealth::api::oci::store::put
    assert_failure 1

    run console
    assert_output --partial 'api/oci/store @ put'
    refute_output --partial '@ fail'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::not_empty
# ------------------------------------------------------------------------------

@test "stealth::util::assert::not_empty: a value -> returns" {
    run stealth::util::assert::not_empty zlib

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::not_empty: an empty value -> exits 1 with the reason" {
    run stealth::util::assert::not_empty '' 'a module path is required'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'a module path is required'
}

@test "stealth::util::assert::not_empty: no reason -> exits 1 with the default" {
    run stealth::util::assert::not_empty ''

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'a value is required'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_int
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_int: a whole number -> returns" {
    run stealth::util::assert::is_int 42

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_int: a signed whole number -> returns" {
    run stealth::util::assert::is_int -7

    assert_success
}

@test "stealth::util::assert::is_int: a decimal -> exits 1 and names the value" {
    run stealth::util::assert::is_int 1.5

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' '1.5 is not a whole number'
}

@test "stealth::util::assert::is_int: a word -> exits 1" {
    run stealth::util::assert::is_int many

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'many is not a whole number'
}

@test "stealth::util::assert::is_int: a reason -> exits 1 with it" {
    run stealth::util::assert::is_int '' 'a job count is a whole number'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'a job count is a whole number'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_number
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_number: a whole number -> returns" {
    run stealth::util::assert::is_number 42

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_number: a decimal -> returns" {
    run stealth::util::assert::is_number 1.25

    assert_success
}

@test "stealth::util::assert::is_number: a word -> exits 1 and names the value" {
    run stealth::util::assert::is_number large

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'large is not a number'
}

@test "stealth::util::assert::is_number: a trailing point -> exits 1" {
    run stealth::util::assert::is_number 1.

    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_bool
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_bool: true -> returns" {
    run stealth::util::assert::is_bool true

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_bool: false -> returns" {
    run stealth::util::assert::is_bool false

    assert_success
}

@test "stealth::util::assert::is_bool: a number -> exits 1 and names the value" {
    run stealth::util::assert::is_bool 1

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' '1 is not true or false'
}

@test "stealth::util::assert::is_bool: a reason -> exits 1 with it" {
    run stealth::util::assert::is_bool yes 'sign takes true or false'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'sign takes true or false'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_regex
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_regex: an expression -> returns" {
    run stealth::util::assert::is_regex '^[a-z]+$'

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_regex: an unclosed bracket -> exits 1 and names it" {
    run stealth::util::assert::is_regex '[unclosed'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' '[unclosed is not a regular expression'
}

@test "stealth::util::assert::is_regex: an empty expression -> returns" {
    run stealth::util::assert::is_regex ''

    assert_success
}

# ------------------------------------------------------------------------------
# stealth::util::assert::match
# ------------------------------------------------------------------------------

@test "stealth::util::assert::match: a value that matches -> returns" {
    run stealth::util::assert::match build '^[a-z]+$'

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::match: a value that does not -> exits 1 and names both" {
    run stealth::util::assert::match 'Build 1' '^[a-z]+$'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'Build 1 does not match ^[a-z]+$'
}

@test "stealth::util::assert::match: a reason -> exits 1 with it" {
    run stealth::util::assert::match 'X' '^[a-z]+$' 'a stage is lowercase'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'a stage is lowercase'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::enum
# ------------------------------------------------------------------------------

@test "stealth::util::assert::enum: the first allowed value -> returns" {
    run stealth::util::assert::enum build build setup root user

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::enum: a later allowed value -> returns" {
    run stealth::util::assert::enum user build setup root user

    assert_success
}

@test "stealth::util::assert::enum: a value that is not allowed -> exits 1 and lists them" {
    run stealth::util::assert::enum deploy build setup root user

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'deploy is not one of build, setup, root, user'
}

@test "stealth::util::assert::enum: no allowed value -> exits 1 and says so" {
    run stealth::util::assert::enum build

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'an enum needs at least one allowed value'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_command
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_command: a command on the path -> returns" {
    run stealth::util::assert::is_command printf

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_command: a command that is missing -> exits 1 and names it" {
    run stealth::util::assert::is_command notaprogram

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'notaprogram is not installed'
}

@test "stealth::util::assert::is_command: a reason -> exits 1 with it" {
    run stealth::util::assert::is_command notaprogram 'install crane to assemble an image'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'install crane to assemble an image'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_file
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_file: a file -> returns" {
    touch "${BATS_TEST_TMPDIR}/spec"

    run stealth::util::assert::is_file "${BATS_TEST_TMPDIR}/spec"

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_file: a directory -> exits 1 and names the path" {
    run stealth::util::assert::is_file "${BATS_TEST_TMPDIR}"

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' "${BATS_TEST_TMPDIR} is not a file"
}

@test "stealth::util::assert::is_file: a path that is not there -> exits 1" {
    run stealth::util::assert::is_file "${BATS_TEST_TMPDIR}/nowhere"

    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_dir
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_dir: a directory -> returns" {
    run stealth::util::assert::is_dir "${BATS_TEST_TMPDIR}"

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_dir: a file -> exits 1 and names the path" {
    touch "${BATS_TEST_TMPDIR}/spec"

    run stealth::util::assert::is_dir "${BATS_TEST_TMPDIR}/spec"

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' "${BATS_TEST_TMPDIR}/spec is not a directory"
}

@test "stealth::util::assert::is_dir: a path that is not there -> exits 1" {
    run stealth::util::assert::is_dir "${BATS_TEST_TMPDIR}/nowhere"

    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::assert::is_safe_path
# ------------------------------------------------------------------------------

@test "stealth::util::assert::is_safe_path: a path two levels down -> returns" {
    run stealth::util::assert::is_safe_path /build/out

    assert_success
    refute_called stealth::util::log::error
}

@test "stealth::util::assert::is_safe_path: a deep path -> returns" {
    run stealth::util::assert::is_safe_path /var/tmp/stealth.XXXX/work

    assert_success
}

@test "stealth::util::assert::is_safe_path: a trailing slash -> returns" {
    run stealth::util::assert::is_safe_path /build/out/

    assert_success
}

@test "stealth::util::assert::is_safe_path: a directory of the system -> exits 1" {
    run stealth::util::assert::is_safe_path /usr

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' '/usr is not a path that may be removed'
}

@test "stealth::util::assert::is_safe_path: the root -> exits 1" {
    run stealth::util::assert::is_safe_path /

    assert_failure 1
}

@test "stealth::util::assert::is_safe_path: a relative path -> exits 1" {
    run stealth::util::assert::is_safe_path build/out

    assert_failure 1
}

@test "stealth::util::assert::is_safe_path: an empty path -> exits 1" {
    run stealth::util::assert::is_safe_path ''

    assert_failure 1
}

@test "stealth::util::assert::is_safe_path: a parent component -> exits 1" {
    run stealth::util::assert::is_safe_path /build/../etc

    assert_failure 1
}

@test "stealth::util::assert::is_safe_path: a trailing parent component -> exits 1" {
    run stealth::util::assert::is_safe_path /build/out/..

    assert_failure 1
}

@test "stealth::util::assert::is_safe_path: a reason -> exits 1 with it" {
    run stealth::util::assert::is_safe_path / 'the store is never the root'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'the store is never the root'
}

# ------------------------------------------------------------------------------
# stealth::util::assert::_fail
# ------------------------------------------------------------------------------

@test "stealth::util::assert::_fail: a reason -> exits 1 with it" {
    run stealth::util::assert::_fail 'the vault is not readable'

    assert_failure 1
    assert_called_once_with stealth::util::log::error \
        --frame 2 'assertion failed: %s' 'the vault is not readable'
}

# ------------------------------------------------------------------------------
# util/assert, the module itself
# ------------------------------------------------------------------------------

@test "util/assert: an assertion inside a function -> the entry names that function" {
    # Defect of the previous library: every assertion reported util/assert as
    # its origin, because the logger read a fixed frame. The real logger runs
    # here, because the frame count is what this checks.
    unmock stealth::util::log::error
    exec {STEALTH_LOG_FD_CONSOLE}>"${BATS_TEST_TMPDIR}/console.log"
    stealth::util::log::init

    run stealth::api::make::pkg::build ''
    assert_failure 1

    run console
    assert_output --partial 'api/make/pkg @ build'
    refute_output --partial '@ _fail'
}

@test "util/assert: sourced twice -> returns before it declares anything" {
    load_lib util/assert

    run stealth::util::assert::not_empty zlib
    assert_success
}
