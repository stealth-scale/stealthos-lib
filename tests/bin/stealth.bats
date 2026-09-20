#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file. The single-quoted text
# written into a module is a script for the run, so what looks like an
# expansion that will not happen is one that happens over there.

# ==============================================================================
# bin/stealth - Test Suite
# ==============================================================================
# The command is a program, so every test runs it. A module records what it
# did in a file, because the run owns standard output by the time a hook runs.
#
# The tests are grouped by subject: finding the library, the options, and then
# the run the options describe.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    STEALTH_BIN="${STEALTH_TEST_ROOT}/src/bin/stealth"
    STEALTH_MODULES="${BATS_TEST_TMPDIR}/modules"
    STEALTH_MARKS="${BATS_TEST_TMPDIR}/marks"
    STEALTH_CONF_FILE="${BATS_TEST_TMPDIR}/stealth.conf"
    STEALTH_CONF_DIR="${BATS_TEST_TMPDIR}/conf.d"

    mkdir -p "${STEALTH_MODULES}" "${STEALTH_CONF_DIR}"
    printf 'stage = build\nlog_color = never\n' > "${STEALTH_CONF_FILE}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Runs the command with the configuration of this test and nothing else. An
# expected status may come first, as `run` takes one.
stealth() {
    local -a _prefix=(run --separate-stderr)
    if [[ "${1}" == -[0-9]* ]]; then
        _prefix+=("${1}")
        shift
    fi

    "${_prefix[@]}" env \
        STEALTH_LIB="${STEALTH_LIB_DIR}" \
        STEALTH_MARKS="${STEALTH_MARKS}" \
        COLUMNS=40 \
        "${STEALTH_BIN}" \
        --config "${STEALTH_CONF_FILE}" \
        --conf-dir "${STEALTH_CONF_DIR}" \
        "$@"
}

# Writes a module whose hooks record that they ran.
given_module() {
    local -r dir="${STEALTH_MODULES}/${1}"

    mkdir -p "${dir}"
    cat > "${dir}/build.sh" <<EOF
mod::${1}::build::start() { printf 'start ${1}\n' >> "\${STEALTH_MARKS}"; }
mod::${1}::build::end() { printf 'end ${1}\n' >> "\${STEALTH_MARKS}"; }
EOF
}

# What the hooks recorded.
marks() {
    if [[ -f "${STEALTH_MARKS}" ]]; then
        printf '%s' "$(< "${STEALTH_MARKS}")"
    fi
}

# ------------------------------------------------------------------------------
# Finding the library
# ------------------------------------------------------------------------------

@test "bin/stealth: a checkout -> runs the library next to it" {
    # The old command preferred /usr/lib/stealth whenever that existed, so a
    # checkout on a machine with the package installed ran the package. The
    # harness exports STEALTH_LIB, so it goes for this one.
    run --separate-stderr env -u STEALTH_LIB "${STEALTH_BIN}" --version

    assert_success
    assert_output "stealth $(< "${STEALTH_TEST_ROOT}/src/lib/VERSION")"
}

@test "bin/stealth: no library anywhere -> says so and stops" {
    cp "${STEALTH_BIN}" "${BATS_TEST_TMPDIR}/stealth"

    run --separate-stderr env -u STEALTH_LIB "${BATS_TEST_TMPDIR}/stealth" --version

    assert_failure 1
    assert_stderr --partial 'no library next to'
}

@test "bin/stealth: STEALTH_LIB that is set -> is the library it uses" {
    stealth --version
    assert_success
}

# ------------------------------------------------------------------------------
# The options
# ------------------------------------------------------------------------------

@test "bin/stealth: --version -> prints the version and stops" {
    stealth --version

    assert_success
    assert_output --partial 'stealth '
}

@test "bin/stealth: --help -> prints how to use it and stops" {
    stealth --help

    assert_success
    assert_output --partial 'Usage: stealth'
}

@test "bin/stealth: an option it does not have -> stops with how to use it" {
    stealth --no-such-option

    assert_failure 1
    assert_stderr --partial 'no option --no-such-option'
    assert_stderr --partial 'Usage: stealth'
}

@test "bin/stealth: an option with no value -> says which one" {
    stealth --stage

    assert_failure 1
    assert_stderr --partial '--stage takes a value'
}

@test "bin/stealth: an option whose value is another option -> says which one" {
    stealth --stage --verbose

    assert_failure 1
    assert_stderr --partial '--stage takes a value'
}

@test "bin/stealth: --stage -> beats the stage in the file" {
    printf 'stage = setup\n' > "${STEALTH_CONF_FILE}"
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module alpha --stage build

    run marks
    assert_output --partial 'start alpha'
}

@test "bin/stealth: --log-level -> is the level the log keeps to" {
    stealth --log-level 4

    assert_stderr --partial 'DEBG'
}

@test "bin/stealth: -vv -> asks the log for everything" {
    stealth -vv

    assert_stderr --partial 'TRAC'
}

@test "bin/stealth: --no-color -> nothing is coloured" {
    printf 'stage = build\n' > "${STEALTH_CONF_FILE}"

    stealth --no-color --verbose

    refute_stderr --partial $'\033['
}

@test "bin/stealth: --trace -> is taken, and the run still finishes" {
    # What `set -x` prints is the shell's business, not this command's, and it
    # cannot be read here anyway: kcov instruments bash by turning xtrace on
    # and pointing BASH_XTRACEFD at itself, so under coverage the trace never
    # reaches standard error. That the option is taken is what this checks.
    stealth --trace

    assert_success
}

@test "bin/stealth: --verbose -> asks the log for more" {
    stealth --verbose

    assert_stderr --partial 'DEBG'
}

@test "bin/stealth: --quiet -> asks the log for less" {
    stealth --quiet

    refute_stderr --partial 'DEBG'
}

@test "bin/stealth: --log-format -> the log is written that way" {
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module alpha \
        --verbose --log-format json

    assert_stderr --partial '{"time":'
}

@test "bin/stealth: --log-file -> the log is written there" {
    stealth --log-file "${BATS_TEST_TMPDIR}/run.log" --verbose

    assert_file_exists "${BATS_TEST_TMPDIR}/run.log"
}

@test "bin/stealth: --dry-run -> the setting is on for the run" {
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() {
    local on
    stealth::core::state::get on dry_run 'off'
    printf '%s\n' "${on}" >> "${STEALTH_MARKS}"
}
EOF

    stealth --module-dir "${STEALTH_MODULES}" --module alpha --dry-run

    run marks
    assert_output '1'
}

@test "bin/stealth: no --dry-run -> the setting is not on" {
    mkdir -p "${STEALTH_MODULES}/alpha"
    cat > "${STEALTH_MODULES}/alpha/build.sh" <<'EOF'
mod::alpha::build::start() {
    local on
    stealth::core::state::get on dry_run 'off'
    printf '%s\n' "${on}" >> "${STEALTH_MARKS}"
}
EOF

    stealth --module-dir "${STEALTH_MODULES}" --module alpha

    run marks
    assert_output 'off'
}

# ------------------------------------------------------------------------------
# The run
# ------------------------------------------------------------------------------

@test "bin/stealth: --module -> loads it and runs its hooks" {
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module alpha

    assert_success
    run marks
    assert_line --index 0 'start alpha'
    assert_line --index 1 'end alpha'
}

@test "bin/stealth: --module twice -> loads both in the order given" {
    given_module alpha
    given_module beta

    stealth --module-dir "${STEALTH_MODULES}" --module beta --module alpha

    run marks
    assert_line --index 0 'start beta'
    assert_line --index 1 'start alpha'
}

@test "bin/stealth: --module-list -> loads what the list names" {
    given_module alpha
    given_module beta
    printf 'MODULES=(alpha beta)\n' > "${BATS_TEST_TMPDIR}/list"

    stealth --module-dir "${STEALTH_MODULES}" --module-list "${BATS_TEST_TMPDIR}/list"

    run marks
    assert_line --index 0 'start alpha'
    assert_line --index 1 'start beta'
}

@test "bin/stealth: --module-dir twice -> looks in both" {
    local -r other="${BATS_TEST_TMPDIR}/other"
    mkdir -p "${other}/gamma"
    printf 'mod::gamma::build::start() { printf "start gamma\\n" >> "${STEALTH_MARKS}"; }\n' \
        > "${other}/gamma/build.sh"
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module-dir "${other}" \
        --module alpha --module gamma

    run marks
    assert_output --partial 'start gamma'
}

@test "bin/stealth: a module no search path holds -> stops" {
    stealth --module-dir "${STEALTH_MODULES}" --module missing

    assert_failure 1
    assert_stderr --partial 'no module missing on any search path'
}

@test "bin/stealth: a payload -> runs between the passes" {
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module alpha -- printf 'payload\n'

    assert_success
    run marks
    assert_line --index 0 'start alpha'
    assert_line --index 1 'end alpha'
}

@test "bin/stealth: a payload without a double hyphen -> is still the payload" {
    given_module alpha

    stealth --module-dir "${STEALTH_MODULES}" --module alpha printf 'payload\n'

    assert_success
    run marks
    assert_line --index 0 'start alpha'
}

@test "bin/stealth: a payload that fails -> the run ends with its status" {
    stealth -- false

    assert_failure 1
}

@test "bin/stealth: a payload that is neither a function nor a command -> ends with 127" {
    stealth -127 -- no_such_thing_anywhere

    assert_stderr --partial 'no function or command named no_such_thing_anywhere'
}

@test "bin/stealth: no module and no payload -> does nothing and succeeds" {
    stealth

    assert_success
}

@test "bin/stealth: a fragment of the configuration -> is read" {
    printf 'log_level = 4\n' > "${STEALTH_CONF_DIR}/level.conf"

    stealth

    assert_stderr --partial 'DEBG'
}
