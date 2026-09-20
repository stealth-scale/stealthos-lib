#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/check - Test Suite
# ==============================================================================
# Every path the module reads is a variable, so setup points them all at a
# directory of this test's own. Nothing here reads the machine the suite runs
# on, and a test that wants an answer writes the file that gives it.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/check
    load_mock util
    mock::stealth::util::log

    # These are not STEALTH_ variables, so common_setup leaves them alone. The
    # suite runs inside a container under coverage, where podman sets
    # container, and under CI, where CI is set. A test that wants one sets it.
    unset container CI GITHUB_ACTIONS GITLAB_CI

    STEALTH_CHECK_ROOT="${BATS_TEST_TMPDIR}/machine"
    mkdir -p "${STEALTH_CHECK_ROOT}"

    STEALTH_CHECK_DOCKERENV="${STEALTH_CHECK_ROOT}/dockerenv"
    STEALTH_CHECK_CONTAINERENV="${STEALTH_CHECK_ROOT}/containerenv"
    STEALTH_CHECK_SYSTEMD="${STEALTH_CHECK_ROOT}/systemd-container"
    STEALTH_CHECK_CGROUP="${STEALTH_CHECK_ROOT}/cgroup"
    STEALTH_CHECK_OSTREE="${STEALTH_CHECK_ROOT}/ostree-booted"
    STEALTH_CHECK_VERSION="${STEALTH_CHECK_ROOT}/version"
    STEALTH_CHECK_PRODUCT="${STEALTH_CHECK_ROOT}/product_name"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Answers as though systemd were not there.
given_no_systemd() {
    mock stealth::sys::check::_systemd_says_virtual '*' 'return 1'
}

# Answers as though systemd said this is a virtual machine.
given_systemd_says_virtual() {
    mock stealth::sys::check::_systemd_says_virtual '*' 'return 0'
}

# ------------------------------------------------------------------------------
# stealth::sys::check::kind
# ------------------------------------------------------------------------------

@test "stealth::sys::check::kind: nothing to go on -> a plain machine" {
    assert_nameref 'plain' stealth::sys::check::kind
}

@test "stealth::sys::check::kind: a container -> says container" {
    : > "${STEALTH_CHECK_DOCKERENV}"

    assert_nameref 'container' stealth::sys::check::kind
}

@test "stealth::sys::check::kind: booted from an image -> says bootc" {
    : > "${STEALTH_CHECK_OSTREE}"

    assert_nameref 'bootc' stealth::sys::check::kind
}

@test "stealth::sys::check::kind: a container on an image -> says container" {
    : > "${STEALTH_CHECK_DOCKERENV}"
    : > "${STEALTH_CHECK_OSTREE}"

    assert_nameref 'container' stealth::sys::check::kind
}

@test "stealth::sys::check::kind: asked twice -> keeps the first answer" {
    local first second

    stealth::sys::check::kind first
    : > "${STEALTH_CHECK_DOCKERENV}"
    stealth::sys::check::kind second

    assert_var_equal second 'plain'
}

@test "stealth::sys::check::kind: no output variable -> exits 1" {
    run stealth::sys::check::kind ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_container
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_container: a container -> returns 0" {
    : > "${STEALTH_CHECK_CONTAINERENV}"

    run stealth::sys::check::is_container
    assert_success
}

@test "stealth::sys::check::is_container: a plain machine -> returns 1" {
    run stealth::sys::check::is_container
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_bootc
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_bootc: booted from an image -> returns 0" {
    : > "${STEALTH_CHECK_OSTREE}"

    run stealth::sys::check::is_bootc
    assert_success
}

@test "stealth::sys::check::is_bootc: a plain machine -> returns 1" {
    run stealth::sys::check::is_bootc
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_ci
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_ci: CI is set -> returns 0" {
    export CI=true

    run stealth::sys::check::is_ci
    assert_success
}

@test "stealth::sys::check::is_ci: GITHUB_ACTIONS is set -> returns 0" {
    export GITHUB_ACTIONS=true

    run stealth::sys::check::is_ci
    assert_success
}

@test "stealth::sys::check::is_ci: GITLAB_CI is set -> returns 0" {
    export GITLAB_CI=true

    run stealth::sys::check::is_ci
    assert_success
}

@test "stealth::sys::check::is_ci: none of them -> returns 1" {
    run stealth::sys::check::is_ci
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_wsl
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_wsl: the kernel names Microsoft -> returns 0" {
    printf 'Linux version 5.15.0-microsoft-standard-WSL2\n' > "${STEALTH_CHECK_VERSION}"

    run stealth::sys::check::is_wsl
    assert_success
}

@test "stealth::sys::check::is_wsl: any case -> returns 0" {
    printf 'Linux version 5.15.0-Microsoft\n' > "${STEALTH_CHECK_VERSION}"

    run stealth::sys::check::is_wsl
    assert_success
}

@test "stealth::sys::check::is_wsl: an ordinary kernel -> returns 1" {
    printf 'Linux version 6.11.3-200.fc40.x86_64\n' > "${STEALTH_CHECK_VERSION}"

    run stealth::sys::check::is_wsl
    assert_failure 1
}

@test "stealth::sys::check::is_wsl: nothing to read -> returns 1" {
    run stealth::sys::check::is_wsl
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_virtual
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_virtual: systemd says so -> returns 0" {
    given_systemd_says_virtual

    run stealth::sys::check::is_virtual
    assert_success
}

@test "stealth::sys::check::is_virtual: the firmware names a hypervisor -> returns 0" {
    given_no_systemd
    printf 'KVM Virtual Machine\n' > "${STEALTH_CHECK_PRODUCT}"

    run stealth::sys::check::is_virtual
    assert_success
}

@test "stealth::sys::check::is_virtual: the firmware names a board -> returns 1" {
    given_no_systemd
    printf 'ThinkPad X1 Carbon\n' > "${STEALTH_CHECK_PRODUCT}"

    run stealth::sys::check::is_virtual
    assert_failure 1
}

@test "stealth::sys::check::is_virtual: nothing to go on -> returns 1" {
    given_no_systemd

    run stealth::sys::check::is_virtual
    assert_failure 1
}

@test "stealth::sys::check::is_virtual: asked twice -> keeps the first answer" {
    given_no_systemd
    stealth::sys::check::is_virtual || true
    printf 'QEMU\n' > "${STEALTH_CHECK_PRODUCT}"

    run stealth::sys::check::is_virtual
    assert_failure 1
}

@test "stealth::sys::check::is_virtual: asked twice after yes -> still yes" {
    given_systemd_says_virtual
    stealth::sys::check::is_virtual

    run stealth::sys::check::is_virtual
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_root
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_root: the user the suite runs as -> is not root" {
    if (( EUID == 0 )); then
        skip 'this suite is running as root'
    fi

    run stealth::sys::check::is_root
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::is_interactive
# ------------------------------------------------------------------------------

@test "stealth::sys::check::is_interactive: no terminal -> returns 1" {
    run stealth::sys::check::is_interactive < /dev/null
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::_in_container
# ------------------------------------------------------------------------------

@test "stealth::sys::check::_in_container: the container variable -> returns 0" {
    export container=podman

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: the docker file -> returns 0" {
    : > "${STEALTH_CHECK_DOCKERENV}"

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: the podman file -> returns 0" {
    : > "${STEALTH_CHECK_CONTAINERENV}"

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: what systemd leaves -> returns 0" {
    : > "${STEALTH_CHECK_SYSTEMD}"

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: a runtime named in the cgroup -> returns 0" {
    printf '0::/system.slice/docker-abc123.scope\n' > "${STEALTH_CHECK_CGROUP}"

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: kubernetes in the cgroup -> returns 0" {
    printf '0::/kubepods/besteffort/pod123\n' > "${STEALTH_CHECK_CGROUP}"

    run stealth::sys::check::_in_container
    assert_success
}

@test "stealth::sys::check::_in_container: an ordinary cgroup -> returns 1" {
    printf '0::/user.slice/user-1000.slice/session-2.scope\n' > "${STEALTH_CHECK_CGROUP}"

    run stealth::sys::check::_in_container
    assert_failure 1
}

@test "stealth::sys::check::_in_container: nothing to go on -> returns 1" {
    run stealth::sys::check::_in_container
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::check::_read
# ------------------------------------------------------------------------------

@test "stealth::sys::check::_read: a file -> gives what is in it" {
    printf 'the contents\n' > "${STEALTH_CHECK_ROOT}/one"

    assert_nameref 'the contents' stealth::sys::check::_read "${STEALTH_CHECK_ROOT}/one"
}

@test "stealth::sys::check::_read: no such file -> gives nothing" {
    assert_nameref '' stealth::sys::check::_read "${STEALTH_CHECK_ROOT}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::check::_systemd_says_virtual
# ------------------------------------------------------------------------------

@test "stealth::sys::check::_systemd_says_virtual: it answers one way or the other" {
    run stealth::sys::check::_systemd_says_virtual

    assert_one_of "${status}" 0 1
}

# ------------------------------------------------------------------------------
# sys/check, the module itself
# ------------------------------------------------------------------------------

@test "sys/check: reading the machine -> runs no command" {
    mock grep '*' 'return 127'
    mock cat '*' 'return 127'
    printf '0::/system.slice/docker-abc.scope\n' > "${STEALTH_CHECK_CGROUP}"

    run stealth::sys::check::is_container

    assert_success
    refute_called grep
    refute_called cat
}

@test "sys/check: sourced twice -> returns before it declares anything" {
    local first
    stealth::sys::check::kind first

    load_lib sys/check

    assert_var_equal _STEALTH_SYS_CHECK_KIND "${first}"
}
