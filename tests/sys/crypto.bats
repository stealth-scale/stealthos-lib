#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/crypto - Test Suite
# ==============================================================================
# A test cannot check that a value is random. What it can check is the shape
# of it, that two calls differ, and that a source which gives less than was
# asked for is an error rather than an empty secret. The last one is the test
# that matters: an empty password nobody notices is worse than a failure.
#
# The random source is pointed at a file of the test's own making wherever
# the amount read has to be known.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/crypto
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::crypto::hex
# ------------------------------------------------------------------------------

@test "stealth::sys::crypto::hex: sixteen bytes -> thirty-two characters" {
    local value

    stealth::sys::crypto::hex value 16

    assert_equal "${#value}" 32
}

@test "stealth::sys::crypto::hex: the characters -> are hexadecimal and nothing else" {
    local value

    stealth::sys::crypto::hex value 32

    assert_regex "${value}" '^[0-9a-f]{64}$'
}

@test "stealth::sys::crypto::hex: one byte -> two characters" {
    local value

    stealth::sys::crypto::hex value 1

    assert_equal "${#value}" 2
}

@test "stealth::sys::crypto::hex: two calls -> give different values" {
    local one two

    stealth::sys::crypto::hex one 32
    stealth::sys::crypto::hex two 32

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::crypto::hex: a source with less in it than was asked for -> exits 1" {
    printf 'ab' > "${WORK}/short"
    STEALTH_CRYPTO_SOURCE="${WORK}/short"

    run stealth::sys::crypto::hex value 16
    assert_refused 'a run of hexadecimal came back 4 characters long, and should have been 32'
}

@test "stealth::sys::crypto::hex: a count of zero -> exits 1" {
    run stealth::sys::crypto::hex value 0
    assert_refused 'a number of bytes is above zero, not 0'
}

@test "stealth::sys::crypto::hex: a count that is not a number -> exits 1" {
    run stealth::sys::crypto::hex value lots
    assert_refused 'a number of bytes is a whole number, not lots'
}

@test "stealth::sys::crypto::hex: no output variable -> exits 1" {
    run stealth::sys::crypto::hex '' 16
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::crypto::base64
# ------------------------------------------------------------------------------

@test "stealth::sys::crypto::base64: twenty-four bytes -> thirty-two characters" {
    local value

    stealth::sys::crypto::base64 value 24

    assert_equal "${#value}" 32
}

@test "stealth::sys::crypto::base64: a count that is not a multiple of three -> is padded" {
    local value

    stealth::sys::crypto::base64 value 16

    assert_equal "${#value}" 24
}

@test "stealth::sys::crypto::base64: the value -> has no line break in it" {
    local value

    stealth::sys::crypto::base64 value 96

    refute_contains "${value}" $'\n'
}

@test "stealth::sys::crypto::base64: two calls -> give different values" {
    local one two

    stealth::sys::crypto::base64 one 24
    stealth::sys::crypto::base64 two 24

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::crypto::base64: a source with less in it than was asked for -> exits 1" {
    # base64 given nothing succeeds and says nothing, so without the length
    # check the caller would be handed an empty secret.
    printf 'ab' > "${WORK}/short"
    STEALTH_CRYPTO_SOURCE="${WORK}/short"

    run stealth::sys::crypto::base64 value 24
    assert_refused 'a run of base64 came back 4 characters long, and should have been 32'
}

@test "stealth::sys::crypto::base64: a count of zero -> exits 1" {
    run stealth::sys::crypto::base64 value 0
    assert_refused 'a number of bytes is above zero, not 0'
}

@test "stealth::sys::crypto::base64: no output variable -> exits 1" {
    run stealth::sys::crypto::base64 '' 24
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::crypto::password
# ------------------------------------------------------------------------------

@test "stealth::sys::crypto::password: nothing said -> twenty-four characters" {
    local value

    stealth::sys::crypto::password value

    assert_equal "${#value}" 24
}

@test "stealth::sys::crypto::password: a length -> is the length" {
    local value

    stealth::sys::crypto::password value 32

    assert_equal "${#value}" 32
}

@test "stealth::sys::crypto::password: the characters -> are letters and digits and nothing else" {
    local value

    stealth::sys::crypto::password value 64

    assert_regex "${value}" '^[A-Za-z0-9]{64}$'
}

@test "stealth::sys::crypto::password: two calls -> give different values" {
    local one two

    stealth::sys::crypto::password one 32
    stealth::sys::crypto::password two 32

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::crypto::password: a source with nothing usable in it -> exits 1" {
    printf '!!!!!!!!!!' > "${WORK}/punctuation"
    STEALTH_CRYPTO_SOURCE="${WORK}/punctuation"

    run stealth::sys::crypto::password value 8
    assert_refused 'a password came back 0 characters long, and should have been 8'
}

@test "stealth::sys::crypto::password: a length of zero -> exits 1" {
    run stealth::sys::crypto::password value 0
    assert_refused 'a length is above zero, not 0'
}

@test "stealth::sys::crypto::password: a length that is not a number -> exits 1" {
    run stealth::sys::crypto::password value long
    assert_refused 'a length is a whole number, not long'
}

@test "stealth::sys::crypto::password: no output variable -> exits 1" {
    run stealth::sys::crypto::password ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::crypto::uuid
# ------------------------------------------------------------------------------

@test "stealth::sys::crypto::uuid: the kernel -> gives one in the usual shape" {
    local value

    stealth::sys::crypto::uuid value

    assert_regex "${value}" '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

@test "stealth::sys::crypto::uuid: two calls -> give different values" {
    local one two

    stealth::sys::crypto::uuid one
    stealth::sys::crypto::uuid two

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::crypto::uuid: a kernel that hands out none -> returns 1" {
    STEALTH_CRYPTO_UUID_SOURCE="${WORK}/nowhere"

    run stealth::sys::crypto::uuid value
    assert_failure 1
}

@test "stealth::sys::crypto::uuid: a kernel that hands out none -> says so" {
    STEALTH_CRYPTO_UUID_SOURCE="${WORK}/nowhere"

    run stealth::sys::crypto::uuid value

    assert_called_with stealth::util::log::debug '*no identifiers at*'
}

@test "stealth::sys::crypto::uuid: no output variable -> exits 1" {
    run stealth::sys::crypto::uuid ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::crypto::keyfile
# ------------------------------------------------------------------------------

@test "stealth::sys::crypto::keyfile: nothing said -> a file of 4096 bytes" {
    stealth::sys::crypto::keyfile "${WORK}/root.key"

    run stat -c %s "${WORK}/root.key"
    assert_output '4096'
}

@test "stealth::sys::crypto::keyfile: --size -> is the size" {
    stealth::sys::crypto::keyfile "${WORK}/root.key" --size 64

    run stat -c %s "${WORK}/root.key"
    assert_output '64'
}

@test "stealth::sys::crypto::keyfile: the file -> is nobody else's to read" {
    stealth::sys::crypto::keyfile "${WORK}/root.key" --size 64

    assert_file_permission 0600 "${WORK}/root.key"
}

@test "stealth::sys::crypto::keyfile: two keys -> hold different bytes" {
    stealth::sys::crypto::keyfile "${WORK}/one.key" --size 64
    stealth::sys::crypto::keyfile "${WORK}/two.key" --size 64

    assert_files_not_equal "${WORK}/one.key" "${WORK}/two.key"
}

@test "stealth::sys::crypto::keyfile: a key that is already there -> is replaced" {
    printf 'the old key\n' > "${WORK}/root.key"

    stealth::sys::crypto::keyfile "${WORK}/root.key" --size 64

    refute_file_contains "${WORK}/root.key" 'the old key'
}

@test "stealth::sys::crypto::keyfile: --size that is not a number -> exits 1" {
    run stealth::sys::crypto::keyfile "${WORK}/root.key" --size big
    assert_refused 'a number of bytes is a whole number, not big'
}

@test "stealth::sys::crypto::keyfile: an option it does not take -> exits 1" {
    run stealth::sys::crypto::keyfile "${WORK}/root.key" --force
    assert_refused 'keyfile does not take --force'
}

@test "stealth::sys::crypto::keyfile: nowhere to write it -> exits 1" {
    run stealth::sys::crypto::keyfile ''
    assert_refused 'somewhere to write the key is required'
}

@test "stealth::sys::crypto::keyfile: nothing to read from -> the old key stays" {
    printf 'the old key\n' > "${WORK}/root.key"
    STEALTH_CRYPTO_SOURCE="${WORK}/nowhere"

    run stealth::sys::crypto::keyfile "${WORK}/root.key" --size 64

    assert_failure 1
    assert_file_contains "${WORK}/root.key" 'the old key'
}

# ------------------------------------------------------------------------------
# sys/crypto, the module itself
# ------------------------------------------------------------------------------

@test "sys/crypto: sourced twice -> returns before it declares anything" {
    run load_lib sys/crypto
    assert_success
}
