#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/math - Test Suite
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

    load_lib util/import util/math
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::util::math::min
# ------------------------------------------------------------------------------

@test "stealth::util::math::min: two values -> gives the smaller" {
    assert_nameref '4' stealth::util::math::min 8 4
}

@test "stealth::util::math::min: several values -> gives the smallest" {
    assert_nameref '2' stealth::util::math::min 8 4 2 16
}

@test "stealth::util::math::min: one value -> gives it" {
    assert_nameref '8' stealth::util::math::min 8
}

@test "stealth::util::math::min: values below zero -> gives the smallest" {
    assert_nameref '-9' stealth::util::math::min -3 -9 4
}

@test "stealth::util::math::min: no value -> exits 1" {
    run stealth::util::math::min out
    assert_refused 'at least one value is required'
}

@test "stealth::util::math::min: a value that is not a number -> exits 1" {
    run stealth::util::math::min out 4 many
    assert_refused 'a value is a whole number, not many'
}

@test "stealth::util::math::min: no output variable -> exits 1" {
    run stealth::util::math::min ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::max
# ------------------------------------------------------------------------------

@test "stealth::util::math::max: two values -> gives the larger" {
    assert_nameref '8' stealth::util::math::max 8 4
}

@test "stealth::util::math::max: several values -> gives the largest" {
    assert_nameref '16' stealth::util::math::max 8 4 2 16
}

@test "stealth::util::math::max: values below zero -> gives the largest" {
    assert_nameref '-3' stealth::util::math::max -3 -9
}

@test "stealth::util::math::max: no value -> exits 1" {
    run stealth::util::math::max out
    assert_refused 'at least one value is required'
}

@test "stealth::util::math::max: no output variable -> exits 1" {
    run stealth::util::math::max ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::sum
# ------------------------------------------------------------------------------

@test "stealth::util::math::sum: several values -> adds them" {
    assert_nameref '30' stealth::util::math::sum 10 15 5
}

@test "stealth::util::math::sum: values below zero -> adds them" {
    assert_nameref '5' stealth::util::math::sum 10 -5
}

@test "stealth::util::math::sum: no value -> gives zero" {
    assert_nameref '0' stealth::util::math::sum
}

@test "stealth::util::math::sum: a value that is not a number -> exits 1" {
    run stealth::util::math::sum out 10 lots
    assert_refused 'a value is a whole number, not lots'
}

@test "stealth::util::math::sum: no output variable -> exits 1" {
    run stealth::util::math::sum ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::abs
# ------------------------------------------------------------------------------

@test "stealth::util::math::abs: a value below zero -> gives it without the sign" {
    assert_nameref '7' stealth::util::math::abs -7
}

@test "stealth::util::math::abs: a value above zero -> gives it" {
    assert_nameref '7' stealth::util::math::abs 7
}

@test "stealth::util::math::abs: zero -> gives zero" {
    assert_nameref '0' stealth::util::math::abs 0
}

@test "stealth::util::math::abs: no output variable -> exits 1" {
    run stealth::util::math::abs ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::clamp
# ------------------------------------------------------------------------------

@test "stealth::util::math::clamp: a value between the bounds -> gives it" {
    assert_nameref '8' stealth::util::math::clamp 8 1 64
}

@test "stealth::util::math::clamp: a value under the low bound -> gives the low bound" {
    assert_nameref '1' stealth::util::math::clamp 0 1 64
}

@test "stealth::util::math::clamp: a value over the high bound -> gives the high bound" {
    assert_nameref '64' stealth::util::math::clamp 999 1 64
}

@test "stealth::util::math::clamp: a value at a bound -> gives it" {
    assert_nameref '64' stealth::util::math::clamp 64 1 64
}

@test "stealth::util::math::clamp: the bounds the wrong way round -> exits 1" {
    run stealth::util::math::clamp out 8 64 1
    assert_refused 'a low bound of 64 is above the high bound of 1'
}

@test "stealth::util::math::clamp: no output variable -> exits 1" {
    run stealth::util::math::clamp ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::div_ceil
# ------------------------------------------------------------------------------

@test "stealth::util::math::div_ceil: a division with a remainder -> rounds up" {
    assert_nameref '3' stealth::util::math::div_ceil 9 4
}

@test "stealth::util::math::div_ceil: a division without a remainder -> gives it" {
    assert_nameref '2' stealth::util::math::div_ceil 8 4
}

@test "stealth::util::math::div_ceil: a dividend below zero -> rounds toward zero" {
    assert_nameref '-2' stealth::util::math::div_ceil -9 4
}

@test "stealth::util::math::div_ceil: both below zero -> rounds away from zero" {
    assert_nameref '3' stealth::util::math::div_ceil -9 -4
}

@test "stealth::util::math::div_ceil: a divisor of zero -> exits 1" {
    run stealth::util::math::div_ceil out 9 0
    assert_refused 'a divisor is never zero'
}

@test "stealth::util::math::div_ceil: no output variable -> exits 1" {
    run stealth::util::math::div_ceil ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::div_round
# ------------------------------------------------------------------------------

@test "stealth::util::math::div_round: a remainder under half -> rounds down" {
    assert_nameref '2' stealth::util::math::div_round 9 4
}

@test "stealth::util::math::div_round: a remainder over half -> rounds up" {
    assert_nameref '3' stealth::util::math::div_round 11 4
}

@test "stealth::util::math::div_round: a remainder of exactly half -> rounds away from zero" {
    assert_nameref '3' stealth::util::math::div_round 10 4
}

@test "stealth::util::math::div_round: no remainder -> gives the quotient" {
    assert_nameref '2' stealth::util::math::div_round 8 4
}

@test "stealth::util::math::div_round: a value below zero at half -> rounds away from zero" {
    assert_nameref '-3' stealth::util::math::div_round -10 4
}

@test "stealth::util::math::div_round: a divisor of zero -> exits 1" {
    run stealth::util::math::div_round out 9 0
    assert_refused 'a divisor is never zero'
}

@test "stealth::util::math::div_round: no output variable -> exits 1" {
    run stealth::util::math::div_round ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::percent
# ------------------------------------------------------------------------------

@test "stealth::util::math::percent: a part of a whole -> gives the share" {
    assert_nameref '25' stealth::util::math::percent 1 4
}

@test "stealth::util::math::percent: a share that is not whole -> rounds to the nearest" {
    assert_nameref '33' stealth::util::math::percent 1 3
}

@test "stealth::util::math::percent: the whole -> gives 100" {
    assert_nameref '100' stealth::util::math::percent 4 4
}

@test "stealth::util::math::percent: nothing done -> gives 0" {
    assert_nameref '0' stealth::util::math::percent 0 4
}

@test "stealth::util::math::percent: a part over the whole -> gives more than 100" {
    assert_nameref '200' stealth::util::math::percent 8 4
}

@test "stealth::util::math::percent: a whole of zero -> exits 1" {
    run stealth::util::math::percent out 1 0
    assert_refused 'a whole is above zero, not 0'
}

@test "stealth::util::math::percent: no output variable -> exits 1" {
    run stealth::util::math::percent ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::to_bytes
# ------------------------------------------------------------------------------

@test "stealth::util::math::to_bytes: a number alone -> gives it" {
    assert_nameref '1024' stealth::util::math::to_bytes '1024'
}

@test "stealth::util::math::to_bytes: a unit letter -> counts in steps of 1024" {
    assert_nameref '1073741824' stealth::util::math::to_bytes '1G'
}

@test "stealth::util::math::to_bytes: the i and the B spellings -> are the same size" {
    local a b c
    stealth::util::math::to_bytes a '1G'
    stealth::util::math::to_bytes b '1Gi'
    stealth::util::math::to_bytes c '1GiB'

    assert_equal "${a}" "${b}"
    assert_equal "${b}" "${c}"
}

@test "stealth::util::math::to_bytes: lower case -> reads the same" {
    assert_nameref '536870912' stealth::util::math::to_bytes '512m'
}

@test "stealth::util::math::to_bytes: a decimal -> gives the share of the unit" {
    assert_nameref '1610612736' stealth::util::math::to_bytes '1.5G'
}

@test "stealth::util::math::to_bytes: two decimals -> gives the share of the unit" {
    assert_nameref '1153433' stealth::util::math::to_bytes '1.10M'
}

@test "stealth::util::math::to_bytes: a space before the unit -> reads it" {
    assert_nameref '1048576' stealth::util::math::to_bytes '1 M'
}

@test "stealth::util::math::to_bytes: a B on its own -> counts bytes" {
    assert_nameref '900' stealth::util::math::to_bytes '900B'
}

@test "stealth::util::math::to_bytes: the largest unit -> counts in steps of 1024" {
    assert_nameref '1152921504606846976' stealth::util::math::to_bytes '1E'
}

@test "stealth::util::math::to_bytes: every unit -> is 1024 of the one before it" {
    local k m g t p
    stealth::util::math::to_bytes k '1K'
    stealth::util::math::to_bytes m '1M'
    stealth::util::math::to_bytes g '1G'
    stealth::util::math::to_bytes t '1T'
    stealth::util::math::to_bytes p '1P'

    assert_equal "${k}" 1024
    assert_equal "${m}" "$(( k * 1024 ))"
    assert_equal "${g}" "$(( m * 1024 ))"
    assert_equal "${t}" "$(( g * 1024 ))"
    assert_equal "${p}" "$(( t * 1024 ))"
}

@test "stealth::util::math::to_bytes: a size that cannot be read -> exits 1" {
    run stealth::util::math::to_bytes out 'huge'
    assert_refused 'a size is a number and an optional unit, not huge'
}

@test "stealth::util::math::to_bytes: an unknown unit -> exits 1" {
    run stealth::util::math::to_bytes out '10X'
    assert_refused 'a size is a number and an optional unit, not 10X'
}

@test "stealth::util::math::to_bytes: no output variable -> exits 1" {
    run stealth::util::math::to_bytes ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::human_size
# ------------------------------------------------------------------------------

@test "stealth::util::math::human_size: under a kibibyte -> counts bytes" {
    assert_nameref '900 B' stealth::util::math::human_size 900
}

@test "stealth::util::math::human_size: zero -> counts bytes" {
    assert_nameref '0 B' stealth::util::math::human_size 0
}

@test "stealth::util::math::human_size: a kibibyte and a half -> gives one decimal" {
    assert_nameref '1.5 KiB' stealth::util::math::human_size 1536
}

@test "stealth::util::math::human_size: a whole mebibyte -> gives a zero decimal" {
    assert_nameref '1.0 MiB' stealth::util::math::human_size 1048576
}

@test "stealth::util::math::human_size: a gibibyte -> names the unit" {
    assert_nameref '2.0 GiB' stealth::util::math::human_size 2147483648
}

@test "stealth::util::math::human_size: the largest unit -> names it" {
    assert_nameref '1.0 EiB' stealth::util::math::human_size 1152921504606846976
}

@test "stealth::util::math::human_size: a round trip through to_bytes -> keeps the size" {
    local bytes size
    stealth::util::math::to_bytes bytes '512M'
    stealth::util::math::human_size size "${bytes}"

    assert_equal "${size}" '512.0 MiB'
}

@test "stealth::util::math::human_size: a size below zero -> exits 1" {
    run stealth::util::math::human_size out -1
    assert_refused 'a size in bytes is a whole number, zero or above, not -1'
}

@test "stealth::util::math::human_size: no output variable -> exits 1" {
    run stealth::util::math::human_size ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::duration
# ------------------------------------------------------------------------------

@test "stealth::util::math::duration: under a minute -> counts seconds" {
    assert_nameref '42s' stealth::util::math::duration 42
}

@test "stealth::util::math::duration: zero -> counts no seconds" {
    assert_nameref '0s' stealth::util::math::duration 0
}

@test "stealth::util::math::duration: over a minute -> counts minutes and seconds" {
    assert_nameref '1m 12s' stealth::util::math::duration 72
}

@test "stealth::util::math::duration: a whole minute -> counts no seconds" {
    assert_nameref '2m 0s' stealth::util::math::duration 120
}

@test "stealth::util::math::duration: over an hour -> counts hours, minutes and seconds" {
    assert_nameref '1h 1m 1s' stealth::util::math::duration 3661
}

@test "stealth::util::math::duration: a duration below zero -> exits 1" {
    run stealth::util::math::duration out -1
    assert_refused 'a duration in seconds is a whole number, zero or above, not -1'
}

@test "stealth::util::math::duration: no output variable -> exits 1" {
    run stealth::util::math::duration ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::math::_all_int
# ------------------------------------------------------------------------------

@test "stealth::util::math::_all_int: whole numbers -> returns" {
    run stealth::util::math::_all_int 1 -2 30
    assert_success
}

@test "stealth::util::math::_all_int: no value -> returns" {
    run stealth::util::math::_all_int
    assert_success
}

# ------------------------------------------------------------------------------
# stealth::util::math::_deny_zero
# ------------------------------------------------------------------------------

@test "stealth::util::math::_deny_zero: a divisor that is not zero -> returns" {
    run stealth::util::math::_deny_zero 4
    assert_success
}

# ------------------------------------------------------------------------------
# util/math, the module itself
# ------------------------------------------------------------------------------

@test "util/math: sourced twice -> returns before it declares anything" {
    load_lib util/math

    assert_nameref '4' stealth::util::math::min 8 4
}

@test "util/math: no function runs a command -> awk and numfmt are never called" {
    mock awk '*' 'return 127'
    mock numfmt '*' 'return 127'

    local bytes size took share
    stealth::util::math::to_bytes bytes '1.5G'
    stealth::util::math::human_size size "${bytes}"
    stealth::util::math::duration took 3661
    stealth::util::math::percent share 1 3

    assert_equal "${size}" '1.5 GiB'
    assert_equal "${took}" '1h 1m 1s'
    assert_equal "${share}" '33'
    refute_called awk
    refute_called numfmt
}
