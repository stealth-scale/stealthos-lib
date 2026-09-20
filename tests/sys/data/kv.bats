#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/data/kv - Test Suite
# ==============================================================================
# The fixture is the shape of an os-release file, with a comment and a blank
# line in it, because keeping those is part of what this module promises.
#
# One test reads a file back with a real shell. That is the only check that
# matters for quoting: whatever this module writes has to come back out of
# `source` as the same bytes that went in.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/data/kv
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    FILE="${WORK}/os-release"

    cat > "${FILE}" <<'EOF'
NAME="Fedora Linux"
# what this machine boots
VERSION_ID=44
ID=fedora

PRETTY_NAME="Fedora Linux 44 (Silverblue)"
EOF
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::read
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::read: a bare value -> comes back as it is" {
    local value

    stealth::sys::data::kv::read value "${FILE}" ID

    assert_equal "${value}" 'fedora'
}

@test "stealth::sys::data::kv::read: a value in double quotes -> comes back without them" {
    local value

    stealth::sys::data::kv::read value "${FILE}" NAME

    assert_equal "${value}" 'Fedora Linux'
}

@test "stealth::sys::data::kv::read: a value in single quotes -> comes back without them" {
    printf "GREETING='hello there'\n" > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" GREETING

    assert_equal "${value}" 'hello there'
}

@test "stealth::sys::data::kv::read: an escaped quote inside one -> comes back as a quote" {
    printf 'SAID="she said \\"no\\""\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" SAID

    assert_equal "${value}" 'she said "no"'
}

@test "stealth::sys::data::kv::read: export in front of the key -> is not part of it" {
    printf 'export EDITOR=vim\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" EDITOR

    assert_equal "${value}" 'vim'
}

@test "stealth::sys::data::kv::read: a key set twice -> the last one wins" {
    printf 'ID=one\nID=two\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" ID

    assert_equal "${value}" 'two'
}

@test "stealth::sys::data::kv::read: an equals sign in the value -> stays in it" {
    printf 'ARGS=a=1,b=2\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" ARGS

    assert_equal "${value}" 'a=1,b=2'
}

@test "stealth::sys::data::kv::read: an empty value -> comes back empty" {
    printf 'EMPTY=\n' > "${FILE}"
    local value='left over'

    stealth::sys::data::kv::read value "${FILE}" EMPTY

    assert_equal "${value}" ''
}

@test "stealth::sys::data::kv::read: a key inside a comment -> is not read" {
    printf '# ID=commented\nNAME=real\n' > "${FILE}"

    run stealth::sys::data::kv::read value "${FILE}" ID
    assert_failure 1
}

@test "stealth::sys::data::kv::read: a key that is not there -> returns 1" {
    run stealth::sys::data::kv::read value "${FILE}" NOTHING
    assert_failure 1
}

@test "stealth::sys::data::kv::read: a key that is not there and a default -> the default" {
    local value

    stealth::sys::data::kv::read value "${FILE}" NOTHING 'fallback'

    assert_equal "${value}" 'fallback'
}

@test "stealth::sys::data::kv::read: an empty default -> is still a default" {
    local value='left over'

    stealth::sys::data::kv::read value "${FILE}" NOTHING ''

    assert_equal "${value}" ''
}

@test "stealth::sys::data::kv::read: a last line with no break after it -> is read" {
    printf 'ID=fedora\nLAST=here' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" LAST

    assert_equal "${value}" 'here'
}

@test "stealth::sys::data::kv::read: no such file -> exits 1" {
    run stealth::sys::data::kv::read value "${WORK}/nowhere" ID
    assert_refused "no file to read at ${WORK}/nowhere"
}

@test "stealth::sys::data::kv::read: no key -> exits 1" {
    run stealth::sys::data::kv::read value "${FILE}"
    assert_refused 'a key is required'
}

@test "stealth::sys::data::kv::read: no output variable -> exits 1" {
    run stealth::sys::data::kv::read '' "${FILE}" ID
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::has
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::has: a key that is set -> returns 0" {
    run stealth::sys::data::kv::has "${FILE}" ID
    assert_success
}

@test "stealth::sys::data::kv::has: a key that is not -> returns 1" {
    run stealth::sys::data::kv::has "${FILE}" NOTHING
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::keys
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::keys: a file -> the keys in the order they are in" {
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names NAME VERSION_ID ID PRETTY_NAME
}

@test "stealth::sys::data::kv::keys: a key set twice -> comes back once" {
    printf 'ID=one\nNAME=x\nID=two\n' > "${FILE}"
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names ID NAME
}

@test "stealth::sys::data::kv::keys: a file of nothing but comments -> an empty array" {
    printf '# one\n\n# two\n' > "${FILE}"
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_empty names
}

@test "stealth::sys::data::kv::keys: no output array -> exits 1" {
    run stealth::sys::data::kv::keys '' "${FILE}"
    assert_refused 'an output array is required'
}

@test "stealth::sys::data::kv::keys: no such file -> exits 1" {
    run stealth::sys::data::kv::keys names "${WORK}/nowhere"
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::load
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::load: a file -> everything it sets" {
    local -A all=()

    stealth::sys::data::kv::load all "${FILE}"

    assert_equal "${all[ID]}" 'fedora'
    assert_equal "${all[NAME]}" 'Fedora Linux'
    assert_array_length all 4
}

@test "stealth::sys::data::kv::load: a key set twice -> holds the last value" {
    printf 'ID=one\nID=two\n' > "${FILE}"
    local -A all=()

    stealth::sys::data::kv::load all "${FILE}"

    assert_equal "${all[ID]}" 'two'
}

@test "stealth::sys::data::kv::load: an array with something in it -> is emptied first" {
    local -A all=([STALE]=yes)

    stealth::sys::data::kv::load all "${FILE}"

    refute_array_has_key all STALE
}

@test "stealth::sys::data::kv::load: no output array -> exits 1" {
    run stealth::sys::data::kv::load '' "${FILE}"
    assert_refused 'an output array is required'
}

@test "stealth::sys::data::kv::load: no such file -> exits 1" {
    run stealth::sys::data::kv::load all "${WORK}/nowhere"
    assert_refused "no file to read at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::set
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::set: a key that is there -> is changed" {
    stealth::sys::data::kv::set "${FILE}" VERSION_ID 45
    local value

    stealth::sys::data::kv::read value "${FILE}" VERSION_ID

    assert_equal "${value}" '45'
}

@test "stealth::sys::data::kv::set: a key that is there -> stays where it was" {
    stealth::sys::data::kv::set "${FILE}" VERSION_ID 45
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names NAME VERSION_ID ID PRETTY_NAME
}

@test "stealth::sys::data::kv::set: a key that is there -> the comments stay" {
    stealth::sys::data::kv::set "${FILE}" VERSION_ID 45

    assert_file_contains "${FILE}" '# what this machine boots'
}

@test "stealth::sys::data::kv::set: a key that is not there -> goes on the end" {
    stealth::sys::data::kv::set "${FILE}" VARIANT_ID 'stealth'
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_equal "${names[-1]}" 'VARIANT_ID'
}

@test "stealth::sys::data::kv::set: a value with spaces -> is quoted" {
    stealth::sys::data::kv::set "${FILE}" TITLE 'Stealth OS 1'

    assert_file_contains "${FILE}" 'TITLE="Stealth OS 1"'
}

@test "stealth::sys::data::kv::set: a plain value -> is not quoted" {
    stealth::sys::data::kv::set "${FILE}" ID 'stealth'

    assert_file_contains "${FILE}" 'ID=stealth'
}

@test "stealth::sys::data::kv::set: a value a sed expression would eat -> survives" {
    # An ampersand is the whole match in a sed replacement, and a vertical bar
    # ends the expression. Neither means anything here.
    local -r tricky='a&b|c\d$e`f'
    stealth::sys::data::kv::set "${FILE}" TRICKY "${tricky}"
    local value

    stealth::sys::data::kv::read value "${FILE}" TRICKY

    assert_equal "${value}" "${tricky}"
}

@test "stealth::sys::data::kv::set: what it writes -> a shell reads back unchanged" {
    local -r tricky='a&b|c\d$e`f "g" $(h)'
    stealth::sys::data::kv::set "${FILE}" TRICKY "${tricky}"

    run bash -c 'set -a; . "${1}"; printf "%s" "${TRICKY}"' _ "${FILE}"

    assert_output "${tricky}"
}

@test "stealth::sys::data::kv::set: a key set twice -> only the first line is left" {
    printf 'ID=one\nNAME=x\nID=two\n' > "${FILE}"

    stealth::sys::data::kv::set "${FILE}" ID three

    assert_file_contains "${FILE}" 'ID=three'
    refute_file_contains "${FILE}" 'ID=two'
}

@test "stealth::sys::data::kv::set: the file -> keeps its last line break" {
    stealth::sys::data::kv::set "${FILE}" ID stealth

    run bash -c 'tail -c1 "${1}" | od -An -c | tr -d " "' _ "${FILE}"
    assert_output '\n'
}

@test "stealth::sys::data::kv::set: no file yet -> one is made with the key in it" {
    stealth::sys::data::kv::set "${WORK}/new.env" ID stealth

    assert_file_contains "${WORK}/new.env" 'ID=stealth'
}

@test "stealth::sys::data::kv::set: a key no shell can read -> exits 1" {
    run stealth::sys::data::kv::set "${FILE}" 'a-key' value
    assert_refused 'a-key is not a key a shell can read'
}

@test "stealth::sys::data::kv::set: a value with a line break -> exits 1" {
    run stealth::sys::data::kv::set "${FILE}" ID $'one\ntwo'
    assert_refused 'the value of ID has a line break in it, which this file cannot hold'
}

@test "stealth::sys::data::kv::set: no key -> exits 1" {
    run stealth::sys::data::kv::set "${FILE}"
    assert_refused 'a key is required'
}

@test "stealth::sys::data::kv::set: no file -> exits 1" {
    run stealth::sys::data::kv::set '' ID value
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::delete: a key -> is gone" {
    stealth::sys::data::kv::delete "${FILE}" ID

    run stealth::sys::data::kv::has "${FILE}" ID
    assert_failure 1
}

@test "stealth::sys::data::kv::delete: a key -> the rest stays" {
    stealth::sys::data::kv::delete "${FILE}" ID
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names NAME VERSION_ID PRETTY_NAME
}

@test "stealth::sys::data::kv::delete: a key -> the comments stay" {
    stealth::sys::data::kv::delete "${FILE}" ID

    assert_file_contains "${FILE}" '# what this machine boots'
}

@test "stealth::sys::data::kv::delete: a key set twice -> both lines go" {
    printf 'ID=one\nNAME=x\nID=two\n' > "${FILE}"

    stealth::sys::data::kv::delete "${FILE}" ID

    refute_file_contains "${FILE}" 'ID='
}

@test "stealth::sys::data::kv::delete: a key that was never there -> is no trouble" {
    run stealth::sys::data::kv::delete "${FILE}" NOTHING
    assert_success
}

@test "stealth::sys::data::kv::delete: the only line -> leaves an empty file" {
    printf 'ID=one\n' > "${FILE}"

    stealth::sys::data::kv::delete "${FILE}" ID

    assert_file_empty "${FILE}"
}

@test "stealth::sys::data::kv::delete: no such file -> exits 1" {
    run stealth::sys::data::kv::delete "${WORK}/nowhere" ID
    assert_refused "no file to change at ${WORK}/nowhere"
}

@test "stealth::sys::data::kv::delete: no key -> exits 1" {
    run stealth::sys::data::kv::delete "${FILE}"
    assert_refused 'a key is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::merge
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::merge: a key both set -> the source wins" {
    printf 'ID=stealth\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"
    local value

    stealth::sys::data::kv::read value "${FILE}" ID

    assert_equal "${value}" 'stealth'
}

@test "stealth::sys::data::kv::merge: a key only the source sets -> goes on the end" {
    printf 'VARIANT_ID=stealth\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_equal "${names[-1]}" 'VARIANT_ID'
}

@test "stealth::sys::data::kv::merge: a key only the target sets -> is left alone" {
    printf 'VARIANT_ID=stealth\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"
    local value

    stealth::sys::data::kv::read value "${FILE}" NAME

    assert_equal "${value}" 'Fedora Linux'
}

@test "stealth::sys::data::kv::merge: the target -> keeps its comments and its order" {
    printf 'ID=stealth\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names NAME VERSION_ID ID PRETTY_NAME
    assert_file_contains "${FILE}" '# what this machine boots'
}

@test "stealth::sys::data::kv::merge: a source that sets nothing -> the target is untouched" {
    printf '# nothing here\n' > "${WORK}/over.env"
    cp "${FILE}" "${WORK}/before"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"

    assert_files_equal "${FILE}" "${WORK}/before"
}

@test "stealth::sys::data::kv::merge: a value needing quotes -> gets them" {
    printf 'TITLE=plain\n' > "${WORK}/over.env"
    printf 'TITLE="two words"\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"

    assert_file_contains "${FILE}" 'TITLE="two words"'
}

@test "stealth::sys::data::kv::merge: a key the target set twice -> one line is left" {
    printf 'ID=one\nNAME=x\nID=two\n' > "${FILE}"
    printf 'ID=stealth\n' > "${WORK}/over.env"

    stealth::sys::data::kv::merge "${FILE}" "${WORK}/over.env"
    local names

    stealth::sys::data::kv::keys names "${FILE}"

    assert_array_equal names ID NAME
    assert_file_contains "${FILE}" 'ID=stealth'
    refute_file_contains "${FILE}" 'ID=two'
}

@test "stealth::sys::data::kv::merge: no such source -> exits 1" {
    run stealth::sys::data::kv::merge "${FILE}" "${WORK}/nowhere"
    assert_refused "no file to merge in at ${WORK}/nowhere"
}

@test "stealth::sys::data::kv::merge: no target -> exits 1" {
    run stealth::sys::data::kv::merge '' "${FILE}"
    assert_refused 'a file to change is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::is_valid
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::is_valid: a file of settings -> returns 0" {
    run stealth::sys::data::kv::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::kv::is_valid: an empty file -> returns 0" {
    : > "${FILE}"

    run stealth::sys::data::kv::is_valid "${FILE}"
    assert_success
}

@test "stealth::sys::data::kv::is_valid: a line that sets nothing -> returns 1" {
    printf 'ID=fedora\nthis is prose\n' > "${FILE}"

    run stealth::sys::data::kv::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::kv::is_valid: a line that sets nothing -> says which" {
    printf 'ID=fedora\nthis is prose\n' > "${FILE}"

    run stealth::sys::data::kv::is_valid "${FILE}"

    assert_called_with stealth::util::log::debug '*sets nothing*'
}

@test "stealth::sys::data::kv::is_valid: a key no shell can read -> returns 1" {
    printf 'a-key=value\n' > "${FILE}"

    run stealth::sys::data::kv::is_valid "${FILE}"
    assert_failure 1
}

@test "stealth::sys::data::kv::is_valid: no such file -> returns 1" {
    run stealth::sys::data::kv::is_valid "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::data::kv::is_valid: nothing -> returns 1" {
    run stealth::sys::data::kv::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::data::kv::_unquote
# ------------------------------------------------------------------------------

@test "stealth::sys::data::kv::_unquote: one quote character on its own -> stays" {
    printf 'ODD="\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" ODD

    assert_equal "${value}" '"'
}

@test "stealth::sys::data::kv::_unquote: an escaped backslash -> comes back as one" {
    printf 'PATHS="a\\\\\\\\b"\n' > "${FILE}"
    local value

    stealth::sys::data::kv::read value "${FILE}" PATHS

    assert_equal "${value}" 'a\\b'
}

# ------------------------------------------------------------------------------
# sys/data/kv, the module itself
# ------------------------------------------------------------------------------

@test "sys/data/kv: sourced twice -> returns before it declares anything" {
    run load_lib sys/data/kv
    assert_success
}
