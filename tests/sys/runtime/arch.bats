#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/arch - Test Suite
# ==============================================================================
# STEALTH_ARCH is set in most of these, so a suite gives the same answers on
# an x86_64 machine and on an aarch64 one. The tests that leave it unset are
# the ones about where the answer comes from.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/arch
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::is_known
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::is_known: a kernel name -> returns 0" {
    run stealth::sys::runtime::arch::is_known 'x86_64'
    assert_success
}

@test "stealth::sys::runtime::arch::is_known: another spelling -> returns 0" {
    run stealth::sys::runtime::arch::is_known 'arm64'
    assert_success
}

@test "stealth::sys::runtime::arch::is_known: a name nothing uses -> returns 1" {
    run stealth::sys::runtime::arch::is_known 'vax'
    assert_failure 1
}

@test "stealth::sys::runtime::arch::is_known: nothing -> returns 1" {
    run stealth::sys::runtime::arch::is_known
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::normalize
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::normalize: amd64 -> x86_64" {
    local name

    stealth::sys::runtime::arch::normalize name 'amd64'

    assert_equal "${name}" 'x86_64'
}

@test "stealth::sys::runtime::arch::normalize: arm64 -> aarch64" {
    local name

    stealth::sys::runtime::arch::normalize name 'arm64'

    assert_equal "${name}" 'aarch64'
}

@test "stealth::sys::runtime::arch::normalize: a kernel name -> comes back as it went in" {
    local name

    stealth::sys::runtime::arch::normalize name 'aarch64'

    assert_equal "${name}" 'aarch64'
}

@test "stealth::sys::runtime::arch::normalize: ppc64el -> ppc64le" {
    local name

    stealth::sys::runtime::arch::normalize name 'ppc64el'

    assert_equal "${name}" 'ppc64le'
}

@test "stealth::sys::runtime::arch::normalize: a name nothing uses -> exits 1" {
    run stealth::sys::runtime::arch::normalize name 'vax'
    assert_refused 'no architecture goes by the name vax'
}

@test "stealth::sys::runtime::arch::normalize: nothing to translate -> exits 1" {
    run stealth::sys::runtime::arch::normalize name
    assert_refused 'no architecture goes by the name '
}

@test "stealth::sys::runtime::arch::normalize: no output variable -> exits 1" {
    run stealth::sys::runtime::arch::normalize '' 'amd64'
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::kernel
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::kernel: STEALTH_ARCH -> is what it says" {
    export STEALTH_ARCH='aarch64'
    local name

    stealth::sys::runtime::arch::kernel name

    assert_equal "${name}" 'aarch64'
}

@test "stealth::sys::runtime::arch::kernel: STEALTH_ARCH in another spelling -> is translated" {
    export STEALTH_ARCH='arm64'
    local name

    stealth::sys::runtime::arch::kernel name

    assert_equal "${name}" 'aarch64'
}

@test "stealth::sys::runtime::arch::kernel: nothing said -> the machine bash is on" {
    local name

    stealth::sys::runtime::arch::kernel name

    local machine
    machine="$(uname -m)"
    assert_equal "${name}" "${machine}"
}

@test "stealth::sys::runtime::arch::kernel: no HOSTTYPE -> uname is asked" {
    unset HOSTTYPE
    mock uname '*' 'echo aarch64'
    local name

    stealth::sys::runtime::arch::kernel name

    assert_equal "${name}" 'aarch64'
    assert_called_with_args uname -m
}

@test "stealth::sys::runtime::arch::kernel: a machine nothing knows -> exits 1" {
    export STEALTH_ARCH='vax'

    run stealth::sys::runtime::arch::kernel name
    assert_refused 'no architecture goes by the name vax'
}

@test "stealth::sys::runtime::arch::kernel: no output variable -> exits 1" {
    run stealth::sys::runtime::arch::kernel ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::oci
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::oci: x86_64 -> amd64" {
    local name

    stealth::sys::runtime::arch::oci name 'x86_64'

    assert_equal "${name}" 'amd64'
}

@test "stealth::sys::runtime::arch::oci: aarch64 -> arm64" {
    local name

    stealth::sys::runtime::arch::oci name 'aarch64'

    assert_equal "${name}" 'arm64'
}

@test "stealth::sys::runtime::arch::oci: riscv64 -> the name it already had" {
    local name

    stealth::sys::runtime::arch::oci name 'riscv64'

    assert_equal "${name}" 'riscv64'
}

@test "stealth::sys::runtime::arch::oci: nothing said -> this machine" {
    export STEALTH_ARCH='aarch64'
    local name

    stealth::sys::runtime::arch::oci name

    assert_equal "${name}" 'arm64'
}

@test "stealth::sys::runtime::arch::oci: a name nothing uses -> exits 1" {
    run stealth::sys::runtime::arch::oci name 'vax'
    assert_refused 'no architecture goes by the name vax'
}

@test "stealth::sys::runtime::arch::oci: no output variable -> exits 1" {
    run stealth::sys::runtime::arch::oci ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::platform
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::platform: aarch64 -> linux/arm64" {
    local name

    stealth::sys::runtime::arch::platform name 'aarch64'

    assert_equal "${name}" 'linux/arm64'
}

@test "stealth::sys::runtime::arch::platform: nothing said -> this machine" {
    export STEALTH_ARCH='x86_64'
    local name

    stealth::sys::runtime::arch::platform name

    assert_equal "${name}" 'linux/amd64'
}

@test "stealth::sys::runtime::arch::platform: no output variable -> exits 1" {
    run stealth::sys::runtime::arch::platform ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::triple
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::triple: nothing said -> this machine with the vendor pc" {
    export STEALTH_ARCH='x86_64'
    local name

    stealth::sys::runtime::arch::triple name

    assert_equal "${name}" 'x86_64-pc-linux-gnu'
}

@test "stealth::sys::runtime::arch::triple: a vendor -> takes the middle field" {
    export STEALTH_ARCH='x86_64'
    local name

    stealth::sys::runtime::arch::triple name '' 'lfs'

    assert_equal "${name}" 'x86_64-lfs-linux-gnu'
}

@test "stealth::sys::runtime::arch::triple: another architecture -> is translated first" {
    local name

    stealth::sys::runtime::arch::triple name 'arm64'

    assert_equal "${name}" 'aarch64-pc-linux-gnu'
}

@test "stealth::sys::runtime::arch::triple: a name nothing uses -> exits 1" {
    run stealth::sys::runtime::arch::triple name 'vax'
    assert_refused 'no architecture goes by the name vax'
}

@test "stealth::sys::runtime::arch::triple: no output variable -> exits 1" {
    run stealth::sys::runtime::arch::triple ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::arch::is
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::arch::is: the machine it is -> returns 0" {
    export STEALTH_ARCH='aarch64'

    run stealth::sys::runtime::arch::is 'aarch64'
    assert_success
}

@test "stealth::sys::runtime::arch::is: another spelling of it -> returns 0" {
    export STEALTH_ARCH='aarch64'

    run stealth::sys::runtime::arch::is 'arm64'
    assert_success
}

@test "stealth::sys::runtime::arch::is: a machine it is not -> returns 1" {
    export STEALTH_ARCH='aarch64'

    run stealth::sys::runtime::arch::is 'amd64'
    assert_failure 1
}

@test "stealth::sys::runtime::arch::is: a name nothing uses -> returns 1" {
    export STEALTH_ARCH='aarch64'

    run stealth::sys::runtime::arch::is 'vax'
    assert_failure 1
}

@test "stealth::sys::runtime::arch::is: nothing -> returns 1" {
    run stealth::sys::runtime::arch::is
    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/runtime/arch, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/arch: sourced twice -> returns before it declares anything" {
    run load_lib sys/runtime/arch
    assert_success
}
