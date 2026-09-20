#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/lock - Test Suite
# ==============================================================================
# The lock directory is inside the test's own directory, so nothing here can
# take a lock another run cares about.
#
# A test cannot hold a lock against itself: flock on a second descriptor in
# the same process is granted, because the lock belongs to the process. The
# tests that need a lock held by somebody else start a background shell that
# holds it and waits.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/lock
    load_mock util
    mock::stealth::util::log

    STEALTH_LOCK_DIR="${BATS_TEST_TMPDIR}/locks"
    HOLDER=''
}

teardown() {
    if [[ -n "${HOLDER}" ]]; then
        kill "${HOLDER}" 2>/dev/null || true
        wait "${HOLDER}" 2>/dev/null || true
    fi
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Starts another process holding a named lock and waits until it has it.
# Whoever calls this gets the lock file that process is holding.
hold_elsewhere() {
    local -r file="${STEALTH_LOCK_DIR}/${1}.lock"
    local -r ready="${BATS_TEST_TMPDIR}/ready"

    mkdir -p "${STEALTH_LOCK_DIR}"
    : > "${file}"

    bash -c '
        exec {fd}>>"${1}"
        flock -x "${fd}"
        : > "${2}"
        sleep 30
    ' _ "${file}" "${ready}" &
    HOLDER=$!

    local -i waited=0
    while [[ ! -e "${ready}" ]] && (( waited < 200 )); do
        sleep 0.05
        waited=$(( waited + 1 ))
    done
    [[ -e "${ready}" ]]
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::is_held
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::is_held: a lock this run took -> returns 0" {
    stealth::sys::runtime::lock::acquire 'sources'

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_success
}

@test "stealth::sys::runtime::lock::is_held: a lock nobody took -> returns 1" {
    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::is_held: nothing -> returns 1" {
    run stealth::sys::runtime::lock::is_held
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::acquire
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::acquire: a free lock -> is held" {
    stealth::sys::runtime::lock::acquire 'sources'

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_success
}

@test "stealth::sys::runtime::lock::acquire: a free lock -> the file is there" {
    stealth::sys::runtime::lock::acquire 'sources'

    assert_file_exists "${STEALTH_LOCK_DIR}/sources.lock"
}

@test "stealth::sys::runtime::lock::acquire: the lock file -> is nobody else's to take" {
    stealth::sys::runtime::lock::acquire 'sources'

    assert_file_permission 0600 "${STEALTH_LOCK_DIR}/sources.lock"
}

@test "stealth::sys::runtime::lock::acquire: the directory -> is nobody else's to read" {
    stealth::sys::runtime::lock::acquire 'sources'

    assert_file_permission 0700 "${STEALTH_LOCK_DIR}"
}

@test "stealth::sys::runtime::lock::acquire: a lock this run holds -> is no trouble" {
    stealth::sys::runtime::lock::acquire 'sources'

    run stealth::sys::runtime::lock::acquire 'sources'
    assert_success
}

@test "stealth::sys::runtime::lock::acquire: somebody else holds it -> --wait runs out" {
    hold_elsewhere 'sources'

    run stealth::sys::runtime::lock::acquire 'sources' --wait 1
    assert_failure 1
}

@test "stealth::sys::runtime::lock::acquire: the wait ran out -> the lock is not held" {
    hold_elsewhere 'sources'
    stealth::sys::runtime::lock::acquire 'sources' --wait 1 || true

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::acquire: --wait that is not a number -> exits 1" {
    run stealth::sys::runtime::lock::acquire 'sources' --wait soon
    assert_refused '--wait takes whole seconds, not soon'
}

@test "stealth::sys::runtime::lock::acquire: an option it does not take -> exits 1" {
    run stealth::sys::runtime::lock::acquire 'sources' --force
    assert_refused 'acquire does not take --force'
}

@test "stealth::sys::runtime::lock::acquire: a name with a slash in it -> exits 1" {
    run stealth::sys::runtime::lock::acquire '../escape'
    assert_refused '../escape is not a name a lock can have'
}

@test "stealth::sys::runtime::lock::acquire: no name -> exits 1" {
    run stealth::sys::runtime::lock::acquire ''
    assert_refused 'a lock name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::try
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::try: a free lock -> returns 0" {
    run stealth::sys::runtime::lock::try 'sources'
    assert_success
}

@test "stealth::sys::runtime::lock::try: somebody else holds it -> returns 1" {
    hold_elsewhere 'sources'

    run stealth::sys::runtime::lock::try 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::try: somebody else holds it -> nothing waits" {
    hold_elsewhere 'sources'
    local -r started="${SECONDS}"

    stealth::sys::runtime::lock::try 'sources' || true

    assert_lt "$(( SECONDS - started ))" 5
}

@test "stealth::sys::runtime::lock::try: no name -> exits 1" {
    run stealth::sys::runtime::lock::try ''
    assert_refused 'a lock name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::release
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::release: a lock this run holds -> is given back" {
    stealth::sys::runtime::lock::acquire 'sources'

    stealth::sys::runtime::lock::release 'sources'

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::release: afterwards -> somebody else can take it" {
    stealth::sys::runtime::lock::acquire 'sources'
    stealth::sys::runtime::lock::release 'sources'

    run flock -x -n "${STEALTH_LOCK_DIR}/sources.lock" true
    assert_success
}

@test "stealth::sys::runtime::lock::release: a lock this run never took -> returns 1" {
    run stealth::sys::runtime::lock::release 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::release: a lock this run never took -> says so" {
    run stealth::sys::runtime::lock::release 'sources'

    assert_called_with stealth::util::log::warn '*not holding*'
}

@test "stealth::sys::runtime::lock::release: no name -> exits 1" {
    run stealth::sys::runtime::lock::release ''
    assert_refused 'a lock name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::run
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::run: a command -> runs it" {
    stealth::sys::runtime::lock::run 'sources' -- touch "${BATS_TEST_TMPDIR}/ran"

    assert_file_exists "${BATS_TEST_TMPDIR}/ran"
}

@test "stealth::sys::runtime::lock::run: a command -> the lock is held while it runs" {
    stealth::sys::runtime::lock::run 'sources' -- \
        bash -c 'flock -x -n "${1}" true && exit 3 || exit 0' _ \
        "${STEALTH_LOCK_DIR}/sources.lock"
}

@test "stealth::sys::runtime::lock::run: afterwards -> the lock is given back" {
    stealth::sys::runtime::lock::run 'sources' -- true

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::run: a command that failed -> the lock is still given back" {
    stealth::sys::runtime::lock::run 'sources' -- false || true

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::run: a command that failed -> its status comes back" {
    run stealth::sys::runtime::lock::run 'sources' -- bash -c 'exit 7'
    assert_failure 7
}

@test "stealth::sys::runtime::lock::run: a lock the caller already held -> stays held" {
    stealth::sys::runtime::lock::acquire 'sources'

    stealth::sys::runtime::lock::run 'sources' -- true

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_success
}

@test "stealth::sys::runtime::lock::run: --wait -> is passed on" {
    hold_elsewhere 'sources'

    run stealth::sys::runtime::lock::run 'sources' --wait 1 -- true
    assert_failure 1
}

@test "stealth::sys::runtime::lock::run: the lock was never taken -> the command does not run" {
    hold_elsewhere 'sources'

    stealth::sys::runtime::lock::run 'sources' --wait 1 -- \
        touch "${BATS_TEST_TMPDIR}/ran" || true

    assert_file_not_exists "${BATS_TEST_TMPDIR}/ran"
}

@test "stealth::sys::runtime::lock::run: no command -> exits 1" {
    run stealth::sys::runtime::lock::run 'sources' --
    assert_refused 'a command to run is required'
}

@test "stealth::sys::runtime::lock::run: no name -> exits 1" {
    run stealth::sys::runtime::lock::run ''
    assert_refused 'a lock name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::cleanup
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::cleanup: every lock held -> is given back" {
    stealth::sys::runtime::lock::acquire 'sources'
    stealth::sys::runtime::lock::acquire 'images'

    stealth::sys::runtime::lock::cleanup

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_failure 1
    run stealth::sys::runtime::lock::is_held 'images'
    assert_failure 1
}

@test "stealth::sys::runtime::lock::cleanup: afterwards -> somebody else can take them" {
    stealth::sys::runtime::lock::acquire 'sources'
    stealth::sys::runtime::lock::cleanup

    run flock -x -n "${STEALTH_LOCK_DIR}/sources.lock" true
    assert_success
}

@test "stealth::sys::runtime::lock::cleanup: nothing held -> returns 0" {
    run stealth::sys::runtime::lock::cleanup
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::lock::_open
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::lock::_open: the directory is not there -> it is made" {
    assert_dir_not_exists "${STEALTH_LOCK_DIR}"

    stealth::sys::runtime::lock::acquire 'sources'

    assert_dir_exists "${STEALTH_LOCK_DIR}"
}

@test "stealth::sys::runtime::lock::_open: a name with nothing wrong with it -> is taken" {
    run stealth::sys::runtime::lock::acquire 'lfs.binutils_pass-1'
    assert_success
}

@test "stealth::sys::runtime::lock::_open: a name starting with a dot -> exits 1" {
    run stealth::sys::runtime::lock::acquire '.hidden'
    assert_refused '.hidden is not a name a lock can have'
}

@test "stealth::sys::runtime::lock::_open: nothing can be opened on the file -> ends the run" {
    # A directory where the lock file goes. touch is happy with it and the
    # open that follows is not.
    mkdir -p "${STEALTH_LOCK_DIR}/sources.lock"

    run stealth::sys::runtime::lock::acquire 'sources'

    assert_failure 1
    assert_called_with stealth::util::log::error '*no descriptor could be opened*'
}

# ------------------------------------------------------------------------------
# sys/runtime/lock, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/lock: the cleanup the engine looks for -> is here by that name" {
    run declare -F stealth::sys::runtime::lock::cleanup
    assert_success
}

@test "sys/runtime/lock: sourced twice -> returns before it declares anything" {
    stealth::sys::runtime::lock::acquire 'sources'

    load_lib sys/runtime/lock

    run stealth::sys::runtime::lock::is_held 'sources'
    assert_success
}
