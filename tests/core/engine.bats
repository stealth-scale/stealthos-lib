#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file. The single-quoted text
# given to in_run and in_shell is a script for a child shell, so what looks
# like an expansion that will not happen is one that happens over there.

# ==============================================================================
# core/engine - Test Suite
# ==============================================================================
# Reading the configuration and calling a hook are ordinary functions, and are
# tested in the test's own shell. A whole run is not: it takes over the
# descriptors and the traps. Those cases run a shell of their own through
# `in_run`, and the hooks of the fixture modules record what happened in a
# file, because standard output belongs to the run by then.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    STEALTH_MODULES="${BATS_TEST_TMPDIR}/modules"
    STEALTH_MARKS="${BATS_TEST_TMPDIR}/marks"
    STEALTH_CONF_FILE="${BATS_TEST_TMPDIR}/stealth.conf"
    STEALTH_CONF_DIR="${BATS_TEST_TMPDIR}/conf.d"
    mkdir -p "${STEALTH_MODULES}" "${STEALTH_CONF_DIR}"
    : > "${STEALTH_CONF_FILE}"

    load_lib util/import core/engine
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Writes a module whose hooks record that they ran.
#
#   given_module NAME [START_STATUS]
given_module() {
    local -r name="${1}"
    local -r status="${2:-0}"
    local -r dir="${STEALTH_MODULES}/${name}"

    mkdir -p "${dir}"
    cat > "${dir}/common.sh" <<EOF
mod::${name}::init() { printf 'init ${name}\n' >> "\${STEALTH_MARKS}"; }
EOF
    cat > "${dir}/build.sh" <<EOF
mod::${name}::build::start() {
    printf 'start ${name}\n' >> "\${STEALTH_MARKS}"
    return ${status}
}
mod::${name}::build::end() { printf 'end ${name}\n' >> "\${STEALTH_MARKS}"; }
EOF
}

# Writes a module whose start hook fails on its first line and then tries to
# go on, for the test that it does not.
#
#   given_failing_module NAME
given_failing_module() {
    local -r name="${1}"
    local -r dir="${STEALTH_MODULES}/${name}"

    mkdir -p "${dir}"
    cat > "${dir}/build.sh" <<EOF
mod::${name}::build::start() {
    false
    printf 'PAST THE FAILURE\n' >&2
}
EOF
}

# Runs a script in a shell of its own, as a run would have it. An expected
# status may come first, as `run` takes one.
in_run() {
    local -a _prefix=(run --separate-stderr)
    if [[ "${1}" == -* ]]; then
        _prefix+=("${1}")
        shift
    fi

    "${_prefix[@]}" bash -c "
        set -Eeuo pipefail
        export STEALTH_LIB='${STEALTH_LIB_DIR}'
        export STEALTH_CONF_FILE='${STEALTH_CONF_FILE}'
        export STEALTH_CONF_DIR='${STEALTH_CONF_DIR}'
        export STEALTH_MARKS='${STEALTH_MARKS}'
        export STEALTH_LOG_COLOR=never STEALTH_UI_WIDTH=40
        source \"\${STEALTH_LIB}/util/import.sh\"
        stealth::util::import core/engine
        stealth::core::engine::configure
        stealth::core::state::add_search_path '${STEALTH_MODULES}'
        ${1}
    "
}

# What the hooks recorded, in the order they ran.
marks() {
    if [[ -f "${STEALTH_MARKS}" ]]; then
        printf '%s' "$(< "${STEALTH_MARKS}")"
    fi
}

# ------------------------------------------------------------------------------
# stealth::core::engine::configure
# ------------------------------------------------------------------------------

@test "stealth::core::engine::configure: a setting in the file -> is in the registry" {
    printf 'log_level = 4\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '4' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: the STEALTH_ spelling -> is the same setting" {
    printf 'STEALTH_LOG_LEVEL=4\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '4' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: an export in front -> is read the same" {
    printf 'export log_level=4\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '4' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: quotes around a value -> are taken off" {
    printf 'log_file = "/var/log/stealth.log"\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '/var/log/stealth.log' stealth::core::state::get 'log_file'
}

@test "stealth::core::engine::configure: single quotes -> are taken off too" {
    printf "log_file = '/var/log/stealth.log'\n" > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '/var/log/stealth.log' stealth::core::state::get 'log_file'
}

@test "stealth::core::engine::configure: comments and blank lines -> are skipped" {
    printf '# a comment\n\n   \nlog_level = 4\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '4' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: a line that is not a setting -> is reported" {
    printf 'this is not a setting\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_called_with_args stealth::util::log::warn \
        '%s line %d is not a setting: %s' \
        "${STEALTH_CONF_FILE}" 1 'this is not a setting'
}

@test "stealth::core::engine::configure: a line that is not a setting -> is not a setting" {
    printf 'this is not a setting\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    run stealth::core::state::has 'this is not a setting'
    assert_failure 1
}

@test "stealth::core::engine::configure: a fragment -> is read as well" {
    printf 'log_level = 4\n' > "${STEALTH_CONF_FILE}"
    printf 'jobs = 8\n' > "${STEALTH_CONF_DIR}/jobs.conf"

    stealth::core::engine::configure

    assert_nameref '8' stealth::core::state::get 'jobs'
}

@test "stealth::core::engine::configure: a later fragment -> wins over an earlier one" {
    printf 'jobs = 2\n' > "${STEALTH_CONF_DIR}/10-jobs.conf"
    printf 'jobs = 8\n' > "${STEALTH_CONF_DIR}/20-jobs.conf"

    stealth::core::engine::configure

    assert_nameref '8' stealth::core::state::get 'jobs'
}

@test "stealth::core::engine::configure: a file that is not there -> is no trouble" {
    STEALTH_CONF_FILE="${BATS_TEST_TMPDIR}/nowhere.conf"

    run stealth::core::engine::configure
    assert_success
}

@test "stealth::core::engine::configure: a setting already given -> beats the file" {
    export STEALTH_LOG_LEVEL=1
    printf 'log_level = 4\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_nameref '1' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: called twice -> reads the file once" {
    printf 'log_level = 4\n' > "${STEALTH_CONF_FILE}"
    stealth::core::engine::configure
    stealth::core::state::set 'log_level' '9'

    stealth::core::engine::configure

    assert_nameref '9' stealth::core::state::get 'log_level'
}

@test "stealth::core::engine::configure: a setting the util layer reads -> becomes a variable" {
    printf 'log_format = json\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_var_equal STEALTH_LOG_FORMAT json
}

@test "stealth::core::engine::configure: dry_run -> reaches sys, which cannot read the registry" {
    printf 'dry_run = 1\n' > "${STEALTH_CONF_FILE}"

    stealth::core::engine::configure

    assert_var_equal STEALTH_DRY_RUN 1
}

# ------------------------------------------------------------------------------
# stealth::core::engine::run
# ------------------------------------------------------------------------------

@test "stealth::core::engine::run: the stage from the file -> decides which file loads" {
    # The configuration is read before a module is loaded, so a stage set in a
    # file is the one whose file the loader reads. The old engine read the
    # configuration afterwards and ignored it.
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_success
    run marks
    assert_line --index 1 'start alpha'
}

@test "stealth::core::engine::run: the start hooks -> run in load order" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha
    given_module beta

    in_run 'stealth::core::loader::module alpha beta; stealth::core::engine::run'

    run marks
    assert_line --index 2 'start alpha'
    assert_line --index 3 'start beta'
}

@test "stealth::core::engine::run: the end hooks -> run in reverse" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha
    given_module beta

    in_run 'stealth::core::loader::module alpha beta; stealth::core::engine::run'

    run marks
    assert_line --index 4 'end beta'
    assert_line --index 5 'end alpha'
}

@test "stealth::core::engine::run: every init -> runs before every start" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha
    given_module beta

    in_run 'stealth::core::loader::module alpha beta; stealth::core::engine::run'

    run marks
    assert_line --index 0 'init alpha'
    assert_line --index 1 'init beta'
}

@test "stealth::core::engine::run: a payload -> runs between the passes" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    in_run '
        work() { printf "payload\n" >> "${STEALTH_MARKS}"; }
        stealth::core::loader::module alpha
        stealth::core::engine::run work
    '

    assert_success
    run marks
    assert_line --index 2 'payload'
    assert_line --index 3 'end alpha'
}

@test "stealth::core::engine::run: a payload that fails -> gives its status back" {
    in_run '
        work() { return 3; }
        stealth::core::engine::run work
    '

    assert_equal "${status}" 3
}

@test "stealth::core::engine::run: a payload that fails -> the end hooks still run" {
    # The old engine ran the payload through a function that exits, so the end
    # pass was unreachable and nothing a module took was ever given back.
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    in_run '
        work() { return 3; }
        stealth::core::loader::module alpha
        stealth::core::engine::run work
    '

    assert_equal "${status}" 3
    run marks
    assert_output --partial 'end alpha'
}

@test "stealth::core::engine::run: a start hook that fails -> stops the pass" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha 2
    given_module beta

    in_run 'stealth::core::loader::module alpha beta; stealth::core::engine::run'

    assert_equal "${status}" 2
    run marks
    refute_output --partial 'start beta'
}

@test "stealth::core::engine::run: a start hook that fails -> the end hooks still run" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha 2

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    run marks
    assert_output --partial 'end alpha'
}

@test "stealth::core::engine::run: a payload that is neither a function nor a command -> exits 127" {
    in_run -127 'stealth::core::engine::run no_such_thing_anywhere'

    assert_equal "${status}" 127
    assert_stderr --partial 'no function or command named no_such_thing_anywhere'
}

@test "stealth::core::engine::run: no module -> runs the payload on its own" {
    in_run '
        work() { printf "payload\n" >> "${STEALTH_MARKS}"; }
        stealth::core::engine::run work
    '

    assert_success
    run marks
    assert_output 'payload'
}

@test "stealth::core::engine::run: a module that started -> is drawn as a status line" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_stderr --partial '[ ok ] alpha'
}

@test "stealth::core::engine::run: a hook that fails -> stops where it failed" {
    # Written as `hook || status=$?` the rest of the hook runs anyway: bash
    # turns errexit off for a command in a condition and leaves it off for
    # everything that command calls.
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_failing_module halfway

    in_run -1 'stealth::core::loader::module halfway
        stealth::core::engine::run'

    assert_failure
    refute_stderr --partial 'PAST THE FAILURE'
}

@test "stealth::core::engine::run: a module that failed -> is drawn as a failed line" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha 2

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_stderr --partial '[fail] alpha'
}

# ------------------------------------------------------------------------------
# The flight recorder
# ------------------------------------------------------------------------------

@test "core/engine: a run that fails -> prints what went to standard error" {
    # The old engine deferred the temporary-file cleanup through the trap, and
    # that cleanup removed the recorder before the exit handler read it, so
    # this never printed anything.
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() {
    printf 'configure: error: no acceptable C compiler\n' >&2
    return 2
}
EOF

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_equal "${status}" 2
    assert_stderr --partial 'configure: error: no acceptable C compiler'
}

@test "core/engine: a run that works -> prints nothing it collected" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() { printf 'a warning nobody needs\n' >&2; }
EOF

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_success
    refute_stderr --partial 'a warning nobody needs'
}

@test "core/engine: a run that fails -> prints the failing step and not the ones before" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    mkdir -p "${STEALTH_MODULES}/alpha" "${STEALTH_MODULES}/beta"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() { printf 'noise from alpha\n' >&2; }
EOF
    cat > "${STEALTH_MODULES}/beta/build.sh" <<'EOF'
mod::beta::build::start() { printf 'the real problem\n' >&2; return 1; }
EOF

    in_run 'stealth::core::loader::module alpha beta; stealth::core::engine::run'

    assert_stderr --partial 'the real problem'
    refute_stderr --partial 'noise from alpha'
}

@test "core/engine: standard output of a run -> does not reach the caller" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() { printf 'checking for gcc... yes\n'; }
EOF

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    refute_output --partial 'checking for gcc'
}

@test "core/engine: a log file -> takes the standard output of a run" {
    printf 'stage = build\nlog_file = %s/run.log\n' "${BATS_TEST_TMPDIR}" \
        > "${STEALTH_CONF_FILE}"
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() { printf 'checking for gcc... yes\n'; }
EOF

    in_run 'stealth::core::loader::module alpha; stealth::core::engine::run'

    assert_file_contains "${BATS_TEST_TMPDIR}/run.log" 'checking for gcc'
}

@test "core/engine: a log directory that is not there -> is made" {
    printf 'stage = build\nlog_file = %s/deep/down/run.log\n' "${BATS_TEST_TMPDIR}" \
        > "${STEALTH_CONF_FILE}"

    in_run 'stealth::core::engine::run'

    assert_success
    assert_dir_exists "${BATS_TEST_TMPDIR}/deep/down"
}

@test "core/engine: a log directory that cannot be made -> ends the run" {
    printf 'stage = build\nlog_file = /proc/one/two/run.log\n' > "${STEALTH_CONF_FILE}"

    in_run 'stealth::core::engine::run'

    assert_failure
    assert_stderr --partial 'no log directory could be made at /proc/one/two'
}

@test "core/engine: a log file that cannot be opened -> ends the run" {
    printf 'stage = build\nlog_file = %s\n' "${BATS_TEST_TMPDIR}" > "${STEALTH_CONF_FILE}"

    in_run 'stealth::core::engine::run'

    assert_failure
    assert_stderr --partial 'could not be opened'
}

@test "core/engine: a log file of auto and a run as root -> goes under the system log directory" {
    printf 'stage = build\nlog_file = auto\n' > "${STEALTH_CONF_FILE}"

    in_run '
        stealth::core::state::is_root() { return 0; }
        mkdir() { printf "mkdir %s\n" "${*: -1}" >> "${STEALTH_MARKS}"; }
        exec() { :; }
        stealth::core::engine::_open_log_file || true
    '

    run marks
    assert_output --partial 'mkdir /var/log/stealth'
}

@test "core/engine: a log directory whose mode cannot be set -> says so and carries on" {
    printf 'stage = build\nlog_file = %s/deep/run.log\n' "${BATS_TEST_TMPDIR}" \
        > "${STEALTH_CONF_FILE}"

    in_run '
        chmod() { return 1; }
        stealth::core::engine::run
    '

    assert_success
    assert_stderr --partial 'the mode of'
}

@test "core/engine: no file to collect standard error in -> ends the run" {
    in_run '
        mktemp() { return 1; }
        stealth::core::engine::run
    '

    assert_failure
    assert_stderr --partial 'no file could be made to collect standard error'
}

@test "core/engine: a log file of auto -> goes under the state directory of the home" {
    printf 'stage = build\nlog_file = auto\n' > "${STEALTH_CONF_FILE}"

    run --separate-stderr bash -c "
        set -Eeuo pipefail
        export STEALTH_LIB='${STEALTH_LIB_DIR}' HOME='${BATS_TEST_TMPDIR}/home'
        export STEALTH_CONF_FILE='${STEALTH_CONF_FILE}' STEALTH_CONF_DIR='${STEALTH_CONF_DIR}'
        export STEALTH_LOG_COLOR=never
        source \"\${STEALTH_LIB}/util/import.sh\"
        stealth::util::import core/engine
        stealth::core::engine::run
    "

    assert_success
    assert_file_exists "${BATS_TEST_TMPDIR}/home/.local/state/stealth/stealth.log"
}

# ------------------------------------------------------------------------------
# stealth::core::engine::bootstrap
# ------------------------------------------------------------------------------

@test "stealth::core::engine::bootstrap: called twice -> gets ready once" {
    in_run '
        stealth::core::engine::bootstrap
        stealth::core::engine::bootstrap
        printf "%s\n" "${_STEALTH_CORE_ENGINE_READY}" >> "${STEALTH_MARKS}"
    '

    run marks
    assert_output '1'
}

@test "stealth::core::engine::bootstrap: the traps -> are taken over" {
    in_run '
        stealth::core::engine::bootstrap
        trap -p EXIT >> "${STEALTH_MARKS}"
    '

    run marks
    assert_output --partial 'stealth::core::trap::_on_exit'
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_defer_cleanups
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_defer_cleanups: a library with a cleanup -> registers it" {
    # A layer may not import the one above it, so sys cannot ask core/trap to
    # run its cleanup. core finds it by name instead.
    # shellcheck disable=SC2329  # found by name, not called here
    stealth::util::text::cleanup() { :; }

    stealth::core::engine::_defer_cleanups

    assert_array_contains _STEALTH_CORE_TRAP_STACK 'stealth::util::text::cleanup'
}

@test "stealth::core::engine::_defer_cleanups: no library has one -> registers nothing" {
    stealth::core::engine::_defer_cleanups

    assert_array_empty _STEALTH_CORE_TRAP_STACK
}

@test "stealth::core::engine::_defer_cleanups: a run that ends -> the cleanup has run" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"

    in_run '
        stealth::util::import sys/cmd
        stealth::sys::cmd::cleanup() { printf "cleanup ran\n" >> "${STEALTH_MARKS}"; }
        stealth::core::engine::run
    '

    assert_success
    run marks
    assert_output 'cleanup ran'
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_to_key
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_to_key: a variable name -> gives the setting" {
    assert_nameref 'log_level' stealth::core::engine::_to_key 'STEALTH_LOG_LEVEL'
}

@test "stealth::core::engine::_to_key: a setting name -> gives itself" {
    assert_nameref 'log_level' stealth::core::engine::_to_key 'log_level'
}

@test "stealth::core::engine::_to_key: a name without the prefix -> keeps all of it" {
    assert_nameref 'jobs' stealth::core::engine::_to_key 'JOBS'
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_can_run
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_can_run: a function -> returns 0" {
    # shellcheck disable=SC2329  # looked for by name, not called
    a_function_of_the_run() { :; }

    run stealth::core::engine::_can_run a_function_of_the_run
    assert_success
}

@test "stealth::core::engine::_can_run: a command -> returns 0" {
    run stealth::core::engine::_can_run printf
    assert_success
}

@test "stealth::core::engine::_can_run: neither -> returns 1" {
    run stealth::core::engine::_can_run no_such_thing_anywhere
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_call_hook
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_call_hook: a hook the module defines -> runs it" {
    # shellcheck disable=SC2329  # called through the namespace
    mod::alpha::build::start() { printf 'ran\n'; }

    run stealth::core::engine::_call_hook alpha 'build::start'

    assert_success
    assert_output 'ran'
}

@test "stealth::core::engine::_call_hook: a hook the module does not define -> returns 0" {
    run stealth::core::engine::_call_hook alpha 'build::start'
    assert_success
}

@test "stealth::core::engine::_call_hook: a hook that fails -> gives its status back" {
    # shellcheck disable=SC2329  # called through the namespace
    mod::alpha::build::start() { return 5; }

    run stealth::core::engine::_call_hook alpha 'build::start'
    assert_failure 5
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_end_all
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_end_all: called twice -> runs the hooks once" {
    stealth::core::state::set 'stage' 'build'
    stealth::core::state::register_module alpha
    # shellcheck disable=SC2329  # called through the namespace
    mod::alpha::build::end() { printf 'end\n' >> "${STEALTH_MARKS}"; }

    stealth::core::engine::_end_all
    stealth::core::engine::_end_all

    run marks
    assert_output 'end'
}

@test "stealth::core::engine::_end_all: an end hook that fails -> the rest still run" {
    stealth::core::state::set 'stage' 'build'
    stealth::core::state::register_module alpha
    stealth::core::state::register_module beta
    # shellcheck disable=SC2329  # called through the namespace
    mod::beta::build::end() { return 1; }
    # shellcheck disable=SC2329  # called through the namespace
    mod::alpha::build::end() { printf 'alpha ended\n' >> "${STEALTH_MARKS}"; }

    stealth::core::engine::_end_all

    run marks
    assert_output 'alpha ended'
}

# ------------------------------------------------------------------------------
# stealth::core::engine::_rotate_recorder
# ------------------------------------------------------------------------------

@test "stealth::core::engine::_rotate_recorder: a recorder -> starts again from nothing" {
    # Reopening rather than emptying is the point. Standard error keeps its
    # offset through a file that was emptied under it, and what it writes next
    # begins after a hole as long as what was thrown away.
    in_run '
        _STEALTH_CORE_ENGINE_RECORDER="${STEALTH_MARKS}.recorder"
        exec 2>"${_STEALTH_CORE_ENGINE_RECORDER}"
        printf "thrown away\\n" >&2
        stealth::core::engine::_rotate_recorder
        printf "kept\\n" >&2
        cat -- "${_STEALTH_CORE_ENGINE_RECORDER}" > "${STEALTH_MARKS}"
    '

    run marks
    assert_output 'kept'
}

@test "stealth::core::engine::_rotate_recorder: no recorder -> returns 0" {
    _STEALTH_CORE_ENGINE_RECORDER=''

    run stealth::core::engine::_rotate_recorder
    assert_success
}

# ------------------------------------------------------------------------------
# core/engine, the module itself
# ------------------------------------------------------------------------------

@test "core/engine: a run that is interrupted -> still gives back what it took" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    in_run '
        stealth::core::loader::module alpha
        work() { kill -TERM $$; sleep 5; }
        stealth::core::engine::run work
    '

    assert_equal "${status}" 143
    run marks
    assert_output --partial 'end alpha'
}

@test "core/engine: sourced twice -> returns before it declares anything" {
    stealth::core::engine::configure

    load_lib core/engine

    assert_var_equal _STEALTH_CORE_ENGINE_CONFIGURED 1
}
