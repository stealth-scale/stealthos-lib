#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/fmt - Test Suite
# ==============================================================================
# Every function writes through a nameref, so the happy paths use
# assert_nameref. A function that refuses its arguments ends the process
# through util/log, which is mocked, and assert_refused reads that call.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/fmt
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Red text and the sequence that resets it, as util/log writes them.
readonly RED=$'\033[31m'
readonly RESET=$'\033[0m'

# ------------------------------------------------------------------------------
# stealth::util::fmt::strip_ansi
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::strip_ansi: a coloured value -> leaves the text" {
    assert_nameref 'FAIL' stealth::util::fmt::strip_ansi "${RED}FAIL${RESET}"
}

@test "stealth::util::fmt::strip_ansi: several sequences -> removes each of them" {
    assert_nameref 'ab' stealth::util::fmt::strip_ansi "${RED}a${RESET}${RED}b${RESET}"
}

@test "stealth::util::fmt::strip_ansi: a cursor sequence -> removes it" {
    assert_nameref 'done' stealth::util::fmt::strip_ansi $'\033[?25ldone\033[2K'
}

@test "stealth::util::fmt::strip_ansi: no sequence -> returns the value" {
    assert_nameref 'plain text' stealth::util::fmt::strip_ansi 'plain text'
}

@test "stealth::util::fmt::strip_ansi: a sequence that never ends -> removes the rest" {
    assert_nameref 'a' stealth::util::fmt::strip_ansi $'a\033[31'
}

@test "stealth::util::fmt::strip_ansi: an empty value -> returns empty" {
    assert_nameref '' stealth::util::fmt::strip_ansi ''
}

@test "stealth::util::fmt::strip_ansi: no output variable -> exits 1" {
    run stealth::util::fmt::strip_ansi ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::width
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::width: plain text -> counts the characters" {
    assert_nameref '4' stealth::util::fmt::width 'FAIL'
}

@test "stealth::util::fmt::width: a coloured value -> counts what a reader sees" {
    assert_nameref '4' stealth::util::fmt::width "${RED}FAIL${RESET}"
}

@test "stealth::util::fmt::width: an empty value -> counts nothing" {
    assert_nameref '0' stealth::util::fmt::width ''
}

@test "stealth::util::fmt::width: no output variable -> exits 1" {
    run stealth::util::fmt::width ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::repeat
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::repeat: a character and a count -> repeats it" {
    assert_nameref '-----' stealth::util::fmt::repeat '-' 5
}

@test "stealth::util::fmt::repeat: a value of several characters -> repeats all of it" {
    assert_nameref 'ababab' stealth::util::fmt::repeat 'ab' 3
}

@test "stealth::util::fmt::repeat: a count of zero -> returns empty" {
    assert_nameref '' stealth::util::fmt::repeat '-' 0
}

@test "stealth::util::fmt::repeat: a count below zero -> returns empty" {
    assert_nameref '' stealth::util::fmt::repeat '-' -3
}

@test "stealth::util::fmt::repeat: a count that is not a number -> exits 1" {
    run stealth::util::fmt::repeat out '-' many
    assert_refused 'a count is a whole number, not many'
}

@test "stealth::util::fmt::repeat: no output variable -> exits 1" {
    run stealth::util::fmt::repeat ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::pad_right
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::pad_right: a value under the width -> pads it to the width" {
    assert_nameref 'key       ' stealth::util::fmt::pad_right 'key' 10
}

@test "stealth::util::fmt::pad_right: a value at the width -> returns it" {
    assert_nameref 'exactly10!' stealth::util::fmt::pad_right 'exactly10!' 10
}

@test "stealth::util::fmt::pad_right: a value over the width -> returns it whole" {
    assert_nameref 'far too long' stealth::util::fmt::pad_right 'far too long' 5
}

@test "stealth::util::fmt::pad_right: a character to pad with -> uses it" {
    assert_nameref 'key.......' stealth::util::fmt::pad_right 'key' 10 '.'
}

@test "stealth::util::fmt::pad_right: a coloured value -> pads to what a reader sees" {
    assert_nameref "${RED}FAIL${RESET}...." \
        stealth::util::fmt::pad_right "${RED}FAIL${RESET}" 8 '.'
}

@test "stealth::util::fmt::pad_right: a width that is not a number -> exits 1" {
    run stealth::util::fmt::pad_right out 'key' wide
    assert_refused 'a width is a whole number, not wide'
}

@test "stealth::util::fmt::pad_right: no output variable -> exits 1" {
    run stealth::util::fmt::pad_right ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::pad_left
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::pad_left: a value under the width -> pads in front of it" {
    assert_nameref '    42' stealth::util::fmt::pad_left '42' 6
}

@test "stealth::util::fmt::pad_left: a character to pad with -> uses it" {
    assert_nameref '0042' stealth::util::fmt::pad_left '42' 4 '0'
}

@test "stealth::util::fmt::pad_left: a value over the width -> returns it whole" {
    assert_nameref '123456' stealth::util::fmt::pad_left '123456' 3
}

@test "stealth::util::fmt::pad_left: a width that is not a number -> exits 1" {
    run stealth::util::fmt::pad_left out '42' wide
    assert_refused 'a width is a whole number, not wide'
}

@test "stealth::util::fmt::pad_left: no output variable -> exits 1" {
    run stealth::util::fmt::pad_left ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::truncate
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::truncate: a value over the width -> cuts it and marks it" {
    assert_nameref 'sys/io/...' stealth::util::fmt::truncate 'sys/io/fs/atomic' 10
}

@test "stealth::util::fmt::truncate: a value under the width -> returns it" {
    assert_nameref 'short' stealth::util::fmt::truncate 'short' 10
}

@test "stealth::util::fmt::truncate: a value at the width -> returns it" {
    assert_nameref 'exactly10!' stealth::util::fmt::truncate 'exactly10!' 10
}

@test "stealth::util::fmt::truncate: a marker of its own -> uses it" {
    assert_nameref 'sys/io/fs>' stealth::util::fmt::truncate 'sys/io/fs/atomic' 10 '>'
}

@test "stealth::util::fmt::truncate: no room for the marker -> cuts without it" {
    assert_nameref 'ab' stealth::util::fmt::truncate 'abcdef' 2
}

@test "stealth::util::fmt::truncate: an empty marker -> cuts to the width" {
    assert_nameref 'abcde' stealth::util::fmt::truncate 'abcdef' 5 ''
}

@test "stealth::util::fmt::truncate: a width that is not a number -> exits 1" {
    run stealth::util::fmt::truncate out 'abc' wide
    assert_refused 'a width is a whole number, not wide'
}

@test "stealth::util::fmt::truncate: no output variable -> exits 1" {
    run stealth::util::fmt::truncate ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::wrap
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::wrap: text over the width -> breaks between words" {
    assert_nameref $'the quick brown fox\njumps over the lazy\ndog' \
        stealth::util::fmt::wrap 'the quick brown fox jumps over the lazy dog' 20
}

@test "stealth::util::fmt::wrap: text under the width -> returns one line" {
    assert_nameref 'one line' stealth::util::fmt::wrap 'one line' 20
}

@test "stealth::util::fmt::wrap: a line break in the value -> keeps it" {
    assert_nameref $'a\nb' stealth::util::fmt::wrap $'a\nb' 20
}

@test "stealth::util::fmt::wrap: a word over the width -> leaves it whole on its line" {
    assert_nameref $'sha256:aaaaaaaaaaaaaaaaaaaaaaaa\nis long' \
        stealth::util::fmt::wrap 'sha256:aaaaaaaaaaaaaaaaaaaaaaaa is long' 20
}

@test "stealth::util::fmt::wrap: a prefix -> puts it in front of every line" {
    assert_nameref $'| a\n| b' stealth::util::fmt::wrap $'a\nb' 20 '| '
}

@test "stealth::util::fmt::wrap: a prefix -> counts toward the width" {
    assert_nameref $'>>>>>one two\n>>>>>three' \
        stealth::util::fmt::wrap 'one two three' 13 '>>>>>'
}

@test "stealth::util::fmt::wrap: whitespace between words -> becomes one space" {
    assert_nameref 'a b c' stealth::util::fmt::wrap $'a   b\tc' 20
}

@test "stealth::util::fmt::wrap: a width that is not a number -> exits 1" {
    run stealth::util::fmt::wrap out 'text' wide
    assert_refused 'a width is a whole number, not wide'
}

@test "stealth::util::fmt::wrap: no output variable -> exits 1" {
    run stealth::util::fmt::wrap ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::fmt::_filler
# ------------------------------------------------------------------------------

@test "stealth::util::fmt::_filler: a value under the width -> gives what is missing" {
    assert_nameref '...' stealth::util::fmt::_filler 'ab' 5 '.'
}

@test "stealth::util::fmt::_filler: a value at the width -> gives nothing" {
    assert_nameref '' stealth::util::fmt::_filler 'abcde' 5 '.'
}

# ------------------------------------------------------------------------------
# util/fmt, the module itself
# ------------------------------------------------------------------------------

@test "util/fmt: sourced twice -> returns before it declares anything" {
    load_lib util/fmt

    assert_nameref '---' stealth::util::fmt::repeat '-' 3
}
