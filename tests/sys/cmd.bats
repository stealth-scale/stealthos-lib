#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/cmd - Test Suite
# ==============================================================================
# The logger is mocked, so a test reads the call a function made rather than
# what a sink received. A command that ends the run does so through
# util::log::error, and assert_refused and assert_called_with_args are how
# that is read.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/cmd
    load_mock util
    mock::stealth::util::log
}

teardown() {
    stealth::sys::cmd::cleanup || true
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::run
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::run: a command that works -> returns 0" {
    run stealth::sys::cmd::run true
    assert_success
}

@test "stealth::sys::cmd::run: a command that works -> writes nothing to the caller" {
    run stealth::sys::cmd::run printf 'checking for gcc\n'
    assert_output ''
}

@test "stealth::sys::cmd::run: a command that fails -> ends the run with its status" {
    run stealth::sys::cmd::run bash -c 'exit 2'

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        -c 2 'the run cannot go on without %s' bash
}

@test "stealth::sys::cmd::run: a command that fails -> logs what it printed" {
    run stealth::sys::cmd::run bash -c 'printf "no acceptable C compiler\n" >&2; exit 1'

    assert_called_with stealth::util::log::warn '*no acceptable C compiler*'
}

@test "stealth::sys::cmd::run: a command that is not there -> ends the run" {
    run stealth::sys::cmd::run no_such_command_anywhere

    assert_failure 1
    assert_called_with stealth::util::log::error '*the run cannot go on*'
}

@test "stealth::sys::cmd::run: a dry run -> says what it would have run" {
    STEALTH_DRY_RUN=1

    run stealth::sys::cmd::run rm -rf /

    assert_success
    assert_called_with_args stealth::util::log::info 'would run: %s' 'rm -rf /'
}

@test "stealth::sys::cmd::run: no command -> exits 1" {
    run stealth::sys::cmd::run ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::try
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::try: a command that works -> returns 0" {
    run stealth::sys::cmd::try true
    assert_success
}

@test "stealth::sys::cmd::try: a command that fails -> gives its status back" {
    run stealth::sys::cmd::try bash -c 'exit 3'
    assert_failure 3
}

@test "stealth::sys::cmd::try: a command that fails -> does not end the run" {
    run stealth::sys::cmd::try false

    refute_called stealth::util::log::error
}

@test "stealth::sys::cmd::try: a command that fails -> logs what it printed at debug" {
    run stealth::sys::cmd::try bash -c 'printf "the reason\n"; exit 1'

    assert_called_with stealth::util::log::debug '*the reason*'
}

@test "stealth::sys::cmd::try: a dry run -> returns 0 without running it" {
    STEALTH_DRY_RUN=1

    run stealth::sys::cmd::try false
    assert_success
}

@test "stealth::sys::cmd::try: no command -> exits 1" {
    run stealth::sys::cmd::try ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::capture
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::capture: what a command prints -> is the value" {
    assert_nameref 'the answer' stealth::sys::cmd::capture printf 'the answer'
}

@test "stealth::sys::cmd::capture: the line breaks at the end -> are taken off" {
    assert_nameref 'one' stealth::sys::cmd::capture printf 'one\n\n'
}

@test "stealth::sys::cmd::capture: several lines -> are kept whole" {
    assert_nameref $'one\ntwo' stealth::sys::cmd::capture printf 'one\ntwo\n'
}

@test "stealth::sys::cmd::capture: what went to standard error -> is not the value" {
    assert_nameref 'out' stealth::sys::cmd::capture \
        bash -c 'printf "out"; printf "err\n" >&2'
}

@test "stealth::sys::cmd::capture: a command that fails -> gives its status back" {
    run stealth::sys::cmd::capture out bash -c 'exit 4'
    assert_failure 4
}

@test "stealth::sys::cmd::capture: a command that fails -> logs what went to standard error" {
    # At DEBUG, not WARN. A caller that takes the status back expects to
    # handle a failure, and asking for something that is not there is an
    # answer rather than a fault. run is what escalates.
    run stealth::sys::cmd::capture out bash -c 'printf "the reason\n" >&2; exit 1'

    assert_called_with stealth::util::log::debug '*the reason*'
    refute_called_with stealth::util::log::warn '*the reason*'
}

@test "stealth::sys::cmd::capture: a dry run -> gives an empty value" {
    STEALTH_DRY_RUN=1

    assert_nameref '' stealth::sys::cmd::capture printf 'the answer'
}

@test "stealth::sys::cmd::capture: no output variable -> exits 1" {
    run stealth::sys::cmd::capture ''
    assert_refused 'an output variable is required'
}

@test "stealth::sys::cmd::capture: no command -> exits 1" {
    run stealth::sys::cmd::capture out ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::stream
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::stream: what a command prints -> goes to the console sink" {
    exec {_STEALTH_UTIL_LOG_FD_CONSOLE}>"${BATS_TEST_TMPDIR}/console"

    stealth::sys::cmd::stream printf 'watching this\n'

    assert_file_contains "${BATS_TEST_TMPDIR}/console" 'watching this'
}

@test "stealth::sys::cmd::stream: standard error -> goes there as well" {
    exec {_STEALTH_UTIL_LOG_FD_CONSOLE}>"${BATS_TEST_TMPDIR}/console"

    stealth::sys::cmd::stream bash -c 'printf "a warning\n" >&2'

    assert_file_contains "${BATS_TEST_TMPDIR}/console" 'a warning'
}

@test "stealth::sys::cmd::stream: a command that fails -> gives its status back" {
    exec {_STEALTH_UTIL_LOG_FD_CONSOLE}>"${BATS_TEST_TMPDIR}/console"

    run stealth::sys::cmd::stream bash -c 'exit 5'
    assert_failure 5
}

@test "stealth::sys::cmd::stream: a dry run -> returns 0 without running it" {
    STEALTH_DRY_RUN=1

    run stealth::sys::cmd::stream false
    assert_success
}

@test "stealth::sys::cmd::stream: no command -> exits 1" {
    run stealth::sys::cmd::stream ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::silent
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::silent: a command that works -> returns 0" {
    run stealth::sys::cmd::silent true
    assert_success
}

@test "stealth::sys::cmd::silent: a command that fails -> gives its status back" {
    run stealth::sys::cmd::silent bash -c 'exit 6'
    assert_failure 6
}

@test "stealth::sys::cmd::silent: what a command prints -> reaches nobody" {
    run stealth::sys::cmd::silent bash -c 'printf "out\n"; printf "err\n" >&2'

    assert_output ''
}

@test "stealth::sys::cmd::silent: a dry run -> returns 0 without running it" {
    STEALTH_DRY_RUN=1

    run stealth::sys::cmd::silent false
    assert_success
}

@test "stealth::sys::cmd::silent: no command -> exits 1" {
    run stealth::sys::cmd::silent ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::timeout
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::timeout: a command that finishes -> returns 0" {
    run stealth::sys::cmd::timeout 5s true
    assert_success
}

@test "stealth::sys::cmd::timeout: a command that takes too long -> returns 124" {
    # The old module went through run, which exits, so a caller could never
    # tell a timeout from any other failure.
    run stealth::sys::cmd::timeout 0.1s sleep 5
    assert_failure 124
}

@test "stealth::sys::cmd::timeout: a command that takes too long -> says so" {
    run stealth::sys::cmd::timeout 0.1s sleep 5

    assert_called_with_args stealth::util::log::warn \
        '%s did not finish within %s' sleep '0.1s'
}

@test "stealth::sys::cmd::timeout: a command that fails on its own -> gives that status" {
    run stealth::sys::cmd::timeout 5s bash -c 'exit 7'
    assert_failure 7
}

@test "stealth::sys::cmd::timeout: no duration -> exits 1" {
    run stealth::sys::cmd::timeout ''
    assert_refused 'a duration is required'
}

@test "stealth::sys::cmd::timeout: no command -> exits 1" {
    run stealth::sys::cmd::timeout 5s ''
    assert_refused 'a command to run is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::exists
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::exists: a command on the path -> returns 0" {
    run stealth::sys::cmd::exists printf
    assert_success
}

@test "stealth::sys::cmd::exists: a command that is not -> returns 1" {
    run stealth::sys::cmd::exists no_such_command_anywhere
    assert_failure 1
}

@test "stealth::sys::cmd::exists: a shell function of that name -> returns 1" {
    # A caller asking this wants to know whether the program is installed.
    # The old module used type -t, which is true for a function as well. The
    # name is one no machine has, so the answer cannot come from the path.
    # shellcheck disable=SC2329  # looked for by name, not called
    no_such_program_anywhere() { :; }

    run stealth::sys::cmd::exists no_such_program_anywhere
    assert_failure 1
}

@test "stealth::sys::cmd::exists: asked twice -> remembers the answer" {
    stealth::sys::cmd::exists printf

    assert_equal "${_STEALTH_SYS_CMD_FOUND[printf]}" 0

    run stealth::sys::cmd::exists printf
    assert_success
}

@test "stealth::sys::cmd::exists: a command that is not, asked twice -> remembers that too" {
    stealth::sys::cmd::exists no_such_command_anywhere || true

    assert_equal "${_STEALTH_SYS_CMD_FOUND[no_such_command_anywhere]}" 1

    run stealth::sys::cmd::exists no_such_command_anywhere
    assert_failure 1
}

@test "stealth::sys::cmd::exists: no name -> exits 1" {
    run stealth::sys::cmd::exists ''
    assert_refused 'the name of a command is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::cleanup
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::cleanup: a directory that was made -> is removed" {
    stealth::sys::cmd::try true
    local -r made="${_STEALTH_SYS_CMD_BUFFER_DIR}"

    stealth::sys::cmd::cleanup

    assert_dir_not_exists "${made}"
    assert_var_equal _STEALTH_SYS_CMD_BUFFER_DIR ''
}

@test "stealth::sys::cmd::cleanup: nothing made -> returns 0" {
    run stealth::sys::cmd::cleanup
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_buffer_dir
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_buffer_dir: the directory -> is readable by nobody else" {
    stealth::sys::cmd::_buffer_dir

    assert_file_permission 700 "${_STEALTH_SYS_CMD_BUFFER_DIR}"
}

@test "stealth::sys::cmd::_buffer_dir: asked twice -> makes one directory" {
    stealth::sys::cmd::_buffer_dir
    local -r first="${_STEALTH_SYS_CMD_BUFFER_DIR}"

    stealth::sys::cmd::_buffer_dir

    assert_var_equal _STEALTH_SYS_CMD_BUFFER_DIR "${first}"
}

@test "stealth::sys::cmd::_buffer_dir: no directory can be made -> ends the run" {
    mock mktemp '*' 'return 1'

    run stealth::sys::cmd::_buffer_dir

    assert_failure 1
    assert_called_with stealth::util::log::error \
        'no directory could be made to hold command output'
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_open_buffer
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_open_buffer: two buffers -> have names of their own" {
    local one two

    stealth::sys::cmd::_open_buffer one
    stealth::sys::cmd::_open_buffer two

    refute_equal "${one}" "${two}"
}

@test "stealth::sys::cmd::_open_buffer: a buffer -> sits in the private directory" {
    local path

    stealth::sys::cmd::_open_buffer path

    assert_starts_with "${path}" "${_STEALTH_SYS_CMD_BUFFER_DIR}/"
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_signal_name
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_signal_name: a signal it knows -> names it" {
    assert_nameref 'SIGKILL' stealth::sys::cmd::_signal_name 9
}

@test "stealth::sys::cmd::_signal_name: an interrupt -> names it" {
    assert_nameref 'SIGINT' stealth::sys::cmd::_signal_name 2
}

@test "stealth::sys::cmd::_signal_name: a signal it does not know -> gives its number" {
    assert_nameref 'signal 31' stealth::sys::cmd::_signal_name 31
}

@test "stealth::sys::cmd::_signal_name: every signal it knows -> has a name" {
    local name
    local -i number

    for number in 1 2 3 6 9 11 13 15; do
        stealth::sys::cmd::_signal_name name "${number}"
        assert_starts_with "${name}" 'SIG'
    done
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_log_buffer
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_log_buffer: a short buffer -> is written whole" {
    printf 'one\ntwo\n' > "${BATS_TEST_TMPDIR}/buffer"

    stealth::sys::cmd::_log_buffer warn "${BATS_TEST_TMPDIR}/buffer" 'what it printed'

    assert_called_with stealth::util::log::warn '*one*two*'
}

@test "stealth::sys::cmd::_log_buffer: a long buffer -> has its middle left out" {
    local -i i
    for (( i = 1; i <= 50; i++ )); do
        printf 'line %d\n' "${i}" >> "${BATS_TEST_TMPDIR}/buffer"
    done

    stealth::sys::cmd::_log_buffer warn "${BATS_TEST_TMPDIR}/buffer" 'what it printed'

    assert_called_with stealth::util::log::warn '*50 lines, 10 shown at each end*'
}

@test "stealth::sys::cmd::_log_buffer: a buffer with nothing in it -> writes nothing" {
    : > "${BATS_TEST_TMPDIR}/buffer"

    stealth::sys::cmd::_log_buffer warn "${BATS_TEST_TMPDIR}/buffer" 'what it printed'

    refute_called stealth::util::log::warn
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_report_failure
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_report_failure: a status -> says which" {
    : > "${BATS_TEST_TMPDIR}/buffer"

    stealth::sys::cmd::_report_failure warn 2 "${BATS_TEST_TMPDIR}/buffer" podman build

    assert_called_with_args stealth::util::log::warn \
        '%s failed with status %d' podman 2
}

@test "stealth::sys::cmd::_report_failure: a signal -> names it instead of the status" {
    : > "${BATS_TEST_TMPDIR}/buffer"

    stealth::sys::cmd::_report_failure warn 137 "${BATS_TEST_TMPDIR}/buffer" podman build

    assert_called_with_args stealth::util::log::warn \
        '%s was stopped by %s' podman SIGKILL
}

# ------------------------------------------------------------------------------
# stealth::sys::cmd::_is_dry_run
# ------------------------------------------------------------------------------

@test "stealth::sys::cmd::_is_dry_run: the setting is off -> returns 1" {
    STEALTH_DRY_RUN=0

    run stealth::sys::cmd::_is_dry_run rm -rf /
    assert_failure 1
}

@test "stealth::sys::cmd::_is_dry_run: the setting is on -> returns 0" {
    STEALTH_DRY_RUN=1

    run stealth::sys::cmd::_is_dry_run rm -rf /
    assert_success
}

# ------------------------------------------------------------------------------
# sys/cmd, the module itself
# ------------------------------------------------------------------------------

@test "sys/cmd: a command that was stopped by a signal -> is reported as that signal" {
    run stealth::sys::cmd::try bash -c 'kill -TERM $$'

    assert_called_with_args stealth::util::log::debug \
        '%s was stopped by %s' bash SIGTERM
}

@test "sys/cmd: a buffer -> is removed once the command has run" {
    stealth::sys::cmd::try true

    run bash -c "ls -A '${_STEALTH_SYS_CMD_BUFFER_DIR}'"
    assert_output ''
}

@test "sys/cmd: sourced twice -> returns before it declares anything" {
    stealth::sys::cmd::exists printf

    load_lib sys/cmd

    assert_equal "${_STEALTH_SYS_CMD_FOUND[printf]}" 0
}
