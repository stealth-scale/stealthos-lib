#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# core/loader - Test Suite
# ==============================================================================
# Every test builds the module tree it needs under the test's own temporary
# directory and puts that directory on the search path. A module records that
# it was read by defining a function, which the test then looks for.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import core/loader
    load_mock util
    mock::stealth::util::log

    STEALTH_MODULES="${BATS_TEST_TMPDIR}/modules"
    mkdir -p "${STEALTH_MODULES}"
    stealth::core::state::add_search_path "${STEALTH_MODULES}"
    stealth::core::state::set 'stage' 'build'
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Writes a module that records which of its files were read.
#
#   given_module NAME [STAGE]
given_module() {
    local -r name="${1}"
    local -r stage="${2:-build}"
    local -r dir="${STEALTH_MODULES}/${name}"
    local ns="${name//\//::}"
    ns="${ns//-/_}"

    mkdir -p "${dir}"
    printf 'mod::%s::init() { :; }\nread_common_%s=1\n' \
        "${ns}" "${ns//::/_}" > "${dir}/common.sh"
    printf 'mod::%s::%s::start() { :; }\nread_stage_%s=1\n' \
        "${ns}" "${stage}" "${ns//::/_}" > "${dir}/${stage}.sh"
}

# ------------------------------------------------------------------------------
# stealth::core::loader::to_namespace
# ------------------------------------------------------------------------------

@test "stealth::core::loader::to_namespace: a module path -> sits under mod" {
    assert_nameref 'mod::pkg::zlib' stealth::core::loader::to_namespace 'pkg/zlib'
}

@test "stealth::core::loader::to_namespace: one component -> sits under mod" {
    assert_nameref 'mod::alpha' stealth::core::loader::to_namespace 'alpha'
}

@test "stealth::core::loader::to_namespace: a hyphen -> becomes an underscore" {
    assert_nameref 'mod::gcc_pass_one' stealth::core::loader::to_namespace 'gcc-pass-one'
}

@test "stealth::core::loader::to_namespace: a prefix of its own -> sits under that" {
    assert_nameref 'stealth::util::log' \
        stealth::core::loader::to_namespace 'util/log' 'stealth'
}

@test "stealth::core::loader::to_namespace: no output variable -> exits 1" {
    run stealth::core::loader::to_namespace ''
    assert_refused 'an output variable is required'
}

@test "stealth::core::loader::to_namespace: no module path -> exits 1" {
    run stealth::core::loader::to_namespace out ''
    assert_refused 'a module path is required'
}

# ------------------------------------------------------------------------------
# stealth::core::loader::module
# ------------------------------------------------------------------------------

@test "stealth::core::loader::module: a module -> reads its common file" {
    given_module alpha

    stealth::core::loader::module alpha

    assert_var_equal read_common_alpha 1
}

@test "stealth::core::loader::module: a module -> reads the file of the stage" {
    given_module alpha

    stealth::core::loader::module alpha

    assert_var_equal read_stage_alpha 1
}

@test "stealth::core::loader::module: another stage -> that file is not read" {
    given_module alpha setup

    stealth::core::loader::module alpha

    refute_var_set read_stage_alpha
}

@test "stealth::core::loader::module: no common file -> the stage file is still read" {
    mkdir -p "${STEALTH_MODULES}/alpha"
    printf 'read_stage_alpha=1\n' > "${STEALTH_MODULES}/alpha/build.sh"

    stealth::core::loader::module alpha

    assert_var_equal read_stage_alpha 1
}

@test "stealth::core::loader::module: a directory with no file in it -> loads" {
    mkdir -p "${STEALTH_MODULES}/alpha"

    run stealth::core::loader::module alpha
    assert_success
}

@test "stealth::core::loader::module: a module -> is registered with its directory" {
    given_module alpha

    stealth::core::loader::module alpha

    run stealth::core::state::is_module_loaded alpha
    assert_success
    assert_nameref "${STEALTH_MODULES}/alpha" stealth::core::state::get_path alpha
}

@test "stealth::core::loader::module: several -> are registered in the order given" {
    given_module alpha
    given_module beta
    local -a order=()

    stealth::core::loader::module beta alpha
    stealth::core::state::get_module_order order

    assert_array_equal order beta alpha
}

@test "stealth::core::loader::module: a module under a path -> loads" {
    given_module 'pkg/zlib'

    stealth::core::loader::module 'pkg/zlib'

    assert_var_equal read_common_pkg_zlib 1
}

@test "stealth::core::loader::module: one already loaded -> is not read again" {
    given_module alpha
    stealth::core::loader::module alpha
    read_common_alpha=0

    stealth::core::loader::module alpha

    assert_var_equal read_common_alpha 0
}

@test "stealth::core::loader::module: the second search path -> is looked in too" {
    local -r other="${BATS_TEST_TMPDIR}/other"
    mkdir -p "${other}/gamma"
    printf 'read_common_gamma=1\n' > "${other}/gamma/common.sh"
    stealth::core::state::add_search_path "${other}"

    stealth::core::loader::module gamma

    assert_var_equal read_common_gamma 1
}

@test "stealth::core::loader::module: the first search path that has it -> wins" {
    local -r other="${BATS_TEST_TMPDIR}/other"
    mkdir -p "${other}/alpha" "${STEALTH_MODULES}/alpha"
    printf 'came_from=second\n' > "${other}/alpha/common.sh"
    printf 'came_from=first\n' > "${STEALTH_MODULES}/alpha/common.sh"
    stealth::core::state::add_search_path "${other}"

    stealth::core::loader::module alpha

    assert_var_equal came_from first
}

@test "stealth::core::loader::module: a module no search path holds -> exits 1" {
    run stealth::core::loader::module missing

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        'no module %s on any search path' missing
}

@test "stealth::core::loader::module: a path that climbs out -> exits 1" {
    run stealth::core::loader::module '../etc/passwd'
    assert_refused 'a module path is a name and slashes, not ../etc/passwd'
}

@test "stealth::core::loader::module: a module that loads itself -> exits 1" {
    mkdir -p "${STEALTH_MODULES}/alpha"
    printf 'stealth::core::loader::module alpha\n' > "${STEALTH_MODULES}/alpha/common.sh"

    run stealth::core::loader::module alpha
    assert_refused 'the module alpha loads itself'
}

@test "stealth::core::loader::module: no module -> does nothing" {
    run stealth::core::loader::module
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::core::loader::load_manifest
# ------------------------------------------------------------------------------

@test "stealth::core::loader::load_manifest: a list -> loads what it names" {
    given_module alpha
    given_module beta
    printf 'MODULES=(alpha beta)\n' > "${BATS_TEST_TMPDIR}/list"
    local -a order=()

    stealth::core::loader::load_manifest "${BATS_TEST_TMPDIR}/list"
    stealth::core::state::get_module_order order

    assert_array_equal order alpha beta
}

@test "stealth::core::loader::load_manifest: the list -> does not leak MODULES" {
    given_module alpha
    printf 'MODULES=(alpha)\n' > "${BATS_TEST_TMPDIR}/list"

    stealth::core::loader::load_manifest "${BATS_TEST_TMPDIR}/list"

    refute_var_set MODULES
}

@test "stealth::core::loader::load_manifest: a list that names nothing -> exits 1" {
    printf 'MODULES=()\n' > "${BATS_TEST_TMPDIR}/list"

    run stealth::core::loader::load_manifest "${BATS_TEST_TMPDIR}/list"

    assert_failure 1
    assert_called_with_args stealth::util::log::error \
        'the module list %s names no module' "${BATS_TEST_TMPDIR}/list"
}

@test "stealth::core::loader::load_manifest: no such file -> exits 1" {
    run stealth::core::loader::load_manifest "${BATS_TEST_TMPDIR}/nowhere"
    assert_refused "no module list at ${BATS_TEST_TMPDIR}/nowhere"
}

@test "stealth::core::loader::load_manifest: no file -> exits 1" {
    run stealth::core::loader::load_manifest ''
    assert_refused 'no module list at '
}

# ------------------------------------------------------------------------------
# stealth::core::loader::_resolve
# ------------------------------------------------------------------------------

@test "stealth::core::loader::_resolve: a module that is there -> gives its directory" {
    mkdir -p "${STEALTH_MODULES}/alpha"

    assert_nameref "${STEALTH_MODULES}/alpha" stealth::core::loader::_resolve alpha
}

@test "stealth::core::loader::_resolve: a module that is not -> returns 1" {
    run stealth::core::loader::_resolve out missing
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::core::loader::_source
# ------------------------------------------------------------------------------

@test "stealth::core::loader::_source: a file -> reads it" {
    printf 'read_it=1\n' > "${BATS_TEST_TMPDIR}/one.sh"

    stealth::core::loader::_source "${BATS_TEST_TMPDIR}/one.sh"

    assert_var_equal read_it 1
}

@test "stealth::core::loader::_source: no such file -> returns 0" {
    run stealth::core::loader::_source "${BATS_TEST_TMPDIR}/nowhere.sh"
    assert_success
}

# ------------------------------------------------------------------------------
# core/loader, the module itself
# ------------------------------------------------------------------------------

@test "core/loader: a module file -> is read from its own directory, not the library" {
    # A module named like a library path used to be read out of the library,
    # because util/import looks in the library root before the search paths.
    mkdir -p "${STEALTH_MODULES}/util/log"
    printf 'came_from=the_module\n' > "${STEALTH_MODULES}/util/log/common.sh"

    stealth::core::loader::module 'util/log'

    assert_var_equal came_from the_module
}

@test "core/loader: sourced twice -> returns before it declares anything" {
    given_module alpha
    stealth::core::loader::module alpha

    load_lib core/loader

    run stealth::core::state::is_module_loaded alpha
    assert_success
}
