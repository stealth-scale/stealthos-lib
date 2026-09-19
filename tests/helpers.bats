#!/usr/bin/env bats

# ==============================================================================
# The test helper - Test Suite
# ==============================================================================
# The harness every suite builds on: the helper loads, the three bats libraries
# answer, and a module is sourced by its path. Run with `make test`.
# ==============================================================================

bats_load_library stealth

setup() {
    # shellcheck disable=SC2034  # read by load_lib
    STEALTH_LIB_DIR="$BATS_TEST_DIRNAME/fixtures/lib"
    common_setup
}

teardown() {
    common_teardown
}

@test "load_lib: module path -> sources src/lib/PATH.sh and its functions are callable" {
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
    load_lib probe
    run_matrix stealth::probe::greet <<'EOM'
        # name  | status | output
        world   | 0      | hello, world
                | 0      | hello, stranger
EOM
}
