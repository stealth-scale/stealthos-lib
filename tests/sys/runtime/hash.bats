#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/hash - Test Suite
# ==============================================================================
# The digests below were computed with coreutils and are written out in full.
# A test that computes the expected value the same way the module does would
# pass whatever the module did.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/hash
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"

    # sha256sum and md5sum of the five bytes 'hello', with no newline after.
    HELLO_SHA256='2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
    HELLO_MD5='5d41402abc4b2a76b9719d911017c592'
    # The same five bytes with a newline after them, which is what a
    # here-string would have hashed instead.
    HELLO_NEWLINE_SHA256='5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03'
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::is_algo
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::is_algo: sha256 -> returns 0" {
    run stealth::sys::runtime::hash::is_algo 'sha256'
    assert_success
}

@test "stealth::sys::runtime::hash::is_algo: sha512 -> returns 0" {
    run stealth::sys::runtime::hash::is_algo 'sha512'
    assert_success
}

@test "stealth::sys::runtime::hash::is_algo: md5 -> returns 0" {
    run stealth::sys::runtime::hash::is_algo 'md5'
    assert_success
}

@test "stealth::sys::runtime::hash::is_algo: sha1 -> returns 1" {
    run stealth::sys::runtime::hash::is_algo 'sha1'
    assert_failure 1
}

@test "stealth::sys::runtime::hash::is_algo: nothing -> returns 1" {
    run stealth::sys::runtime::hash::is_algo
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::file
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::file: a file -> its sha256" {
    printf 'hello' > "${WORK}/f"
    local sum

    stealth::sys::runtime::hash::file sum "${WORK}/f"

    assert_equal "${sum}" "${HELLO_SHA256}"
}

@test "stealth::sys::runtime::hash::file: md5 -> its md5" {
    printf 'hello' > "${WORK}/f"
    local sum

    stealth::sys::runtime::hash::file sum "${WORK}/f" md5

    assert_equal "${sum}" "${HELLO_MD5}"
}

@test "stealth::sys::runtime::hash::file: sha512 -> 128 characters" {
    printf 'hello' > "${WORK}/f"
    local sum

    stealth::sys::runtime::hash::file sum "${WORK}/f" sha512

    assert_equal "${#sum}" 128
}

@test "stealth::sys::runtime::hash::file: the name of the file -> is not in the answer" {
    printf 'hello' > "${WORK}/f"
    local sum

    stealth::sys::runtime::hash::file sum "${WORK}/f"

    assert_regex "${sum}" '^[0-9a-f]{64}$'
}

@test "stealth::sys::runtime::hash::file: an empty file -> the digest of nothing" {
    : > "${WORK}/f"
    local sum

    stealth::sys::runtime::hash::file sum "${WORK}/f"

    assert_equal "${sum}" \
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
}

@test "stealth::sys::runtime::hash::file: an algorithm nothing here computes -> exits 1" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::file sum "${WORK}/f" sha1
    assert_refused 'nothing here computes a sha1 digest'
}

@test "stealth::sys::runtime::hash::file: no such file -> exits 1" {
    run stealth::sys::runtime::hash::file sum "${WORK}/nowhere"
    assert_refused "no file to hash at ${WORK}/nowhere"
}

@test "stealth::sys::runtime::hash::file: no output variable -> exits 1" {
    run stealth::sys::runtime::hash::file '' "${WORK}"
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::string
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::string: a string -> the digest of what was passed" {
    local sum

    stealth::sys::runtime::hash::string sum 'hello'

    assert_equal "${sum}" "${HELLO_SHA256}"
}

@test "stealth::sys::runtime::hash::string: a string -> no newline is added to it" {
    local sum

    stealth::sys::runtime::hash::string sum 'hello'

    refute_equal "${sum}" "${HELLO_NEWLINE_SHA256}"
}

@test "stealth::sys::runtime::hash::string: a string -> agrees with the same file" {
    printf 'hello' > "${WORK}/f"
    local from_string from_file

    stealth::sys::runtime::hash::string from_string 'hello'
    stealth::sys::runtime::hash::file from_file "${WORK}/f"

    assert_equal "${from_string}" "${from_file}"
}

@test "stealth::sys::runtime::hash::string: md5 -> its md5" {
    local sum

    stealth::sys::runtime::hash::string sum 'hello' md5

    assert_equal "${sum}" "${HELLO_MD5}"
}

@test "stealth::sys::runtime::hash::string: an empty string -> the digest of nothing" {
    local sum

    stealth::sys::runtime::hash::string sum ''

    assert_equal "${sum}" \
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
}

@test "stealth::sys::runtime::hash::string: no string at all -> the digest of nothing" {
    local sum

    stealth::sys::runtime::hash::string sum

    assert_equal "${sum}" \
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
}

@test "stealth::sys::runtime::hash::string: a string with a newline in it -> is kept" {
    local with without

    stealth::sys::runtime::hash::string with $'hello\n'
    stealth::sys::runtime::hash::string without 'hello'

    assert_equal "${with}" "${HELLO_NEWLINE_SHA256}"
    refute_equal "${with}" "${without}"
}

@test "stealth::sys::runtime::hash::string: an algorithm nothing here computes -> exits 1" {
    run stealth::sys::runtime::hash::string sum 'hello' sha1
    assert_refused 'nothing here computes a sha1 digest'
}

@test "stealth::sys::runtime::hash::string: no output variable -> exits 1" {
    run stealth::sys::runtime::hash::string '' 'hello'
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::digest
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::digest: a file -> the algorithm in front" {
    printf 'hello' > "${WORK}/f"
    local name

    stealth::sys::runtime::hash::digest name "${WORK}/f"

    assert_equal "${name}" "sha256:${HELLO_SHA256}"
}

@test "stealth::sys::runtime::hash::digest: sha512 -> says sha512 in front" {
    printf 'hello' > "${WORK}/f"
    local name

    stealth::sys::runtime::hash::digest name "${WORK}/f" sha512

    assert_starts_with "${name}" 'sha512:'
}

@test "stealth::sys::runtime::hash::digest: what it writes -> verify reads back" {
    printf 'hello' > "${WORK}/f"
    local name

    stealth::sys::runtime::hash::digest name "${WORK}/f" sha512

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${name}"
    assert_success
}

@test "stealth::sys::runtime::hash::digest: no such file -> exits 1" {
    run stealth::sys::runtime::hash::digest name "${WORK}/nowhere"
    assert_refused "no file to hash at ${WORK}/nowhere"
}

@test "stealth::sys::runtime::hash::digest: no output variable -> exits 1" {
    run stealth::sys::runtime::hash::digest ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::split
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::split: a value with an algorithm in front -> both parts" {
    local algo sum

    stealth::sys::runtime::hash::split algo sum "sha512:${HELLO_SHA256}"

    assert_equal "${algo}" 'sha512'
    assert_equal "${sum}" "${HELLO_SHA256}"
}

@test "stealth::sys::runtime::hash::split: a bare value -> sha256 unless told otherwise" {
    local algo sum

    stealth::sys::runtime::hash::split algo sum "${HELLO_SHA256}"

    assert_equal "${algo}" 'sha256'
    assert_equal "${sum}" "${HELLO_SHA256}"
}

@test "stealth::sys::runtime::hash::split: a bare value and an algorithm -> takes the algorithm" {
    local algo sum

    stealth::sys::runtime::hash::split algo sum "${HELLO_MD5}" md5

    assert_equal "${algo}" 'md5'
    assert_equal "${sum}" "${HELLO_MD5}"
}

@test "stealth::sys::runtime::hash::split: 64 characters -> is not guessed to be anything" {
    local algo sum

    stealth::sys::runtime::hash::split algo sum "${HELLO_SHA256}" sha512

    assert_equal "${algo}" 'sha512'
}

@test "stealth::sys::runtime::hash::split: 32 characters -> is not guessed to be md5" {
    local algo sum

    stealth::sys::runtime::hash::split algo sum "${HELLO_MD5}"

    assert_equal "${algo}" 'sha256'
}

@test "stealth::sys::runtime::hash::split: an algorithm nothing here computes -> exits 1" {
    run stealth::sys::runtime::hash::split algo sum 'sha1:abc'
    assert_refused 'nothing here computes a sha1 digest'
}

@test "stealth::sys::runtime::hash::split: nothing to take apart -> exits 1" {
    run stealth::sys::runtime::hash::split algo sum ''
    assert_refused 'a digest to take apart is required'
}

@test "stealth::sys::runtime::hash::split: no output variable -> exits 1" {
    run stealth::sys::runtime::hash::split '' sum 'sha256:abc'
    assert_refused 'an output variable is required'
}

@test "stealth::sys::runtime::hash::split: no second output variable -> exits 1" {
    run stealth::sys::runtime::hash::split algo '' 'sha256:abc'
    assert_refused 'a second output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::verify
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::verify: the digest it has -> returns 0" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${HELLO_SHA256}"
    assert_success
}

@test "stealth::sys::runtime::hash::verify: an algorithm in front -> is the one used" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "md5:${HELLO_MD5}"
    assert_success
}

@test "stealth::sys::runtime::hash::verify: a bare value and an algorithm -> is the one used" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${HELLO_MD5}" md5
    assert_success
}

@test "stealth::sys::runtime::hash::verify: an upstream that writes in capitals -> returns 0" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${HELLO_SHA256^^}"
    assert_success
}

@test "stealth::sys::runtime::hash::verify: another digest -> returns 1" {
    printf 'goodbye' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${HELLO_SHA256}"
    assert_failure 1
}

@test "stealth::sys::runtime::hash::verify: another digest -> says what it found" {
    printf 'goodbye' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" "${HELLO_SHA256}"

    assert_called_with stealth::util::log::debug '*has %s digest*'
}

@test "stealth::sys::runtime::hash::verify: half a sha512 -> is not taken for a sha256" {
    printf 'hello' > "${WORK}/f"
    local long
    stealth::sys::runtime::hash::file long "${WORK}/f" sha512

    run stealth::sys::runtime::hash::verify "${WORK}/f" "sha512:${long:0:64}"
    assert_failure 1
}

@test "stealth::sys::runtime::hash::verify: no such file -> exits 1" {
    run stealth::sys::runtime::hash::verify "${WORK}/nowhere" "${HELLO_SHA256}"
    assert_refused "no file to verify at ${WORK}/nowhere"
}

@test "stealth::sys::runtime::hash::verify: nothing to verify against -> exits 1" {
    printf 'hello' > "${WORK}/f"

    run stealth::sys::runtime::hash::verify "${WORK}/f" ''
    assert_refused 'a digest to verify against is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::hash::_run
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::hash::_run: the program fails -> ends the run" {
    printf 'hello' > "${WORK}/f"
    mock sha256sum '*' 'return 1'

    run stealth::sys::runtime::hash::file sum "${WORK}/f"

    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/runtime/hash, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/hash: sourced twice -> returns before it declares anything" {
    run load_lib sys/runtime/hash
    assert_success
}
