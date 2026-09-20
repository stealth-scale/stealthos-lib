#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file. The single-quoted text
# given to in_run and in_shell is a script for a child shell, so what looks
# like an expansion that will not happen is one that happens over there.

# ==============================================================================
# core/trap - Test Suite
# ==============================================================================
# Registering a handler is state, and is tested here in the test's own shell.
# Taking over the four traps is not: an EXIT trap installed here would fire
# while bats is finishing the test. Those cases run a shell of their own with
# the library loaded, through `in_shell`, and read what it printed.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import core/trap
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Runs a script in a shell of its own with the library loaded, as a run would
# have it: strict options, core/trap imported, everything on standard error.
in_shell() {
    run --separate-stderr bash -c "
        set -Eeuo pipefail
        export STEALTH_LIB='${STEALTH_LIB_DIR}'
        export STEALTH_LOG_LEVEL=5 STEALTH_LOG_FORMAT=text STEALTH_LOG_COLOR=never
        source \"\${STEALTH_LIB}/util/import.sh\"
        stealth::util::import core/trap
        ${1}
    "
}

# A handler that records the arguments it was given.
mark() {
    printf 'mark(%s)\n' "$*" >> "${BATS_TEST_TMPDIR}/marks"
}

# What the handlers recorded, in the order they ran.
marks() {
    if [[ -f "${BATS_TEST_TMPDIR}/marks" ]]; then
        printf '%s' "$(< "${BATS_TEST_TMPDIR}/marks")"
    fi
}

# ------------------------------------------------------------------------------
# stealth::core::trap::init
# ------------------------------------------------------------------------------

@test "stealth::core::trap::init: the four traps -> are taken over" {
    in_shell 'stealth::core::trap::init; trap -p ERR EXIT INT TERM'

    assert_output --partial 'stealth::core::trap::_on_err'
    assert_output --partial 'stealth::core::trap::_on_exit'
    assert_output --partial 'stealth::core::trap::_on_signal SIGINT'
    assert_output --partial 'stealth::core::trap::_on_signal SIGTERM'
}

@test "stealth::core::trap::init: called twice -> takes them over once" {
    in_shell 'stealth::core::trap::init; stealth::core::trap::init; printf "%s\n" "${_STEALTH_CORE_TRAP_READY}"'

    assert_output '1'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::disable
# ------------------------------------------------------------------------------

@test "stealth::core::trap::disable: the four traps -> go back to the shell" {
    in_shell 'stealth::core::trap::init; stealth::core::trap::disable; trap -p ERR EXIT INT TERM'

    refute_output --partial 'stealth::core::trap'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::defer
# ------------------------------------------------------------------------------

@test "stealth::core::trap::defer: a handler -> is on the stack" {
    stealth::core::trap::defer mark

    assert_array_length _STEALTH_CORE_TRAP_STACK 1
}

@test "stealth::core::trap::defer: handlers -> run in the reverse of the order registered" {
    in_shell '
        one() { printf "one\n"; }
        two() { printf "two\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer one
        stealth::core::trap::defer two
    '

    assert_line --index 0 'two'
    assert_line --index 1 'one'
}

@test "stealth::core::trap::defer: arguments -> reach the handler whole" {
    in_shell '
        show() { printf "[%s]" "$@"; printf "\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer show "a path with spaces" "a;semicolon"
    '

    assert_output '[a path with spaces][a;semicolon]'
}

@test "stealth::core::trap::defer: a handler that fails -> the rest still run" {
    in_shell '
        bad() { return 1; }
        good() { printf "good ran\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer good
        stealth::core::trap::defer bad
    '

    assert_output --partial 'good ran'
}

@test "stealth::core::trap::defer: no function -> exits 1" {
    run stealth::core::trap::defer ''
    assert_refused 'the name of a function is required'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::finally
# ------------------------------------------------------------------------------

@test "stealth::core::trap::finally: a handler -> runs after every deferred one" {
    in_shell '
        last() { printf "last %s\n" "$1"; }
        first() { printf "first\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer first
        stealth::core::trap::finally last
    '

    assert_line --index 0 'first'
    assert_line --index 1 'last 0'
}

@test "stealth::core::trap::finally: the status of the run -> is its last argument" {
    in_shell '
        last() { printf "status %s\n" "$1"; }
        stealth::core::trap::init
        stealth::core::trap::finally last
        exit 7
    '

    assert_output --partial 'status 7'
}

@test "stealth::core::trap::finally: arguments of its own -> come before the status" {
    in_shell '
        last() { printf "[%s]" "$@"; printf "\n"; }
        stealth::core::trap::init
        stealth::core::trap::finally last recorder
        exit 3
    '

    assert_output '[recorder][3]'
}

@test "stealth::core::trap::finally: no function -> exits 1" {
    run stealth::core::trap::finally ''
    assert_refused 'the name of a function is required'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::reported
# ------------------------------------------------------------------------------

@test "stealth::core::trap::reported: nothing reported -> the status is said" {
    in_shell 'stealth::core::trap::init; exit 4'

    assert_equal "${status}" 4
    assert_stderr --partial 'the run ended with status 4'
}

@test "stealth::core::trap::reported: called first -> the status is not said again" {
    in_shell 'stealth::core::trap::init; stealth::core::trap::reported; exit 4'

    assert_equal "${status}" 4
    refute_stderr --partial 'the run ended with status'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::print_stack
# ------------------------------------------------------------------------------

@test "stealth::core::trap::print_stack: inside a function -> names it" {
    outer() { stealth::core::trap::print_stack; }

    outer

    # The line is where outer was called, not where this assertion sits, so
    # the pattern ends open rather than pinning a number that moves.
    assert_called_with stealth::util::log::debug \
        "  at %s (%s line %s) outer ${BASH_SOURCE[0]} *"
}

@test "stealth::core::trap::print_stack: the frames of this module -> are left out" {
    outer() { stealth::core::trap::print_stack; }

    outer

    refute_called_with stealth::util::log::debug '*stealth::core::trap*'
}

@test "stealth::core::trap::print_stack: a percent in a name -> is not read as a format" {
    # The old module passed the trace as the format of printf, so a name with
    # a percent in it came out mangled or took an argument that was not there.
    # shellcheck disable=SC2329  # called through the name below
    eval 'weird%s() { stealth::core::trap::print_stack; }'

    run 'weird%s'

    assert_success
}

# ------------------------------------------------------------------------------
# stealth::core::trap::_run_handler
# ------------------------------------------------------------------------------

@test "stealth::core::trap::_run_handler: a handler with no arguments -> runs it" {
    stealth::core::trap::_run_handler 'mark'

    run marks
    assert_output 'mark()'
}

@test "stealth::core::trap::_run_handler: a handler with arguments -> passes them whole" {
    stealth::core::trap::_run_handler "mark${_STEALTH_CORE_TRAP_UNIT}one two"

    run marks
    assert_output 'mark(one two)'
}

@test "stealth::core::trap::_run_handler: a name that is not a function -> says so" {
    stealth::core::trap::_run_handler 'no_such_handler'

    assert_called_with_args stealth::util::log::warn \
        'no handler named %s to run at the end' 'no_such_handler'
}

@test "stealth::core::trap::_run_handler: a handler that fails -> says so and returns 0" {
    # shellcheck disable=SC2329  # called through _run_handler
    failing() { return 1; }

    run stealth::core::trap::_run_handler 'failing'
    assert_success

    stealth::core::trap::_run_handler 'failing'
    assert_called_with_args stealth::util::log::warn \
        'the handler %s failed while the run was ending' 'failing'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::_on_err
# ------------------------------------------------------------------------------

@test "stealth::core::trap::_on_err: a command that fails -> ends the run with its status" {
    in_shell '
        stealth::core::trap::init
        false_with() { return 9; }
        false_with
        printf "this line is never reached\n"
    '

    assert_equal "${status}" 9
    refute_output --partial 'never reached'
}

@test "stealth::core::trap::_on_err: a command that fails -> names the command itself" {
    in_shell '
        stealth::core::trap::init
        failing() { return 9; }
        failing
    '

    assert_equal "${status}" 9
    assert_stderr --partial 'return 9 failed with status 9'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::_on_signal
# ------------------------------------------------------------------------------

# An interrupt is driven by calling the handler, not by sending the signal.
# bats ignores SIGINT in a test process, a child inherits that, and a shell
# cannot trap a signal that was ignored when it started. A termination is not
# ignored, so that one is sent for real.

@test "stealth::core::trap::_on_signal: an interrupt -> ends the run with 130" {
    in_shell 'stealth::core::trap::init; stealth::core::trap::_on_signal SIGINT 130'

    assert_equal "${status}" 130
    assert_stderr --partial 'the run was stopped by SIGINT'
}

@test "stealth::core::trap::_on_signal: a termination -> ends the run with 143" {
    in_shell 'stealth::core::trap::init; kill -TERM $$'

    assert_equal "${status}" 143
    assert_stderr --partial 'the run was stopped by SIGTERM'
}

@test "stealth::core::trap::_on_signal: a signal -> still runs the handlers" {
    in_shell '
        cleanup() { printf "cleanup ran\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer cleanup
        kill -TERM $$
    '

    assert_output --partial 'cleanup ran'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::_reset_terminal
# ------------------------------------------------------------------------------

@test "stealth::core::trap::_reset_terminal: no terminal -> writes nothing" {
    run --separate-stderr stealth::core::trap::_reset_terminal

    assert_success
    assert_equal "${stderr}" ''
}

@test "stealth::core::trap::_reset_terminal: a terminal -> shows the cursor and drops the colour" {
    mock stealth::core::trap::_is_terminal '*' 'return 0'

    run --separate-stderr stealth::core::trap::_reset_terminal

    assert_success
    assert_equal "${stderr}" $'\033[?25h\033[0m'
}

# ------------------------------------------------------------------------------
# stealth::core::trap::_is_terminal
# ------------------------------------------------------------------------------

@test "stealth::core::trap::_is_terminal: standard error is a file -> returns 1" {
    run stealth::core::trap::_is_terminal
    assert_failure 1
}

# ------------------------------------------------------------------------------
# core/trap, the module itself
# ------------------------------------------------------------------------------

@test "core/trap: a run that ends well -> the handlers still run" {
    in_shell '
        cleanup() { printf "cleanup ran\n"; }
        stealth::core::trap::init
        stealth::core::trap::defer cleanup
        printf "the work is done\n"
    '

    assert_success
    assert_line --index 0 'the work is done'
    assert_line --index 1 'cleanup ran'
}

@test "core/trap: sourced twice -> returns before it declares anything" {
    stealth::core::trap::defer mark
    load_lib core/trap

    assert_array_length _STEALTH_CORE_TRAP_STACK 1
}
