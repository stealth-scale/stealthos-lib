#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/data/toml - Test Suite
# ==============================================================================
# The fixture holds one value of each kind the subset covers, a comment, a
# dotted table name, and an array written across several lines, because those
# are the four things a reader of one of these gets wrong.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/data/toml
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    FILE="${WORK}/config.toml"

    cat > "${FILE}" <<'EOF'
name = "build"
# what this machine runs

[engine]
timeout = 30
debug = false
ratio = 1.5
label = "a # not a comment"
hosts = [
  "one",
  "two",
]

[engine.runtime]
kind = "crun"
EOF
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::read
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::read: a string -> comes back without its quotes" {
    local value

    stealth::sys::data::toml::read value "${FILE}" '' name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::toml::read: a number -> comes back as it is" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::data::toml::read: a boolean -> comes back as it is" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine debug

    assert_equal "${value}" 'false'
}

@test "stealth::sys::data::toml::read: a dotted table -> is its own table" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine.runtime kind

    assert_equal "${value}" 'crun'
}

@test "stealth::sys::data::toml::read: a hash inside a string -> is part of it" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine label

    assert_equal "${value}" 'a # not a comment'
}

@test "stealth::sys::data::toml::read: a comment after a value -> is not part of it" {
    printf '[a]\nport = 8080  # the listener\n' > "${FILE}"
    local value

    stealth::sys::data::toml::read value "${FILE}" a port

    assert_equal "${value}" '8080'
}

@test "stealth::sys::data::toml::read: a literal string -> keeps its backslashes" {
    printf "[a]\npath = 'C:\\\\tmp'\n" > "${FILE}"
    local value

    stealth::sys::data::toml::read value "${FILE}" a path

    assert_equal "${value}" 'C:\tmp'
}

@test "stealth::sys::data::toml::read: an escape in a basic string -> is undone" {
    printf '[a]\nsaid = "she said \\"no\\""\n' > "${FILE}"
    local value

    stealth::sys::data::toml::read value "${FILE}" a said

    assert_equal "${value}" 'she said "no"'
}

@test "stealth::sys::data::toml::read: an array across several lines -> comes back whole" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine hosts

    assert_contains "${value}" 'one'
    assert_contains "${value}" 'two'
    assert_starts_with "${value}" '['
    assert_ends_with "${value}" ']'
}

@test "stealth::sys::data::toml::read: a key that is not there -> returns 1" {
    run stealth::sys::data::toml::read value "${FILE}" engine nothing
    assert_failure 1
}

@test "stealth::sys::data::toml::read: a key that is not there and a default -> the default" {
    local value

    stealth::sys::data::toml::read value "${FILE}" engine nothing 'fallback'

    assert_equal "${value}" 'fallback'
}

@test "stealth::sys::data::toml::read: a table that is not there -> returns 1" {
    run stealth::sys::data::toml::read value "${FILE}" nowhere timeout
    assert_failure 1
}

@test "stealth::sys::data::toml::read: a key set twice -> the last wins" {
    printf '[a]\nport = 1\nport = 2\n' > "${FILE}"
    local value

    stealth::sys::data::toml::read value "${FILE}" a port

    assert_equal "${value}" '2'
}

@test "stealth::sys::data::toml::read: no such file -> exits 1" {
    run stealth::sys::data::toml::read value "${WORK}/nowhere" a b
    assert_refused "no file to read at ${WORK}/nowhere"
}

@test "stealth::sys::data::toml::read: no key -> exits 1" {
    run stealth::sys::data::toml::read value "${FILE}" engine
    assert_refused 'a key is required'
}

@test "stealth::sys::data::toml::read: no output variable -> exits 1" {
    run stealth::sys::data::toml::read '' "${FILE}" engine timeout
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::has
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::has: a key that is set -> returns 0" {
    run stealth::sys::data::toml::has "${FILE}" engine timeout
    assert_success
}

@test "stealth::sys::data::toml::has: a key that is not -> returns 1" {
    run stealth::sys::data::toml::has "${FILE}" engine nothing
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::has_table
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::has_table: a table that is there -> returns 0" {
    run stealth::sys::data::toml::has_table "${FILE}" engine
    assert_success
}

@test "stealth::sys::data::toml::has_table: a dotted one -> returns 0" {
    run stealth::sys::data::toml::has_table "${FILE}" engine.runtime
    assert_success
}

@test "stealth::sys::data::toml::has_table: a table that is not -> returns 1" {
    run stealth::sys::data::toml::has_table "${FILE}" nowhere
    assert_failure 1
}

@test "stealth::sys::data::toml::has_table: no such file -> exits 1" {
    run stealth::sys::data::toml::has_table "${WORK}/nowhere" a
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::tables
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::tables: a file -> them in the order they open" {
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_equal names engine engine.runtime
}

@test "stealth::sys::data::toml::tables: a table opened twice -> comes back once" {
    printf '[a]\nx = 1\n[b]\ny = 2\n[a]\nz = 3\n' > "${FILE}"
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_equal names a b
}

@test "stealth::sys::data::toml::tables: an array of tables -> is not listed" {
    printf '[a]\nx = 1\n[[registry]]\nlocation = "x"\n' > "${FILE}"
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_equal names a
}

@test "stealth::sys::data::toml::tables: a file with none -> an empty array" {
    printf 'name = "build"\n' > "${FILE}"
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_empty names
}

@test "stealth::sys::data::toml::tables: no output array -> exits 1" {
    run stealth::sys::data::toml::tables '' "${FILE}"
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::keys: a table -> its keys in order" {
    local names

    stealth::sys::data::toml::keys names "${FILE}" engine

    assert_array_equal names timeout debug ratio label hosts
}

@test "stealth::sys::data::toml::keys: the keys before any table -> come back for the empty name" {
    local names

    stealth::sys::data::toml::keys names "${FILE}" ''

    assert_array_equal names name
}

@test "stealth::sys::data::toml::keys: a key set twice -> comes back once" {
    printf '[a]\nport = 1\nport = 2\n' > "${FILE}"
    local names

    stealth::sys::data::toml::keys names "${FILE}" a

    assert_array_equal names port
}

@test "stealth::sys::data::toml::keys: lines inside an array -> are not taken for keys" {
    printf '[a]\nhosts = [\n  "x = 1",\n]\n' > "${FILE}"
    local names

    stealth::sys::data::toml::keys names "${FILE}" a

    assert_array_equal names hosts
}

@test "stealth::sys::data::toml::keys: a quoted key -> is not part of the subset" {
    printf '[a]\n"quoted key" = 1\nplain = 2\n' > "${FILE}"
    local names

    stealth::sys::data::toml::keys names "${FILE}" a

    assert_array_equal names plain
}

@test "stealth::sys::data::toml::keys: an array of tables -> sets no key" {
    printf '[a]\nplain = 2\n[[registry]]\nlocation = "x"\n' > "${FILE}"
    local names

    stealth::sys::data::toml::keys names "${FILE}" a

    assert_array_equal names plain
}

@test "stealth::sys::data::toml::keys: a bracket that never closes -> sets no key" {
    printf '[a]\nplain = 2\n[unclosed\n' > "${FILE}"
    local names

    stealth::sys::data::toml::keys names "${FILE}" a

    assert_array_equal names plain
}

@test "stealth::sys::data::toml::keys: a table that is not there -> an empty array" {
    local names

    stealth::sys::data::toml::keys names "${FILE}" nowhere

    assert_array_empty names
}

@test "stealth::sys::data::toml::keys: no output array -> exits 1" {
    run stealth::sys::data::toml::keys '' "${FILE}" engine
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::load
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::load: a table -> everything in it" {
    local -A engine=()

    stealth::sys::data::toml::load engine "${FILE}" engine

    assert_equal "${engine[timeout]}" '30'
    assert_equal "${engine[debug]}" 'false'
    assert_array_length engine 5
}

@test "stealth::sys::data::toml::load: a dotted table -> is not part of its parent" {
    local -A engine=()

    stealth::sys::data::toml::load engine "${FILE}" engine

    refute_array_has_key engine kind
}

@test "stealth::sys::data::toml::load: an array with something in it -> is emptied first" {
    local -A engine=([stale]=yes)

    stealth::sys::data::toml::load engine "${FILE}" engine

    refute_array_has_key engine stale
}

@test "stealth::sys::data::toml::load: no output array -> exits 1" {
    run stealth::sys::data::toml::load '' "${FILE}" engine
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::type
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::type: a quoted value -> string" {
    local kind

    stealth::sys::data::toml::type kind "${FILE}" '' name

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::toml::type: a whole number -> integer" {
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'integer'
}

@test "stealth::sys::data::toml::type: a number with a point -> float" {
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine ratio

    assert_equal "${kind}" 'float'
}

@test "stealth::sys::data::toml::type: true or false -> boolean" {
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine debug

    assert_equal "${kind}" 'boolean'
}

@test "stealth::sys::data::toml::type: an array across several lines -> array" {
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine hosts

    assert_equal "${kind}" 'array'
}

@test "stealth::sys::data::toml::type: an inline table -> table" {
    printf '[a]\npoint = { x = 1, y = 2 }\n' > "${FILE}"
    local kind

    stealth::sys::data::toml::type kind "${FILE}" a point

    assert_equal "${kind}" 'table'
}

@test "stealth::sys::data::toml::type: a number written as a string -> string" {
    printf '[a]\nport = "8080"\n' > "${FILE}"
    local kind

    stealth::sys::data::toml::type kind "${FILE}" a port

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::toml::type: a key that is not there -> returns 1" {
    run stealth::sys::data::toml::type kind "${FILE}" engine nothing
    assert_failure 1
}

@test "stealth::sys::data::toml::type: no output variable -> exits 1" {
    run stealth::sys::data::toml::type '' "${FILE}" engine timeout
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::set
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::set: a key that is there -> is changed" {
    stealth::sys::data::toml::set "${FILE}" engine timeout 60
    local value

    stealth::sys::data::toml::read value "${FILE}" engine timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::toml::set: a number -> goes in without quotes" {
    stealth::sys::data::toml::set "${FILE}" engine timeout 60
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'integer'
}

@test "stealth::sys::data::toml::set: a word -> goes in with quotes" {
    stealth::sys::data::toml::set "${FILE}" engine mode fast

    assert_file_contains "${FILE}" 'mode = "fast"'
}

@test "stealth::sys::data::toml::set: true -> goes in as a boolean" {
    stealth::sys::data::toml::set "${FILE}" engine debug true
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine debug

    assert_equal "${kind}" 'boolean'
}

@test "stealth::sys::data::toml::set: --string -> a number goes in as one" {
    stealth::sys::data::toml::set "${FILE}" engine port 8080 --string
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine port

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::toml::set: --raw -> goes in exactly as written" {
    stealth::sys::data::toml::set "${FILE}" engine hosts '["a", "b"]' --raw
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine hosts

    assert_equal "${kind}" 'array'
}

@test "stealth::sys::data::toml::set: an array written out -> is recognised without --raw" {
    stealth::sys::data::toml::set "${FILE}" engine hosts '["a", "b"]'
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine hosts

    assert_equal "${kind}" 'array'
}

@test "stealth::sys::data::toml::set: a quote in a value -> is escaped" {
    stealth::sys::data::toml::set "${FILE}" engine said 'she said "no"'
    local value

    stealth::sys::data::toml::read value "${FILE}" engine said

    assert_equal "${value}" 'she said "no"'
}

@test "stealth::sys::data::toml::set: a change -> the comments stay" {
    stealth::sys::data::toml::set "${FILE}" engine timeout 60

    assert_file_contains "${FILE}" '# what this machine runs'
}

@test "stealth::sys::data::toml::set: a new key -> goes at the end of its own table" {
    stealth::sys::data::toml::set "${FILE}" engine mode fast
    local names

    stealth::sys::data::toml::keys names "${FILE}" engine

    assert_equal "${names[-1]}" 'mode'
}

@test "stealth::sys::data::toml::set: a new key -> does not land in the next table" {
    stealth::sys::data::toml::set "${FILE}" engine mode fast
    local names

    stealth::sys::data::toml::keys names "${FILE}" engine.runtime

    assert_array_equal names kind
}

@test "stealth::sys::data::toml::set: a new key in the last table -> goes at the end of it" {
    stealth::sys::data::toml::set "${FILE}" engine.runtime path /usr/bin/crun
    local names

    stealth::sys::data::toml::keys names "${FILE}" engine.runtime

    assert_array_equal names kind path
}

@test "stealth::sys::data::toml::set: a new table -> is opened at the end" {
    stealth::sys::data::toml::set "${FILE}" boot loader systemd-boot
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_equal names engine engine.runtime boot
}

@test "stealth::sys::data::toml::set: a key before any table -> goes at the top" {
    printf '[a]\nx = 1\n' > "${FILE}"

    stealth::sys::data::toml::set "${FILE}" '' name build
    local value

    stealth::sys::data::toml::read value "${FILE}" '' name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::toml::set: a key whose value spans lines -> the old lines go" {
    stealth::sys::data::toml::set "${FILE}" engine hosts '["three"]'

    refute_file_contains "${FILE}" '"one",'
    refute_file_contains "${FILE}" '"two",'
}

@test "stealth::sys::data::toml::set: no file yet -> one is made with the key in it" {
    stealth::sys::data::toml::set "${WORK}/new.toml" a b c
    local value

    stealth::sys::data::toml::read value "${WORK}/new.toml" a b

    assert_equal "${value}" 'c'
}

@test "stealth::sys::data::toml::set: a key with a space in it -> exits 1" {
    run stealth::sys::data::toml::set "${FILE}" a 'a b' value
    assert_refused 'a b is not a key this file can hold'
}

@test "stealth::sys::data::toml::set: a table with a bracket -> exits 1" {
    run stealth::sys::data::toml::set "${FILE}" 'a]b' key value
    assert_refused 'a]b is not a table name this file can hold'
}

@test "stealth::sys::data::toml::set: an option it does not take -> exits 1" {
    run stealth::sys::data::toml::set "${FILE}" a b c --number
    assert_refused 'set does not take --number'
}

@test "stealth::sys::data::toml::set: no key -> exits 1" {
    run stealth::sys::data::toml::set "${FILE}" engine
    assert_refused 'a key is required'
}

@test "stealth::sys::data::toml::set: no file -> exits 1" {
    run stealth::sys::data::toml::set '' a b c
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::delete: a key -> is gone" {
    stealth::sys::data::toml::delete "${FILE}" engine timeout

    run stealth::sys::data::toml::has "${FILE}" engine timeout
    assert_failure 1
}

@test "stealth::sys::data::toml::delete: a key -> the rest of the table stays" {
    stealth::sys::data::toml::delete "${FILE}" engine timeout
    local names

    stealth::sys::data::toml::keys names "${FILE}" engine

    assert_array_equal names debug ratio label hosts
}

@test "stealth::sys::data::toml::delete: a key whose value spans lines -> all of it goes" {
    stealth::sys::data::toml::delete "${FILE}" engine hosts

    refute_file_contains "${FILE}" '"one",'
    refute_file_contains "${FILE}" '"two",'
}

@test "stealth::sys::data::toml::delete: a key -> the comments stay" {
    stealth::sys::data::toml::delete "${FILE}" engine timeout

    assert_file_contains "${FILE}" '# what this machine runs'
}

@test "stealth::sys::data::toml::delete: a key that was never there -> is no trouble" {
    run stealth::sys::data::toml::delete "${FILE}" engine nothing
    assert_success
}

@test "stealth::sys::data::toml::delete: the only line of the file -> leaves it empty" {
    printf 'x = 1\n' > "${FILE}"

    stealth::sys::data::toml::delete "${FILE}" '' x

    assert_file_empty "${FILE}"
}

@test "stealth::sys::data::toml::delete: no such file -> exits 1" {
    run stealth::sys::data::toml::delete "${WORK}/nowhere" a b
    assert_refused "no file to change at ${WORK}/nowhere"
}

@test "stealth::sys::data::toml::delete: no key -> exits 1" {
    run stealth::sys::data::toml::delete "${FILE}" engine
    assert_refused 'a key is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::delete_table
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::delete_table: a table -> is gone" {
    stealth::sys::data::toml::delete_table "${FILE}" engine.runtime

    run stealth::sys::data::toml::has_table "${FILE}" engine.runtime
    assert_failure 1
}

@test "stealth::sys::data::toml::delete_table: a table -> what was in it goes too" {
    stealth::sys::data::toml::delete_table "${FILE}" engine.runtime

    refute_file_contains "${FILE}" 'kind = "crun"'
}

@test "stealth::sys::data::toml::delete_table: a parent -> its child is a table of its own" {
    stealth::sys::data::toml::delete_table "${FILE}" engine
    local names

    stealth::sys::data::toml::tables names "${FILE}"

    assert_array_equal names engine.runtime
}

@test "stealth::sys::data::toml::delete_table: a table that was never there -> is no trouble" {
    run stealth::sys::data::toml::delete_table "${FILE}" nowhere
    assert_success
}

@test "stealth::sys::data::toml::delete_table: the only table -> leaves an empty file" {
    printf '[a]\nx = 1\n' > "${FILE}"

    stealth::sys::data::toml::delete_table "${FILE}" a

    assert_file_empty "${FILE}"
}

@test "stealth::sys::data::toml::delete_table: no table -> exits 1" {
    run stealth::sys::data::toml::delete_table "${FILE}"
    assert_refused 'a table is required'
}

@test "stealth::sys::data::toml::delete_table: no such file -> exits 1" {
    run stealth::sys::data::toml::delete_table "${WORK}/nowhere" a
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::merge: a key both set -> the source wins" {
    printf '[engine]\ntimeout = 99\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"
    local value

    stealth::sys::data::toml::read value "${FILE}" engine timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::data::toml::merge: a number -> is still a number afterwards" {
    printf '[engine]\ntimeout = 99\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine timeout

    assert_equal "${kind}" 'integer'
}

@test "stealth::sys::data::toml::merge: a string -> is still a string afterwards" {
    printf '[engine]\nmode = "fast"\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"
    local kind

    stealth::sys::data::toml::type kind "${FILE}" engine mode

    assert_equal "${kind}" 'string'
}

@test "stealth::sys::data::toml::merge: a table only the source has -> is opened" {
    printf '[boot]\nloader = "systemd-boot"\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"

    run stealth::sys::data::toml::has_table "${FILE}" boot
    assert_success
}

@test "stealth::sys::data::toml::merge: keys before any table -> are merged too" {
    printf 'name = "merged"\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"
    local value

    stealth::sys::data::toml::read value "${FILE}" '' name

    assert_equal "${value}" 'merged'
}

@test "stealth::sys::data::toml::merge: a key only the target sets -> is left alone" {
    printf '[engine]\ntimeout = 99\n' > "${WORK}/over.toml"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"
    local value

    stealth::sys::data::toml::read value "${FILE}" engine.runtime kind

    assert_equal "${value}" 'crun'
}

@test "stealth::sys::data::toml::merge: a source holding nothing -> the target is untouched" {
    printf '# nothing here\n' > "${WORK}/over.toml"
    cp "${FILE}" "${WORK}/before"

    stealth::sys::data::toml::merge "${FILE}" "${WORK}/over.toml"

    assert_files_equal "${FILE}" "${WORK}/before"
}

@test "stealth::sys::data::toml::merge: no such source -> exits 1" {
    run stealth::sys::data::toml::merge "${FILE}" "${WORK}/nowhere"
    assert_refused "no file to merge in at ${WORK}/nowhere"
}

@test "stealth::sys::data::toml::merge: no target -> exits 1" {
    run stealth::sys::data::toml::merge '' "${FILE}"
    assert_refused 'a file to change is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::is_valid: the fixture -> returns 0" {
    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::toml::is_valid: an empty file -> returns 0" {
    : > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::toml::is_valid: an array of tables -> returns 1" {
    printf '[[registry]]\nlocation = "example.com"\n' > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::toml::is_valid: an array of tables -> says which line" {
    printf '[[registry]]\nlocation = "example.com"\n' > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"

    assert_called_with stealth::util::log::debug '*not one this reader knows*'
}

@test "stealth::sys::data::toml::is_valid: a bracket that is never closed -> returns 1" {
    # A reader here joins lines until the brackets balance, so one that never
    # does swallows the rest of the file.
    printf '[a]\nhosts = [\n  "one",\n' > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::toml::is_valid: a heading with something after it -> returns 1" {
    printf '[a]\nx = 1\n[b] and then some\n' > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::toml::is_valid: a line that sets nothing -> returns 1" {
    printf '[a]\nthis is prose\n' > "${FILE}"

    run stealth::sys::data::toml::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::toml::is_valid: no such file -> returns 1" {
    run stealth::sys::data::toml::is_valid "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::data::toml::is_valid: nothing -> returns 1" {
    run stealth::sys::data::toml::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::_depth
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::_depth: a bracket inside a string -> is not counted" {
    local -i open=0

    stealth::sys::data::toml::_depth open 'label = "a [ bracket"'

    assert_equal "${open}" '0'
}

@test "stealth::sys::data::toml::_depth: a bracket after a comment -> is not counted" {
    local -i open=0

    stealth::sys::data::toml::_depth open 'x = 1  # see [a]'

    assert_equal "${open}" '0'
}

@test "stealth::sys::data::toml::_depth: an array left open -> counts one" {
    local -i open=0

    stealth::sys::data::toml::_depth open 'hosts = ['

    assert_equal "${open}" '1'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::toml::_table
# ------------------------------------------------------------------------------

@test "stealth::sys::data::toml::_table: an ordinary line -> leaves the tracker alone" {
    local at='engine'

    stealth::sys::data::toml::_table at 'timeout = 30' || true

    assert_equal "${at}" 'engine'
}

@test "stealth::sys::data::toml::_table: an array of tables -> closes the one before it" {
    # The name keeps its brackets, and a bracket is not allowed in a name a
    # caller can ask for, so the keys under it belong to nothing readable.
    local at='engine'

    stealth::sys::data::toml::_table at '[[registry]]'

    assert_equal "${at}" '[registry]'
}

@test "stealth::sys::data::toml::_table: a bracket that never closes -> is not a table" {
    local at='engine'

    run stealth::sys::data::toml::_table at '[unclosed'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# sys/data/toml, the module itself
# ------------------------------------------------------------------------------

@test "sys/data/toml: sourced twice -> returns before it declares anything" {
    run load_lib sys/data/toml
    assert_success
}
