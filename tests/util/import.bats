#!/usr/bin/env bats

# shellcheck disable=SC2034
# Variables here are read by name through the library's namerefs.

# ==============================================================================
# util/import - Test Suite
# ==============================================================================
# The linker. Every test sources the real module with STEALTH_LIB pointing at a
# fixture tree, so the root and the search paths are under the test's control.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    # Two fixture trees: the root the importer resolves from first, and a
    # second one for the search path. A module of either records that it was
    # sourced in the log, so a test can tell a source from a cache hit.
    STEALTH_ROOT_DIR="${BATS_TEST_TMPDIR}/root"
    STEALTH_EXTRA_DIR="${BATS_TEST_TMPDIR}/extra"
    STEALTH_SOURCED_LOG="${BATS_TEST_TMPDIR}/sourced.log"
    mkdir -p "${STEALTH_ROOT_DIR}/util" "${STEALTH_EXTRA_DIR}/pkg"

    # common_setup points STEALTH_LIB at the checkout. This module is the one
    # that reads it, so its tests take the fixture tree instead.
    export STEALTH_LIB="${STEALTH_ROOT_DIR}"
    load_lib util/import
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Writes a module that records every source and defines one function.
#
# Arguments:
#   $1 - Directory of the tree
#   $2 - Module path without the extension
write_module() {
    local -r dir="${1}" path="${2}"

    local guard="${path^^}"
    guard="_STEALTH_LIB_${guard//[\/-]/_}"

    local -r fn="${path//\//::}"

    mkdir -p "${dir}/${path%/*}"
    cat > "${dir}/${path}.sh" <<EOF
printf '%s\n' "${path}" >> "${STEALTH_SOURCED_LOG}"
if [[ -n "\${${guard}:-}" ]]; then return 0; fi
declare -gr ${guard}=1
stealth::${fn}::name() { printf '%s\n' '${path}'; }
EOF
}

# Reads the modules that were sourced, in order.
sourced_modules() {
    if [[ -f "${STEALTH_SOURCED_LOG}" ]]; then
        printf '%s' "$(< "${STEALTH_SOURCED_LOG}")"
    fi
}

# ------------------------------------------------------------------------------
# stealth::util::import
# ------------------------------------------------------------------------------

@test "stealth::util::import: a module in the root -> sources it and its functions are callable" {
    write_module "${STEALTH_ROOT_DIR}" util/probe

    stealth::util::import util/probe

    run stealth::util::probe::name
    assert_success
    assert_output util/probe
}

@test "stealth::util::import: the same module twice -> sources it once" {
    write_module "${STEALTH_ROOT_DIR}" util/probe

    stealth::util::import util/probe
    stealth::util::import util/probe

    run sourced_modules
    assert_output util/probe
}

@test "stealth::util::import: several modules -> sources each of them" {
    write_module "${STEALTH_ROOT_DIR}" util/one
    write_module "${STEALTH_ROOT_DIR}" util/two

    stealth::util::import util/one util/two

    run sourced_modules
    assert_line --index 0 util/one
    assert_line --index 1 util/two
}

@test "stealth::util::import: a module whose guard is set -> marks it loaded without sourcing" {
    write_module "${STEALTH_ROOT_DIR}" util/probe
    declare -g _STEALTH_LIB_UTIL_PROBE=1

    stealth::util::import util/probe

    run sourced_modules
    assert_output ''
    assert stealth::util::import::is_loaded util/probe
}

@test "stealth::util::import: a module in a search path -> resolves it after the root" {
    write_module "${STEALTH_EXTRA_DIR}" pkg/zlib
    stealth::util::import::add_path "${STEALTH_EXTRA_DIR}"

    stealth::util::import pkg/zlib

    run stealth::pkg::zlib::name
    assert_success
    assert_output pkg/zlib
}

@test "stealth::util::import: a module in both trees -> the root wins" {
    write_module "${STEALTH_ROOT_DIR}" pkg/zlib
    mkdir -p "${STEALTH_EXTRA_DIR}/pkg"
    printf 'printf %%s\\\\n shadowed >> %s\n' "${STEALTH_SOURCED_LOG}" \
        > "${STEALTH_EXTRA_DIR}/pkg/zlib.sh"
    stealth::util::import::add_path "${STEALTH_EXTRA_DIR}"

    stealth::util::import pkg/zlib

    run sourced_modules
    assert_output pkg/zlib
}

@test "stealth::util::import: a module that imports itself -> fails and names the module" {
    printf 'stealth::util::import util/loop\n' > "${STEALTH_ROOT_DIR}/util/loop.sh"

    run stealth::util::import util/loop
    assert_failure 1
    assert_output --partial 'util/loop imports itself'
}

@test "stealth::util::import: a missing module -> fails and names the module" {
    run stealth::util::import util/nowhere
    assert_failure 1
    assert_output --partial 'no module util/nowhere'
}

@test "stealth::util::import: a path that leaves the tree -> fails as an invalid name" {
    run stealth::util::import ../../etc/passwd
    assert_failure 1
    assert_output --partial 'is not a module path'
}

@test "stealth::util::import: a name with a dot -> fails as an invalid name" {
    run stealth::util::import util/log.sh
    assert_failure 1
    assert_output --partial 'util/log.sh is not a module path'
}

@test "stealth::util::import: an empty name -> fails as an invalid name" {
    run stealth::util::import ''
    assert_failure 1
    assert_output --partial 'is not a module path'
}

@test "stealth::util::import: no argument -> succeeds and loads nothing" {
    run stealth::util::import
    assert_success

    run sourced_modules
    assert_output ''
}

# ------------------------------------------------------------------------------
# stealth::util::import::add_path
# ------------------------------------------------------------------------------

@test "stealth::util::import::add_path: a directory -> registers it" {
    run stealth::util::import::add_path "${STEALTH_EXTRA_DIR}"
    assert_success

    stealth::util::import::add_path "${STEALTH_EXTRA_DIR}"
    local -a paths=()
    stealth::util::import::paths paths
    assert_array_equal paths "${STEALTH_EXTRA_DIR}"
}

@test "stealth::util::import::add_path: no argument -> fails and names the reason" {
    run stealth::util::import::add_path
    assert_failure 1
    assert_output --partial 'no path given'
}

@test "stealth::util::import::add_path: an empty path -> fails and registers the rest" {
    run stealth::util::import::add_path '' "${STEALTH_EXTRA_DIR}"
    assert_failure 1
    assert_output --partial 'the path is empty'

    stealth::util::import::add_path '' "${STEALTH_EXTRA_DIR}" || true
    local -a paths=()
    stealth::util::import::paths paths
    assert_array_equal paths "${STEALTH_EXTRA_DIR}"
}

@test "stealth::util::import::add_path: a relative path -> fails and names the path" {
    run stealth::util::import::add_path modules
    assert_failure 1
    assert_output --partial 'modules is not absolute'
}

@test "stealth::util::import::add_path: a directory that does not exist -> warns and registers it" {
    run stealth::util::import::add_path "${BATS_TEST_TMPDIR}/later"
    assert_success
    assert_output --partial 'does not exist'
}

# ------------------------------------------------------------------------------
# stealth::util::import::paths
# ------------------------------------------------------------------------------

@test "stealth::util::import::paths: no path added -> returns an empty array" {
    local -a paths=(stale)
    stealth::util::import::paths paths
    assert_array_empty paths
}

# ------------------------------------------------------------------------------
# stealth::util::import::loaded
# ------------------------------------------------------------------------------

@test "stealth::util::import::loaded: after two imports -> returns them in load order" {
    write_module "${STEALTH_ROOT_DIR}" util/one
    write_module "${STEALTH_ROOT_DIR}" util/two
    stealth::util::import util/two util/one

    local -a order=()
    stealth::util::import::loaded order
    assert_array_equal order util/two util/one
}

# ------------------------------------------------------------------------------
# stealth::util::import::is_loaded
# ------------------------------------------------------------------------------

@test "stealth::util::import::is_loaded: a loaded module -> succeeds" {
    write_module "${STEALTH_ROOT_DIR}" util/probe
    stealth::util::import util/probe

    run stealth::util::import::is_loaded util/probe
    assert_success
}

@test "stealth::util::import::is_loaded: an unknown module -> fails" {
    run stealth::util::import::is_loaded util/nowhere
    assert_failure
}

@test "stealth::util::import::is_loaded: no argument -> fails" {
    run stealth::util::import::is_loaded
    assert_failure
}

# ------------------------------------------------------------------------------
# stealth::util::import::_to_guard_var
# ------------------------------------------------------------------------------

@test "stealth::util::import::_to_guard_var: a nested path -> upper cases it and replaces the slashes" {
    local guard=''
    stealth::util::import::_to_guard_var guard sys/io/fs
    assert_equal "${guard}" _STEALTH_LIB_SYS_IO_FS
}

@test "stealth::util::import::_to_guard_var: a path with a hyphen -> replaces it with an underscore" {
    local guard=''
    stealth::util::import::_to_guard_var guard api/os/boot-c
    assert_equal "${guard}" _STEALTH_LIB_API_OS_BOOT_C
}

# ------------------------------------------------------------------------------
# stealth::util::import::_resolve
# ------------------------------------------------------------------------------

@test "stealth::util::import::_resolve: a module in the root -> returns its path" {
    write_module "${STEALTH_ROOT_DIR}" util/probe

    local file=''
    stealth::util::import::_resolve file util/probe
    assert_equal "${file}" "${STEALTH_ROOT_DIR}/util/probe.sh"
}

@test "stealth::util::import::_resolve: an unknown module -> fails and leaves the output alone" {
    local file=untouched
    run stealth::util::import::_resolve file util/nowhere
    assert_failure 1
    assert_equal "${file}" untouched
}

# ------------------------------------------------------------------------------
# stealth::util::import::_log
# ------------------------------------------------------------------------------

@test "stealth::util::import::_log: the logger is loaded -> calls it with the format and its arguments" {
    # The logger takes a format and its arguments, so the stub does too.
    # shellcheck disable=SC2059  # the format is the caller's first argument
    stealth::util::log::warn() { printf 'logger: '; printf "$@"; printf '\n'; }

    run stealth::util::import::_log WARN 'a %s line' formatted
    assert_success
    assert_output 'logger: a formatted line'
}

@test "stealth::util::import::_log: no logger and an error -> prints it to stderr" {
    run --separate-stderr stealth::util::import::_log ERROR 'broke on %s' zlib
    assert_success
    assert_equal "${stderr}" '[bootstrap] [ERROR] broke on zlib'
}

@test "stealth::util::import::_log: no logger and a debug line -> prints nothing" {
    run --separate-stderr stealth::util::import::_log DEBUG 'searched %s' /lib
    assert_success
    assert_output ''
    assert_equal "${stderr}" ''
}

# ------------------------------------------------------------------------------
# util/import, the module itself
# ------------------------------------------------------------------------------

@test "util/import: sourced twice -> returns before it declares anything" {
    stealth::util::import::add_path "${STEALTH_EXTRA_DIR}"

    load_lib util/import

    local -a paths=()
    stealth::util::import::paths paths
    assert_array_equal paths "${STEALTH_EXTRA_DIR}"
}

@test "util/import: STEALTH_LIB is unset -> resolves the directory above the module" {
    local checkout
    checkout="$(readlink -f -- "${BATS_TEST_DIRNAME}/../..")"

    run bash -c "unset STEALTH_LIB
        source '${checkout}/src/lib/util/import.sh'
        printf '%s\n' \"\${_STEALTH_UTIL_IMPORT_ROOT}\""

    assert_success
    assert_output "${checkout}/src/lib"
}
