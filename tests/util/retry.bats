#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/retry - Test Suite
# ==============================================================================
# Both functions run a command and wait, so every test mocks sleep and the
# command. Mocking sleep keeps the suite fast and lets a test read the delays
# that were asked for.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/retry
    load_mock util
    mock::stealth::util::log

    # No test waits for real time.
    mock sleep '*' 'return 0'
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# A command that fails the first COUNT times it runs and succeeds after that.
# The count is kept in a file, because each attempt may run in a subshell.
fails_times() {
    local -r count="${1}"
    local -r ledger="${BATS_TEST_TMPDIR}/attempts"

    mock flaky '*' "
        printf 'x' >> '${ledger}'
        attempts=\$(< '${ledger}')
        if (( \${#attempts} <= ${count} )); then return 7; fi
        return 0
    "
}

# How many times the flaky command ran.
attempts() {
    local -r ledger="${BATS_TEST_TMPDIR}/attempts"
    if [[ ! -f "${ledger}" ]]; then
        printf '0'
        return 0
    fi
    local -r marks="$(< "${ledger}")"
    printf '%s' "${#marks}"
}

# ------------------------------------------------------------------------------
# stealth::util::retry::run
# ------------------------------------------------------------------------------

@test "stealth::util::retry::run: the command succeeds -> runs it once" {
    fails_times 0

    run stealth::util::retry::run 3 1 flaky
    assert_success

    run attempts
    assert_output '1'
}

@test "stealth::util::retry::run: the command succeeds late -> runs it until it does" {
    fails_times 2

    run stealth::util::retry::run 3 1 flaky
    assert_success

    run attempts
    assert_output '3'
}

@test "stealth::util::retry::run: every attempt fails -> gives the last status back" {
    fails_times 99

    run stealth::util::retry::run 2 1 flaky
    assert_failure 7
}

@test "stealth::util::retry::run: every attempt fails -> runs the retries and no more" {
    fails_times 99

    run stealth::util::retry::run 2 1 flaky

    run attempts
    assert_output '3'
}

@test "stealth::util::retry::run: no retries -> runs the command once" {
    fails_times 99

    run stealth::util::retry::run 0 1 flaky
    assert_failure 7

    run attempts
    assert_output '1'
}

@test "stealth::util::retry::run: giving up -> does not end the process" {
    fails_times 99

    stealth::util::retry::run 1 1 flaky || true

    refute_called stealth::util::log::error
}

@test "stealth::util::retry::run: a failure -> waits before the next attempt" {
    fails_times 1

    run stealth::util::retry::run 3 5 flaky
    assert_success

    assert_called_once_with sleep 5
}

@test "stealth::util::retry::run: several failures -> the delay grows" {
    fails_times 2

    run stealth::util::retry::run 3 1 flaky
    assert_success

    assert_called_times sleep 2
    assert_called_with_args sleep 1
}

@test "stealth::util::retry::run: the command succeeds -> never waits" {
    fails_times 0

    run stealth::util::retry::run 3 1 flaky
    assert_success

    refute_called sleep
}

@test "stealth::util::retry::run: a late success -> says which attempt it was" {
    fails_times 1

    run stealth::util::retry::run 3 1 flaky

    assert_called_with_args stealth::util::log::debug \
        'attempt %d of %d succeeded' 2 4
}

@test "stealth::util::retry::run: no command -> exits 1" {
    run stealth::util::retry::run 3 1
    assert_refused 'a command to run is required'
}

@test "stealth::util::retry::run: a count of retries that is not a number -> exits 1" {
    run stealth::util::retry::run many 1 true
    assert_refused 'a number of retries is a whole number, zero or above, not many'
}

@test "stealth::util::retry::run: a count of retries below zero -> exits 1" {
    run stealth::util::retry::run -1 1 true
    assert_refused 'a number of retries is a whole number, zero or above, not -1'
}

@test "stealth::util::retry::run: a delay that is not a number -> exits 1" {
    run stealth::util::retry::run 3 soon true
    assert_refused 'a delay in seconds is a whole number, zero or above, not soon'
}

# ------------------------------------------------------------------------------
# stealth::util::retry::until
# ------------------------------------------------------------------------------

@test "stealth::util::retry::until: the command succeeds -> returns 0" {
    fails_times 0

    run stealth::util::retry::until 60 5 flaky
    assert_success

    run attempts
    assert_output '1'
}

@test "stealth::util::retry::until: the command succeeds late -> returns 0" {
    fails_times 2

    run stealth::util::retry::until 60 5 flaky
    assert_success

    run attempts
    assert_output '3'
}

@test "stealth::util::retry::until: a deadline of zero -> still asks once" {
    fails_times 99

    run stealth::util::retry::until 0 5 flaky
    assert_failure 124

    run attempts
    assert_output '1'
}

@test "stealth::util::retry::until: the deadline passes -> returns 124" {
    fails_times 99

    run stealth::util::retry::until 0 5 flaky
    assert_failure 124
}

@test "stealth::util::retry::until: the deadline passes -> never waits after the last attempt" {
    fails_times 99

    run stealth::util::retry::until 0 5 flaky

    refute_called sleep
}

@test "stealth::util::retry::until: the deadline passes -> says what it waited for" {
    fails_times 99

    run stealth::util::retry::until 0 5 flaky

    assert_called_with_args stealth::util::log::warn \
        '%s did not succeed within %ds' flaky 0
}

@test "stealth::util::retry::until: a failure before the deadline -> waits the interval" {
    fails_times 1

    run stealth::util::retry::until 60 5 flaky
    assert_success

    assert_called_once_with sleep 5
}

@test "stealth::util::retry::until: no command -> exits 1" {
    run stealth::util::retry::until 60 5
    assert_refused 'a command to run is required'
}

@test "stealth::util::retry::until: a timeout that is not a number -> exits 1" {
    run stealth::util::retry::until later 5 true
    assert_refused 'a timeout in seconds is a whole number, zero or above, not later'
}

@test "stealth::util::retry::until: an interval that is not a number -> exits 1" {
    run stealth::util::retry::until 60 often true
    assert_refused 'an interval in seconds is a whole number, zero or above, not often'
}

# ------------------------------------------------------------------------------
# stealth::util::retry::_backoff
# ------------------------------------------------------------------------------

@test "stealth::util::retry::_backoff: a delay -> doubles it" {
    local next

    stealth::util::retry::_backoff next 4

    assert_ge "${next}" 8
    assert_le "${next}" 10
}

@test "stealth::util::retry::_backoff: a delay at the cap -> holds it at the cap" {
    local next

    stealth::util::retry::_backoff next 60

    assert_ge "${next}" 60
    assert_le "${next}" 75
}

@test "stealth::util::retry::_backoff: a delay of zero -> stays at zero" {
    local next

    stealth::util::retry::_backoff next 0

    assert_equal "${next}" 0
}

@test "stealth::util::retry::_backoff: called many times -> never goes past the cap and its jitter" {
    local next i

    for (( i = 0; i < 20; i++ )); do
        stealth::util::retry::_backoff next 60
        assert_le "${next}" 75
    done
}

# ------------------------------------------------------------------------------
# util/retry, the module itself
# ------------------------------------------------------------------------------

@test "util/retry: sourced twice -> returns before it declares anything" {
    load_lib util/retry
    fails_times 0

    run stealth::util::retry::run 1 1 flaky
    assert_success
}
