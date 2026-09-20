#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/proc - Test Suite
# ==============================================================================
# Two kinds of test live here. The ones about reading /proc point the module
# at a directory of the test's own making, so an answer does not depend on
# what happens to be running. The ones about signalling start a real process
# and stop it, because a signal that is mocked proves nothing about whether
# the process went.
#
# Every real process started here is a sleep, and teardown takes what is left.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/proc
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    STARTED=()
}

teardown() {
    local pid
    for pid in "${STARTED[@]:-}"; do
        if [[ -n "${pid}" ]]; then
            kill -9 "${pid}" 2>/dev/null || true
            wait "${pid}" 2>/dev/null || true
        fi
    done
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Starts a process that sits there, leaves its number in PID, and remembers
# it so teardown can take it.
#
# The five seconds are an upper bound, not a wait. Every test here signals
# the process or gives up on it within three, and teardown kills whatever is
# left. The bound is there so that a run which dies before teardown leaves
# nothing behind for longer than that.
#
# The number comes back in a variable rather than on standard output. A
# command substitution around this would wait for the pipe to close, and the
# process holding it open is the one being started.
start_one() {
    sleep 5 &
    PID="$!"
    STARTED+=("${PID}")
}

# Makes a directory that looks enough like /proc for the readers to work on.
fake_proc() {
    STEALTH_PROC_DIR="${WORK}/proc"
    mkdir -p "${STEALTH_PROC_DIR}/${1}"
    printf '%s\n' "${2:-sleep}" > "${STEALTH_PROC_DIR}/${1}/comm"
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::exists
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::exists: a process that is running -> returns 0" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_success
}

@test "stealth::sys::runtime::proc::exists: a process that has gone -> returns 1" {
    start_one
    local -r pid="${PID}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::exists: a process of somebody else's -> returns 0" {
    # kill -0 answers this one with a permission error, which reads the same
    # as no such process. Reading /proc does not have that trouble.
    run stealth::sys::runtime::proc::exists 1
    assert_success
}

@test "stealth::sys::runtime::proc::exists: not a number -> exits 1" {
    run stealth::sys::runtime::proc::exists 'nginx'
    assert_refused 'a process number is a whole number, not nginx'
}

@test "stealth::sys::runtime::proc::exists: nothing -> exits 1" {
    run stealth::sys::runtime::proc::exists
    assert_refused 'a process number is a whole number, not '
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::find
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::find: a program that is running -> its number" {
    start_one
    local -r pid="${PID}"
    local pids

    stealth::sys::runtime::proc::find pids 'sleep'

    assert_array_contains pids "${pid}"
}

@test "stealth::sys::runtime::proc::find: a program nothing is running -> returns 1" {
    run stealth::sys::runtime::proc::find pids 'nothing-runs-by-this-name'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::find: a program nothing is running -> the array is empty" {
    local pids=(stale)

    stealth::sys::runtime::proc::find pids 'nothing-runs-by-this-name' || true

    assert_array_empty pids
}

@test "stealth::sys::runtime::proc::find: part of a name -> is not a match" {
    start_one

    run stealth::sys::runtime::proc::find pids 'sle'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::find: --full -> matches the command line" {
    start_one
    local -r pid="${PID}"
    local pids

    stealth::sys::runtime::proc::find pids 'sleep 5' --full

    assert_array_contains pids "${pid}"
}

@test "stealth::sys::runtime::proc::find: a dry run -> finds nothing rather than a blank" {
    # A dry run captures nothing at all, and pgrep never printed a number.
    # Without the guard the array would hold one empty string, and a caller
    # would go on to signal a process with no number.
    STEALTH_DRY_RUN=1
    local pids

    run stealth::sys::runtime::proc::find pids 'sleep'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::find: no output array -> exits 1" {
    run stealth::sys::runtime::proc::find '' 'sleep'
    assert_refused 'an output array is required'
}

@test "stealth::sys::runtime::proc::find: no name -> exits 1" {
    run stealth::sys::runtime::proc::find pids
    assert_refused 'a name to look for is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::children
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::children: a process with one -> its number" {
    start_one
    local -r pid="${PID}"
    local pids

    stealth::sys::runtime::proc::children pids "$$"

    assert_array_contains pids "${pid}"
}

@test "stealth::sys::runtime::proc::children: a process with none -> returns 1" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::children pids "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::children: no output array -> exits 1" {
    run stealth::sys::runtime::proc::children '' 1
    assert_refused 'an output array is required'
}

@test "stealth::sys::runtime::proc::children: not a number -> exits 1" {
    run stealth::sys::runtime::proc::children pids 'init'
    assert_refused 'a process number is a whole number, not init'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::command
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::command: a process -> the program it runs" {
    start_one
    local -r pid="${PID}"
    local name

    stealth::sys::runtime::proc::command name "${pid}"

    assert_equal "${name}" 'sleep'
}

@test "stealth::sys::runtime::proc::command: a long program name -> comes back cut to 15" {
    fake_proc 4242 'a-very-long-pro'
    local name

    stealth::sys::runtime::proc::command name 4242

    assert_equal "${name}" 'a-very-long-pro'
}

@test "stealth::sys::runtime::proc::command: a process that has gone -> returns 1" {
    start_one
    local -r pid="${PID}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::command name "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::command: no output variable -> exits 1" {
    run stealth::sys::runtime::proc::command '' 1
    assert_refused 'an output variable is required'
}

@test "stealth::sys::runtime::proc::command: not a number -> exits 1" {
    run stealth::sys::runtime::proc::command name 'init'
    assert_refused 'a process number is a whole number, not init'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::is_named
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::is_named: the program it runs -> returns 0" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::is_named "${pid}" 'sleep'
    assert_success
}

@test "stealth::sys::runtime::proc::is_named: another program -> returns 1" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::is_named "${pid}" 'nginx'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::is_named: a name past 15 characters -> the first 15 decide" {
    fake_proc 4242 'qemu-system-x86'

    run stealth::sys::runtime::proc::is_named 4242 'qemu-system-x86_64'
    assert_success
}

@test "stealth::sys::runtime::proc::is_named: a process that has gone -> returns 1" {
    start_one
    local -r pid="${PID}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::is_named "${pid}" 'sleep'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::is_named: no program name -> exits 1" {
    run stealth::sys::runtime::proc::is_named 1 ''
    assert_refused 'a program name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::signal
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::signal: a process number -> the process goes" {
    start_one
    local -r pid="${PID}"

    stealth::sys::runtime::proc::signal "${pid}"
    stealth::sys::runtime::proc::wait "${pid}" --timeout 5

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::signal: --signal -> is the one sent" {
    start_one
    local -r pid="${PID}"

    stealth::sys::runtime::proc::signal "${pid}" --signal SIGKILL
    stealth::sys::runtime::proc::wait "${pid}" --timeout 5

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::signal: a program name -> everything running it is sent one" {
    start_one
    local -r one="${PID}"
    start_one
    local -r two="${PID}"
    mock stealth::sys::cmd::try '*' 'return 0'

    stealth::sys::runtime::proc::signal 'sleep'

    assert_called_with stealth::sys::cmd::try "*${one}*"
    assert_called_with stealth::sys::cmd::try "*${two}*"
}

@test "stealth::sys::runtime::proc::signal: a name nothing runs -> returns 1" {
    run stealth::sys::runtime::proc::signal 'nothing-runs-by-this-name'
    assert_failure 1
}

@test "stealth::sys::runtime::proc::signal: a number that has gone -> is no trouble" {
    start_one
    local -r pid="${PID}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::signal "${pid}"
    assert_success
}

@test "stealth::sys::runtime::proc::signal: --signal with nothing after it -> exits 1" {
    run stealth::sys::runtime::proc::signal 1 --signal
    assert_refused '--signal takes a signal'
}

@test "stealth::sys::runtime::proc::signal: an option it does not take -> exits 1" {
    run stealth::sys::runtime::proc::signal 1 --force
    assert_refused 'signal does not take --force'
}

@test "stealth::sys::runtime::proc::signal: nothing named -> exits 1" {
    run stealth::sys::runtime::proc::signal ''
    assert_refused 'a process number or a name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::wait
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::wait: a process that has gone -> returns 0 at once" {
    start_one
    local -r pid="${PID}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::wait "${pid}"
    assert_success
}

@test "stealth::sys::runtime::proc::wait: a process that goes -> returns 0" {
    start_one
    local -r pid="${PID}"
    ( sleep 1; kill -9 "${pid}" ) &
    STARTED+=("$!")

    run stealth::sys::runtime::proc::wait "${pid}" --timeout 10
    assert_success
}

@test "stealth::sys::runtime::proc::wait: a process that stays -> returns 1" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::wait "${pid}" --timeout 1
    assert_failure 1
}

@test "stealth::sys::runtime::proc::wait: --timeout that is not a number -> exits 1" {
    run stealth::sys::runtime::proc::wait 1 --timeout soon
    assert_refused '--timeout takes whole seconds, not soon'
}

@test "stealth::sys::runtime::proc::wait: an option it does not take -> exits 1" {
    run stealth::sys::runtime::proc::wait 1 --forever
    assert_refused 'wait does not take --forever'
}

@test "stealth::sys::runtime::proc::wait: not a number -> exits 1" {
    run stealth::sys::runtime::proc::wait 'nginx'
    assert_refused 'a process number is a whole number, not nginx'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::stop
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::stop: a process -> it goes" {
    start_one
    local -r pid="${PID}"

    stealth::sys::runtime::proc::stop "${pid}" --wait 5

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::stop: a process -> returns 0" {
    start_one
    local -r pid="${PID}"

    run stealth::sys::runtime::proc::stop "${pid}" --wait 5
    assert_success
}

@test "stealth::sys::runtime::proc::stop: nothing to stop -> returns 0" {
    run stealth::sys::runtime::proc::stop 'nothing-runs-by-this-name'
    assert_success
}

@test "stealth::sys::runtime::proc::stop: a process that ignores SIGTERM -> is killed" {
    bash -c 'trap "" TERM; sleep 5' &
    local -r pid="$!"
    STARTED+=("${pid}")
    sleep 0.3

    stealth::sys::runtime::proc::stop "${pid}" --wait 1

    run stealth::sys::runtime::proc::exists "${pid}"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::stop: a process that ignores SIGTERM -> says it killed it" {
    bash -c 'trap "" TERM; sleep 5' &
    local -r pid="$!"
    STARTED+=("${pid}")
    sleep 0.3

    stealth::sys::runtime::proc::stop "${pid}" --wait 1

    assert_called_with stealth::util::log::warn '*did not go when asked*'
}

@test "stealth::sys::runtime::proc::stop: --wait that is not a number -> exits 1" {
    run stealth::sys::runtime::proc::stop 1 --wait soon
    assert_refused '--wait takes whole seconds, not soon'
}

@test "stealth::sys::runtime::proc::stop: an option it does not take -> exits 1" {
    run stealth::sys::runtime::proc::stop 1 --now
    assert_refused 'stop does not take --now'
}

@test "stealth::sys::runtime::proc::stop: nothing named -> exits 1" {
    run stealth::sys::runtime::proc::stop ''
    assert_refused 'a process number or a name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::_insist
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::_insist: a process nothing can kill -> returns 1" {
    fake_proc 4242
    local left=(4242)
    mock stealth::sys::cmd::try '*' 'return 0'

    run stealth::sys::runtime::proc::_insist left

    assert_failure 1
    assert_called_with stealth::util::log::warn '*still there after SIGKILL*'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::pidfile_write
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::pidfile_write: a number -> is in the file" {
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" 4242

    assert_file_contains "${WORK}/app.pid" '4242'
}

@test "stealth::sys::runtime::proc::pidfile_write: no number -> this shell goes in" {
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid"

    assert_file_contains "${WORK}/app.pid" "$$"
}

@test "stealth::sys::runtime::proc::pidfile_write: not a number -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" 'later'
    assert_refused 'a process number is a whole number, not later'
}

@test "stealth::sys::runtime::proc::pidfile_write: no file -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_write ''
    assert_refused 'a pid file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::pidfile_read
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::pidfile_read: a process still running -> its number" {
    start_one
    local -r pid="${PID}"
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" "${pid}"
    local got

    stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid"

    assert_equal "${got}" "${pid}"
}

@test "stealth::sys::runtime::proc::pidfile_read: --named that matches -> its number" {
    start_one
    local -r pid="${PID}"
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" "${pid}"
    local got

    stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid" --named sleep

    assert_equal "${got}" "${pid}"
}

@test "stealth::sys::runtime::proc::pidfile_read: --named that does not match -> returns 2" {
    start_one
    local -r pid="${PID}"
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" "${pid}"

    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid" --named nginx
    assert_failure 2
}

@test "stealth::sys::runtime::proc::pidfile_read: a number that has gone -> returns 2" {
    start_one
    local -r pid="${PID}"
    stealth::sys::runtime::proc::pidfile_write "${WORK}/app.pid" "${pid}"
    kill -9 "${pid}"
    wait "${pid}" 2>/dev/null || true

    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid"
    assert_failure 2
}

@test "stealth::sys::runtime::proc::pidfile_read: no such file -> returns 1" {
    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/nowhere.pid"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::pidfile_read: something that is not a number -> returns 1" {
    printf 'not a pid\n' > "${WORK}/app.pid"

    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::pidfile_read: an empty file -> returns 1" {
    : > "${WORK}/app.pid"

    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid"
    assert_failure 1
}

@test "stealth::sys::runtime::proc::pidfile_read: --named with nothing after it -> exits 1" {
    printf '1\n' > "${WORK}/app.pid"

    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid" --named
    assert_refused '--named takes a program'
}

@test "stealth::sys::runtime::proc::pidfile_read: an option it does not take -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_read got "${WORK}/app.pid" --stale
    assert_refused 'pidfile_read does not take --stale'
}

@test "stealth::sys::runtime::proc::pidfile_read: no output variable -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_read '' "${WORK}/app.pid"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::runtime::proc::pidfile_read: no file -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_read got ''
    assert_refused 'a pid file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::proc::pidfile_clear
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::proc::pidfile_clear: a file -> is gone" {
    printf '4242\n' > "${WORK}/app.pid"

    stealth::sys::runtime::proc::pidfile_clear "${WORK}/app.pid"

    assert_file_not_exists "${WORK}/app.pid"
}

@test "stealth::sys::runtime::proc::pidfile_clear: a file that is already gone -> is no trouble" {
    run stealth::sys::runtime::proc::pidfile_clear "${WORK}/nowhere.pid"
    assert_success
}

@test "stealth::sys::runtime::proc::pidfile_clear: no file -> exits 1" {
    run stealth::sys::runtime::proc::pidfile_clear ''
    assert_refused 'a pid file is required'
}

# ------------------------------------------------------------------------------
# sys/runtime/proc, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/proc: sourced twice -> returns before it declares anything" {
    run load_lib sys/runtime/proc
    assert_success
}
