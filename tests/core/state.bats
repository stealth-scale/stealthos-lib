#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# core/state - Test Suite
# ==============================================================================
# The registry is global, and every @test is its own process, so a test starts
# from an empty one without clearing anything.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import core/state
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Answers as root for the stage that depends on which user a run is.
given_root() {
    mock stealth::core::state::is_root '*' 'return 0'
}

# Answers as anyone but root.
given_not_root() {
    mock stealth::core::state::is_root '*' 'return 1'
}

# ------------------------------------------------------------------------------
# stealth::core::state::set
# ------------------------------------------------------------------------------

@test "stealth::core::state::set: a key and a value -> the registry holds it" {
    stealth::core::state::set 'dry_run' 'true'

    assert_nameref 'true' stealth::core::state::get 'dry_run'
}

@test "stealth::core::state::set: the same key twice -> keeps the second value" {
    stealth::core::state::set 'jobs' '4'
    stealth::core::state::set 'jobs' '8'

    assert_nameref '8' stealth::core::state::get 'jobs'
}

@test "stealth::core::state::set: no value -> records an empty one" {
    stealth::core::state::set 'jobs'

    assert_nameref '' stealth::core::state::get 'jobs'
}

@test "stealth::core::state::set: no key -> exits 1" {
    run stealth::core::state::set ''
    assert_refused 'a setting key is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::get
# ------------------------------------------------------------------------------

@test "stealth::core::state::get: a key in the registry -> reads it" {
    stealth::core::state::set 'log_level' '4'

    assert_nameref '4' stealth::core::state::get 'log_level'
}

@test "stealth::core::state::get: a key only in STEALTH_ -> reads that" {
    export STEALTH_LOG_LEVEL=5

    assert_nameref '5' stealth::core::state::get 'log_level'
}

@test "stealth::core::state::get: the registry -> beats the environment" {
    export STEALTH_LOG_LEVEL=5
    stealth::core::state::set 'log_level' '2'

    assert_nameref '2' stealth::core::state::get 'log_level'
}

@test "stealth::core::state::get: a key under its own name -> reads that last" {
    # shellcheck disable=SC2034  # read back through the registry lookup
    local concurrency=16

    assert_nameref '16' stealth::core::state::get 'concurrency'
}

@test "stealth::core::state::get: a key that is not set -> returns 1" {
    run stealth::core::state::get out 'nothing_set_anywhere'
    assert_failure 1
}

@test "stealth::core::state::get: a default -> uses it when nothing is set" {
    assert_nameref '4' stealth::core::state::get 'nothing_set_anywhere' '4'
}

@test "stealth::core::state::get: an empty default -> still succeeds" {
    local value='untouched'

    stealth::core::state::get value 'nothing_set_anywhere' ''

    assert_var_equal value ''
}

@test "stealth::core::state::get: a default -> is not used when the key is set" {
    stealth::core::state::set 'jobs' '2'

    assert_nameref '2' stealth::core::state::get 'jobs' '99'
}

@test "stealth::core::state::get: no output variable -> exits 1" {
    run stealth::core::state::get ''
    assert_refused 'an output variable is required'
}

@test "stealth::core::state::get: no key -> exits 1" {
    run stealth::core::state::get out ''
    assert_refused 'a setting key is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::has
# ------------------------------------------------------------------------------

@test "stealth::core::state::has: a key that is set -> returns 0" {
    stealth::core::state::set 'jobs' '4'

    run stealth::core::state::has 'jobs'
    assert_success
}

@test "stealth::core::state::has: a key that is not set -> returns 1" {
    run stealth::core::state::has 'nothing_set_anywhere'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_stages
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_stages: the stages -> are the four a run can be in" {
    local -a stages=()

    stealth::core::state::get_stages stages

    assert_array_equal stages build setup root user
}

@test "stealth::core::state::get_stages: no output variable -> exits 1" {
    run stealth::core::state::get_stages ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::is_stage
# ------------------------------------------------------------------------------

@test "stealth::core::state::is_stage: a stage -> returns 0" {
    run stealth::core::state::is_stage build
    assert_success
}

@test "stealth::core::state::is_stage: something else -> returns 1" {
    run stealth::core::state::is_stage deploy
    assert_failure 1
}

@test "stealth::core::state::is_stage: nothing -> returns 1" {
    run stealth::core::state::is_stage
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::core::state::detect_stage
# ------------------------------------------------------------------------------

@test "stealth::core::state::detect_stage: the stage setting -> is what it takes" {
    stealth::core::state::set 'stage' 'build'

    assert_nameref 'build' stealth::core::state::detect_stage
}

@test "stealth::core::state::detect_stage: no setting and root -> gives root" {
    given_root

    assert_nameref 'root' stealth::core::state::detect_stage
}

@test "stealth::core::state::detect_stage: no setting and anyone else -> gives user" {
    given_not_root

    assert_nameref 'user' stealth::core::state::detect_stage
}

@test "stealth::core::state::detect_stage: STEALTH_STAGE -> is read like any setting" {
    export STEALTH_STAGE=setup

    assert_nameref 'setup' stealth::core::state::detect_stage
}

@test "stealth::core::state::detect_stage: called twice -> keeps the first answer" {
    stealth::core::state::set 'stage' 'build'
    local first second

    stealth::core::state::detect_stage first
    stealth::core::state::set 'stage' 'setup'
    stealth::core::state::detect_stage second

    assert_var_equal second 'build'
}

@test "stealth::core::state::detect_stage: a stage that is not one of the four -> exits 1" {
    stealth::core::state::set 'stage' 'deploy'

    run stealth::core::state::detect_stage out
    assert_refused 'a stage is one of build, setup, root, user, not deploy'
}

@test "stealth::core::state::detect_stage: no output variable -> exits 1" {
    run stealth::core::state::detect_stage ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::add_search_path
# ------------------------------------------------------------------------------

@test "stealth::core::state::add_search_path: a directory -> is on the list" {
    local -a paths=()

    stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}"
    stealth::core::state::get_search_paths paths

    assert_array_equal paths "${BATS_TEST_TMPDIR}"
}

@test "stealth::core::state::add_search_path: a directory -> is on the importer's list too" {
    local -a paths=()

    stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}"
    stealth::util::import::paths paths

    assert_array_contains paths "${BATS_TEST_TMPDIR}"
}

@test "stealth::core::state::add_search_path: the same directory twice -> is on the list once" {
    local -a paths=()

    stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}"
    stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}"
    stealth::core::state::get_search_paths paths

    assert_array_length paths 1
}

@test "stealth::core::state::add_search_path: a relative path -> returns 1" {
    run stealth::core::state::add_search_path 'modules'
    assert_failure 1
}

@test "stealth::core::state::add_search_path: a directory that is not there -> returns 1" {
    run stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}/nowhere"
    assert_failure 1
}

@test "stealth::core::state::add_search_path: no path -> exits 1" {
    run stealth::core::state::add_search_path ''
    assert_refused 'a search path is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::add_search_paths
# ------------------------------------------------------------------------------

@test "stealth::core::state::add_search_paths: several -> keeps their order" {
    mkdir -p "${BATS_TEST_TMPDIR}/one" "${BATS_TEST_TMPDIR}/two"
    local -a paths=()

    stealth::core::state::add_search_paths \
        "${BATS_TEST_TMPDIR}/one" "${BATS_TEST_TMPDIR}/two"
    stealth::core::state::get_search_paths paths

    assert_array_equal paths "${BATS_TEST_TMPDIR}/one" "${BATS_TEST_TMPDIR}/two"
}

@test "stealth::core::state::add_search_paths: one that is not there -> adds the rest" {
    local -a paths=()

    run stealth::core::state::add_search_paths \
        "${BATS_TEST_TMPDIR}/nowhere" "${BATS_TEST_TMPDIR}"
    assert_failure 1

    stealth::core::state::add_search_paths \
        "${BATS_TEST_TMPDIR}/nowhere" "${BATS_TEST_TMPDIR}" || true
    stealth::core::state::get_search_paths paths

    assert_array_equal paths "${BATS_TEST_TMPDIR}"
}

@test "stealth::core::state::add_search_paths: no path -> exits 1" {
    run stealth::core::state::add_search_paths ''
    assert_refused 'a search path is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_search_paths
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_search_paths: none added -> gives an empty array" {
    local -a paths=(stale)

    stealth::core::state::get_search_paths paths

    assert_array_empty paths
}

@test "stealth::core::state::get_search_paths: no output variable -> exits 1" {
    run stealth::core::state::get_search_paths ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::register_module
# ------------------------------------------------------------------------------

@test "stealth::core::state::register_module: a module -> is loaded and in the order" {
    local -a order=()

    stealth::core::state::register_module 'pkg/zlib'
    stealth::core::state::get_module_order order

    assert_array_equal order 'pkg/zlib'
}

@test "stealth::core::state::register_module: several -> keeps the order they came in" {
    local -a order=()

    stealth::core::state::register_module 'toolchain/final'
    stealth::core::state::register_module 'pkg/zlib'
    stealth::core::state::get_module_order order

    assert_array_equal order 'toolchain/final' 'pkg/zlib'
}

@test "stealth::core::state::register_module: the same module twice -> is in the order once" {
    local -a order=()

    stealth::core::state::register_module 'pkg/zlib'
    stealth::core::state::register_module 'pkg/zlib'
    stealth::core::state::get_module_order order

    assert_array_length order 1
}

@test "stealth::core::state::register_module: a directory -> is remembered with it" {
    stealth::core::state::register_module 'pkg/zlib' '/srv/modules/pkg/zlib'

    assert_nameref '/srv/modules/pkg/zlib' stealth::core::state::get_path 'pkg/zlib'
}

@test "stealth::core::state::register_module: no module path -> exits 1" {
    run stealth::core::state::register_module ''
    assert_refused 'a module path is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::is_module_loaded
# ------------------------------------------------------------------------------

@test "stealth::core::state::is_module_loaded: a module that is -> returns 0" {
    stealth::core::state::register_module 'pkg/zlib'

    run stealth::core::state::is_module_loaded 'pkg/zlib'
    assert_success
}

@test "stealth::core::state::is_module_loaded: a module that is not -> returns 1" {
    run stealth::core::state::is_module_loaded 'pkg/zlib'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_module_order
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_module_order: no module -> gives an empty array" {
    local -a order=(stale)

    stealth::core::state::get_module_order order

    assert_array_empty order
}

@test "stealth::core::state::get_module_order: no output variable -> exits 1" {
    run stealth::core::state::get_module_order ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_path
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_path: a module with no directory -> returns 1" {
    stealth::core::state::register_module 'pkg/zlib'

    run stealth::core::state::get_path out 'pkg/zlib'
    assert_failure 1
}

@test "stealth::core::state::get_path: no output variable -> exits 1" {
    run stealth::core::state::get_path ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::depends
# ------------------------------------------------------------------------------

@test "stealth::core::state::depends: what a module needs -> is recorded" {
    local -a deps=()

    stealth::core::state::depends 'pkg/zlib' 'toolchain/final' 'pkg/musl'
    stealth::core::state::get_deps deps 'pkg/zlib'

    assert_array_equal deps 'toolchain/final' 'pkg/musl'
}

@test "stealth::core::state::depends: declared twice -> adds to what is there" {
    local -a deps=()

    stealth::core::state::depends 'pkg/zlib' 'toolchain/final'
    stealth::core::state::depends 'pkg/zlib' 'pkg/musl'
    stealth::core::state::get_deps deps 'pkg/zlib'

    assert_array_equal deps 'toolchain/final' 'pkg/musl'
}

@test "stealth::core::state::depends: the same dependency twice -> records it once" {
    local -a deps=()

    stealth::core::state::depends 'pkg/zlib' 'pkg/musl' 'pkg/musl'
    stealth::core::state::get_deps deps 'pkg/zlib'

    assert_array_equal deps 'pkg/musl'
}

@test "stealth::core::state::depends: no dependency -> records nothing" {
    local -a graph=()

    stealth::core::state::depends 'pkg/zlib'
    stealth::core::state::get_graph graph

    assert_array_empty graph
}

@test "stealth::core::state::depends: a module that needs itself -> exits 1" {
    run stealth::core::state::depends 'pkg/zlib' 'pkg/zlib'
    assert_refused 'a module does not depend on itself, and pkg/zlib does'
}

@test "stealth::core::state::depends: no module path -> exits 1" {
    run stealth::core::state::depends ''
    assert_refused 'a module path is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_deps
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_deps: a module that declared none -> gives an empty array" {
    local -a deps=(stale)

    stealth::core::state::get_deps deps 'pkg/zlib'

    assert_array_empty deps
}

@test "stealth::core::state::get_deps: no output variable -> exits 1" {
    run stealth::core::state::get_deps ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::get_graph
# ------------------------------------------------------------------------------

@test "stealth::core::state::get_graph: the edges -> are a module and one dependency each" {
    local -a graph=()

    stealth::core::state::depends 'pkg/zlib' 'toolchain/final' 'pkg/musl'
    stealth::core::state::get_graph graph

    assert_array_equal graph 'pkg/zlib toolchain/final' 'pkg/zlib pkg/musl'
}

@test "stealth::core::state::get_graph: several modules -> come in the order they declared" {
    local -a graph=()

    stealth::core::state::depends 'b' 'a'
    stealth::core::state::depends 'c' 'b'
    stealth::core::state::get_graph graph

    assert_array_equal graph 'b a' 'c b'
}

@test "stealth::core::state::get_graph: the edges -> are what tsort orders" {
    local -a graph=()
    stealth::core::state::depends 'pkg/zlib' 'toolchain/final'
    stealth::core::state::depends 'toolchain/final' 'toolchain/seed'
    stealth::core::state::get_graph graph

    run bash -c "printf '%s\n' \"\$@\" | tsort" _ "${graph[@]}"

    assert_success
    assert_line --index 0 'pkg/zlib'
    assert_line --index 2 'toolchain/seed'
}

@test "stealth::core::state::get_graph: nothing declared -> gives an empty array" {
    local -a graph=(stale)

    stealth::core::state::get_graph graph

    assert_array_empty graph
}

@test "stealth::core::state::get_graph: no output variable -> exits 1" {
    run stealth::core::state::get_graph ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::core::state::dump
# ------------------------------------------------------------------------------

@test "stealth::core::state::dump: the registry -> is written to the log" {
    stealth::core::state::set 'jobs' '4'
    stealth::core::state::add_search_path "${BATS_TEST_TMPDIR}"
    stealth::core::state::register_module 'pkg/zlib'

    stealth::core::state::dump

    assert_called_with_args stealth::util::log::debug 'state: %d settings' 1
    assert_called_with_args stealth::util::log::debug 'state: %d modules' 1
}

# ------------------------------------------------------------------------------
# stealth::core::state::is_root
# ------------------------------------------------------------------------------

@test "stealth::core::state::is_root: the user the suite runs as -> is not root" {
    if (( EUID == 0 )); then
        skip 'this suite is running as root'
    fi

    run stealth::core::state::is_root
    assert_failure 1
}

# ------------------------------------------------------------------------------
# core/state, the module itself
# ------------------------------------------------------------------------------

@test "core/state: sourced twice -> returns before it declares anything" {
    stealth::core::state::set 'jobs' '4'

    load_lib core/state

    assert_nameref '4' stealth::core::state::get 'jobs'
}
