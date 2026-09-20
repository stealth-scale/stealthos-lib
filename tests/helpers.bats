#!/usr/bin/env bats

# shellcheck disable=SC2030,SC2031
# Every @test is its own process, not a subshell of the file, so a variable a
# test sets is not lost.

# ==============================================================================
# The test helper - Test Suite
# ==============================================================================
# The harness every suite builds on: the helper loads, the three bats libraries
# answer, and a module is sourced by its path. Run with `make test`.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup
}

teardown() {
    common_teardown
}

@test "load_lib: module path -> sources src/lib/PATH.sh and its functions are callable" {
    # shellcheck disable=SC2034  # read by load_lib
    STEALTH_LIB_DIR="${BATS_TEST_DIRNAME}/fixtures/lib"
    load_lib probe
    run stealth::probe::greet world
    assert_success
    assert_output 'hello, world'
}

@test "load_lib: missing module -> fails and names the path" {
    run load_lib nowhere/missing
    assert_failure
    assert_output --partial 'no module nowhere/missing'
}

@test "load_mock: missing mock -> fails and names the mock" {
    run load_mock missing
    assert_failure
    assert_output --partial 'no mock missing'
}

@test "common_setup: a STEALTH_ variable in the environment -> unsets it" {
    export STEALTH_LOG_LEVEL=4
    export STEALTH_DRY_RUN=1

    common_setup

    refute_var_set STEALTH_LOG_LEVEL
    refute_var_set STEALTH_DRY_RUN
}

@test "common_setup: the harness variables -> keeps them" {
    common_setup

    assert_var_equal STEALTH_LIB_DIR "${STEALTH_TEST_ROOT}/src/lib"
    assert_var_equal STEALTH_TEST_DIR "${STEALTH_TEST_ROOT}/tests"
    assert_var_equal STEALTH_TEST_ROOT "${BATS_TEST_DIRNAME%/tests}"
}

@test "common_setup: no STEALTH_LIB in the environment -> points it at STEALTH_LIB_DIR" {
    common_setup

    assert_var_equal STEALTH_LIB "${STEALTH_LIB_DIR}"
    assert_declared -x STEALTH_LIB
}

@test "bats-expect: assertions -> loaded" {
    assert_equal a a
    assert_regex 2026-09-19 '^[0-9]{4}-'
}

@test "bats-mock: a mock -> answers and records its call" {
    mock probe '*' 'echo mocked'
    run probe a b
    assert_output mocked
    assert_called_with probe 'a b'
}

@test "bats-matrix: a table -> runs every row" {
    # shellcheck disable=SC2034  # read by load_lib
    STEALTH_LIB_DIR="${BATS_TEST_DIRNAME}/fixtures/lib"
    load_lib probe
    run_matrix stealth::probe::greet <<'EOM'
        # name  | status | output
        world   | 0      | hello, world
                | 0      | hello, stranger
EOM
}
