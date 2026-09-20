#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/text - Test Suite
# ==============================================================================
# Every function writes through a nameref, so the happy paths use
# assert_nameref, which calls the function with an output variable of its own
# and reads what came back. A function that refuses its arguments ends the
# process through util/log, which is mocked, so those cases read the status
# and the call.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/text
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::util::text::trim
# ------------------------------------------------------------------------------

@test "stealth::util::text::trim: spaces at both ends -> removes them" {
    assert_nameref 'zlib' stealth::util::text::trim '   zlib   '
}

@test "stealth::util::text::trim: tabs and newlines -> removes them too" {
    assert_nameref 'zlib' stealth::util::text::trim $'\t\n zlib \n\t'
}

@test "stealth::util::text::trim: nothing to remove -> returns the value" {
    assert_nameref 'zlib' stealth::util::text::trim 'zlib'
}

@test "stealth::util::text::trim: an inner space -> keeps it" {
    assert_nameref 'gcc pass one' stealth::util::text::trim '  gcc pass one  '
}

@test "stealth::util::text::trim: whitespace only -> returns empty" {
    assert_nameref '' stealth::util::text::trim $'  \t  '
}

@test "stealth::util::text::trim: no value -> returns empty" {
    assert_nameref '' stealth::util::text::trim
}

@test "stealth::util::text::trim: no output variable -> exits 1" {
    run stealth::util::text::trim ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::trim_start
# ------------------------------------------------------------------------------

@test "stealth::util::text::trim_start: whitespace at the start -> removes it" {
    assert_nameref 'zlib  ' stealth::util::text::trim_start '  zlib  '
}

@test "stealth::util::text::trim_start: whitespace at the end only -> keeps it" {
    assert_nameref 'zlib  ' stealth::util::text::trim_start 'zlib  '
}

@test "stealth::util::text::trim_start: no output variable -> exits 1" {
    run stealth::util::text::trim_start ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::trim_end
# ------------------------------------------------------------------------------

@test "stealth::util::text::trim_end: whitespace at the end -> removes it" {
    assert_nameref '  zlib' stealth::util::text::trim_end '  zlib  '
}

@test "stealth::util::text::trim_end: whitespace at the start only -> keeps it" {
    assert_nameref '  zlib' stealth::util::text::trim_end '  zlib'
}

@test "stealth::util::text::trim_end: no output variable -> exits 1" {
    run stealth::util::text::trim_end ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::squeeze
# ------------------------------------------------------------------------------

@test "stealth::util::text::squeeze: a run of spaces -> leaves one" {
    assert_nameref 'gcc pass one' stealth::util::text::squeeze 'gcc    pass  one'
}

@test "stealth::util::text::squeeze: a tab and a newline -> each becomes a space" {
    assert_nameref 'a b c' stealth::util::text::squeeze $'a\tb\nc'
}

@test "stealth::util::text::squeeze: whitespace at the ends -> removes it" {
    assert_nameref 'zlib' stealth::util::text::squeeze $'  \t zlib \n '
}

@test "stealth::util::text::squeeze: single spaces only -> returns the value" {
    assert_nameref 'gcc pass one' stealth::util::text::squeeze 'gcc pass one'
}

@test "stealth::util::text::squeeze: no output variable -> exits 1" {
    run stealth::util::text::squeeze ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::to_lower
# ------------------------------------------------------------------------------

@test "stealth::util::text::to_lower: upper case -> converts it" {
    assert_nameref 'debug' stealth::util::text::to_lower 'DEBUG'
}

@test "stealth::util::text::to_lower: a digit and a symbol -> leaves them" {
    assert_nameref 'sha256:ab' stealth::util::text::to_lower 'SHA256:AB'
}

@test "stealth::util::text::to_lower: no output variable -> exits 1" {
    run stealth::util::text::to_lower ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::to_upper
# ------------------------------------------------------------------------------

@test "stealth::util::text::to_upper: lower case -> converts it" {
    assert_nameref 'DEBUG' stealth::util::text::to_upper 'debug'
}

@test "stealth::util::text::to_upper: no output variable -> exits 1" {
    run stealth::util::text::to_upper ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::to_const
# ------------------------------------------------------------------------------

@test "stealth::util::text::to_const: a module path -> gives a constant name" {
    assert_nameref 'SYS_IO_FS' stealth::util::text::to_const 'sys/io/fs'
}

@test "stealth::util::text::to_const: a hyphen -> becomes an underscore" {
    assert_nameref 'LOG_LEVEL' stealth::util::text::to_const 'log-level'
}

@test "stealth::util::text::to_const: a constant name -> returns it" {
    assert_nameref 'STEALTH_LIB' stealth::util::text::to_const 'STEALTH_LIB'
}

@test "stealth::util::text::to_const: no output variable -> exits 1" {
    run stealth::util::text::to_const ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::replace
# ------------------------------------------------------------------------------

@test "stealth::util::text::replace: a substring -> replaces every occurrence" {
    assert_nameref 'a-b-c' stealth::util::text::replace 'a:b:c' ':' '-'
}

@test "stealth::util::text::replace: a glob -> replaces what it matches" {
    assert_nameref 'ac' stealth::util::text::replace 'a<b>c' '<*>' ''
}

@test "stealth::util::text::replace: no replacement -> removes the match" {
    assert_nameref 'abc' stealth::util::text::replace 'a b c' ' '
}

@test "stealth::util::text::replace: a pattern that is not there -> returns the value" {
    assert_nameref 'zlib' stealth::util::text::replace 'zlib' 'x' 'y'
}

@test "stealth::util::text::replace: no pattern -> exits 1" {
    run stealth::util::text::replace out 'zlib'
    assert_refused 'a pattern is required'
}

@test "stealth::util::text::replace: no output variable -> exits 1" {
    run stealth::util::text::replace ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::remove_prefix
# ------------------------------------------------------------------------------

@test "stealth::util::text::remove_prefix: the prefix is there -> removes it" {
    assert_nameref 'ab' stealth::util::text::remove_prefix 'sha256:ab' 'sha256:'
}

@test "stealth::util::text::remove_prefix: the prefix is not there -> returns the value" {
    assert_nameref 'ab' stealth::util::text::remove_prefix 'ab' 'sha256:'
}

@test "stealth::util::text::remove_prefix: no output variable -> exits 1" {
    run stealth::util::text::remove_prefix ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::remove_suffix
# ------------------------------------------------------------------------------

@test "stealth::util::text::remove_suffix: the suffix is there -> removes it" {
    assert_nameref 'rootfs' stealth::util::text::remove_suffix 'rootfs.tar' '.tar'
}

@test "stealth::util::text::remove_suffix: the suffix is not there -> returns the value" {
    assert_nameref 'rootfs' stealth::util::text::remove_suffix 'rootfs' '.tar'
}

@test "stealth::util::text::remove_suffix: no output variable -> exits 1" {
    run stealth::util::text::remove_suffix ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::indent
# ------------------------------------------------------------------------------

@test "stealth::util::text::indent: one line -> puts two spaces in front" {
    assert_nameref '  zlib' stealth::util::text::indent 'zlib'
}

@test "stealth::util::text::indent: several lines -> indents each of them" {
    assert_nameref $'    a\n    b' stealth::util::text::indent $'a\nb' '    '
}

@test "stealth::util::text::indent: an empty prefix -> returns the value" {
    assert_nameref 'zlib' stealth::util::text::indent 'zlib' ''
}

@test "stealth::util::text::indent: an empty value -> returns empty" {
    assert_nameref '' stealth::util::text::indent ''
}

@test "stealth::util::text::indent: no output variable -> exits 1" {
    run stealth::util::text::indent ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::slug
# ------------------------------------------------------------------------------

@test "stealth::util::text::slug: a name and a version -> joins them with a hyphen" {
    assert_nameref 'gcc-13-2-0' stealth::util::text::slug 'GCC 13.2.0'
}

@test "stealth::util::text::slug: a run of other characters -> leaves one hyphen" {
    assert_nameref 'a-b' stealth::util::text::slug 'a   ///   b'
}

@test "stealth::util::text::slug: characters at the ends -> removes the hyphens" {
    assert_nameref 'zlib' stealth::util::text::slug '  zlib.  '
}

@test "stealth::util::text::slug: a slug -> returns it" {
    assert_nameref 'gcc-pass-one' stealth::util::text::slug 'gcc-pass-one'
}

@test "stealth::util::text::slug: nothing usable -> returns empty" {
    assert_nameref '' stealth::util::text::slug '...'
}

@test "stealth::util::text::slug: no output variable -> exits 1" {
    run stealth::util::text::slug ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::filename
# ------------------------------------------------------------------------------

@test "stealth::util::text::filename: a separator -> becomes an underscore" {
    assert_nameref 'a_b_c.tar' stealth::util::text::filename 'a/b c.tar'
}

@test "stealth::util::text::filename: a dot and a hyphen -> keeps them" {
    assert_nameref 'gcc-13.2.0.tar.zst' stealth::util::text::filename 'gcc-13.2.0.tar.zst'
}

@test "stealth::util::text::filename: leading dots and hyphens -> removes them" {
    assert_nameref 'rf' stealth::util::text::filename '.-.-rf'
}

@test "stealth::util::text::filename: longer than the limit -> cuts it to the limit" {
    local long out
    printf -v long '%0.sa' {1..300}

    stealth::util::text::filename out "${long}"

    assert_equal "${#out}" 255
}

@test "stealth::util::text::filename: dots alone -> exits 1" {
    run stealth::util::text::filename out '..'
    assert_refused 'no filename can be built from ..'
}

@test "stealth::util::text::filename: no output variable -> exits 1" {
    run stealth::util::text::filename ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::quote
# ------------------------------------------------------------------------------

@test "stealth::util::text::quote: a value with a space -> the shell reads it as one word" {
    local quoted
    stealth::util::text::quote quoted 'gcc pass one'

    local -a words=()
    eval "words=(${quoted})"

    assert_array_equal words 'gcc pass one'
}

@test "stealth::util::text::quote: a value with a quote -> the shell reads it back" {
    local quoted
    stealth::util::text::quote quoted "it's"

    local -a words=()
    eval "words=(${quoted})"

    assert_array_equal words "it's"
}

@test "stealth::util::text::quote: a word that needs nothing -> returns it" {
    assert_nameref 'zlib' stealth::util::text::quote 'zlib'
}

@test "stealth::util::text::quote: no output variable -> exits 1" {
    run stealth::util::text::quote ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::split
# ------------------------------------------------------------------------------

@test "stealth::util::text::split: a delimiter of one character -> gives the fields" {
    local -a parts=()
    stealth::util::text::split parts 'a,b,c' ','

    assert_array_equal parts a b c
}

@test "stealth::util::text::split: a delimiter of several characters -> gives the fields" {
    local -a parts=()
    stealth::util::text::split parts 'zlib, gcc, make' ', '

    assert_array_equal parts zlib gcc make
}

@test "stealth::util::text::split: the delimiter is not there -> gives one field" {
    local -a parts=()
    stealth::util::text::split parts 'zlib' ','

    assert_array_equal parts zlib
}

@test "stealth::util::text::split: a field between two delimiters is empty -> keeps it" {
    local -a parts=()
    stealth::util::text::split parts 'a,,c' ','

    assert_array_equal parts a '' c
}

@test "stealth::util::text::split: a delimiter at the end -> keeps the empty field" {
    local -a parts=()
    stealth::util::text::split parts 'a,' ','

    assert_array_equal parts a ''
}

@test "stealth::util::text::split: an empty value -> gives one empty field" {
    local -a parts=()
    stealth::util::text::split parts '' ','

    assert_array_equal parts ''
}

@test "stealth::util::text::split: a key and a value -> splits on the first delimiter only when asked" {
    local -a parts=()
    stealth::util::text::split parts 'KEY=a=b' '='

    assert_array_equal parts KEY a b
}

@test "stealth::util::text::split: no delimiter -> exits 1" {
    run stealth::util::text::split parts 'a,b'
    assert_refused 'a delimiter is required'
}

@test "stealth::util::text::split: no output variable -> exits 1" {
    run stealth::util::text::split ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::join
# ------------------------------------------------------------------------------

@test "stealth::util::text::join: several elements -> puts the delimiter between them" {
    assert_nameref 'zlib, gcc, make' stealth::util::text::join ', ' zlib gcc make
}

@test "stealth::util::text::join: one element -> returns it" {
    assert_nameref 'zlib' stealth::util::text::join ', ' zlib
}

@test "stealth::util::text::join: no element -> returns empty" {
    assert_nameref '' stealth::util::text::join ', '
}

@test "stealth::util::text::join: an empty delimiter -> joins them together" {
    assert_nameref 'abc' stealth::util::text::join '' a b c
}

@test "stealth::util::text::join: an element with a space -> keeps it whole" {
    assert_nameref 'gcc pass one:zlib' stealth::util::text::join ':' 'gcc pass one' zlib
}

@test "stealth::util::text::join: no output variable -> exits 1" {
    run stealth::util::text::join ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::text::contains
# ------------------------------------------------------------------------------

@test "stealth::util::text::contains: the substring is there -> returns 0" {
    run stealth::util::text::contains 'KEY=value' '='
    assert_success
}

@test "stealth::util::text::contains: the substring is not there -> returns 1" {
    run stealth::util::text::contains 'KEY' '='
    assert_failure 1
}

@test "stealth::util::text::contains: no arguments -> returns 0 for the empty substring" {
    run stealth::util::text::contains
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::util::text::starts_with
# ------------------------------------------------------------------------------

@test "stealth::util::text::starts_with: the prefix is there -> returns 0" {
    run stealth::util::text::starts_with 'sha256:ab' 'sha256:'
    assert_success
}

@test "stealth::util::text::starts_with: the prefix is not there -> returns 1" {
    run stealth::util::text::starts_with 'ab' 'sha256:'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::text::ends_with
# ------------------------------------------------------------------------------

@test "stealth::util::text::ends_with: the suffix is there -> returns 0" {
    run stealth::util::text::ends_with 'rootfs.tar.zst' '.zst'
    assert_success
}

@test "stealth::util::text::ends_with: the suffix is not there -> returns 1" {
    run stealth::util::text::ends_with 'rootfs.tar' '.zst'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::text::is_blank
# ------------------------------------------------------------------------------

@test "stealth::util::text::is_blank: an empty value -> returns 0" {
    run stealth::util::text::is_blank ''
    assert_success
}

@test "stealth::util::text::is_blank: whitespace only -> returns 0" {
    run stealth::util::text::is_blank $'  \t\n '
    assert_success
}

@test "stealth::util::text::is_blank: no argument -> returns 0" {
    run stealth::util::text::is_blank
    assert_success
}

@test "stealth::util::text::is_blank: a value -> returns 1" {
    run stealth::util::text::is_blank '  zlib  '
    assert_failure 1
}

# ------------------------------------------------------------------------------
# util/text, the module itself
# ------------------------------------------------------------------------------

@test "util/text: sourced twice -> returns before it declares anything" {
    load_lib util/text

    assert_nameref 'zlib' stealth::util::text::trim ' zlib '
}
