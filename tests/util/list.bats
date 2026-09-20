#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/list - Test Suite
# ==============================================================================
# Every function takes the name of an array, so a test declares one, calls the
# subject and reads it back with the array assertions. A function that refuses
# its arguments ends the process through util/log, which is mocked, and
# assert_refused reads that call.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/list
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::util::list::contains
# ------------------------------------------------------------------------------

@test "stealth::util::list::contains: the value is there -> returns 0" {
    local -a packages=(zlib gcc make)

    run stealth::util::list::contains packages gcc
    assert_success
}

@test "stealth::util::list::contains: the value is not there -> returns 1" {
    local -a packages=(zlib gcc make)

    run stealth::util::list::contains packages perl
    assert_failure 1
}

@test "stealth::util::list::contains: a part of an element -> returns 1" {
    local -a packages=(zlib-devel)

    run stealth::util::list::contains packages zlib
    assert_failure 1
}

@test "stealth::util::list::contains: an element with a space -> matches it whole" {
    local -a steps=('gcc pass one' 'gcc pass two')

    run stealth::util::list::contains steps 'gcc pass one'
    assert_success
}

@test "stealth::util::list::contains: an empty array -> returns 1" {
    local -a packages=()

    run stealth::util::list::contains packages zlib
    assert_failure 1
}

@test "stealth::util::list::contains: no array named -> exits 1" {
    run stealth::util::list::contains ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::index_of
# ------------------------------------------------------------------------------

@test "stealth::util::list::index_of: the value is there -> gives its index" {
    local -a packages=(zlib gcc make)
    local at

    stealth::util::list::index_of at packages make

    assert_var_equal at 2
}

@test "stealth::util::list::index_of: the value is there twice -> gives the first index" {
    local -a packages=(zlib gcc zlib)
    local at

    stealth::util::list::index_of at packages zlib

    assert_var_equal at 0
}

@test "stealth::util::list::index_of: the value is not there -> gives -1" {
    local -a packages=(zlib gcc)
    local at

    stealth::util::list::index_of at packages perl

    assert_var_equal at -1
}

@test "stealth::util::list::index_of: an empty array -> gives -1" {
    local -a packages=()
    local at

    stealth::util::list::index_of at packages zlib

    assert_var_equal at -1
}

@test "stealth::util::list::index_of: no output variable -> exits 1" {
    run stealth::util::list::index_of ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::list::index_of: no array named -> exits 1" {
    run stealth::util::list::index_of at ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::append
# ------------------------------------------------------------------------------

@test "stealth::util::list::append: a value -> puts it at the end" {
    local -a packages=(zlib)

    stealth::util::list::append packages gcc

    assert_array_equal packages zlib gcc
}

@test "stealth::util::list::append: several values -> keeps their order" {
    local -a packages=(zlib)

    stealth::util::list::append packages gcc make

    assert_array_equal packages zlib gcc make
}

@test "stealth::util::list::append: a value that is already there -> adds it again" {
    local -a packages=(zlib)

    stealth::util::list::append packages zlib

    assert_array_equal packages zlib zlib
}

@test "stealth::util::list::append: an empty array -> holds the values" {
    local -a packages=()

    stealth::util::list::append packages zlib

    assert_array_equal packages zlib
}

@test "stealth::util::list::append: no value -> leaves the array alone" {
    local -a packages=(zlib)

    stealth::util::list::append packages

    assert_array_equal packages zlib
}

@test "stealth::util::list::append: no array named -> exits 1" {
    run stealth::util::list::append ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::prepend
# ------------------------------------------------------------------------------

@test "stealth::util::list::prepend: a value -> puts it at the front" {
    local -a paths=(/usr/bin)

    stealth::util::list::prepend paths /usr/local/bin

    assert_array_equal paths /usr/local/bin /usr/bin
}

@test "stealth::util::list::prepend: several values -> keeps their order at the front" {
    local -a paths=(/usr/bin)

    stealth::util::list::prepend paths /opt/bin /usr/local/bin

    assert_array_equal paths /opt/bin /usr/local/bin /usr/bin
}

@test "stealth::util::list::prepend: an empty array -> holds the values" {
    local -a paths=()

    stealth::util::list::prepend paths /usr/bin

    assert_array_equal paths /usr/bin
}

@test "stealth::util::list::prepend: no value -> leaves the array alone" {
    local -a paths=(/usr/bin)

    stealth::util::list::prepend paths

    assert_array_equal paths /usr/bin
}

@test "stealth::util::list::prepend: no array named -> exits 1" {
    run stealth::util::list::prepend ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::add_unique
# ------------------------------------------------------------------------------

@test "stealth::util::list::add_unique: a value that is not there -> adds it" {
    local -a deps=(zlib)

    stealth::util::list::add_unique deps gcc

    assert_array_equal deps zlib gcc
}

@test "stealth::util::list::add_unique: a value that is there -> leaves the array alone" {
    local -a deps=(zlib gcc)

    stealth::util::list::add_unique deps zlib

    assert_array_equal deps zlib gcc
}

@test "stealth::util::list::add_unique: the same value twice -> adds it once" {
    local -a deps=()

    stealth::util::list::add_unique deps zlib zlib

    assert_array_equal deps zlib
}

@test "stealth::util::list::add_unique: called twice -> the second call changes nothing" {
    local -a deps=()

    stealth::util::list::add_unique deps zlib gcc
    stealth::util::list::add_unique deps zlib gcc

    assert_array_equal deps zlib gcc
}

@test "stealth::util::list::add_unique: no array named -> exits 1" {
    run stealth::util::list::add_unique ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::remove
# ------------------------------------------------------------------------------

@test "stealth::util::list::remove: a value -> takes it out and closes the gap" {
    local -a packages=(zlib gcc make)

    stealth::util::list::remove packages gcc

    assert_array_equal packages zlib make
}

@test "stealth::util::list::remove: a value that is there twice -> takes out both" {
    local -a packages=(zlib gcc zlib)

    stealth::util::list::remove packages zlib

    assert_array_equal packages gcc
}

@test "stealth::util::list::remove: several values -> takes out each of them" {
    local -a packages=(zlib gcc make)

    stealth::util::list::remove packages zlib make

    assert_array_equal packages gcc
}

@test "stealth::util::list::remove: a value that is not there -> leaves the array alone" {
    local -a packages=(zlib gcc)

    stealth::util::list::remove packages perl

    assert_array_equal packages zlib gcc
}

@test "stealth::util::list::remove: every value -> leaves the array empty" {
    local -a packages=(zlib)

    stealth::util::list::remove packages zlib

    assert_array_empty packages
}

@test "stealth::util::list::remove: no array named -> exits 1" {
    run stealth::util::list::remove ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::remove_at
# ------------------------------------------------------------------------------

@test "stealth::util::list::remove_at: an index in the middle -> closes the gap" {
    local -a packages=(zlib gcc make)

    stealth::util::list::remove_at packages 1

    assert_array_equal packages zlib make
}

@test "stealth::util::list::remove_at: the first index -> takes out the first element" {
    local -a packages=(zlib gcc)

    stealth::util::list::remove_at packages 0

    assert_array_equal packages gcc
}

@test "stealth::util::list::remove_at: the last index -> takes out the last element" {
    local -a packages=(zlib gcc)

    stealth::util::list::remove_at packages 1

    assert_array_equal packages zlib
}

@test "stealth::util::list::remove_at: elements with spaces -> keeps them whole" {
    local -a steps=('gcc pass one' 'gcc pass two' 'glibc final')

    stealth::util::list::remove_at steps 1

    assert_array_equal steps 'gcc pass one' 'glibc final'
}

@test "stealth::util::list::remove_at: an index past the end -> leaves the array alone" {
    local -a packages=(zlib gcc)

    stealth::util::list::remove_at packages 9

    assert_array_equal packages zlib gcc
}

@test "stealth::util::list::remove_at: an index below zero -> leaves the array alone" {
    local -a packages=(zlib gcc)

    stealth::util::list::remove_at packages -1

    assert_array_equal packages zlib gcc
}

@test "stealth::util::list::remove_at: an index that is not a number -> exits 1" {
    local -a packages=(zlib)

    run stealth::util::list::remove_at packages last
    assert_refused 'an index is a whole number, not last'
}

@test "stealth::util::list::remove_at: no array named -> exits 1" {
    run stealth::util::list::remove_at ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::unique
# ------------------------------------------------------------------------------

@test "stealth::util::list::unique: a repeated value -> keeps the first of it" {
    local -a deps=(zlib gcc zlib make gcc)

    stealth::util::list::unique deps

    assert_array_equal deps zlib gcc make
}

@test "stealth::util::list::unique: no repeats -> leaves the order alone" {
    local -a deps=(make gcc zlib)

    stealth::util::list::unique deps

    assert_array_equal deps make gcc zlib
}

@test "stealth::util::list::unique: an empty array -> stays empty" {
    local -a deps=()

    stealth::util::list::unique deps

    assert_array_empty deps
}

@test "stealth::util::list::unique: no array named -> exits 1" {
    run stealth::util::list::unique ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::reverse
# ------------------------------------------------------------------------------

@test "stealth::util::list::reverse: several elements -> turns the order around" {
    local -a loaded=(util/log util/assert util/text)

    stealth::util::list::reverse loaded

    assert_array_equal loaded util/text util/assert util/log
}

@test "stealth::util::list::reverse: one element -> leaves it alone" {
    local -a loaded=(util/log)

    stealth::util::list::reverse loaded

    assert_array_equal loaded util/log
}

@test "stealth::util::list::reverse: an empty array -> stays empty" {
    local -a loaded=()

    stealth::util::list::reverse loaded

    assert_array_empty loaded
}

@test "stealth::util::list::reverse: no array named -> exits 1" {
    run stealth::util::list::reverse ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::sort
# ------------------------------------------------------------------------------

@test "stealth::util::list::sort: several elements -> puts them in byte order" {
    local -a files=(usr/lib/libc.so bin/sh etc/passwd)

    stealth::util::list::sort files

    assert_array_equal files bin/sh etc/passwd usr/lib/libc.so
}

@test "stealth::util::list::sort: upper and lower case -> sorts by byte, not by letter" {
    local -a names=(b A a B)

    stealth::util::list::sort names

    assert_array_equal names A B a b
}

@test "stealth::util::list::sort: one element -> leaves it alone" {
    local -a files=(bin/sh)

    stealth::util::list::sort files

    assert_array_equal files bin/sh
}

@test "stealth::util::list::sort: an empty array -> stays empty" {
    local -a files=()

    stealth::util::list::sort files

    assert_array_empty files
}

@test "stealth::util::list::sort: an element with a line break -> exits 1" {
    local -a files=($'a\nb' c)

    run stealth::util::list::sort files
    assert_refused "an element to sort holds a line break: ${files[0]}"
}

@test "stealth::util::list::sort: the sort command fails -> exits 1" {
    local -a files=(b a)
    mock sort '*' 'return 2'

    run stealth::util::list::sort files

    assert_failure 1
    assert_called_with_args stealth::util::log::error 'sorting %d elements failed' 2
}

@test "stealth::util::list::sort: no array named -> exits 1" {
    run stealth::util::list::sort ''
    assert_refused 'the name of an array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::difference
# ------------------------------------------------------------------------------

@test "stealth::util::list::difference: values the second array has -> leaves them out" {
    local -a required=(zlib gcc make)
    local -a built=(gcc)
    local -a missing=()

    stealth::util::list::difference missing required built

    assert_array_equal missing zlib make
}

@test "stealth::util::list::difference: nothing in common -> gives the first array" {
    local -a required=(zlib gcc)
    local -a built=(perl)
    local -a missing=()

    stealth::util::list::difference missing required built

    assert_array_equal missing zlib gcc
}

@test "stealth::util::list::difference: everything in common -> gives an empty array" {
    local -a required=(zlib)
    local -a built=(zlib)
    local -a missing=()

    stealth::util::list::difference missing required built

    assert_array_empty missing
}

@test "stealth::util::list::difference: an empty first array -> gives an empty array" {
    local -a required=()
    local -a built=(zlib)
    local -a missing=()

    stealth::util::list::difference missing required built

    assert_array_empty missing
}

@test "stealth::util::list::difference: no output variable -> exits 1" {
    run stealth::util::list::difference ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::list::difference: no first array -> exits 1" {
    run stealth::util::list::difference missing ''
    assert_refused 'the name of an array is required'
}

@test "stealth::util::list::difference: no second array -> exits 1" {
    run stealth::util::list::difference missing required ''
    assert_refused 'the name of a second array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::list::intersection
# ------------------------------------------------------------------------------

@test "stealth::util::list::intersection: values in both -> keeps them in the first order" {
    local -a required=(zlib gcc make)
    local -a available=(make zlib)
    local -a shared=()

    stealth::util::list::intersection shared required available

    assert_array_equal shared zlib make
}

@test "stealth::util::list::intersection: nothing in both -> gives an empty array" {
    local -a required=(zlib)
    local -a available=(perl)
    local -a shared=()

    stealth::util::list::intersection shared required available

    assert_array_empty shared
}

@test "stealth::util::list::intersection: no output variable -> exits 1" {
    run stealth::util::list::intersection ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::list::intersection: no first array -> exits 1" {
    run stealth::util::list::intersection shared ''
    assert_refused 'the name of an array is required'
}

@test "stealth::util::list::intersection: no second array -> exits 1" {
    run stealth::util::list::intersection shared required ''
    assert_refused 'the name of a second array is required'
}

# ------------------------------------------------------------------------------
# util/list, the module itself
# ------------------------------------------------------------------------------

@test "util/list: sourced twice -> returns before it declares anything" {
    load_lib util/list

    local -a packages=(zlib)
    stealth::util::list::append packages gcc

    assert_array_equal packages zlib gcc
}
