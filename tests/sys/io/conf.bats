#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/io/conf - Test Suite
# ==============================================================================
# One file of each kind is written in setup, all holding the same thing, so
# that a test can ask the same question five ways and get the same answer.
# That is the whole promise of this module, and the tests are arranged to
# make a break in it show up as five failures rather than one.
#
# The modules underneath are not mocked. What is being tested is that the
# routing reaches the right one with the right arguments, and a mock would
# accept arguments the real one refuses.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/io/conf
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"

    printf 'NAME="Fedora Linux"\ntimeout=30\n'      > "${WORK}/os-release"
    printf '[engine]\ntimeout = 30\nhost = here\n'  > "${WORK}/c.ini"
    printf '[engine]\ntimeout = 30\nhost = "here"\n' > "${WORK}/c.toml"
    printf '{"engine":{"timeout":30,"host":"here"}}' > "${WORK}/c.json"
    printf 'engine:\n  timeout: 30\n  host: here\n' > "${WORK}/c.yaml"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::kind
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::kind: a .json file -> json" {
    local format

    stealth::sys::io::conf::kind format /etc/a.json

    assert_equal "${format}" 'json'
}

@test "stealth::sys::io::conf::kind: a .yaml file -> yaml" {
    local format

    stealth::sys::io::conf::kind format /etc/a.yaml

    assert_equal "${format}" 'yaml'
}

@test "stealth::sys::io::conf::kind: a .yml file -> yaml as well" {
    local format

    stealth::sys::io::conf::kind format /etc/a.yml

    assert_equal "${format}" 'yaml'
}

@test "stealth::sys::io::conf::kind: a .toml file -> toml" {
    local format

    stealth::sys::io::conf::kind format /etc/a.toml

    assert_equal "${format}" 'toml'
}

@test "stealth::sys::io::conf::kind: a .ini file -> ini" {
    local format

    stealth::sys::io::conf::kind format /etc/a.ini

    assert_equal "${format}" 'ini'
}

@test "stealth::sys::io::conf::kind: an ending in capitals -> is the same ending" {
    local format

    stealth::sys::io::conf::kind format /etc/A.JSON

    assert_equal "${format}" 'json'
}

@test "stealth::sys::io::conf::kind: a name with no ending -> kv" {
    local format

    stealth::sys::io::conf::kind format /etc/os-release

    assert_equal "${format}" 'kv'
}

@test "stealth::sys::io::conf::kind: an ending nothing knows -> kv" {
    local format

    stealth::sys::io::conf::kind format /etc/a.rc

    assert_equal "${format}" 'kv'
}

@test "stealth::sys::io::conf::kind: a dot in a directory above -> is not the ending" {
    local format

    stealth::sys::io::conf::kind format /etc/conf.d/setting

    assert_equal "${format}" 'kv'
}

@test "stealth::sys::io::conf::kind: a file that is not there -> is still named" {
    local format

    stealth::sys::io::conf::kind format "${WORK}/nowhere.toml"

    assert_equal "${format}" 'toml'
}

@test "stealth::sys::io::conf::kind: no output variable -> exits 1" {
    run stealth::sys::io::conf::kind '' /etc/a.json
    assert_refused 'an output variable is required'
}

@test "stealth::sys::io::conf::kind: no file -> exits 1" {
    run stealth::sys::io::conf::kind format
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::read
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::read: a KEY=VALUE file -> the one key" {
    local value

    stealth::sys::io::conf::read value "${WORK}/os-release" timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::read: an INI file -> a section and a key" {
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::read: a TOML file -> a table and a key" {
    local value

    stealth::sys::io::conf::read value "${WORK}/c.toml" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::read: a JSON file -> a path" {
    local value

    stealth::sys::io::conf::read value "${WORK}/c.json" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::read: a YAML file -> a path" {
    local value

    stealth::sys::io::conf::read value "${WORK}/c.yaml" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::read: one step in an INI file -> before any section" {
    printf 'name = build\n[engine]\ntimeout = 30\n' > "${WORK}/c.ini"
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::io::conf::read: a key that is not there -> returns 1" {
    run stealth::sys::io::conf::read value "${WORK}/c.ini" engine nowhere
    assert_failure 1
}

@test "stealth::sys::io::conf::read: deeper than a flat file goes -> exits 1" {
    run stealth::sys::io::conf::read value "${WORK}/os-release" engine timeout
    assert_refused 'a kv file goes 1 deep, and this path goes 2'
}

@test "stealth::sys::io::conf::read: deeper than a sectioned file goes -> exits 1" {
    run stealth::sys::io::conf::read value "${WORK}/c.ini" a b c
    assert_refused 'a ini file goes 2 deep, and this path goes 3'
}

@test "stealth::sys::io::conf::read: as deep as a JSON file likes -> is no trouble" {
    printf '{"a":{"b":{"c":{"d":"deep"}}}}' > "${WORK}/c.json"
    local value

    stealth::sys::io::conf::read value "${WORK}/c.json" a b c d

    assert_equal "${value}" 'deep'
}

@test "stealth::sys::io::conf::read: no path -> exits 1" {
    run stealth::sys::io::conf::read value "${WORK}/c.ini"
    assert_refused 'a path is required'
}

@test "stealth::sys::io::conf::read: no such file -> exits 1" {
    run stealth::sys::io::conf::read value "${WORK}/nowhere.ini" a
    assert_refused "no file to read at ${WORK}/nowhere.ini"
}

@test "stealth::sys::io::conf::read: no output variable -> exits 1" {
    run stealth::sys::io::conf::read '' "${WORK}/c.ini" engine timeout
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::has
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::has: a key that is set -> returns 0" {
    run stealth::sys::io::conf::has "${WORK}/c.toml" engine timeout
    assert_success
}

@test "stealth::sys::io::conf::has: a key that is not -> returns 1" {
    run stealth::sys::io::conf::has "${WORK}/c.toml" engine nowhere
    assert_failure 1
}

@test "stealth::sys::io::conf::has: a KEY=VALUE file -> answers for the one key" {
    run stealth::sys::io::conf::has "${WORK}/os-release" NAME
    assert_success
}

@test "stealth::sys::io::conf::has: no path -> exits 1" {
    run stealth::sys::io::conf::has "${WORK}/c.ini"
    assert_refused 'a path is required'
}

@test "stealth::sys::io::conf::has: no such file -> exits 1" {
    run stealth::sys::io::conf::has "${WORK}/nowhere.ini" a
    assert_refused "no file to read at ${WORK}/nowhere.ini"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::keys: a KEY=VALUE file -> its keys" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/os-release"

    assert_array_equal names NAME timeout
}

@test "stealth::sys::io::conf::keys: an INI section -> its keys" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.ini" engine

    assert_array_equal names timeout host
}

@test "stealth::sys::io::conf::keys: a TOML table -> its keys" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.toml" engine

    assert_array_equal names timeout host
}

@test "stealth::sys::io::conf::keys: a JSON path -> its keys" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.json" engine

    assert_array_equal names timeout host
}

@test "stealth::sys::io::conf::keys: a YAML path -> its keys" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.yaml" engine

    assert_array_equal names timeout host
}

@test "stealth::sys::io::conf::keys: no path in an INI file -> the keys before any section" {
    printf 'name = build\n[engine]\ntimeout = 30\n' > "${WORK}/c.ini"
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.ini"

    assert_array_equal names name
}

@test "stealth::sys::io::conf::keys: no path in a JSON file -> the top of the document" {
    local names

    stealth::sys::io::conf::keys names "${WORK}/c.json"

    assert_array_equal names engine
}

@test "stealth::sys::io::conf::keys: as deep as a value in a flat file -> exits 1" {
    run stealth::sys::io::conf::keys names "${WORK}/os-release" NAME
    assert_refused 'a kv file has nothing under NAME'
}

@test "stealth::sys::io::conf::keys: as deep as a value in an INI file -> exits 1" {
    run stealth::sys::io::conf::keys names "${WORK}/c.ini" engine timeout
    assert_refused 'a ini file has nothing under engine timeout'
}

@test "stealth::sys::io::conf::keys: no output array -> exits 1" {
    run stealth::sys::io::conf::keys '' "${WORK}/c.ini"
    assert_refused 'an output array is required'
}

@test "stealth::sys::io::conf::keys: no such file -> exits 1" {
    run stealth::sys::io::conf::keys names "${WORK}/nowhere.ini"
    assert_refused "no file to read at ${WORK}/nowhere.ini"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::set
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::set: a KEY=VALUE file -> is changed" {
    stealth::sys::io::conf::set "${WORK}/os-release" timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/os-release" timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: an INI file -> is changed" {
    stealth::sys::io::conf::set "${WORK}/c.ini" engine timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: a TOML file -> is changed" {
    stealth::sys::io::conf::set "${WORK}/c.toml" engine timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/c.toml" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: a JSON file -> is changed" {
    stealth::sys::io::conf::set "${WORK}/c.json" engine timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/c.json" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: a YAML file -> is changed" {
    stealth::sys::io::conf::set "${WORK}/c.yaml" engine timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/c.yaml" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: a number in a TOML file -> stays a number" {
    stealth::sys::io::conf::set "${WORK}/c.toml" engine timeout 60
    local kind

    stealth::sys::data::toml::type kind "${WORK}/c.toml" engine timeout

    assert_equal "${kind}" 'integer'
}

@test "stealth::sys::io::conf::set: --string in a TOML file -> makes it one" {
    stealth::sys::io::conf::set "${WORK}/c.toml" --string engine timeout 60
    local kind

    stealth::sys::data::toml::type kind "${WORK}/c.toml" engine timeout

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::io::conf::set: --string in a JSON file -> makes it one" {
    stealth::sys::io::conf::set "${WORK}/c.json" --string engine timeout 60
    local kind

    stealth::sys::data::json::type kind "${WORK}/c.json" engine timeout

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::io::conf::set: --string in a YAML file -> makes it one" {
    stealth::sys::io::conf::set "${WORK}/c.yaml" --string engine timeout 60
    local kind

    stealth::sys::data::yaml::type kind "${WORK}/c.yaml" engine timeout

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::io::conf::set: --string in a file with no types -> is no trouble" {
    stealth::sys::io::conf::set "${WORK}/os-release" --string timeout 60
    local value

    stealth::sys::io::conf::read value "${WORK}/os-release" timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::io::conf::set: a key that is not there -> is added" {
    stealth::sys::io::conf::set "${WORK}/c.ini" engine retries 3
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" engine retries

    assert_equal "${value}" '3'
}

@test "stealth::sys::io::conf::set: no file yet -> one is made" {
    stealth::sys::io::conf::set "${WORK}/new.ini" engine timeout 30
    local value

    stealth::sys::io::conf::read value "${WORK}/new.ini" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::io::conf::set: deeper than a flat file goes -> exits 1" {
    run stealth::sys::io::conf::set "${WORK}/os-release" engine timeout 60
    assert_refused 'a kv file goes 1 deep, and this path goes 2'
}

@test "stealth::sys::io::conf::set: no value -> exits 1" {
    run stealth::sys::io::conf::set "${WORK}/c.ini" engine
    assert_refused 'a path and a value are required'
}

@test "stealth::sys::io::conf::set: no file -> exits 1" {
    run stealth::sys::io::conf::set '' a b
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::delete: a KEY=VALUE file -> the key goes" {
    stealth::sys::io::conf::delete "${WORK}/os-release" timeout

    run stealth::sys::io::conf::has "${WORK}/os-release" timeout
    assert_failure 1
}

@test "stealth::sys::io::conf::delete: an INI file -> the key goes" {
    stealth::sys::io::conf::delete "${WORK}/c.ini" engine timeout

    run stealth::sys::io::conf::has "${WORK}/c.ini" engine timeout
    assert_failure 1
}

@test "stealth::sys::io::conf::delete: a TOML file -> the key goes" {
    stealth::sys::io::conf::delete "${WORK}/c.toml" engine timeout

    run stealth::sys::io::conf::has "${WORK}/c.toml" engine timeout
    assert_failure 1
}

@test "stealth::sys::io::conf::delete: a JSON file -> the key goes" {
    stealth::sys::io::conf::delete "${WORK}/c.json" engine timeout

    run stealth::sys::io::conf::has "${WORK}/c.json" engine timeout
    assert_failure 1
}

@test "stealth::sys::io::conf::delete: a YAML file -> the key goes" {
    stealth::sys::io::conf::delete "${WORK}/c.yaml" engine timeout

    run stealth::sys::io::conf::has "${WORK}/c.yaml" engine timeout
    assert_failure 1
}

@test "stealth::sys::io::conf::delete: the rest of the file -> stays" {
    stealth::sys::io::conf::delete "${WORK}/c.ini" engine timeout
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" engine host

    assert_equal "${value}" 'here'
}

@test "stealth::sys::io::conf::delete: no path -> exits 1" {
    run stealth::sys::io::conf::delete "${WORK}/c.ini"
    assert_refused 'a path is required'
}

@test "stealth::sys::io::conf::delete: no such file -> exits 1" {
    run stealth::sys::io::conf::delete "${WORK}/nowhere.ini" a
    assert_refused "no file to change at ${WORK}/nowhere.ini"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::merge: two INI files -> the source wins" {
    printf '[engine]\ntimeout = 99\n' > "${WORK}/over.ini"

    stealth::sys::io::conf::merge "${WORK}/c.ini" "${WORK}/over.ini"
    local value

    stealth::sys::io::conf::read value "${WORK}/c.ini" engine timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::io::conf::merge: two JSON files -> the source wins" {
    printf '{"engine":{"timeout":99}}' > "${WORK}/over.json"

    stealth::sys::io::conf::merge "${WORK}/c.json" "${WORK}/over.json"
    local value

    stealth::sys::io::conf::read value "${WORK}/c.json" engine timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::io::conf::merge: two KEY=VALUE files -> the source wins" {
    printf 'timeout=99\n' > "${WORK}/over"

    stealth::sys::io::conf::merge "${WORK}/os-release" "${WORK}/over"
    local value

    stealth::sys::io::conf::read value "${WORK}/os-release" timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::io::conf::merge: two kinds -> exits 1" {
    run stealth::sys::io::conf::merge "${WORK}/c.ini" "${WORK}/c.json"
    assert_refused "${WORK}/c.ini is ini and ${WORK}/c.json is json, which do not merge"
}

@test "stealth::sys::io::conf::merge: no such source -> exits 1" {
    run stealth::sys::io::conf::merge "${WORK}/c.ini" "${WORK}/nowhere.ini"
    assert_refused "no file to merge in at ${WORK}/nowhere.ini"
}

@test "stealth::sys::io::conf::merge: no target -> exits 1" {
    run stealth::sys::io::conf::merge '' "${WORK}/c.ini"
    assert_refused 'a file to change is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::conf::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::io::conf::is_valid: an INI file -> returns 0" {
    run stealth::sys::io::conf::is_valid "${WORK}/c.ini"
    assert_success
}

@test "stealth::sys::io::conf::is_valid: a JSON file -> returns 0" {
    run stealth::sys::io::conf::is_valid "${WORK}/c.json"
    assert_success
}

@test "stealth::sys::io::conf::is_valid: a YAML file -> returns 0" {
    run stealth::sys::io::conf::is_valid "${WORK}/c.yaml"
    assert_success
}

@test "stealth::sys::io::conf::is_valid: JSON in a file called .json -> returns 1 when it is not" {
    printf '{oops' > "${WORK}/c.json"

    run stealth::sys::io::conf::is_valid "${WORK}/c.json"
    assert_failure 1
}

@test "stealth::sys::io::conf::is_valid: a file named for a kind it is not -> returns 1" {
    # The name says JSON, so it is read as JSON, and it is not.
    cp "${WORK}/c.ini" "${WORK}/lying.json"

    run stealth::sys::io::conf::is_valid "${WORK}/lying.json"
    assert_failure 1
}

@test "stealth::sys::io::conf::is_valid: no such file -> returns 1" {
    run stealth::sys::io::conf::is_valid "${WORK}/nowhere.ini"
    assert_failure 1
}

@test "stealth::sys::io::conf::is_valid: nothing -> returns 1" {
    run stealth::sys::io::conf::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/io/conf, the module itself
# ------------------------------------------------------------------------------

@test "sys/io/conf: sourced twice -> returns before it declares anything" {
    run load_lib sys/io/conf
    assert_success
}
