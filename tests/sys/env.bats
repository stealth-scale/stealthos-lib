#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/env - Test Suite
# ==============================================================================
# Every test works on a variable of its own rather than on PATH, so a suite
# that fails does not take the shell it ran in with it.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/env
    load_mock util
    mock::stealth::util::log

    TOOLPATH=''
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::env::contains
# ------------------------------------------------------------------------------

@test "stealth::sys::env::contains: an entry that is there -> returns 0" {
    TOOLPATH='/usr/bin:/usr/local/bin'

    run stealth::sys::env::contains TOOLPATH /usr/local/bin
    assert_success
}

@test "stealth::sys::env::contains: an entry that is not -> returns 1" {
    TOOLPATH='/usr/bin'

    run stealth::sys::env::contains TOOLPATH /opt/bin
    assert_failure 1
}

@test "stealth::sys::env::contains: an entry inside another -> returns 1" {
    TOOLPATH='/usr/local/bin/extra'

    run stealth::sys::env::contains TOOLPATH /usr/local/bin
    assert_failure 1
}

@test "stealth::sys::env::contains: a variable that holds nothing -> returns 1" {
    run stealth::sys::env::contains TOOLPATH /usr/bin
    assert_failure 1
}

@test "stealth::sys::env::contains: no variable named -> exits 1" {
    run stealth::sys::env::contains ''
    assert_refused 'the name of a variable is required'
}

@test "stealth::sys::env::contains: no entry -> exits 1" {
    run stealth::sys::env::contains TOOLPATH ''
    assert_refused 'an entry is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::prepend
# ------------------------------------------------------------------------------

@test "stealth::sys::env::prepend: an entry -> goes to the front" {
    TOOLPATH='/usr/bin'

    stealth::sys::env::prepend TOOLPATH /opt/toolchain/bin

    assert_var_equal TOOLPATH '/opt/toolchain/bin:/usr/bin'
}

@test "stealth::sys::env::prepend: a variable that holds nothing -> holds the entry" {
    stealth::sys::env::prepend TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/opt/bin'
}

@test "stealth::sys::env::prepend: several entries -> keep the order given" {
    TOOLPATH='/usr/bin'

    stealth::sys::env::prepend TOOLPATH /opt/one /opt/two

    assert_var_equal TOOLPATH '/opt/one:/opt/two:/usr/bin'
}

@test "stealth::sys::env::prepend: an entry already there -> moves to the front" {
    TOOLPATH='/usr/bin:/opt/toolchain/bin'

    stealth::sys::env::prepend TOOLPATH /opt/toolchain/bin

    assert_var_equal TOOLPATH '/opt/toolchain/bin:/usr/bin'
}

@test "stealth::sys::env::prepend: called twice -> the entry is there once" {
    TOOLPATH='/usr/bin'

    stealth::sys::env::prepend TOOLPATH /opt/bin
    stealth::sys::env::prepend TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/opt/bin:/usr/bin'
}

@test "stealth::sys::env::prepend: a directory that is not there -> is still added" {
    # A build makes its directories as it goes, and an entry that is not there
    # yet costs nothing.
    stealth::sys::env::prepend TOOLPATH "${BATS_TEST_TMPDIR}/not-yet"

    assert_var_equal TOOLPATH "${BATS_TEST_TMPDIR}/not-yet"
}

@test "stealth::sys::env::prepend: the variable -> is exported" {
    stealth::sys::env::prepend TOOLPATH /opt/bin

    assert_declared -x TOOLPATH
}

@test "stealth::sys::env::prepend: no variable named -> exits 1" {
    run stealth::sys::env::prepend ''
    assert_refused 'the name of a variable is required'
}

@test "stealth::sys::env::prepend: no entry -> exits 1" {
    run stealth::sys::env::prepend TOOLPATH ''
    assert_refused 'an entry is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::append
# ------------------------------------------------------------------------------

@test "stealth::sys::env::append: an entry -> goes to the end" {
    TOOLPATH='/usr/bin'

    stealth::sys::env::append TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/usr/bin:/opt/bin'
}

@test "stealth::sys::env::append: an entry already there -> stays where it is" {
    TOOLPATH='/opt/bin:/usr/bin'

    stealth::sys::env::append TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/opt/bin:/usr/bin'
}

@test "stealth::sys::env::append: a variable that holds nothing -> holds the entry" {
    stealth::sys::env::append TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/opt/bin'
}

@test "stealth::sys::env::append: no variable named -> exits 1" {
    run stealth::sys::env::append ''
    assert_refused 'the name of a variable is required'
}

@test "stealth::sys::env::append: no entry -> exits 1" {
    run stealth::sys::env::append TOOLPATH ''
    assert_refused 'an entry is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::remove
# ------------------------------------------------------------------------------

@test "stealth::sys::env::remove: an entry -> is taken out" {
    TOOLPATH='/usr/bin:/opt/bin:/usr/local/bin'

    stealth::sys::env::remove TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/usr/bin:/usr/local/bin'
}

@test "stealth::sys::env::remove: an entry that is not there -> changes nothing" {
    TOOLPATH='/usr/bin'

    stealth::sys::env::remove TOOLPATH /opt/bin

    assert_var_equal TOOLPATH '/usr/bin'
}

@test "stealth::sys::env::remove: the only entry -> leaves the variable empty" {
    TOOLPATH='/opt/bin'

    stealth::sys::env::remove TOOLPATH /opt/bin

    assert_var_equal TOOLPATH ''
}

@test "stealth::sys::env::remove: several entries -> takes out each of them" {
    TOOLPATH='/one:/two:/three'

    stealth::sys::env::remove TOOLPATH /one /three

    assert_var_equal TOOLPATH '/two'
}

@test "stealth::sys::env::remove: no variable named -> exits 1" {
    run stealth::sys::env::remove ''
    assert_refused 'the name of a variable is required'
}

@test "stealth::sys::env::remove: no entry -> exits 1" {
    run stealth::sys::env::remove TOOLPATH ''
    assert_refused 'an entry is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::entries
# ------------------------------------------------------------------------------

@test "stealth::sys::env::entries: a list -> comes back in order" {
    TOOLPATH='/one:/two:/three'
    local -a dirs=()

    stealth::sys::env::entries dirs TOOLPATH

    assert_array_equal dirs /one /two /three
}

@test "stealth::sys::env::entries: a variable that holds nothing -> gives an empty array" {
    local -a dirs=(stale)

    stealth::sys::env::entries dirs TOOLPATH

    assert_array_empty dirs
}

@test "stealth::sys::env::entries: no output variable -> exits 1" {
    run stealth::sys::env::entries ''
    assert_refused 'an output variable is required'
}

@test "stealth::sys::env::entries: no variable named -> exits 1" {
    run stealth::sys::env::entries dirs ''
    assert_refused 'the name of a variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::load
# ------------------------------------------------------------------------------

@test "stealth::sys::env::load: a setting -> is exported" {
    printf 'CC=gcc\n' > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CC gcc
    assert_declared -x CC
}

@test "stealth::sys::env::load: an export in front -> is read the same" {
    printf 'export CC=gcc\n' > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CC gcc
}

@test "stealth::sys::env::load: quotes around a value -> are taken off" {
    printf 'CFLAGS="-O2 -pipe"\n' > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CFLAGS '-O2 -pipe'
}

@test "stealth::sys::env::load: single quotes -> are taken off too" {
    printf "CFLAGS='-O2'\n" > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CFLAGS '-O2'
}

@test "stealth::sys::env::load: comments and blank lines -> are skipped" {
    printf '# the toolchain\n\nCC=gcc\n' > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CC gcc
}

@test "stealth::sys::env::load: a line that is not a setting -> is reported and skipped" {
    # The old module exported whatever a line held without looking at it.
    printf 'this is not a setting\nCC=gcc\n' > "${BATS_TEST_TMPDIR}/toolchain.env"

    stealth::sys::env::load "${BATS_TEST_TMPDIR}/toolchain.env"

    assert_var_equal CC gcc
    assert_called_with_args stealth::util::log::warn \
        '%s line %d is not a setting: %s' \
        "${BATS_TEST_TMPDIR}/toolchain.env" 1 'this is not a setting'
}

@test "stealth::sys::env::load: no such file -> returns 1" {
    run stealth::sys::env::load "${BATS_TEST_TMPDIR}/nowhere.env"

    assert_failure 1
    assert_called_with_args stealth::util::log::warn \
        'no environment file to read at %s' "${BATS_TEST_TMPDIR}/nowhere.env"
}

@test "stealth::sys::env::load: no file named -> exits 1" {
    run stealth::sys::env::load ''
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::env::_to_array
# ------------------------------------------------------------------------------

@test "stealth::sys::env::_to_array: a variable that holds nothing -> gives no entry" {
    local -a dirs=()

    stealth::sys::env::_to_array dirs TOOLPATH

    assert_array_empty dirs
}

@test "stealth::sys::env::_to_array: one entry -> gives one" {
    TOOLPATH='/usr/bin'
    local -a dirs=()

    stealth::sys::env::_to_array dirs TOOLPATH

    assert_array_equal dirs /usr/bin
}

# ------------------------------------------------------------------------------
# stealth::sys::env::_from_array
# ------------------------------------------------------------------------------

@test "stealth::sys::env::_from_array: an array -> is written back with separators" {
    local -a dirs=(/one /two)

    stealth::sys::env::_from_array TOOLPATH dirs

    assert_var_equal TOOLPATH '/one:/two'
}

@test "stealth::sys::env::_from_array: an empty array -> writes an empty variable" {
    local -a dirs=()

    stealth::sys::env::_from_array TOOLPATH dirs

    assert_var_equal TOOLPATH ''
}

# ------------------------------------------------------------------------------
# sys/env, the module itself
# ------------------------------------------------------------------------------

@test "sys/env: a list built up and taken apart -> ends where it started" {
    TOOLPATH='/usr/bin:/usr/local/bin'

    stealth::sys::env::prepend TOOLPATH /opt/toolchain/bin
    stealth::sys::env::append TOOLPATH /opt/extra/bin
    stealth::sys::env::remove TOOLPATH /opt/toolchain/bin /opt/extra/bin

    assert_var_equal TOOLPATH '/usr/bin:/usr/local/bin'
}

@test "sys/env: sourced twice -> returns before it declares anything" {
    stealth::sys::env::prepend TOOLPATH /opt/bin

    load_lib sys/env

    assert_var_equal TOOLPATH '/opt/bin'
}
