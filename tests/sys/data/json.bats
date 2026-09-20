#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/data/json - Test Suite
# ==============================================================================
# The fixture holds a value of every JSON kind, a key set to null, and a key
# with a dot in its name. The last two are what a reader of one of these gets
# wrong: null reads the same as absent, and a dotted key read as a path is a
# different key.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/data/json
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    FILE="${WORK}/config.json"

    cat > "${FILE}" <<'EOF'
{
  "name": "build",
  "engine": {
    "timeout": 30,
    "debug": false,
    "ratio": 1.5,
    "hosts": ["a", "b"],
    "assets": [{"name": "tool-linux-amd64.tar.gz"}, {"name": "tool-linux-arm64.tar.gz"}],
    "extra": {"nested": 1}
  },
  "empty": null,
  "odd.key": "dotted",
  "numeric": {"0": "a key that looks like an index"}
}
EOF
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::read
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::read: a string -> comes back without its quotes" {
    local value

    stealth::sys::data::json::read value "${FILE}" name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::json::read: a number -> comes back as it is" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::data::json::read: a boolean -> comes back as it is" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine debug

    assert_equal "${value}" 'false'
}

@test "stealth::sys::data::json::read: an array -> comes back on one line" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine hosts

    assert_equal "${value}" '["a","b"]'
}

@test "stealth::sys::data::json::read: an object -> comes back on one line" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine extra

    assert_equal "${value}" '{"nested":1}'
}

@test "stealth::sys::data::json::read: a step into an array -> is an index" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine hosts 1

    assert_equal "${value}" 'b'
}

@test "stealth::sys::data::json::read: a step into an array of objects -> goes through it" {
    local value

    stealth::sys::data::json::read value "${FILE}" engine assets 0 name

    assert_equal "${value}" 'tool-linux-amd64.tar.gz'
}

@test "stealth::sys::data::json::read: a key that looks like an index -> is still a key" {
    # An object with the key "0" and an array indexed by 0 both answer for
    # the step 0, each in its own way.
    local value

    stealth::sys::data::json::read value "${FILE}" numeric 0

    assert_equal "${value}" 'a key that looks like an index'
}

@test "stealth::sys::data::json::read: an index past the end -> returns 1" {
    run stealth::sys::data::json::read value "${FILE}" engine hosts 9
    assert_failure 1
}

@test "stealth::sys::data::json::read: a name where an array wants an index -> returns 1" {
    run stealth::sys::data::json::read value "${FILE}" engine hosts first
    assert_failure 1
}

@test "stealth::sys::data::json::read: a key with a dot in it -> is one step, not two" {
    local value

    stealth::sys::data::json::read value "${FILE}" 'odd.key'

    assert_equal "${value}" 'dotted'
}

@test "stealth::sys::data::json::read: a key set to null -> comes back as null" {
    local value

    stealth::sys::data::json::read value "${FILE}" empty

    assert_equal "${value}" 'null'
}

@test "stealth::sys::data::json::read: deeper than the document goes -> returns 1" {
    run stealth::sys::data::json::read value "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::json::read: a path that is not there and a default -> the default" {
    local value

    stealth::sys::data::json::read value "${FILE}" --default 60 engine nowhere

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::json::read: through something that is not an object -> returns 1" {
    run stealth::sys::data::json::read value "${FILE}" name deeper
    assert_failure 1
}

@test "stealth::sys::data::json::read: no such file -> exits 1" {
    run stealth::sys::data::json::read value "${WORK}/nowhere" name
    assert_refused "no file to read at ${WORK}/nowhere"
}

@test "stealth::sys::data::json::read: no path -> exits 1" {
    run stealth::sys::data::json::read value "${FILE}"
    assert_refused 'a path is required'
}

@test "stealth::sys::data::json::read: no output variable -> exits 1" {
    run stealth::sys::data::json::read '' "${FILE}" name
    assert_refused 'an output variable is required'
}

@test "stealth::sys::data::json::read: --default with nothing after it -> exits 1" {
    run stealth::sys::data::json::read value "${FILE}" --default
    assert_refused '--default takes a value'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::has
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::has: a path that is there -> returns 0" {
    run stealth::sys::data::json::has "${FILE}" engine timeout
    assert_success
}

@test "stealth::sys::data::json::has: a key set to null -> returns 0" {
    # Null is a value. A reader that cannot tell it from absent gives the
    # default for a key somebody set on purpose.
    run stealth::sys::data::json::has "${FILE}" empty
    assert_success
}

@test "stealth::sys::data::json::has: an index the array is long enough for -> returns 0" {
    run stealth::sys::data::json::has "${FILE}" engine hosts 1
    assert_success
}

@test "stealth::sys::data::json::has: an index past the end -> returns 1" {
    run stealth::sys::data::json::has "${FILE}" engine hosts 2
    assert_failure 1
}

@test "stealth::sys::data::json::has: a path that is not there -> returns 1" {
    run stealth::sys::data::json::has "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::json::has: through something that is not an object -> returns 1" {
    run stealth::sys::data::json::has "${FILE}" name deeper
    assert_failure 1
}

@test "stealth::sys::data::json::has: a file that is not JSON -> returns 1" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::has "${FILE}" name
    assert_failure 1
}

@test "stealth::sys::data::json::has: no path -> exits 1" {
    run stealth::sys::data::json::has "${FILE}"
    assert_refused 'a path is required'
}

@test "stealth::sys::data::json::has: no such file -> exits 1" {
    run stealth::sys::data::json::has "${WORK}/nowhere" name
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::keys: the document -> its keys in the order written" {
    local names

    stealth::sys::data::json::keys names "${FILE}"

    assert_array_equal names name engine empty 'odd.key' numeric
}

@test "stealth::sys::data::json::keys: a path -> that object's keys" {
    local names

    stealth::sys::data::json::keys names "${FILE}" engine

    assert_array_equal names timeout debug ratio hosts assets extra
}

@test "stealth::sys::data::json::keys: something that is not an object -> an empty array" {
    local names

    stealth::sys::data::json::keys names "${FILE}" engine hosts

    assert_array_empty names
}

@test "stealth::sys::data::json::keys: a file that is not JSON -> returns 1" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::keys names "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::json::keys: no output array -> exits 1" {
    run stealth::sys::data::json::keys '' "${FILE}"
    assert_refused 'an output array is required'
}

@test "stealth::sys::data::json::keys: no such file -> exits 1" {
    run stealth::sys::data::json::keys names "${WORK}/nowhere"
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::load
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::load: an object -> everything in it" {
    local -A engine=()

    stealth::sys::data::json::load engine "${FILE}" engine

    assert_equal "${engine[timeout]}" '30'
    assert_equal "${engine[debug]}" 'false'
    assert_array_length engine 6
}

@test "stealth::sys::data::json::load: a value that is not a scalar -> comes back as JSON" {
    local -A engine=()

    stealth::sys::data::json::load engine "${FILE}" engine

    assert_equal "${engine[hosts]}" '["a","b"]'
    assert_equal "${engine[extra]}" '{"nested":1}'
}

@test "stealth::sys::data::json::load: a string -> comes back without its quotes" {
    local -A top=()

    stealth::sys::data::json::load top "${FILE}"

    assert_equal "${top[name]}" 'build'
}

@test "stealth::sys::data::json::load: an array with something in it -> is emptied first" {
    local -A engine=([stale]=yes)

    stealth::sys::data::json::load engine "${FILE}" engine

    refute_array_has_key engine stale
}

@test "stealth::sys::data::json::load: something that is not an object -> an empty array" {
    local -A out=()

    stealth::sys::data::json::load out "${FILE}" engine hosts

    assert_array_empty out
}

@test "stealth::sys::data::json::load: a file that is not JSON -> returns 1" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::load out "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::json::load: no output array -> exits 1" {
    run stealth::sys::data::json::load '' "${FILE}"
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::type
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::type: a string -> string" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" name

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::json::type: a number -> number" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'number'
}

@test "stealth::sys::data::json::type: a boolean -> boolean" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine debug

    assert_equal "${kind}" 'boolean'
}

@test "stealth::sys::data::json::type: an array -> array" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine hosts

    assert_equal "${kind}" 'array'
}

@test "stealth::sys::data::json::type: an object -> object" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine

    assert_equal "${kind}" 'object'
}

@test "stealth::sys::data::json::type: a key set to null -> null" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" empty

    assert_equal "${kind}" 'null'
}

@test "stealth::sys::data::json::type: something inside an array -> its own kind" {
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine assets 0

    assert_equal "${kind}" 'object'
}

@test "stealth::sys::data::json::type: a path that is not there -> returns 1" {
    run stealth::sys::data::json::type kind "${FILE}" engine nowhere
    assert_failure 1
}

@test "stealth::sys::data::json::type: no output variable -> exits 1" {
    run stealth::sys::data::json::type '' "${FILE}" name
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::set
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::set: a path that is there -> is changed" {
    stealth::sys::data::json::set "${FILE}" engine timeout 60
    local value

    stealth::sys::data::json::read value "${FILE}" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::json::set: a number -> goes in as one" {
    stealth::sys::data::json::set "${FILE}" engine timeout 60
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'number'
}

@test "stealth::sys::data::json::set: a word -> goes in as a string" {
    stealth::sys::data::json::set "${FILE}" engine mode fast
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine mode

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::json::set: true -> goes in as a boolean" {
    stealth::sys::data::json::set "${FILE}" engine debug true
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine debug

    assert_equal "${kind}" 'boolean'
}

@test "stealth::sys::data::json::set: --string -> a number goes in as a string" {
    stealth::sys::data::json::set "${FILE}" --string engine port 8080
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine port

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::json::set: --json -> goes in as what it parses to" {
    stealth::sys::data::json::set "${FILE}" --json engine hosts '["x","y"]'
    local value

    stealth::sys::data::json::read value "${FILE}" engine hosts

    assert_equal "${value}" '["x","y"]'
}

@test "stealth::sys::data::json::set: --json given something that is not -> exits 1" {
    run stealth::sys::data::json::set "${FILE}" --json engine hosts 'not json'
    assert_refused '--json was given not json, which is not JSON'
}

@test "stealth::sys::data::json::set: a value with spaces -> comes back whole" {
    stealth::sys::data::json::set "${FILE}" engine note 'two words here'
    local value

    stealth::sys::data::json::read value "${FILE}" engine note

    assert_equal "${value}" 'two words here'
}

@test "stealth::sys::data::json::set: a value with a quote in it -> comes back whole" {
    stealth::sys::data::json::set "${FILE}" engine said 'she said "no"'
    local value

    stealth::sys::data::json::read value "${FILE}" engine said

    assert_equal "${value}" 'she said "no"'
}

@test "stealth::sys::data::json::set: a place in an array -> is changed in place" {
    stealth::sys::data::json::set "${FILE}" engine hosts 0 z
    local value

    stealth::sys::data::json::read value "${FILE}" engine hosts

    assert_equal "${value}" '["z","b"]'
}

@test "stealth::sys::data::json::set: a key that looks like an index -> is still a key" {
    stealth::sys::data::json::set "${FILE}" numeric 0 changed
    local value

    stealth::sys::data::json::read value "${FILE}" numeric 0

    assert_equal "${value}" 'changed'
}

@test "stealth::sys::data::json::set: a path that is not there -> the objects are made" {
    stealth::sys::data::json::set "${FILE}" deep down here yes
    local value

    stealth::sys::data::json::read value "${FILE}" deep down here

    assert_equal "${value}" 'yes'
}

@test "stealth::sys::data::json::set: a key with a dot in it -> is one step" {
    stealth::sys::data::json::set "${FILE}" 'a.b' value
    local names

    stealth::sys::data::json::keys names "${FILE}"

    assert_array_contains names 'a.b'
}

@test "stealth::sys::data::json::set: the rest of the document -> is left alone" {
    stealth::sys::data::json::set "${FILE}" engine timeout 60
    local value

    stealth::sys::data::json::read value "${FILE}" name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::json::set: no file yet -> one is made with the value in it" {
    stealth::sys::data::json::set "${WORK}/new.json" a b c
    local value

    stealth::sys::data::json::read value "${WORK}/new.json" a b

    assert_equal "${value}" 'c'
}

@test "stealth::sys::data::json::set: a file that is not JSON -> is left alone" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::set "${FILE}" a b
    assert_failure 1
    assert_file_contains "${FILE}" '{oops'
}

@test "stealth::sys::data::json::set: no value -> exits 1" {
    run stealth::sys::data::json::set "${FILE}" name
    assert_refused 'a path and a value are required'
}

@test "stealth::sys::data::json::set: no file -> exits 1" {
    run stealth::sys::data::json::set '' a b
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::delete: a path -> is gone" {
    stealth::sys::data::json::delete "${FILE}" engine debug

    run stealth::sys::data::json::has "${FILE}" engine debug
    assert_failure 1
}

@test "stealth::sys::data::json::delete: a path -> the rest of the object stays" {
    stealth::sys::data::json::delete "${FILE}" engine debug
    local names

    stealth::sys::data::json::keys names "${FILE}" engine

    assert_array_equal names timeout ratio hosts assets extra
}

@test "stealth::sys::data::json::delete: a whole object -> goes with what was in it" {
    stealth::sys::data::json::delete "${FILE}" engine
    local names

    stealth::sys::data::json::keys names "${FILE}"

    assert_array_equal names name empty 'odd.key' numeric
}

@test "stealth::sys::data::json::delete: a key set to null -> is gone" {
    stealth::sys::data::json::delete "${FILE}" empty

    run stealth::sys::data::json::has "${FILE}" empty
    assert_failure 1
}

@test "stealth::sys::data::json::delete: an element of an array -> the array gets shorter" {
    stealth::sys::data::json::delete "${FILE}" engine hosts 0
    local value

    stealth::sys::data::json::read value "${FILE}" engine hosts

    assert_equal "${value}" '["b"]'
}

@test "stealth::sys::data::json::delete: a path that was never there -> is no trouble" {
    run stealth::sys::data::json::delete "${FILE}" engine nowhere
    assert_success
}

@test "stealth::sys::data::json::delete: no path -> exits 1" {
    run stealth::sys::data::json::delete "${FILE}"
    assert_refused 'a path is required'
}

@test "stealth::sys::data::json::delete: no such file -> exits 1" {
    run stealth::sys::data::json::delete "${WORK}/nowhere" a
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::length
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::length: an array -> how many elements" {
    local count

    stealth::sys::data::json::length count "${FILE}" engine hosts

    assert_equal "${count}" '2'
}

@test "stealth::sys::data::json::length: an object -> how many keys" {
    local count

    stealth::sys::data::json::length count "${FILE}" engine extra

    assert_equal "${count}" '1'
}

@test "stealth::sys::data::json::length: a string -> how many characters" {
    local count

    stealth::sys::data::json::length count "${FILE}" name

    assert_equal "${count}" '5'
}

@test "stealth::sys::data::json::length: the whole document -> how many keys" {
    local count

    stealth::sys::data::json::length count "${FILE}"

    assert_equal "${count}" '5'
}

@test "stealth::sys::data::json::length: an array -> is walkable from bash with read" {
    # This is what makes finding a release asset possible without handing a
    # pattern to jq as part of a program.
    local count name found=''

    stealth::sys::data::json::length count "${FILE}" engine assets
    local -i at=0
    while (( at < count )); do
        stealth::sys::data::json::read name "${FILE}" engine assets "${at}" name
        if [[ "${name}" == *arm64* ]]; then
            found="${name}"
        fi
        at=$(( at + 1 ))
    done

    assert_equal "${found}" 'tool-linux-arm64.tar.gz'
}

@test "stealth::sys::data::json::length: a number -> returns 1" {
    run stealth::sys::data::json::length count "${FILE}" engine timeout
    assert_failure 1
}

@test "stealth::sys::data::json::length: a path that is not there -> returns 1" {
    run stealth::sys::data::json::length count "${FILE}" nowhere
    assert_failure 1
}

@test "stealth::sys::data::json::length: a file that is not JSON -> returns 1" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::length count "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::json::length: no output variable -> exits 1" {
    run stealth::sys::data::json::length '' "${FILE}"
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::merge: a key both hold -> the source wins" {
    printf '{"engine":{"timeout":99}}' > "${WORK}/over.json"

    stealth::sys::data::json::merge "${FILE}" "${WORK}/over.json"
    local value

    stealth::sys::data::json::read value "${FILE}" engine timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::data::json::merge: an object in both -> keeps what only the target had" {
    printf '{"engine":{"timeout":99}}' > "${WORK}/over.json"

    stealth::sys::data::json::merge "${FILE}" "${WORK}/over.json"
    local value

    stealth::sys::data::json::read value "${FILE}" engine debug

    assert_equal "${value}" 'false'
}

@test "stealth::sys::data::json::merge: a key only the source has -> is added" {
    printf '{"extra":true}' > "${WORK}/over.json"

    stealth::sys::data::json::merge "${FILE}" "${WORK}/over.json"
    local value

    stealth::sys::data::json::read value "${FILE}" extra

    assert_equal "${value}" 'true'
}

@test "stealth::sys::data::json::merge: a source that is not JSON -> the target is left alone" {
    printf '{oops' > "${WORK}/over.json"

    run stealth::sys::data::json::merge "${FILE}" "${WORK}/over.json"

    assert_failure 1
    local value
    stealth::sys::data::json::read value "${FILE}" engine timeout
    assert_equal "${value}" '30'
}

@test "stealth::sys::data::json::merge: no such source -> exits 1" {
    run stealth::sys::data::json::merge "${FILE}" "${WORK}/nowhere"
    assert_refused "no file to merge in at ${WORK}/nowhere"
}

@test "stealth::sys::data::json::merge: no such target -> exits 1" {
    run stealth::sys::data::json::merge "${WORK}/nowhere" "${FILE}"
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::is_valid: a JSON file -> returns 0" {
    run stealth::sys::data::json::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::json::is_valid: a file that is not JSON -> returns 1" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::json::is_valid: a file that is not JSON -> says so" {
    printf '{oops' > "${FILE}"

    run stealth::sys::data::json::is_valid "${FILE}"

    assert_called_with stealth::util::log::debug '*not JSON jq will read*'
}

@test "stealth::sys::data::json::is_valid: an empty file -> returns 1" {
    : > "${FILE}"

    run stealth::sys::data::json::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::json::is_valid: no such file -> returns 1" {
    run stealth::sys::data::json::is_valid "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::data::json::is_valid: nothing -> returns 1" {
    run stealth::sys::data::json::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::json::_encode
# ------------------------------------------------------------------------------

@test "stealth::sys::data::json::_encode: an empty value -> goes in as an empty string" {
    stealth::sys::data::json::set "${FILE}" engine note ''
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine note

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::json::_encode: null written out -> goes in as null" {
    stealth::sys::data::json::set "${FILE}" engine note null
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine note

    assert_equal "${kind}" 'null'
}

@test "stealth::sys::data::json::_encode: --string and null -> goes in as a string" {
    stealth::sys::data::json::set "${FILE}" --string engine note null
    local kind

    stealth::sys::data::json::type kind "${FILE}" engine note

    assert_equal "${kind}" 'string'
}

# ------------------------------------------------------------------------------
# sys/data/json, the module itself
# ------------------------------------------------------------------------------

@test "sys/data/json: sourced twice -> returns before it declares anything" {
    run load_lib sys/data/json
    assert_success
}
