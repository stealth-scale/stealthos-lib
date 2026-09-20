#!/usr/bin/env bash
# The test helper of stealthos-lib. A test file loads it first:
#
#   bats_load_library stealth
#   setup() { common_setup; load_lib util/log; }
#   teardown() { common_teardown; }
#
# BATS_LIB_PATH points at tests/helpers, so this library, bats-expect, bats-mock and
# bats-matrix are all found by name. The Makefile sets it for the image and the host.
#
# Globals:
#   STEALTH_LIB_DIR  - Where load_lib reads modules from. Default: src/lib of the checkout
#   STEALTH_TEST_DIR - Where load_mock reads mocks from. Default: tests of the checkout

bats_load_library bats-expect
bats_load_library bats-mock
bats_load_library bats-matrix

STEALTH_TEST_ROOT="$(readlink -f -- "${BASH_SOURCE[0]%/*}/../../..")"
: "${STEALTH_LIB_DIR:=${STEALTH_TEST_ROOT}/src/lib}"
: "${STEALTH_TEST_DIR:=${STEALTH_TEST_ROOT}/tests}"

#######################################
# Unsets every STEALTH_* variable the library reads, so a value in the shell
# that started the run cannot change what a test does. The three variables of
# the harness are kept. The list is local, because a global of its own would
# match the pattern and the loop would unset it.
#
# Returns:
#   0 - Scrubbed
#######################################
stealth_scrub_env() {
    local -ra keep=(STEALTH_TEST_ROOT STEALTH_LIB_DIR STEALTH_TEST_DIR)
    local name kept

    while IFS= read -r name; do
        for kept in "${keep[@]}"; do
            if [[ "${name}" == "${kept}" ]]; then
                continue 2
            fi
        done
        unset "${name}" 2>/dev/null || true
    done < <(compgen -v STEALTH_ || true)
    return 0
}

#######################################
# The setup every test shares: the bats version the assertions need, a scrubbed
# environment, the library root, and a mock session. Call it first in setup().
#
# A test of the importer points STEALTH_LIB at a fixture tree after this
# returns. Every other test keeps the checkout, so an import inside the module
# under test finds the real dependency.
#
# Globals:
#   STEALTH_LIB_DIR (Read)
#   STEALTH_LIB (Write)
# Returns:
#   0 - Ready
#######################################
common_setup() {
    bats_require_minimum_version 1.5.0

    stealth_scrub_env
    export STEALTH_LIB="${STEALTH_LIB_DIR}"

    mock_setup
}

#######################################
# The teardown that ends the mock session. Call it in teardown().
#
# Returns:
#   0 - Done
#######################################
common_teardown() {
    mock_teardown
}

#######################################
# Sources modules of the library by their path under src/lib.
#
# Arguments:
#   $@ (String) - Module paths without the extension: util/log, sys/cmd
# Globals:
#   STEALTH_LIB_DIR (Read)
# Returns:
#   0 - Every module sourced
#   1 - A module is missing
#######################################
load_lib() {
    local lib
    for lib in "$@"; do
        if [[ ! -f "${STEALTH_LIB_DIR}/${lib}.sh" ]]; then
            printf 'load_lib: no module %s under %s\n' "${lib}" "${STEALTH_LIB_DIR}" >&2
            return 1
        fi
        # shellcheck source=/dev/null
        source "${STEALTH_LIB_DIR}/${lib}.sh"
    done
}

#######################################
# Sources mock definitions shared by tests, from tests/mocks.
#
# Arguments:
#   $@ (String) - Mock names without the extension
# Globals:
#   STEALTH_TEST_DIR (Read)
# Returns:
#   0 - Every mock sourced
#   1 - A mock is missing
#######################################
load_mock() {
    local mock
    for mock in "$@"; do
        if [[ ! -f "${STEALTH_TEST_DIR}/mocks/${mock}.bash" ]]; then
            printf 'load_mock: no mock %s under %s/mocks\n' "${mock}" "${STEALTH_TEST_DIR}" >&2
            return 1
        fi
        # shellcheck source=/dev/null
        source "${STEALTH_TEST_DIR}/mocks/${mock}.bash"
    done
}
