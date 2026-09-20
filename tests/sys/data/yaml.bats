#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/data/yaml - Test Suite
# ==============================================================================
# The fixture carries two comments, because keeping them through a write is
# the reason this module goes to yq rather than doing what its reader does
# and going through JSON.
#
# Reading is sys/data/json's job here, so the reading tests are thin: enough
# to show the document reaches it whole and the answers come back in JSON's
# words. The writing tests are the ones that earn their place.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/data/yaml
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    FILE="${WORK}/config.yaml"

    cat > "${FILE}" <<'EOF'
# what this machine is
name: build
engine:
  # how long to wait
  timeout: 30
  debug: false
  hosts: [a, b]
empty: null
odd.key: dotted
EOF
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::read
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::read: a string -> comes back as itself" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::yaml::read: a number -> comes back as it is" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::data::yaml::read: a list -> comes back on one line" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine hosts

    assert_equal "${value}" '["a","b"]'
}

@test "stealth::sys::data::yaml::read: a step into a list -> is an index" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine hosts 1

    assert_equal "${value}" 'b'
}

@test "stealth::sys::data::yaml::read: a step into a list of mappings -> goes through it" {
    printf 'assets:\n  - name: one\n  - name: two\n' > "${FILE}"
    local value

    stealth::sys::data::yaml::read value "${FILE}" assets 1 name

    assert_equal "${value}" 'two'
}

@test "stealth::sys::data::yaml::read: a key with a dot in it -> is one step, not two" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" 'odd.key'

    assert_equal "${value}" 'dotted'
}

@test "stealth::sys::data::yaml::read: a key set to null -> comes back as null" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" empty

    assert_equal "${value}" 'null'
}

@test "stealth::sys::data::yaml::read: a path that is not there -> returns 1" {
    run stealth::sys::data::yaml::read value "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::yaml::read: a path that is not there and a default -> the default" {
    local value

    stealth::sys::data::yaml::read value "${FILE}" --default 60 engine nowhere

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::yaml::read: a file that is not YAML -> returns 1" {
    printf 'a:\n - b\n  c: d\n' > "${FILE}"

    run stealth::sys::data::yaml::read value "${FILE}" a
    assert_failure 1
}

@test "stealth::sys::data::yaml::read: no such file -> exits 1" {
    run stealth::sys::data::yaml::read value "${WORK}/nowhere" name
    assert_refused "no file to read at ${WORK}/nowhere"
}

@test "stealth::sys::data::yaml::read: no output variable -> exits 1" {
    run stealth::sys::data::yaml::read '' "${FILE}" name
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::has
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::has: a path that is there -> returns 0" {
    run stealth::sys::data::yaml::has "${FILE}" engine timeout
    assert_success
}

@test "stealth::sys::data::yaml::has: a key set to null -> returns 0" {
    run stealth::sys::data::yaml::has "${FILE}" empty
    assert_success
}

@test "stealth::sys::data::yaml::has: a path that is not there -> returns 1" {
    run stealth::sys::data::yaml::has "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::yaml::has: a file that is not YAML -> returns 1" {
    printf 'a:\n - b\n  c: d\n' > "${FILE}"

    run stealth::sys::data::yaml::has "${FILE}" a
    assert_failure 1
}

@test "stealth::sys::data::yaml::has: no path -> exits 1" {
    run stealth::sys::data::yaml::has "${FILE}"
    assert_refused 'a path is required'
}

@test "stealth::sys::data::yaml::has: no such file -> exits 1" {
    run stealth::sys::data::yaml::has "${WORK}/nowhere" name
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::keys: the document -> its keys in the order written" {
    local names

    stealth::sys::data::yaml::keys names "${FILE}"

    assert_array_equal names name engine empty 'odd.key'
}

@test "stealth::sys::data::yaml::keys: a path -> that mapping's keys" {
    local names

    stealth::sys::data::yaml::keys names "${FILE}" engine

    assert_array_equal names timeout debug hosts
}

@test "stealth::sys::data::yaml::keys: something that is not a mapping -> an empty array" {
    local names

    stealth::sys::data::yaml::keys names "${FILE}" engine hosts

    assert_array_empty names
}

@test "stealth::sys::data::yaml::keys: no output array -> exits 1" {
    run stealth::sys::data::yaml::keys '' "${FILE}"
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::load
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::load: a mapping -> everything in it" {
    local -A engine=()

    stealth::sys::data::yaml::load engine "${FILE}" engine

    assert_equal "${engine[timeout]}" '30'
    assert_equal "${engine[debug]}" 'false'
    assert_array_length engine 3
}

@test "stealth::sys::data::yaml::load: a list -> comes back as JSON" {
    local -A engine=()

    stealth::sys::data::yaml::load engine "${FILE}" engine

    assert_equal "${engine[hosts]}" '["a","b"]'
}

@test "stealth::sys::data::yaml::load: no output array -> exits 1" {
    run stealth::sys::data::yaml::load '' "${FILE}"
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::type
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::type: a number -> number, not the YAML tag" {
    # yq would say !!int here. A caller reading a .yaml and a caller reading
    # a .json have to get the same word for the same kind of value.
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'number'
}

@test "stealth::sys::data::yaml::type: a list -> array" {
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine hosts

    assert_equal "${kind}" 'array'
}

@test "stealth::sys::data::yaml::type: a mapping -> object" {
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine

    assert_equal "${kind}" 'object'
}

@test "stealth::sys::data::yaml::type: a key set to null -> null" {
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" empty

    assert_equal "${kind}" 'null'
}

@test "stealth::sys::data::yaml::type: a path that is not there -> returns 1" {
    run stealth::sys::data::yaml::type kind "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::yaml::type: no output variable -> exits 1" {
    run stealth::sys::data::yaml::type '' "${FILE}" name
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::set
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::set: a path that is there -> is changed" {
    stealth::sys::data::yaml::set "${FILE}" engine timeout 60
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::yaml::set: a change -> the comments stay" {
    stealth::sys::data::yaml::set "${FILE}" engine timeout 60

    assert_file_contains "${FILE}" '# what this machine is'
    assert_file_contains "${FILE}" '# how long to wait'
}

@test "stealth::sys::data::yaml::set: a number -> goes in as one" {
    stealth::sys::data::yaml::set "${FILE}" engine timeout 60
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'number'
}

@test "stealth::sys::data::yaml::set: a word -> goes in as a string" {
    stealth::sys::data::yaml::set "${FILE}" engine mode fast
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine mode

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::yaml::set: --string -> a number goes in as a string" {
    stealth::sys::data::yaml::set "${FILE}" --string engine port 8080
    local kind

    stealth::sys::data::yaml::type kind "${FILE}" engine port

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::yaml::set: --yaml -> a list goes in as one" {
    stealth::sys::data::yaml::set "${FILE}" --yaml engine hosts '[x, y]'
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine hosts

    assert_equal "${value}" '["x","y"]'
}

@test "stealth::sys::data::yaml::set: a value with spaces -> comes back whole" {
    stealth::sys::data::yaml::set "${FILE}" engine note 'two words here'
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine note

    assert_equal "${value}" 'two words here'
}

@test "stealth::sys::data::yaml::set: a path that is not there -> the mappings are made" {
    stealth::sys::data::yaml::set "${FILE}" deep down here yes
    local value

    stealth::sys::data::yaml::read value "${FILE}" deep down here

    assert_equal "${value}" 'yes'
}

@test "stealth::sys::data::yaml::set: a place in a list -> is changed in place" {
    stealth::sys::data::yaml::set "${FILE}" engine hosts 0 z
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine hosts

    assert_equal "${value}" '["z","b"]'
}

@test "stealth::sys::data::yaml::set: a key with a dot in it -> is one step" {
    stealth::sys::data::yaml::set "${FILE}" 'a.b' value
    local names

    stealth::sys::data::yaml::keys names "${FILE}"

    assert_array_contains names 'a.b'
}

@test "stealth::sys::data::yaml::set: the rest of the document -> is left alone" {
    stealth::sys::data::yaml::set "${FILE}" engine timeout 60
    local value

    stealth::sys::data::yaml::read value "${FILE}" name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::yaml::set: no file yet -> one is made with the value in it" {
    stealth::sys::data::yaml::set "${WORK}/new.yaml" a b c
    local value

    stealth::sys::data::yaml::read value "${WORK}/new.yaml" a b

    assert_equal "${value}" 'c'
}

@test "stealth::sys::data::yaml::set: a file that is not YAML -> is left alone" {
    printf 'a:\n - b\n  c: d\n' > "${FILE}"

    run stealth::sys::data::yaml::set "${FILE}" a b
    assert_failure 1
    assert_file_contains "${FILE}" '  c: d'
}

@test "stealth::sys::data::yaml::set: no value -> exits 1" {
    run stealth::sys::data::yaml::set "${FILE}" name
    assert_refused 'a path and a value are required'
}

@test "stealth::sys::data::yaml::set: no file -> exits 1" {
    run stealth::sys::data::yaml::set '' a b
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::delete: a path -> is gone" {
    stealth::sys::data::yaml::delete "${FILE}" engine debug

    run stealth::sys::data::yaml::has "${FILE}" engine debug
    assert_failure 1
}

@test "stealth::sys::data::yaml::delete: a path -> the rest of the mapping stays" {
    stealth::sys::data::yaml::delete "${FILE}" engine debug
    local names

    stealth::sys::data::yaml::keys names "${FILE}" engine

    assert_array_equal names timeout hosts
}

@test "stealth::sys::data::yaml::delete: a path -> the comments stay" {
    stealth::sys::data::yaml::delete "${FILE}" engine debug

    assert_file_contains "${FILE}" '# how long to wait'
}

@test "stealth::sys::data::yaml::delete: a whole mapping -> goes with what was in it" {
    stealth::sys::data::yaml::delete "${FILE}" engine
    local names

    stealth::sys::data::yaml::keys names "${FILE}"

    assert_array_equal names name empty 'odd.key'
}

@test "stealth::sys::data::yaml::delete: a path that was never there -> is no trouble" {
    run stealth::sys::data::yaml::delete "${FILE}" engine nowhere
    assert_success
}

@test "stealth::sys::data::yaml::delete: no path -> exits 1" {
    run stealth::sys::data::yaml::delete "${FILE}"
    assert_refused 'a path is required'
}

@test "stealth::sys::data::yaml::delete: no such file -> exits 1" {
    run stealth::sys::data::yaml::delete "${WORK}/nowhere" a
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::merge: a key both hold -> the source wins" {
    printf 'engine:\n  timeout: 99\n' > "${WORK}/over.yaml"

    stealth::sys::data::yaml::merge "${FILE}" "${WORK}/over.yaml"
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::data::yaml::merge: a mapping in both -> keeps what only the target had" {
    printf 'engine:\n  timeout: 99\n' > "${WORK}/over.yaml"

    stealth::sys::data::yaml::merge "${FILE}" "${WORK}/over.yaml"
    local value

    stealth::sys::data::yaml::read value "${FILE}" engine debug

    assert_equal "${value}" 'false'
}

@test "stealth::sys::data::yaml::merge: a key only the source has -> is added" {
    printf 'extra: true\n' > "${WORK}/over.yaml"

    stealth::sys::data::yaml::merge "${FILE}" "${WORK}/over.yaml"
    local value

    stealth::sys::data::yaml::read value "${FILE}" extra

    assert_equal "${value}" 'true'
}

@test "stealth::sys::data::yaml::merge: the target -> keeps its comments" {
    printf 'extra: true\n' > "${WORK}/over.yaml"

    stealth::sys::data::yaml::merge "${FILE}" "${WORK}/over.yaml"

    assert_file_contains "${FILE}" '# what this machine is'
}

@test "stealth::sys::data::yaml::merge: a source that is not YAML -> the target is left alone" {
    printf 'a:\n - b\n  c: d\n' > "${WORK}/over.yaml"

    run stealth::sys::data::yaml::merge "${FILE}" "${WORK}/over.yaml"

    assert_failure 1
    local value
    stealth::sys::data::yaml::read value "${FILE}" engine timeout
    assert_equal "${value}" '30'
}

@test "stealth::sys::data::yaml::merge: no such source -> exits 1" {
    run stealth::sys::data::yaml::merge "${FILE}" "${WORK}/nowhere"
    assert_refused "no file to merge in at ${WORK}/nowhere"
}

@test "stealth::sys::data::yaml::merge: no such target -> exits 1" {
    run stealth::sys::data::yaml::merge "${WORK}/nowhere" "${FILE}"
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::is_valid: a YAML file -> returns 0" {
    run stealth::sys::data::yaml::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::yaml::is_valid: a file that is not YAML -> returns 1" {
    printf 'a:\n - b\n  c: d\n' > "${FILE}"

    run stealth::sys::data::yaml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::yaml::is_valid: a file that is not YAML -> says so" {
    printf 'a:\n - b\n  c: d\n' > "${FILE}"

    run stealth::sys::data::yaml::is_valid "${FILE}"

    assert_called_with stealth::util::log::debug '*not YAML yq will read*'
}

@test "stealth::sys::data::yaml::is_valid: an empty file -> returns 1" {
    : > "${FILE}"

    run stealth::sys::data::yaml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::yaml::is_valid: no such file -> returns 1" {
    run stealth::sys::data::yaml::is_valid "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::data::yaml::is_valid: nothing -> returns 1" {
    run stealth::sys::data::yaml::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::yaml::_as_json
# ------------------------------------------------------------------------------

@test "stealth::sys::data::yaml::_as_json: the temporary file -> does not outlive the read" {
    local before after

    stealth::sys::data::yaml::read before "${FILE}" name
    # shellcheck disable=SC2312  # the count is the answer, not the status
    after="$(find "${TMPDIR}" -name 'yaml.*.json' | wc -l)"

    assert_equal "${after}" '0'
}

# ------------------------------------------------------------------------------
# sys/data/yaml, the module itself
# ------------------------------------------------------------------------------

@test "sys/data/yaml: sourced twice -> returns before it declares anything" {
    run load_lib sys/data/yaml
    assert_success
}
