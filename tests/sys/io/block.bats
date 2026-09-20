#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/io/block - Test Suite
# ==============================================================================
# The test container has no block devices and no lsblk, and nothing here
# needs either. A plain file stands in for a disk, which is a shape this
# module works on for real: a disk image is a file until something loops it.
#
# lsblk is mocked. What is being tested is which question this module asks
# and what it does with the answer, and the one flag that matters is
# --nodeps: without it lsblk answers about the partitions as well, and a
# caller asking a disk its size is handed a number per partition.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/io/block
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    DISK="${WORK}/disk.img"
    : > "${DISK}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::is_target
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::is_target: a disk image -> returns 0" {
    run stealth::sys::io::block::is_target "${DISK}"
    assert_success
}

@test "stealth::sys::io::block::is_target: a directory -> returns 1" {
    run stealth::sys::io::block::is_target "${WORK}"
    assert_failure 1
}

@test "stealth::sys::io::block::is_target: a path that is not there -> returns 1" {
    run stealth::sys::io::block::is_target "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::io::block::is_target: a character device -> returns 1" {
    run stealth::sys::io::block::is_target /dev/null
    assert_failure 1
}

@test "stealth::sys::io::block::is_target: nothing -> exits 1" {
    run stealth::sys::io::block::is_target ''
    assert_refused 'a device is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::uuid
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::uuid: a device with one -> its identifier" {
    mock lsblk '*' 'echo 8e5f1a0c-0000-4000-8000-000000000001'
    local value

    stealth::sys::io::block::uuid value "${DISK}"

    assert_equal "${value}" '8e5f1a0c-0000-4000-8000-000000000001'
}

@test "stealth::sys::io::block::uuid: lsblk -> is asked for UUID and nothing under it" {
    mock lsblk '*' 'echo x'
    local value

    stealth::sys::io::block::uuid value "${DISK}"

    assert_called_with lsblk '*--nodeps*'
    assert_called_with lsblk '*--output UUID*'
}

@test "stealth::sys::io::block::uuid: a device with none -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::uuid value "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::uuid: nothing there -> returns 1" {
    run stealth::sys::io::block::uuid value "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::io::block::uuid: nothing there -> says so" {
    run stealth::sys::io::block::uuid value "${WORK}/nowhere"

    assert_called_with stealth::util::log::debug '*there is no disk at*'
}

@test "stealth::sys::io::block::uuid: lsblk fails -> returns 1" {
    mock lsblk '*' 'return 1'

    run stealth::sys::io::block::uuid value "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::uuid: no output variable -> exits 1" {
    run stealth::sys::io::block::uuid '' "${DISK}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::io::block::uuid: no device -> exits 1" {
    run stealth::sys::io::block::uuid value
    assert_refused 'a device is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::label
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::label: a device with one -> its name" {
    mock lsblk '*' 'echo root'
    local value

    stealth::sys::io::block::label value "${DISK}"

    assert_equal "${value}" 'root'
}

@test "stealth::sys::io::block::label: a name with a space in it -> comes back whole" {
    mock lsblk '*' 'echo "Stealth OS"'
    local value

    stealth::sys::io::block::label value "${DISK}"

    assert_equal "${value}" 'Stealth OS'
}

@test "stealth::sys::io::block::label: a device with none -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::label value "${DISK}"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::fstype
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::fstype: a device with a filesystem -> what kind" {
    mock lsblk '*' 'echo ext4'
    local value

    stealth::sys::io::block::fstype value "${DISK}"

    assert_equal "${value}" 'ext4'
}

@test "stealth::sys::io::block::fstype: lsblk -> is asked for FSTYPE" {
    mock lsblk '*' 'echo ext4'
    local value

    stealth::sys::io::block::fstype value "${DISK}"

    assert_called_with lsblk '*--output FSTYPE*'
}

@test "stealth::sys::io::block::fstype: a device with none -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::fstype value "${DISK}"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::size
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::size: a device -> how many bytes" {
    mock lsblk '*' 'echo 1920383410176'
    local value

    stealth::sys::io::block::size value "${DISK}"

    assert_equal "${value}" '1920383410176'
}

@test "stealth::sys::io::block::size: lsblk -> is asked in bytes" {
    mock lsblk '*' 'echo 1'
    local value

    stealth::sys::io::block::size value "${DISK}"

    assert_called_with lsblk '*--bytes*'
}

@test "stealth::sys::io::block::size: a disk with partitions -> one number, not one per part" {
    # This is what --nodeps is for. Without it lsblk prints a line for the
    # disk and a line for every partition on it.
    # The last rule registered is the first one matched, so the catch-all
    # goes in first and the one that expects --nodeps goes in after it.
    mock lsblk '*' 'printf "1920383410176\n209715200\n16777216\n"'
    mock lsblk '* --nodeps *' 'echo 1920383410176'
    local value

    stealth::sys::io::block::size value "${DISK}"

    assert_equal "${value}" '1920383410176'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::kind
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::kind: a whole disk -> disk" {
    mock lsblk '*' 'echo disk'
    local value

    stealth::sys::io::block::kind value "${DISK}"

    assert_equal "${value}" 'disk'
}

@test "stealth::sys::io::block::kind: a partition -> part" {
    mock lsblk '*' 'echo part'
    local value

    stealth::sys::io::block::kind value "${DISK}"

    assert_equal "${value}" 'part'
}

@test "stealth::sys::io::block::kind: lsblk -> is asked for TYPE" {
    mock lsblk '*' 'echo disk'
    local value

    stealth::sys::io::block::kind value "${DISK}"

    assert_called_with lsblk '*--output TYPE*'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::parent
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::parent: a partition -> the disk it is on" {
    mock lsblk '*' 'echo sda'
    local value

    stealth::sys::io::block::parent value "${DISK}"

    assert_equal "${value}" 'sda'
}

@test "stealth::sys::io::block::parent: a whole disk -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::parent value "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::parent: lsblk -> is asked for PKNAME" {
    mock lsblk '*' 'echo sda'
    local value

    stealth::sys::io::block::parent value "${DISK}"

    assert_called_with lsblk '*--output PKNAME*'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::mountpoint
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::mountpoint: a mounted device -> where" {
    mock lsblk '*' 'echo /boot'
    local value

    stealth::sys::io::block::mountpoint value "${DISK}"

    assert_equal "${value}" '/boot'
}

@test "stealth::sys::io::block::mountpoint: a device that is not mounted -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::mountpoint value "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::mountpoint: lsblk -> is asked for every place it is mounted" {
    mock lsblk '*' 'echo /boot'
    local value

    stealth::sys::io::block::mountpoint value "${DISK}"

    assert_called_with lsblk '*--output MOUNTPOINTS*'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::is_mounted
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::is_mounted: a mounted device -> returns 0" {
    mock lsblk '*' 'echo /boot'

    run stealth::sys::io::block::is_mounted "${DISK}"
    assert_success
}

@test "stealth::sys::io::block::is_mounted: a device that is not -> returns 1" {
    mock lsblk '*' 'return 0'

    run stealth::sys::io::block::is_mounted "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::is_mounted: nothing there -> returns 1" {
    run stealth::sys::io::block::is_mounted "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::io::block::is_mounted: no device -> exits 1" {
    run stealth::sys::io::block::is_mounted ''
    assert_refused 'a device is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::block::reread
# ------------------------------------------------------------------------------

@test "stealth::sys::io::block::reread: a device -> partprobe is run on it" {
    mock stealth::sys::cmd::exists '*' 'return 1'
    mock partprobe '*' 'return 0'

    stealth::sys::io::block::reread "${DISK}"

    assert_called_with_args partprobe "${DISK}"
}

@test "stealth::sys::io::block::reread: udev is there -> the nodes are waited for" {
    # partprobe returns before udev has made the nodes, so a caller that goes
    # straight on to open a new partition opens nothing.
    mock stealth::sys::cmd::exists '*' 'return 0'
    mock partprobe '*' 'return 0'
    mock udevadm '*' 'return 0'

    stealth::sys::io::block::reread "${DISK}"

    assert_called_with_args udevadm settle
}

@test "stealth::sys::io::block::reread: no udev -> is no trouble" {
    mock stealth::sys::cmd::exists '*' 'return 1'
    mock partprobe '*' 'return 0'

    run stealth::sys::io::block::reread "${DISK}"
    assert_success
}

@test "stealth::sys::io::block::reread: udevadm fails -> is no trouble" {
    mock stealth::sys::cmd::exists '*' 'return 0'
    mock partprobe '*' 'return 0'
    mock udevadm '*' 'return 1'

    run stealth::sys::io::block::reread "${DISK}"
    assert_success
}

@test "stealth::sys::io::block::reread: nothing there -> returns 1" {
    run stealth::sys::io::block::reread "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::io::block::reread: nothing there -> says so" {
    run stealth::sys::io::block::reread "${WORK}/nowhere"

    assert_called_with stealth::util::log::warn '*no disk at*'
}

@test "stealth::sys::io::block::reread: partprobe fails -> ends the run" {
    mock partprobe '*' 'return 1'

    run stealth::sys::io::block::reread "${DISK}"
    assert_failure 1
}

@test "stealth::sys::io::block::reread: no device -> exits 1" {
    run stealth::sys::io::block::reread ''
    assert_refused 'a device is required'
}

# ------------------------------------------------------------------------------
# sys/io/block, the module itself
# ------------------------------------------------------------------------------

@test "sys/io/block: sourced twice -> returns before it declares anything" {
    run load_lib sys/io/block
    assert_success
}
