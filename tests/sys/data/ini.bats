#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/data/ini - Test Suite
# ==============================================================================
# The fixture has a key before any section, a comment of each kind, and a
# blank line between the sections, because keeping all of those through a
# write is what this module promises.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/data/ini
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    FILE="${WORK}/config.ini"

    cat > "${FILE}" <<'EOF'
name = build
; who this machine is

[network]
# how long to wait
timeout = 30
host = example.com

[disk]
size = 20G
EOF
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::read
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::read: a key in a section -> its value" {
    local value

    stealth::sys::data::ini::read value "${FILE}" network timeout

    assert_equal "${value}" '30'
}

@test "stealth::sys::data::ini::read: a key before any section -> its value" {
    local value

    stealth::sys::data::ini::read value "${FILE}" '' name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::ini::read: the same key in another section -> is not confused" {
    printf '[a]\nport = 1\n[b]\nport = 2\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" b port

    assert_equal "${value}" '2'
}

@test "stealth::sys::data::ini::read: a key with no spaces around the equals -> its value" {
    printf '[a]\nport=8080\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a port

    assert_equal "${value}" '8080'
}

@test "stealth::sys::data::ini::read: a quoted value -> comes back without the quotes" {
    printf '[a]\ngreeting = "hello there"\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a greeting

    assert_equal "${value}" 'hello there'
}

@test "stealth::sys::data::ini::read: an equals sign in the value -> stays in it" {
    printf '[a]\nargs = x=1,y=2\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a args

    assert_equal "${value}" 'x=1,y=2'
}

@test "stealth::sys::data::ini::read: an empty value -> comes back empty" {
    printf '[a]\nnothing =\n' > "${FILE}"
    local value='left over'

    stealth::sys::data::ini::read value "${FILE}" a nothing

    assert_equal "${value}" ''
}

@test "stealth::sys::data::ini::read: a key set twice in one section -> the last wins" {
    printf '[a]\nport = 1\nport = 2\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a port

    assert_equal "${value}" '2'
}

@test "stealth::sys::data::ini::read: a key inside a comment -> is not read" {
    printf '[a]\n# port = 1\n' > "${FILE}"

    run stealth::sys::data::ini::read value "${FILE}" a port
    assert_failure 1
}

@test "stealth::sys::data::ini::read: a section that is not there -> returns 1" {
    run stealth::sys::data::ini::read value "${FILE}" nowhere timeout
    assert_failure 1
}

@test "stealth::sys::data::ini::read: a key that is not there -> returns 1" {
    run stealth::sys::data::ini::read value "${FILE}" network nothing
    assert_failure 1
}

@test "stealth::sys::data::ini::read: a key that is not there and a default -> the default" {
    local value

    stealth::sys::data::ini::read value "${FILE}" network nothing 'fallback'

    assert_equal "${value}" 'fallback'
}

@test "stealth::sys::data::ini::read: a section heading with spaces around it -> is found" {
    printf '  [ spaced ]  \n  key = value\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" spaced key

    assert_equal "${value}" 'value'
}

@test "stealth::sys::data::ini::read: a last line with no break after it -> is read" {
    printf '[a]\nlast = here' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a last

    assert_equal "${value}" 'here'
}

@test "stealth::sys::data::ini::read: no such file -> exits 1" {
    run stealth::sys::data::ini::read value "${WORK}/nowhere" a b
    assert_refused "no file to read at ${WORK}/nowhere"
}

@test "stealth::sys::data::ini::read: no key -> exits 1" {
    run stealth::sys::data::ini::read value "${FILE}" network
    assert_refused 'a key is required'
}

@test "stealth::sys::data::ini::read: no output variable -> exits 1" {
    run stealth::sys::data::ini::read '' "${FILE}" network timeout
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::has
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::has: a key that is set -> returns 0" {
    run stealth::sys::data::ini::has "${FILE}" network timeout
    assert_success
}

@test "stealth::sys::data::ini::has: a key that is not -> returns 1" {
    run stealth::sys::data::ini::has "${FILE}" network nothing
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::has_section
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::has_section: a section that is there -> returns 0" {
    run stealth::sys::data::ini::has_section "${FILE}" network
    assert_success
}

@test "stealth::sys::data::ini::has_section: a section that is not -> returns 1" {
    run stealth::sys::data::ini::has_section "${FILE}" nowhere
    assert_failure 1
}

@test "stealth::sys::data::ini::has_section: no such file -> exits 1" {
    run stealth::sys::data::ini::has_section "${WORK}/nowhere" a
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::sections
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::sections: a file -> them in the order they open" {
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names network disk
}

@test "stealth::sys::data::ini::sections: a section opened twice -> comes back once" {
    printf '[a]\nx = 1\n[b]\ny = 2\n[a]\nz = 3\n' > "${FILE}"
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names a b
}

@test "stealth::sys::data::ini::sections: a file with no sections -> an empty array" {
    printf 'name = build\n' > "${FILE}"
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_empty names
}

@test "stealth::sys::data::ini::sections: no output array -> exits 1" {
    run stealth::sys::data::ini::sections '' "${FILE}"
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::keys: a section -> its keys in order" {
    local names

    stealth::sys::data::ini::keys names "${FILE}" network

    assert_array_equal names timeout host
}

@test "stealth::sys::data::ini::keys: the keys before any section -> come back for the empty name" {
    local names

    stealth::sys::data::ini::keys names "${FILE}" ''

    assert_array_equal names name
}

@test "stealth::sys::data::ini::keys: a section opened twice -> both halves come back" {
    printf '[a]\nx = 1\n[b]\ny = 2\n[a]\nz = 3\n' > "${FILE}"
    local names

    stealth::sys::data::ini::keys names "${FILE}" a

    assert_array_equal names x z
}

@test "stealth::sys::data::ini::keys: a key set twice in one section -> comes back once" {
    printf '[a]\nport = 1\nport = 2\n' > "${FILE}"
    local names

    stealth::sys::data::ini::keys names "${FILE}" a

    assert_array_equal names port
}

@test "stealth::sys::data::ini::keys: a section that is not there -> an empty array" {
    local names

    stealth::sys::data::ini::keys names "${FILE}" nowhere

    assert_array_empty names
}

@test "stealth::sys::data::ini::keys: no output array -> exits 1" {
    run stealth::sys::data::ini::keys '' "${FILE}" network
    assert_refused 'an output array is required'
}

@test "stealth::sys::data::ini::keys: no such file -> exits 1" {
    run stealth::sys::data::ini::keys names "${WORK}/nowhere" a
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::load
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::load: a section -> everything in it" {
    local -A net=()

    stealth::sys::data::ini::load net "${FILE}" network

    assert_equal "${net[timeout]}" '30'
    assert_equal "${net[host]}" 'example.com'
    assert_array_length net 2
}

@test "stealth::sys::data::ini::load: the keys before any section -> come back for the empty name" {
    local -A top=()

    stealth::sys::data::ini::load top "${FILE}" ''

    assert_equal "${top[name]}" 'build'
}

@test "stealth::sys::data::ini::load: an array with something in it -> is emptied first" {
    local -A net=([stale]=yes)

    stealth::sys::data::ini::load net "${FILE}" network

    refute_array_has_key net stale
}

@test "stealth::sys::data::ini::load: a section that is not there -> an empty array" {
    local -A net=()

    stealth::sys::data::ini::load net "${FILE}" nowhere

    assert_array_empty net
}

@test "stealth::sys::data::ini::load: no output array -> exits 1" {
    run stealth::sys::data::ini::load '' "${FILE}" network
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::set
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::set: a key that is there -> is changed" {
    stealth::sys::data::ini::set "${FILE}" network timeout 60
    local value

    stealth::sys::data::ini::read value "${FILE}" network timeout

    assert_equal "${value}" '60'
}

@test "stealth::sys::data::ini::set: a key that is there -> stays where it was" {
    stealth::sys::data::ini::set "${FILE}" network timeout 60
    local names

    stealth::sys::data::ini::keys names "${FILE}" network

    assert_array_equal names timeout host
}

@test "stealth::sys::data::ini::set: a change -> the comments stay" {
    stealth::sys::data::ini::set "${FILE}" network timeout 60

    assert_file_contains "${FILE}" '# how long to wait'
    assert_file_contains "${FILE}" '; who this machine is'
}

@test "stealth::sys::data::ini::set: a new key -> goes at the end of its own section" {
    stealth::sys::data::ini::set "${FILE}" network retries 3
    local names

    stealth::sys::data::ini::keys names "${FILE}" network

    assert_array_equal names timeout host retries
}

@test "stealth::sys::data::ini::set: a new key -> does not land in the next section" {
    stealth::sys::data::ini::set "${FILE}" network retries 3
    local names

    stealth::sys::data::ini::keys names "${FILE}" disk

    assert_array_equal names size
}

@test "stealth::sys::data::ini::set: a new key in the last section -> goes at the end" {
    stealth::sys::data::ini::set "${FILE}" disk label root
    local names

    stealth::sys::data::ini::keys names "${FILE}" disk

    assert_array_equal names size label
}

@test "stealth::sys::data::ini::set: a new section -> is opened at the end" {
    stealth::sys::data::ini::set "${FILE}" boot mode uefi
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names network disk boot
}

@test "stealth::sys::data::ini::set: a new section -> holds the key" {
    stealth::sys::data::ini::set "${FILE}" boot mode uefi
    local value

    stealth::sys::data::ini::read value "${FILE}" boot mode

    assert_equal "${value}" 'uefi'
}

@test "stealth::sys::data::ini::set: a key before any section -> goes at the top" {
    printf '[a]\nx = 1\n' > "${FILE}"

    stealth::sys::data::ini::set "${FILE}" '' name build
    local value

    stealth::sys::data::ini::read value "${FILE}" '' name

    assert_equal "${value}" 'build'
}

@test "stealth::sys::data::ini::set: a key set twice -> only the first line is left" {
    printf '[a]\nport = 1\nx = 9\nport = 2\n' > "${FILE}"

    stealth::sys::data::ini::set "${FILE}" a port 3
    local names

    stealth::sys::data::ini::keys names "${FILE}" a

    assert_array_equal names port x
    refute_file_contains "${FILE}" 'port = 2'
}

@test "stealth::sys::data::ini::set: a value with spaces -> comes back whole" {
    stealth::sys::data::ini::set "${FILE}" network note 'two words here'
    local value

    stealth::sys::data::ini::read value "${FILE}" network note

    assert_equal "${value}" 'two words here'
}

@test "stealth::sys::data::ini::set: no file yet -> one is made with the key in it" {
    stealth::sys::data::ini::set "${WORK}/new.ini" a b c
    local value

    stealth::sys::data::ini::read value "${WORK}/new.ini" a b

    assert_equal "${value}" 'c'
}

@test "stealth::sys::data::ini::set: a key with an equals sign -> exits 1" {
    run stealth::sys::data::ini::set "${FILE}" a 'a=b' value
    assert_refused 'a=b is not a key this file can hold'
}

@test "stealth::sys::data::ini::set: a key with a bracket -> exits 1" {
    run stealth::sys::data::ini::set "${FILE}" a 'a[b' value
    assert_refused 'a[b is not a key this file can hold'
}

@test "stealth::sys::data::ini::set: a section with a bracket -> exits 1" {
    run stealth::sys::data::ini::set "${FILE}" 'a]b' key value
    assert_refused 'a]b is not a section name this file can hold'
}

@test "stealth::sys::data::ini::set: a value with a line break -> exits 1" {
    run stealth::sys::data::ini::set "${FILE}" a b $'one\ntwo'
    assert_refused 'the value of b has a line break in it, which this file cannot hold'
}

@test "stealth::sys::data::ini::set: no key -> exits 1" {
    run stealth::sys::data::ini::set "${FILE}" network
    assert_refused 'a key is required'
}

@test "stealth::sys::data::ini::set: no file -> exits 1" {
    run stealth::sys::data::ini::set '' a b c
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::delete: a key -> is gone" {
    stealth::sys::data::ini::delete "${FILE}" network host

    run stealth::sys::data::ini::has "${FILE}" network host
    assert_failure 1
}

@test "stealth::sys::data::ini::delete: a key -> the rest of the section stays" {
    stealth::sys::data::ini::delete "${FILE}" network host
    local names

    stealth::sys::data::ini::keys names "${FILE}" network

    assert_array_equal names timeout
}

@test "stealth::sys::data::ini::delete: a key -> the section heading stays" {
    stealth::sys::data::ini::delete "${FILE}" network timeout
    stealth::sys::data::ini::delete "${FILE}" network host

    run stealth::sys::data::ini::has_section "${FILE}" network
    assert_success
}

@test "stealth::sys::data::ini::delete: a key -> the comments stay" {
    stealth::sys::data::ini::delete "${FILE}" network host

    assert_file_contains "${FILE}" '# how long to wait'
}

@test "stealth::sys::data::ini::delete: the same key in another section -> is left alone" {
    printf '[a]\nport = 1\n[b]\nport = 2\n' > "${FILE}"

    stealth::sys::data::ini::delete "${FILE}" a port

    run stealth::sys::data::ini::has "${FILE}" b port
    assert_success
}

@test "stealth::sys::data::ini::delete: a key that was never there -> is no trouble" {
    run stealth::sys::data::ini::delete "${FILE}" network nothing
    assert_success
}

@test "stealth::sys::data::ini::delete: the only line of the file -> leaves it empty" {
    printf 'x = 1\n' > "${FILE}"

    stealth::sys::data::ini::delete "${FILE}" '' x

    assert_file_empty "${FILE}"
}

@test "stealth::sys::data::ini::delete: no such file -> exits 1" {
    run stealth::sys::data::ini::delete "${WORK}/nowhere" a b
    assert_refused "no file to change at ${WORK}/nowhere"
}

@test "stealth::sys::data::ini::delete: no key -> exits 1" {
    run stealth::sys::data::ini::delete "${FILE}" network
    assert_refused 'a key is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::delete_section
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::delete_section: a section -> is gone" {
    stealth::sys::data::ini::delete_section "${FILE}" disk

    run stealth::sys::data::ini::has_section "${FILE}" disk
    assert_failure 1
}

@test "stealth::sys::data::ini::delete_section: a section -> what was in it goes too" {
    stealth::sys::data::ini::delete_section "${FILE}" disk

    refute_file_contains "${FILE}" 'size = 20G'
}

@test "stealth::sys::data::ini::delete_section: a section -> the others stay" {
    stealth::sys::data::ini::delete_section "${FILE}" disk
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names network
}

@test "stealth::sys::data::ini::delete_section: one in the middle -> the one after it stays" {
    printf '[a]\nx = 1\n[b]\ny = 2\n[c]\nz = 3\n' > "${FILE}"

    stealth::sys::data::ini::delete_section "${FILE}" b
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names a c
}

@test "stealth::sys::data::ini::delete_section: a section that was never there -> is no trouble" {
    run stealth::sys::data::ini::delete_section "${FILE}" nowhere
    assert_success
}

@test "stealth::sys::data::ini::delete_section: the only section -> leaves an empty file" {
    printf '[a]\nx = 1\n' > "${FILE}"

    stealth::sys::data::ini::delete_section "${FILE}" a

    assert_file_empty "${FILE}"
}

@test "stealth::sys::data::ini::delete_section: no section -> exits 1" {
    run stealth::sys::data::ini::delete_section "${FILE}"
    assert_refused 'a section is required'
}

@test "stealth::sys::data::ini::delete_section: no such file -> exits 1" {
    run stealth::sys::data::ini::delete_section "${WORK}/nowhere" a
    assert_refused "no file to change at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::merge: a key both set -> the source wins" {
    printf '[network]\ntimeout = 99\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"
    local value

    stealth::sys::data::ini::read value "${FILE}" network timeout

    assert_equal "${value}" '99'
}

@test "stealth::sys::data::ini::merge: a key only the source sets -> is added" {
    printf '[network]\nretries = 3\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"
    local value

    stealth::sys::data::ini::read value "${FILE}" network retries

    assert_equal "${value}" '3'
}

@test "stealth::sys::data::ini::merge: a section only the source has -> is opened" {
    printf '[boot]\nmode = uefi\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"
    local names

    stealth::sys::data::ini::sections names "${FILE}"

    assert_array_equal names network disk boot
}

@test "stealth::sys::data::ini::merge: a key only the target sets -> is left alone" {
    printf '[network]\nretries = 3\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"
    local value

    stealth::sys::data::ini::read value "${FILE}" disk size

    assert_equal "${value}" '20G'
}

@test "stealth::sys::data::ini::merge: keys before any section -> are merged too" {
    printf 'name = merged\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"
    local value

    stealth::sys::data::ini::read value "${FILE}" '' name

    assert_equal "${value}" 'merged'
}

@test "stealth::sys::data::ini::merge: the target -> keeps its comments" {
    printf '[network]\ntimeout = 99\n' > "${WORK}/over.ini"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"

    assert_file_contains "${FILE}" '# how long to wait'
}

@test "stealth::sys::data::ini::merge: a source holding nothing -> the target is untouched" {
    printf '# nothing here\n' > "${WORK}/over.ini"
    cp "${FILE}" "${WORK}/before"

    stealth::sys::data::ini::merge "${FILE}" "${WORK}/over.ini"

    assert_files_equal "${FILE}" "${WORK}/before"
}

@test "stealth::sys::data::ini::merge: no such source -> exits 1" {
    run stealth::sys::data::ini::merge "${FILE}" "${WORK}/nowhere"
    assert_refused "no file to merge in at ${WORK}/nowhere"
}

@test "stealth::sys::data::ini::merge: no target -> exits 1" {
    run stealth::sys::data::ini::merge '' "${FILE}"
    assert_refused 'a file to change is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::is_valid: a file of sections and settings -> returns 0" {
    run stealth::sys::data::ini::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::ini::is_valid: an empty file -> returns 0" {
    : > "${FILE}"

    run stealth::sys::data::ini::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::ini::is_valid: a line that is neither -> returns 1" {
    printf '[a]\nthis is prose\n' > "${FILE}"

    run stealth::sys::data::ini::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::ini::is_valid: a line that is neither -> says which" {
    printf '[a]\nthis is prose\n' > "${FILE}"

    run stealth::sys::data::ini::is_valid "${FILE}"

    assert_called_with stealth::util::log::debug '*neither a section nor a setting*'
}

@test "stealth::sys::data::ini::is_valid: no such file -> returns 1" {
    run stealth::sys::data::ini::is_valid "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::data::ini::is_valid: nothing -> returns 1" {
    run stealth::sys::data::ini::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::_section
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::_section: an ordinary line -> leaves the tracker alone" {
    # Every reader holds the section it is in here. Clearing it on a key line
    # would lose track of where the reader was.
    local at='network'

    run stealth::sys::data::ini::_section at 'timeout = 30'
    assert_failure 1

    stealth::sys::data::ini::_section at 'timeout = 30' || true
    assert_equal "${at}" 'network'
}

@test "stealth::sys::data::ini::_section: a heading -> the tracker becomes it" {
    local at='network'

    stealth::sys::data::ini::_section at '[disk]'

    assert_equal "${at}" 'disk'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::_split
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::_split: a line with nothing before the equals -> sets nothing" {
    printf '[a]\n= orphan\nport = 1\n' > "${FILE}"
    local names

    stealth::sys::data::ini::keys names "${FILE}" a

    assert_array_equal names port
}

# ------------------------------------------------------------------------------
# stealth::sys::data::ini::_unquote
# ------------------------------------------------------------------------------

@test "stealth::sys::data::ini::_unquote: one quote character on its own -> stays" {
    printf '[a]\nodd = "\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a odd

    assert_equal "${value}" '"'
}

@test "stealth::sys::data::ini::_unquote: a quote inside the value -> stays" {
    printf '[a]\nsaid = he said "no" to it\n' > "${FILE}"
    local value

    stealth::sys::data::ini::read value "${FILE}" a said

    assert_equal "${value}" 'he said "no" to it'
}

# ------------------------------------------------------------------------------
# sys/data/ini, the module itself
# ------------------------------------------------------------------------------

@test "sys/data/ini: sourced twice -> returns before it declares anything" {
    run load_lib sys/data/ini
    assert_success
}
