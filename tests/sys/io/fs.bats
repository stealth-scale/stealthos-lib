#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/io/fs - Test Suite
# ==============================================================================
# Every test works inside a directory of its own, so a write that goes wrong
# takes nothing with it.
#
# The guarantee this module makes is that a reader sees the old file or the
# new one and never a part of either. A test cannot watch a rename happen, so
# what is tested instead is everything the guarantee rests on: the staged file
# is in the target's own directory, what the target was carries over to what
# replaces it, and a change that fails leaves the target alone.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/io/fs
    load_mock util
    mock::stealth::util::log

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# How many staged files are left lying about.
staged_left() {
    shopt -s nullglob globstar
    local -a found=("${WORK}"/**/stealth.*)
    shopt -u nullglob globstar

    printf '%s' "${#found[@]}"
}

# When a path was last changed.
mtime() {
    stat -c %Y "${1}"
}

# How many lines a file holds.
lines_in() {
    local -a held=()
    mapfile -t held < "${1}"

    printf '%s' "${#held[@]}"
}

# How many bytes a file holds.
bytes_in() {
    stat -c %s "${1}"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::differs
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::differs: two files that hold the same -> returns 1" {
    printf 'same\n' > "${WORK}/a"
    printf 'same\n' > "${WORK}/b"

    run stealth::sys::io::fs::differs "${WORK}/a" "${WORK}/b"
    assert_failure 1
}

@test "stealth::sys::io::fs::differs: two files that hold different -> returns 0" {
    printf 'one\n' > "${WORK}/a"
    printf 'two\n' > "${WORK}/b"

    run stealth::sys::io::fs::differs "${WORK}/a" "${WORK}/b"
    assert_success
}

@test "stealth::sys::io::fs::differs: a file that is not there -> returns 0" {
    printf 'one\n' > "${WORK}/a"

    run stealth::sys::io::fs::differs "${WORK}/nowhere" "${WORK}/a"
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::mkdir
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::mkdir: a directory -> is made" {
    stealth::sys::io::fs::mkdir "${WORK}/one"

    assert_dir_exists "${WORK}/one"
}

@test "stealth::sys::io::fs::mkdir: a deep path -> the ones above it are made too" {
    stealth::sys::io::fs::mkdir "${WORK}/one/two/three"

    assert_dir_exists "${WORK}/one/two/three"
}

@test "stealth::sys::io::fs::mkdir: no mode -> is made group and world readable" {
    stealth::sys::io::fs::mkdir "${WORK}/one"

    assert_file_permission 755 "${WORK}/one"
}

@test "stealth::sys::io::fs::mkdir: a mode -> is made with it" {
    stealth::sys::io::fs::mkdir "${WORK}/vault" --mode 0700

    assert_file_permission 700 "${WORK}/vault"
}

@test "stealth::sys::io::fs::mkdir: a directory that is already there -> is left alone" {
    mkdir -p "${WORK}/one"
    chmod 0711 "${WORK}/one"

    stealth::sys::io::fs::mkdir "${WORK}/one" --mode 0700

    assert_file_permission 711 "${WORK}/one"
}

@test "stealth::sys::io::fs::mkdir: an owner -> is set on the directory" {
    mock chown '*' 'return 0'

    stealth::sys::io::fs::mkdir "${WORK}/one" --owner root:root

    assert_called_with chown "root:root ${WORK}/one"
}

@test "stealth::sys::io::fs::mkdir: no directory -> exits 1" {
    run stealth::sys::io::fs::mkdir ''
    assert_refused 'a directory is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::write
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::write: text -> is what the file holds" {
    stealth::sys::io::fs::write "${WORK}/hostname" 'buildhost'

    assert_file_contains "${WORK}/hostname" 'buildhost'
}

@test "stealth::sys::io::fs::write: a directory that is not there -> is made on the way" {
    stealth::sys::io::fs::write "${WORK}/a/b/c/hostname" 'buildhost'

    assert_file_exists "${WORK}/a/b/c/hostname"
}

@test "stealth::sys::io::fs::write: a file that is not there -> is made readable" {
    stealth::sys::io::fs::write "${WORK}/hostname" 'buildhost'

    assert_file_permission 644 "${WORK}/hostname"
}

@test "stealth::sys::io::fs::write: a mode -> is what the file is made with" {
    stealth::sys::io::fs::write "${WORK}/netrc" 'secret' --mode 0600

    assert_file_permission 600 "${WORK}/netrc"
}

@test "stealth::sys::io::fs::write: a file nobody else may read -> stays that way" {
    # Writing a file must not open it up. The mode of what is already there
    # carries over unless the caller says otherwise.
    stealth::sys::io::fs::write "${WORK}/netrc" 'secret' --mode 0600

    stealth::sys::io::fs::write "${WORK}/netrc" 'another secret'

    assert_file_permission 600 "${WORK}/netrc"
}

@test "stealth::sys::io::fs::write: the same text again -> the file is not touched" {
    stealth::sys::io::fs::write "${WORK}/hostname" 'buildhost'
    local before after
    before="$(mtime "${WORK}/hostname")"
    touch -d '1 hour ago' "${WORK}/hostname"

    stealth::sys::io::fs::write "${WORK}/hostname" 'buildhost'

    after="$(mtime "${WORK}/hostname")"
    refute_equal "${after}" "${before}"
}

@test "stealth::sys::io::fs::write: text that changed -> replaces what was there" {
    stealth::sys::io::fs::write "${WORK}/hostname" 'one'

    stealth::sys::io::fs::write "${WORK}/hostname" 'two'

    assert_file_contains "${WORK}/hostname" 'two'
    refute_file_contains "${WORK}/hostname" 'one'
}

@test "stealth::sys::io::fs::write: nothing -> the file holds one empty line" {
    stealth::sys::io::fs::write "${WORK}/empty" ''

    local held
    held="$(bytes_in "${WORK}/empty")"
    assert_equal "${held}" 1
}

@test "stealth::sys::io::fs::write: a write -> leaves nothing staged behind" {
    stealth::sys::io::fs::write "${WORK}/hostname" 'buildhost'

    run staged_left
    assert_output '0'
}

@test "stealth::sys::io::fs::write: a target whose attributes cannot be read -> returns 1" {
    printf 'as it was\n' > "${WORK}/one"
    mock cp '*' 'return 1'

    run stealth::sys::io::fs::write "${WORK}/one" 'new'
    assert_failure 1
    assert_file_contains "${WORK}/one" 'as it was'
}

@test "stealth::sys::io::fs::write: no target -> exits 1" {
    run stealth::sys::io::fs::write ''
    assert_refused 'a target is required'
}

@test "stealth::sys::io::fs::write: --mode with no mode -> exits 1" {
    run stealth::sys::io::fs::write "${WORK}/one" 'x' --mode
    assert_refused '--mode takes a mode'
}

@test "stealth::sys::io::fs::write: --owner with no owner -> exits 1" {
    run stealth::sys::io::fs::write "${WORK}/one" 'x' --owner
    assert_refused '--owner takes an owner'
}

@test "stealth::sys::io::fs::write: --sync -> the file is still written" {
    stealth::sys::io::fs::write "${WORK}/durable" 'important' --sync

    assert_file_contains "${WORK}/durable" 'important'
}

@test "stealth::sys::io::fs::write: --sync -> asks for the file and the directory" {
    # The file so the bytes are on the disk, and the directory so the rename
    # that put them there survives a power cut.
    mock sync '*' 'return 0'

    stealth::sys::io::fs::write "${WORK}/durable" 'important' --sync

    assert_called_with sync '--data *'
    assert_called_with sync "--data ${WORK}"
}

@test "stealth::sys::io::fs::write: a wait that fails -> says so and writes anyway" {
    mock sync '*' 'return 1'

    stealth::sys::io::fs::write "${WORK}/durable" 'important' --sync

    assert_file_contains "${WORK}/durable" 'important'
    assert_called_with stealth::util::log::warn '*may not have reached the disk*'
}

@test "stealth::sys::io::fs::write: no --sync -> does not wait" {
    mock sync '*' 'return 0'

    stealth::sys::io::fs::write "${WORK}/quick" 'ordinary'

    refute_called sync
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::read
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::read: a file -> gives what is in it" {
    printf 'buildhost\n' > "${WORK}/hostname"

    assert_nameref 'buildhost' stealth::sys::io::fs::read "${WORK}/hostname"
}

@test "stealth::sys::io::fs::read: the line breaks at the end -> are taken off" {
    printf 'buildhost\n\n\n' > "${WORK}/hostname"

    assert_nameref 'buildhost' stealth::sys::io::fs::read "${WORK}/hostname"
}

@test "stealth::sys::io::fs::read: no such file -> returns 1" {
    run stealth::sys::io::fs::read out "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::io::fs::read: a directory -> returns 1" {
    run stealth::sys::io::fs::read out "${WORK}"
    assert_failure 1
}

@test "stealth::sys::io::fs::read: no output variable -> exits 1" {
    run stealth::sys::io::fs::read ''
    assert_refused 'an output variable is required'
}

@test "stealth::sys::io::fs::read: no file -> exits 1" {
    run stealth::sys::io::fs::read out ''
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::atomic
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::atomic: a function -> works on what the file holds" {
    # The staged file carries the content, so a function edits what is there
    # rather than starting from nothing.
    printf 'one\ntwo\n' > "${WORK}/list"
    # shellcheck disable=SC2329  # given to atomic by name
    add_three() { printf 'three\n' >> "${1}"; }

    stealth::sys::io::fs::atomic "${WORK}/list" add_three

    assert_file_contains "${WORK}/list" 'one'
    assert_file_contains "${WORK}/list" 'three'
}

@test "stealth::sys::io::fs::atomic: arguments -> reach the function after the staged file" {
    # shellcheck disable=SC2329  # given to atomic by name
    put() { printf '%s\n' "${2}" > "${1}"; }

    stealth::sys::io::fs::atomic "${WORK}/one" put 'what was passed'

    assert_file_contains "${WORK}/one" 'what was passed'
}

@test "stealth::sys::io::fs::atomic: a function that fails -> leaves the target alone" {
    printf 'as it was\n' > "${WORK}/one"
    # shellcheck disable=SC2329  # given to atomic by name
    spoil() { printf 'half written\n' > "${1}"; return 1; }

    run stealth::sys::io::fs::atomic "${WORK}/one" spoil

    assert_failure 1
    assert_file_contains "${WORK}/one" 'as it was'
}

@test "stealth::sys::io::fs::atomic: a function that fails -> leaves nothing staged" {
    # shellcheck disable=SC2329  # given to atomic by name
    spoil() { return 1; }

    run stealth::sys::io::fs::atomic "${WORK}/one" spoil

    run staged_left
    assert_output '0'
}

@test "stealth::sys::io::fs::atomic: options before a double hyphen -> are not the function" {
    # shellcheck disable=SC2329  # given to atomic by name
    put() { printf 'x\n' > "${1}"; }

    stealth::sys::io::fs::atomic "${WORK}/one" --mode 0600 -- put

    assert_file_permission 600 "${WORK}/one"
}

@test "stealth::sys::io::fs::atomic: the staged file -> is in the target's own directory" {
    # A rename is only one step within a single filesystem, so staging
    # anywhere else would stop the write being atomic at all.
    local seen=''
    # shellcheck disable=SC2329  # given to atomic by name
    note_where() { seen="${1%/*}"; printf 'x\n' > "${1}"; }

    stealth::sys::io::fs::atomic "${WORK}/one" note_where

    assert_var_equal seen "${WORK}"
}

@test "stealth::sys::io::fs::atomic: a target whose attributes cannot be read -> returns 1" {
    printf 'as it was\n' > "${WORK}/one"
    mock cp '*' 'return 1'

    run stealth::sys::io::fs::atomic "${WORK}/one" -- \
        stealth::sys::io::fs::_put 'new'
    assert_failure 1
    assert_file_contains "${WORK}/one" 'as it was'
}

@test "stealth::sys::io::fs::atomic: no target -> exits 1" {
    run stealth::sys::io::fs::atomic ''
    assert_refused 'a target is required'
}

@test "stealth::sys::io::fs::atomic: no function -> exits 1" {
    run stealth::sys::io::fs::atomic "${WORK}/one"
    assert_refused 'a function is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::line
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::line: a line -> is added at the end" {
    printf 'first\n' > "${WORK}/conf"

    stealth::sys::io::fs::line "${WORK}/conf" 'second'

    run cat "${WORK}/conf"
    assert_line --index 0 'first'
    assert_line --index 1 'second'
}

@test "stealth::sys::io::fs::line: a line already there -> is not added again" {
    printf 'first\n' > "${WORK}/conf"

    stealth::sys::io::fs::line "${WORK}/conf" 'first'

    local held
    held="$(lines_in "${WORK}/conf")"
    assert_equal "${held}" 1
}

@test "stealth::sys::io::fs::line: called twice -> the line is there once" {
    stealth::sys::io::fs::line "${WORK}/conf" 'only once'
    stealth::sys::io::fs::line "${WORK}/conf" 'only once'

    local held
    held="$(lines_in "${WORK}/conf")"
    assert_equal "${held}" 1
}

@test "stealth::sys::io::fs::line: --match -> replaces the line that matches" {
    printf 'PermitRootLogin yes\nPort 22\n' > "${WORK}/sshd"

    stealth::sys::io::fs::line "${WORK}/sshd" 'PermitRootLogin no' \
        --match '^#?PermitRootLogin'

    assert_file_contains "${WORK}/sshd" 'PermitRootLogin no'
    refute_file_contains "${WORK}/sshd" 'PermitRootLogin yes'
}

@test "stealth::sys::io::fs::line: --match -> keeps the rest of the file" {
    printf 'PermitRootLogin yes\nPort 22\n' > "${WORK}/sshd"

    stealth::sys::io::fs::line "${WORK}/sshd" 'PermitRootLogin no' \
        --match '^PermitRootLogin'

    assert_file_contains "${WORK}/sshd" 'Port 22'
    local held
    held="$(lines_in "${WORK}/sshd")"
    assert_equal "${held}" 2
}

@test "stealth::sys::io::fs::line: --match that matches nothing -> adds at the end" {
    printf 'Port 22\n' > "${WORK}/sshd"

    stealth::sys::io::fs::line "${WORK}/sshd" 'PermitRootLogin no' \
        --match '^PermitRootLogin'

    local held
    held="$(lines_in "${WORK}/sshd")"
    assert_equal "${held}" 2
}

@test "stealth::sys::io::fs::line: --match that matches twice -> replaces the first" {
    printf 'Port 22\nPort 2222\n' > "${WORK}/sshd"

    stealth::sys::io::fs::line "${WORK}/sshd" 'Port 8022' --match '^Port'

    run cat "${WORK}/sshd"
    assert_line --index 0 'Port 8022'
    assert_line --index 1 'Port 2222'
}

@test "stealth::sys::io::fs::line: a file that is not there -> is made with the line" {
    stealth::sys::io::fs::line "${WORK}/new" 'the only line'

    assert_file_contains "${WORK}/new" 'the only line'
}

@test "stealth::sys::io::fs::line: the target -> comes first, as it does everywhere else" {
    # The old module took the path in a different place from mkdir and touch.
    printf 'first\n' > "${WORK}/conf"

    run stealth::sys::io::fs::line "${WORK}/conf" 'second'

    assert_success
}

@test "stealth::sys::io::fs::line: --mode -> reaches the file" {
    # line takes the same options as write and passes them on. A line written
    # to a file that is made here decides what that file is made with.
    stealth::sys::io::fs::line "${WORK}/one" 'a line' --mode 0600

    run stat -c '%a' "${WORK}/one"
    assert_output '600'
}

@test "stealth::sys::io::fs::line: --owner -> reaches the file" {
    mock chown '*' 'return 0'

    stealth::sys::io::fs::line "${WORK}/one" 'a line' --owner 'root:root'

    assert_called_with chown '*root:root*'
}

@test "stealth::sys::io::fs::line: --sync -> the wait is asked for" {
    mock sync '*' 'return 0'

    stealth::sys::io::fs::line "${WORK}/one" 'a line' --sync

    assert_called_with sync '*'
}

@test "stealth::sys::io::fs::line: --match with no expression -> exits 1" {
    run stealth::sys::io::fs::line "${WORK}/conf" 'x' --match
    assert_refused '--match takes an expression'
}

@test "stealth::sys::io::fs::line: no target -> exits 1" {
    run stealth::sys::io::fs::line ''
    assert_refused 'a target is required'
}

@test "stealth::sys::io::fs::line: no line -> exits 1" {
    run stealth::sys::io::fs::line "${WORK}/conf"
    assert_refused 'a line is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::cp
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::cp: a file -> is at the destination" {
    printf 'the contents\n' > "${WORK}/src"

    stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/dst"

    assert_file_contains "${WORK}/dst" 'the contents'
}

@test "stealth::sys::io::fs::cp: a destination that is not there -> the path is made" {
    printf 'x\n' > "${WORK}/src"

    stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/a/b/dst"

    assert_file_exists "${WORK}/a/b/dst"
}

@test "stealth::sys::io::fs::cp: a mode -> is what the destination is made with" {
    printf 'x\n' > "${WORK}/src"

    stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/dst" --mode 0755

    assert_file_permission 755 "${WORK}/dst"
}

@test "stealth::sys::io::fs::cp: a destination that already holds it -> is not touched" {
    printf 'same\n' > "${WORK}/src"
    stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/dst"
    touch -d '1 hour ago' "${WORK}/dst"
    local before after
    before="$(mtime "${WORK}/dst")"

    stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/dst"

    after="$(mtime "${WORK}/dst")"
    assert_equal "${after}" "${before}"
}

@test "stealth::sys::io::fs::cp: a destination whose attributes cannot be read -> returns 1" {
    printf 'new\n' > "${WORK}/src"
    printf 'as it was\n' > "${WORK}/one"
    mock cp '*' 'return 1'

    run stealth::sys::io::fs::cp "${WORK}/src" "${WORK}/one"
    assert_failure 1
    assert_file_contains "${WORK}/one" 'as it was'
}

@test "stealth::sys::io::fs::cp: no such source -> exits 1" {
    run stealth::sys::io::fs::cp "${WORK}/nowhere" "${WORK}/dst"
    assert_refused "no file to copy at ${WORK}/nowhere"
}

@test "stealth::sys::io::fs::cp: no destination -> exits 1" {
    printf 'x\n' > "${WORK}/src"

    run stealth::sys::io::fs::cp "${WORK}/src"
    assert_refused 'a destination is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::touch
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::touch: a file that is not there -> is made" {
    stealth::sys::io::fs::touch "${WORK}/a/b/log"

    assert_file_exists "${WORK}/a/b/log"
}

@test "stealth::sys::io::fs::touch: a mode -> is what it is made with" {
    stealth::sys::io::fs::touch "${WORK}/log" --mode 0640

    assert_file_permission 640 "${WORK}/log"
}

@test "stealth::sys::io::fs::touch: a file that is there -> is left as it is" {
    printf 'the contents\n' > "${WORK}/log"

    stealth::sys::io::fs::touch "${WORK}/log"

    assert_file_contains "${WORK}/log" 'the contents'
}

@test "stealth::sys::io::fs::touch: no file -> exits 1" {
    run stealth::sys::io::fs::touch ''
    assert_refused 'a file is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::rm
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::rm: a file -> is gone" {
    : > "${WORK}/one"

    stealth::sys::io::fs::rm "${WORK}/one"

    assert_file_not_exists "${WORK}/one"
}

@test "stealth::sys::io::fs::rm: a directory -> takes what is in it" {
    mkdir -p "${WORK}/tree/deep"
    : > "${WORK}/tree/deep/one"

    stealth::sys::io::fs::rm "${WORK}/tree"

    assert_dir_not_exists "${WORK}/tree"
}

@test "stealth::sys::io::fs::rm: several -> go together" {
    : > "${WORK}/one"
    : > "${WORK}/two"

    stealth::sys::io::fs::rm "${WORK}/one" "${WORK}/two"

    assert_file_not_exists "${WORK}/one"
    assert_file_not_exists "${WORK}/two"
}

@test "stealth::sys::io::fs::rm: a path that is already gone -> is no trouble" {
    run stealth::sys::io::fs::rm "${WORK}/never"
    assert_success
}

@test "stealth::sys::io::fs::rm: a directory of the system -> exits 1" {
    run stealth::sys::io::fs::rm /usr
    assert_refused '/usr is not a path that may be removed'
}

@test "stealth::sys::io::fs::rm: a relative path -> exits 1" {
    run stealth::sys::io::fs::rm 'work/one'
    assert_refused 'work/one is not a path that may be removed'
}

@test "stealth::sys::io::fs::rm: no path -> exits 1" {
    run stealth::sys::io::fs::rm ''
    assert_refused 'a path is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::link
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::link: a link -> points where it was told" {
    stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    assert_symlink_to /usr/lib/stealth "${WORK}/lib"
}

@test "stealth::sys::io::fs::link: a link that is already there -> is replaced" {
    stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    stealth::sys::io::fs::link /opt/stealth/lib "${WORK}/lib"

    assert_symlink_to /opt/stealth/lib "${WORK}/lib"
}

@test "stealth::sys::io::fs::link: a link that already points there -> is left alone" {
    stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    run stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    assert_success
}

@test "stealth::sys::io::fs::link: a directory that is not there -> is made on the way" {
    stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/a/b/lib"

    assert_symlink_to /usr/lib/stealth "${WORK}/a/b/lib"
}

@test "stealth::sys::io::fs::link: a link -> leaves nothing staged behind" {
    stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    run staged_left
    assert_output '0'
}

@test "stealth::sys::io::fs::link: a link with no directory in its path -> is made beside it" {
    cd "${WORK}"

    stealth::sys::io::fs::link /usr/lib/stealth 'bare'

    assert_symlink_to /usr/lib/stealth "${WORK}/bare"
}

@test "stealth::sys::io::fs::link: a link that cannot be put in place -> returns 1" {
    mock mv '*' 'return 1'

    run stealth::sys::io::fs::link /usr/lib/stealth "${WORK}/lib"

    assert_failure 1
    assert_called_with stealth::util::log::warn '*could not be put in place*'
}

@test "stealth::sys::io::fs::link: nothing to point at -> exits 1" {
    run stealth::sys::io::fs::link ''
    assert_refused 'something for the link to point at is required'
}

@test "stealth::sys::io::fs::link: no link -> exits 1" {
    run stealth::sys::io::fs::link /usr/lib/stealth
    assert_refused 'a link is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::is_empty
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::is_empty: a file holding nothing -> returns 0" {
    : > "${WORK}/one"

    run stealth::sys::io::fs::is_empty "${WORK}/one"
    assert_success
}

@test "stealth::sys::io::fs::is_empty: a file holding something -> returns 1" {
    printf 'x\n' > "${WORK}/one"

    run stealth::sys::io::fs::is_empty "${WORK}/one"
    assert_failure 1
}

@test "stealth::sys::io::fs::is_empty: no such file -> returns 1" {
    run stealth::sys::io::fs::is_empty "${WORK}/nowhere"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::_take_options
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::_take_options: the options -> come out separately" {
    local mode owner
    local -i sync=0
    local -a rest=()

    stealth::sys::io::fs::_take_options mode owner sync rest \
        /a/path --mode 0600 --owner root:root --sync 'the rest'

    assert_var_equal mode 0600
    assert_var_equal owner root:root
    assert_var_equal sync 1
    assert_array_equal rest /a/path 'the rest'
}

@test "stealth::sys::io::fs::_take_options: a double hyphen -> ends the options" {
    local mode owner
    local -i sync=0
    local -a rest=()

    stealth::sys::io::fs::_take_options mode owner sync rest \
        /a/path -- --mode --sync

    assert_var_equal mode ''
    assert_array_equal rest /a/path --mode --sync
}

@test "stealth::sys::io::fs::_take_options: a write making a directory -> keeps its own mode" {
    # mkdir reads options too. They used to be variables of the module, so a
    # write that made a directory on its way lost the mode it was given.
    stealth::sys::io::fs::write "${WORK}/deep/down/netrc" 'secret' --mode 0600

    assert_file_permission 600 "${WORK}/deep/down/netrc"
    assert_file_permission 755 "${WORK}/deep/down"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::_stage
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::_stage: a target that is there -> the mode carries over" {
    printf 'x\n' > "${WORK}/one"
    chmod 0600 "${WORK}/one"
    local staged

    stealth::sys::io::fs::_stage staged "${WORK}/one" 0

    assert_file_permission 600 "${staged}"
}

@test "stealth::sys::io::fs::_stage: without the content -> the staged file is empty" {
    printf 'a good deal of content\n' > "${WORK}/one"
    local staged

    stealth::sys::io::fs::_stage staged "${WORK}/one" 0

    assert_file_empty "${staged}"
}

@test "stealth::sys::io::fs::_stage: with the content -> the staged file holds it" {
    printf 'the contents\n' > "${WORK}/one"
    local staged

    stealth::sys::io::fs::_stage staged "${WORK}/one" 1

    assert_file_contains "${staged}" 'the contents'
}

@test "stealth::sys::io::fs::_stage: what the target is cannot be carried over -> says so" {
    printf 'x\n' > "${WORK}/one"
    mock cp '*' 'return 1'
    local staged

    stealth::sys::io::fs::_stage staged "${WORK}/one" 0 || true

    assert_called_with stealth::util::log::warn '*could not be carried over*'
}

@test "stealth::sys::io::fs::_stage: what the target is cannot be carried over -> returns 1" {
    # Going on would write a file with none of the target's attributes, and
    # the caller would be told the write succeeded.
    printf 'x\n' > "${WORK}/one"
    mock cp '*' 'return 1'
    local staged

    run stealth::sys::io::fs::_stage staged "${WORK}/one" 0
    assert_failure 1
}

@test "stealth::sys::io::fs::_stage: a target with no directory in its path -> stages beside it" {
    local staged
    cd "${WORK}"

    stealth::sys::io::fs::_stage staged 'bare' 0

    assert_starts_with "${staged}" './'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::fs::_commit
# ------------------------------------------------------------------------------

@test "stealth::sys::io::fs::_commit: a staged file that cannot be renamed -> returns 1" {
    printf 'as it was\n' > "${WORK}/one"
    local staged
    stealth::sys::io::fs::_stage staged "${WORK}/one" 0
    printf 'new\n' > "${staged}"
    mock mv '*' 'return 1'

    run stealth::sys::io::fs::_commit "${WORK}/one" "${staged}" '' '' 0

    assert_failure 1
    assert_file_contains "${WORK}/one" 'as it was'
}

@test "stealth::sys::io::fs::_commit: the same content and a mode -> the mode is still set" {
    # The staged file is dropped because the bytes match. The mode asked for
    # would go with it, and the caller would be told the write succeeded.
    printf 'same\n' > "${WORK}/one"
    chmod 0644 "${WORK}/one"
    local staged
    stealth::sys::io::fs::_stage staged "${WORK}/one" 1

    stealth::sys::io::fs::_commit "${WORK}/one" "${staged}" '0600' '' 0

    run stat -c '%a' "${WORK}/one"
    assert_output '600'
}

@test "stealth::sys::io::fs::_commit: the same content and an owner -> the owner is still set" {
    printf 'same\n' > "${WORK}/one"
    local staged
    stealth::sys::io::fs::_stage staged "${WORK}/one" 1
    mock chown '*' 'return 0'

    stealth::sys::io::fs::_commit "${WORK}/one" "${staged}" '' 'root:root' 0

    assert_called_with chown '*root:root*'
}

@test "stealth::sys::io::fs::_commit: an owner -> is set on the staged file" {
    local staged
    stealth::sys::io::fs::_stage staged "${WORK}/one" 0
    printf 'x\n' > "${staged}"
    mock chown '*' 'return 0'

    stealth::sys::io::fs::_commit "${WORK}/one" "${staged}" '' 'root:root' 0

    assert_called_with chown '*root:root*'
}

# ------------------------------------------------------------------------------
# sys/io/fs, the module itself
# ------------------------------------------------------------------------------

@test "sys/io/fs: a target that is a symlink -> the link is replaced, not what it points at" {
    printf 'the real file\n' > "${WORK}/real"
    ln -s "${WORK}/real" "${WORK}/link"

    stealth::sys::io::fs::write "${WORK}/link" 'written through'

    assert_file_contains "${WORK}/real" 'the real file'
    assert_file_contains "${WORK}/link" 'written through'
}

@test "sys/io/fs: sourced twice -> returns before it declares anything" {
    stealth::sys::io::fs::write "${WORK}/one" 'x'

    load_lib sys/io/fs

    assert_file_contains "${WORK}/one" 'x'
}
