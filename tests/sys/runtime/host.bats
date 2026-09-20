#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/host - Test Suite
# ==============================================================================
# Nothing here touches the machine running the tests. Every path goes through
# --root into the test's own directory, and the one function that
# would tell the kernel a name is reached only with cmd::exists mocked.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/host
    load_mock util
    mock::stealth::util::log

    # The module composes --root with the paths it knows, so the tests give
    # it a root and leave those paths at what a real system uses.
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}/etc" "${WORK}/var/lib/dbus"

    NAME_FILE="${WORK}/etc/hostname"
    ID_FILE="${WORK}/etc/machine-id"
    DBUS_ID_FILE="${WORK}/var/lib/dbus/machine-id"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::host::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::host::is_valid: a plain name -> returns 0" {
    run stealth::sys::runtime::host::is_valid 'node-01'
    assert_success
}

@test "stealth::sys::runtime::host::is_valid: a name with dots -> returns 0" {
    run stealth::sys::runtime::host::is_valid 'build.stealthscale.io'
    assert_success
}

@test "stealth::sys::runtime::host::is_valid: a label starting with a digit -> returns 0" {
    run stealth::sys::runtime::host::is_valid '01-node'
    assert_success
}

@test "stealth::sys::runtime::host::is_valid: a label starting with a hyphen -> returns 1" {
    run stealth::sys::runtime::host::is_valid '-node'
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: a label ending with a hyphen -> returns 1" {
    run stealth::sys::runtime::host::is_valid 'node-'
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: an underscore -> returns 1" {
    run stealth::sys::runtime::host::is_valid 'build_host'
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: a space -> returns 1" {
    run stealth::sys::runtime::host::is_valid 'build host'
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: a label of 63 characters -> returns 0" {
    local label
    printf -v label '%063d' 0

    run stealth::sys::runtime::host::is_valid "${label}"
    assert_success
}

@test "stealth::sys::runtime::host::is_valid: a label of 64 characters -> returns 1" {
    local label
    printf -v label '%064d' 0

    run stealth::sys::runtime::host::is_valid "${label}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: a name past 253 characters -> returns 1" {
    local name
    printf -v name '%0253d' 0

    run stealth::sys::runtime::host::is_valid "a${name}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: an empty label between dots -> returns 1" {
    run stealth::sys::runtime::host::is_valid 'build..io'
    assert_failure 1
}

@test "stealth::sys::runtime::host::is_valid: nothing -> returns 1" {
    run stealth::sys::runtime::host::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::host::name
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::host::name: HOSTNAME -> is what it says" {
    export HOSTNAME='from-bash'
    local name

    stealth::sys::runtime::host::name name

    assert_equal "${name}" 'from-bash'
}

@test "stealth::sys::runtime::host::name: a root -> the file under it is read" {
    printf 'from-file\n' > "${NAME_FILE}"
    local name

    stealth::sys::runtime::host::name name --root "${WORK}"

    assert_equal "${name}" 'from-file'
}

@test "stealth::sys::runtime::host::name: a root -> HOSTNAME is not what it answers" {
    export HOSTNAME='from-bash'
    printf 'from-file\n' > "${NAME_FILE}"
    local name

    stealth::sys::runtime::host::name name --root "${WORK}"

    assert_equal "${name}" 'from-file'
}

@test "stealth::sys::runtime::host::name: spaces around the name in the file -> come off" {
    printf '  from-file  \n' > "${NAME_FILE}"
    local name

    stealth::sys::runtime::host::name name --root "${WORK}"

    assert_equal "${name}" 'from-file'
}

@test "stealth::sys::runtime::host::name: nothing knows the name -> returns 1" {
    run stealth::sys::runtime::host::name name --root "${WORK}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::name: an empty file -> returns 1" {
    : > "${NAME_FILE}"

    run stealth::sys::runtime::host::name name --root "${WORK}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::name: no HOSTNAME and no root -> the machine is asked" {
    unset HOSTNAME

    run stealth::sys::runtime::host::name name
    assert_output ''
}

@test "stealth::sys::runtime::host::name: no output variable -> exits 1" {
    run stealth::sys::runtime::host::name ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::host::set_name
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::host::set_name: a name -> is in the file" {
    stealth::sys::runtime::host::set_name 'node-01' --root "${WORK}"

    assert_file_contains "${NAME_FILE}" 'node-01'
}

@test "stealth::sys::runtime::host::set_name: no root -> the kernel is told too" {
    # cmd::exists looks for a program on the path and does not count a shell
    # function, so the mock of it is what puts _tell_kernel on this branch.
    mock stealth::sys::cmd::exists '*' 'return 0'
    mock stealth::sys::cmd::run '*' 'return 0'
    STEALTH_HOST_NAME_FILE="${NAME_FILE}"

    stealth::sys::runtime::host::set_name 'node-01'

    assert_called_with_args stealth::sys::cmd::run hostnamectl set-hostname 'node-01'
}

@test "stealth::sys::runtime::host::set_name: no hostnamectl -> hostname is used" {
    mock stealth::sys::cmd::exists '*' 'return 1'
    mock stealth::sys::cmd::run '*' 'return 0'
    STEALTH_HOST_NAME_FILE="${NAME_FILE}"

    stealth::sys::runtime::host::set_name 'node-01'

    assert_called_with_args stealth::sys::cmd::run hostname 'node-01'
}

@test "stealth::sys::runtime::host::set_name: a root -> writes under it" {
    mkdir -p "${WORK}/target/etc"

    stealth::sys::runtime::host::set_name 'node-01' --root "${WORK}/target"

    assert_file_contains "${WORK}/target/etc/hostname" 'node-01'
    assert_file_not_exists "${NAME_FILE}"
}

@test "stealth::sys::runtime::host::set_name: a root -> the kernel is left alone" {
    # cmd::run is what fs::write puts the file in place with, so the refusal
    # is of the one function that would touch the running machine.
    mock stealth::sys::runtime::host::_tell_kernel '*' 'return 0'

    stealth::sys::runtime::host::set_name 'node-01' --root "${WORK}"

    refute_called stealth::sys::runtime::host::_tell_kernel
}

@test "stealth::sys::runtime::host::set_name: a root with a slash after it -> is no trouble" {
    mkdir -p "${WORK}/target/etc"

    stealth::sys::runtime::host::set_name 'node-01' --root "${WORK}/target/"

    assert_file_contains "${WORK}/target/etc/hostname" 'node-01'
}

@test "stealth::sys::runtime::host::set_name: a name no resolver accepts -> exits 1" {
    run stealth::sys::runtime::host::set_name 'build host'
    assert_refused 'build host is not a hostname a resolver will accept'
}

@test "stealth::sys::runtime::host::set_name: a name no resolver accepts -> writes nothing" {
    run stealth::sys::runtime::host::set_name 'build host' --root "${WORK}"

    assert_file_not_exists "${NAME_FILE}"
}

@test "stealth::sys::runtime::host::set_name: no name -> exits 1" {
    run stealth::sys::runtime::host::set_name
    assert_refused 'a hostname is required'
}

@test "stealth::sys::runtime::host::set_name: --root with no directory -> exits 1" {
    run stealth::sys::runtime::host::set_name 'node-01' --root
    assert_refused '--root takes a directory'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::host::id
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::host::id: a machine identifier -> is read" {
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${ID_FILE}"
    local value

    stealth::sys::runtime::host::id value --root "${WORK}"

    assert_equal "${value}" 'deadbeefdeadbeefdeadbeefdeadbeef'
}

@test "stealth::sys::runtime::host::id: no systemd identifier -> the D-Bus one is read" {
    printf 'cafebabecafebabecafebabecafebabe\n' > "${DBUS_ID_FILE}"
    local value

    stealth::sys::runtime::host::id value --root "${WORK}"

    assert_equal "${value}" 'cafebabecafebabecafebabecafebabe'
}

@test "stealth::sys::runtime::host::id: both -> the systemd one wins" {
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${ID_FILE}"
    printf 'cafebabecafebabecafebabecafebabe\n' > "${DBUS_ID_FILE}"
    local value

    stealth::sys::runtime::host::id value --root "${WORK}"

    assert_equal "${value}" 'deadbeefdeadbeefdeadbeefdeadbeef'
}

@test "stealth::sys::runtime::host::id: a root -> reads under it" {
    mkdir -p "${WORK}/target/etc"
    printf 'aaaabbbbccccddddeeeeffff00001111\n' > "${WORK}/target/etc/machine-id"
    local value

    stealth::sys::runtime::host::id value --root "${WORK}/target"

    assert_equal "${value}" 'aaaabbbbccccddddeeeeffff00001111'
}

@test "stealth::sys::runtime::host::id: an image that has not booted -> returns 1" {
    : > "${ID_FILE}"

    run stealth::sys::runtime::host::id value --root "${WORK}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::id: nothing there at all -> returns 1" {
    run stealth::sys::runtime::host::id value --root "${WORK}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::id: no output variable -> exits 1" {
    run stealth::sys::runtime::host::id
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::host::reset_id --root "${WORK}"
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::host::reset_id: an identifier -> the file is emptied" {
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${ID_FILE}"

    stealth::sys::runtime::host::reset_id --root "${WORK}"

    assert_file_empty "${ID_FILE}"
}

@test "stealth::sys::runtime::host::reset_id: an identifier -> the file stays there" {
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${ID_FILE}"

    stealth::sys::runtime::host::reset_id --root "${WORK}"

    assert_file_exists "${ID_FILE}"
}

@test "stealth::sys::runtime::host::reset_id: afterwards -> id reports there is none" {
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${ID_FILE}"

    stealth::sys::runtime::host::reset_id --root "${WORK}"

    run stealth::sys::runtime::host::id value --root "${WORK}"
    assert_failure 1
}

@test "stealth::sys::runtime::host::reset_id: a root -> works under it" {
    mkdir -p "${WORK}/target/etc"
    printf 'deadbeefdeadbeefdeadbeefdeadbeef\n' > "${WORK}/target/etc/machine-id"

    stealth::sys::runtime::host::reset_id --root "${WORK}/target"

    assert_file_empty "${WORK}/target/etc/machine-id"
}

@test "stealth::sys::runtime::host::reset_id: no file yet -> one is made, empty" {
    stealth::sys::runtime::host::reset_id --root "${WORK}"

    assert_file_exists "${ID_FILE}"
    assert_file_empty "${ID_FILE}"
}

# ------------------------------------------------------------------------------
# sys/runtime/host, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/host: sourced twice -> returns before it declares anything" {
    run load_lib sys/runtime/host
    assert_success
}
