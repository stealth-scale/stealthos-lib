#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/system - Test Suite
# ==============================================================================
# Every path the module reads is a variable, so setup points them at a
# directory of this test's own. A test that wants a machine of a given size
# writes the files that describe it, and the suite gives the same answers on
# any machine.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/system
    load_mock util
    mock::stealth::util::log

    STEALTH_SYSTEM_ROOT="${BATS_TEST_TMPDIR}/machine"
    mkdir -p "${STEALTH_SYSTEM_ROOT}"

    STEALTH_SYSTEM_CPU_MAX="${STEALTH_SYSTEM_ROOT}/cpu.max"
    STEALTH_SYSTEM_MEMORY_MAX="${STEALTH_SYSTEM_ROOT}/memory.max"
    STEALTH_SYSTEM_MEMINFO="${STEALTH_SYSTEM_ROOT}/meminfo"
    STEALTH_SYSTEM_CPUINFO="${STEALTH_SYSTEM_ROOT}/cpuinfo"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Writes a cpuinfo listing this many processors.
given_processors() {
    local -i i
    : > "${STEALTH_SYSTEM_CPUINFO}"
    for (( i = 0; i < ${1}; i++ )); do
        printf 'processor\t: %d\nmodel name\t: a processor\n\n' "${i}" \
            >> "${STEALTH_SYSTEM_CPUINFO}"
    done
}

# Writes a meminfo listing this much memory, in kibibytes.
given_memory_kib() {
    printf 'MemTotal:       %d kB\nMemFree:        1024 kB\n' "${1}" \
        > "${STEALTH_SYSTEM_MEMINFO}"
}

# ------------------------------------------------------------------------------
# stealth::sys::system::cpus
# ------------------------------------------------------------------------------

@test "stealth::sys::system::cpus: a cgroup with a limit -> gives the limit" {
    # nproc reports the host's processors to a container that was given two.
    given_processors 64
    printf '200000 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '2' stealth::sys::system::cpus
}

@test "stealth::sys::system::cpus: a cgroup with no limit -> counts the machine" {
    given_processors 8
    printf 'max 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '8' stealth::sys::system::cpus
}

@test "stealth::sys::system::cpus: no cgroup -> counts the machine" {
    given_processors 4

    assert_nameref '4' stealth::sys::system::cpus
}

@test "stealth::sys::system::cpus: nothing to read -> gives one" {
    assert_nameref '1' stealth::sys::system::cpus
}

@test "stealth::sys::system::cpus: no output variable -> exits 1" {
    run stealth::sys::system::cpus ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::system::memory
# ------------------------------------------------------------------------------

@test "stealth::sys::system::memory: a cgroup with a limit -> gives the limit" {
    given_memory_kib 8388608
    printf '2147483648\n' > "${STEALTH_SYSTEM_MEMORY_MAX}"

    assert_nameref '2147483648' stealth::sys::system::memory
}

@test "stealth::sys::system::memory: a cgroup with no limit -> reads the machine" {
    given_memory_kib 1048576
    printf 'max\n' > "${STEALTH_SYSTEM_MEMORY_MAX}"

    assert_nameref '1073741824' stealth::sys::system::memory
}

@test "stealth::sys::system::memory: no cgroup -> reads the machine" {
    given_memory_kib 2097152

    assert_nameref '2147483648' stealth::sys::system::memory
}

@test "stealth::sys::system::memory: nothing to read -> gives something to work with" {
    assert_nameref '1073741824' stealth::sys::system::memory
}

@test "stealth::sys::system::memory: no output variable -> exits 1" {
    run stealth::sys::system::memory ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::system::jobs
# ------------------------------------------------------------------------------

@test "stealth::sys::system::jobs: plenty of memory -> one job per processor" {
    given_processors 4
    given_memory_kib 16777216

    assert_nameref '4' stealth::sys::system::jobs
}

@test "stealth::sys::system::jobs: little memory -> as many as fit in it" {
    # A build that takes its concurrency from the processors alone runs a
    # machine out of memory.
    given_processors 64
    given_memory_kib 4194304

    assert_nameref '2' stealth::sys::system::jobs
}

@test "stealth::sys::system::jobs: a size of its own -> is what a job is given" {
    given_processors 64
    given_memory_kib 16777216

    assert_nameref '2' stealth::sys::system::jobs 8G
}

@test "stealth::sys::system::jobs: less memory than one job -> still one job" {
    given_processors 8
    given_memory_kib 262144

    assert_nameref '1' stealth::sys::system::jobs
}

@test "stealth::sys::system::jobs: a cgroup -> is what it goes by" {
    given_processors 64
    given_memory_kib 16777216
    printf '400000 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '4' stealth::sys::system::jobs
}

@test "stealth::sys::system::jobs: a size that cannot be read -> exits 1" {
    given_processors 4
    given_memory_kib 4194304

    run stealth::sys::system::jobs out 'plenty'
    assert_refused 'a size is a number and an optional unit, not plenty'
}

@test "stealth::sys::system::jobs: a size of nothing -> exits 1" {
    given_processors 4
    given_memory_kib 4194304

    run stealth::sys::system::jobs out 0
    assert_refused 'a job is given more than nothing to work in'
}

@test "stealth::sys::system::jobs: no output variable -> exits 1" {
    run stealth::sys::system::jobs ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::system::_cpu_limit
# ------------------------------------------------------------------------------

@test "stealth::sys::system::_cpu_limit: a quota and a period -> gives the processors" {
    printf '400000 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '4' stealth::sys::system::_cpu_limit
}

@test "stealth::sys::system::_cpu_limit: a quota that is not whole -> rounds up" {
    printf '150000 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '2' stealth::sys::system::_cpu_limit
}

@test "stealth::sys::system::_cpu_limit: a quota under a whole processor -> gives one" {
    printf '50000 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    assert_nameref '1' stealth::sys::system::_cpu_limit
}

@test "stealth::sys::system::_cpu_limit: no limit -> returns 1" {
    printf 'max 100000\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    run stealth::sys::system::_cpu_limit out
    assert_failure 1
}

@test "stealth::sys::system::_cpu_limit: a period of zero -> returns 1" {
    printf '100000 0\n' > "${STEALTH_SYSTEM_CPU_MAX}"

    run stealth::sys::system::_cpu_limit out
    assert_failure 1
}

@test "stealth::sys::system::_cpu_limit: nothing to read -> returns 1" {
    run stealth::sys::system::_cpu_limit out
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::system::_cpu_count
# ------------------------------------------------------------------------------

@test "stealth::sys::system::_cpu_count: a listing -> counts the processors" {
    given_processors 12

    assert_nameref '12' stealth::sys::system::_cpu_count
}

@test "stealth::sys::system::_cpu_count: nothing to read -> gives one" {
    assert_nameref '1' stealth::sys::system::_cpu_count
}

# ------------------------------------------------------------------------------
# stealth::sys::system::_memory_limit
# ------------------------------------------------------------------------------

@test "stealth::sys::system::_memory_limit: a number -> is the limit" {
    printf '536870912\n' > "${STEALTH_SYSTEM_MEMORY_MAX}"

    assert_nameref '536870912' stealth::sys::system::_memory_limit
}

@test "stealth::sys::system::_memory_limit: no limit -> returns 1" {
    printf 'max\n' > "${STEALTH_SYSTEM_MEMORY_MAX}"

    run stealth::sys::system::_memory_limit out
    assert_failure 1
}

@test "stealth::sys::system::_memory_limit: nothing to read -> returns 1" {
    run stealth::sys::system::_memory_limit out
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::system::_memory_total
# ------------------------------------------------------------------------------

@test "stealth::sys::system::_memory_total: a listing -> gives the total in bytes" {
    given_memory_kib 1024

    assert_nameref '1048576' stealth::sys::system::_memory_total
}

@test "stealth::sys::system::_memory_total: nothing to read -> gives something to work with" {
    assert_nameref '1073741824' stealth::sys::system::_memory_total
}

# ------------------------------------------------------------------------------
# stealth::sys::system::_read
# ------------------------------------------------------------------------------

@test "stealth::sys::system::_read: a file -> gives what is in it" {
    printf 'the contents\n' > "${STEALTH_SYSTEM_ROOT}/one"

    assert_nameref 'the contents' stealth::sys::system::_read "${STEALTH_SYSTEM_ROOT}/one"
}

@test "stealth::sys::system::_read: no such file -> gives nothing" {
    assert_nameref '' stealth::sys::system::_read "${STEALTH_SYSTEM_ROOT}/nowhere"
}

# ------------------------------------------------------------------------------
# sys/system, the module itself
# ------------------------------------------------------------------------------

@test "sys/system: reading the machine -> runs no command" {
    mock nproc '*' 'return 127'
    mock grep '*' 'return 127'
    given_processors 4
    given_memory_kib 8388608

    local at_once
    stealth::sys::system::jobs at_once

    assert_var_equal at_once 4
    refute_called nproc
    refute_called grep
}

@test "sys/system: sourced twice -> returns before it declares anything" {
    given_processors 2
    local first

    load_lib sys/system
    stealth::sys::system::cpus first

    assert_var_equal first 2
}
