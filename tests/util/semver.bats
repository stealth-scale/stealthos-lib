#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/semver - Test Suite
# ==============================================================================
# A version that does not follow the grammar ends the process through
# util/log, which is mocked, and assert_refused reads that call. The functions
# that answer a question return a status and are read with run.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import util/semver
    load_mock util
    mock::stealth::util::log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::util::semver::is_valid
# ------------------------------------------------------------------------------

@test "stealth::util::semver::is_valid: three numbers -> returns 0" {
    run stealth::util::semver::is_valid '1.2.3'
    assert_success
}

@test "stealth::util::semver::is_valid: a pre-release -> returns 0" {
    run stealth::util::semver::is_valid '1.0.0-alpha.1'
    assert_success
}

@test "stealth::util::semver::is_valid: build metadata -> returns 0" {
    run stealth::util::semver::is_valid '1.0.0+exp.sha.5114f85'
    assert_success
}

@test "stealth::util::semver::is_valid: both -> returns 0" {
    run stealth::util::semver::is_valid '1.0.0-alpha.1+exp.sha'
    assert_success
}

@test "stealth::util::semver::is_valid: zeroes -> returns 0" {
    run stealth::util::semver::is_valid '0.0.0'
    assert_success
}

@test "stealth::util::semver::is_valid: two numbers -> returns 1" {
    run stealth::util::semver::is_valid '1.2'
    assert_failure 1
}

@test "stealth::util::semver::is_valid: a leading zero -> returns 1" {
    run stealth::util::semver::is_valid '01.2.3'
    assert_failure 1
}

@test "stealth::util::semver::is_valid: a v in front -> returns 1" {
    run stealth::util::semver::is_valid 'v1.2.3'
    assert_failure 1
}

@test "stealth::util::semver::is_valid: a word -> returns 1" {
    run stealth::util::semver::is_valid 'banana'
    assert_failure 1
}

@test "stealth::util::semver::is_valid: an empty pre-release -> returns 1" {
    run stealth::util::semver::is_valid '1.2.3-'
    assert_failure 1
}

@test "stealth::util::semver::is_valid: nothing -> returns 1" {
    run stealth::util::semver::is_valid
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::major
# ------------------------------------------------------------------------------

@test "stealth::util::semver::major: a version -> gives the first number" {
    assert_nameref '1' stealth::util::semver::major '1.2.3'
}

@test "stealth::util::semver::major: a number of several digits -> gives all of it" {
    assert_nameref '13' stealth::util::semver::major '13.2.0'
}

@test "stealth::util::semver::major: a version that is not valid -> exits 1" {
    run stealth::util::semver::major out 'banana'
    assert_refused 'a version follows semver 2.0.0, and banana does not'
}

@test "stealth::util::semver::major: no output variable -> exits 1" {
    run stealth::util::semver::major ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::minor
# ------------------------------------------------------------------------------

@test "stealth::util::semver::minor: a version -> gives the second number" {
    assert_nameref '2' stealth::util::semver::minor '1.2.3'
}

@test "stealth::util::semver::minor: a version that is not valid -> exits 1" {
    run stealth::util::semver::minor out '1.2'
    assert_refused 'a version follows semver 2.0.0, and 1.2 does not'
}

@test "stealth::util::semver::minor: no output variable -> exits 1" {
    run stealth::util::semver::minor ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::patch
# ------------------------------------------------------------------------------

@test "stealth::util::semver::patch: a version -> gives the third number" {
    assert_nameref '3' stealth::util::semver::patch '1.2.3'
}

@test "stealth::util::semver::patch: a pre-release -> gives the number without it" {
    assert_nameref '0' stealth::util::semver::patch '1.2.0-rc.1'
}

@test "stealth::util::semver::patch: no output variable -> exits 1" {
    run stealth::util::semver::patch ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::prerelease
# ------------------------------------------------------------------------------

@test "stealth::util::semver::prerelease: a pre-release -> gives it" {
    assert_nameref 'alpha.1' stealth::util::semver::prerelease '1.0.0-alpha.1'
}

@test "stealth::util::semver::prerelease: a pre-release and build metadata -> gives the pre-release" {
    assert_nameref 'alpha.1' stealth::util::semver::prerelease '1.0.0-alpha.1+exp.sha'
}

@test "stealth::util::semver::prerelease: a pre-release with a hyphen -> gives all of it" {
    assert_nameref 'alpha-1' stealth::util::semver::prerelease '1.0.0-alpha-1'
}

@test "stealth::util::semver::prerelease: no pre-release -> gives empty" {
    assert_nameref '' stealth::util::semver::prerelease '1.0.0'
}

@test "stealth::util::semver::prerelease: no output variable -> exits 1" {
    run stealth::util::semver::prerelease ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::build
# ------------------------------------------------------------------------------

@test "stealth::util::semver::build: build metadata -> gives it" {
    assert_nameref 'exp.sha.5114f85' stealth::util::semver::build '1.0.0+exp.sha.5114f85'
}

@test "stealth::util::semver::build: a pre-release and build metadata -> gives the metadata" {
    assert_nameref 'exp.sha' stealth::util::semver::build '1.0.0-alpha.1+exp.sha'
}

@test "stealth::util::semver::build: no build metadata -> gives empty" {
    assert_nameref '' stealth::util::semver::build '1.0.0'
}

@test "stealth::util::semver::build: no output variable -> exits 1" {
    run stealth::util::semver::build ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::is_prerelease
# ------------------------------------------------------------------------------

@test "stealth::util::semver::is_prerelease: a pre-release -> returns 0" {
    run stealth::util::semver::is_prerelease '1.0.0-rc.1'
    assert_success
}

@test "stealth::util::semver::is_prerelease: a release -> returns 1" {
    run stealth::util::semver::is_prerelease '1.0.0'
    assert_failure 1
}

@test "stealth::util::semver::is_prerelease: build metadata alone -> returns 1" {
    run stealth::util::semver::is_prerelease '1.0.0+build'
    assert_failure 1
}

@test "stealth::util::semver::is_prerelease: a version that is not valid -> exits 1" {
    run stealth::util::semver::is_prerelease 'banana'
    assert_refused 'a version follows semver 2.0.0, and banana does not'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::is_stable
# ------------------------------------------------------------------------------

@test "stealth::util::semver::is_stable: a release -> returns 0" {
    run stealth::util::semver::is_stable '1.0.0'
    assert_success
}

@test "stealth::util::semver::is_stable: a pre-release -> returns 1" {
    run stealth::util::semver::is_stable '1.0.0-rc.1'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::compare
# ------------------------------------------------------------------------------

@test "stealth::util::semver::compare: a lower major -> gives -1" {
    assert_nameref '-1' stealth::util::semver::compare '1.0.0' '2.0.0'
}

@test "stealth::util::semver::compare: a higher major -> gives 1" {
    assert_nameref '1' stealth::util::semver::compare '2.0.0' '1.9.9'
}

@test "stealth::util::semver::compare: a higher minor -> gives 1" {
    assert_nameref '1' stealth::util::semver::compare '1.2.0' '1.1.9'
}

@test "stealth::util::semver::compare: a higher patch -> gives 1" {
    assert_nameref '1' stealth::util::semver::compare '1.1.2' '1.1.1'
}

@test "stealth::util::semver::compare: the same version -> gives 0" {
    assert_nameref '0' stealth::util::semver::compare '1.2.3' '1.2.3'
}

@test "stealth::util::semver::compare: numbers of several digits -> compares by value" {
    assert_nameref '1' stealth::util::semver::compare '1.11.0' '1.9.0'
}

@test "stealth::util::semver::compare: build metadata -> takes no part" {
    assert_nameref '0' stealth::util::semver::compare '1.0.0+a' '1.0.0+b'
}

@test "stealth::util::semver::compare: a pre-release against its release -> gives -1" {
    assert_nameref '-1' stealth::util::semver::compare '1.0.0-rc.1' '1.0.0'
}

@test "stealth::util::semver::compare: a release against a pre-release -> gives 1" {
    assert_nameref '1' stealth::util::semver::compare '1.0.0' '1.0.0-rc.1'
}

@test "stealth::util::semver::compare: pre-release numbers -> compares by value, not by text" {
    assert_nameref '1' stealth::util::semver::compare '1.0.0-beta.11' '1.0.0-beta.2'
}

@test "stealth::util::semver::compare: a number against a word -> the number is lower" {
    assert_nameref '-1' stealth::util::semver::compare '1.0.0-1' '1.0.0-alpha'
}

@test "stealth::util::semver::compare: fewer identifiers -> the shorter is lower" {
    assert_nameref '-1' stealth::util::semver::compare '1.0.0-alpha' '1.0.0-alpha.1'
}

@test "stealth::util::semver::compare: more identifiers -> the longer is higher" {
    assert_nameref '1' stealth::util::semver::compare '1.0.0-alpha.1' '1.0.0-alpha'
}

@test "stealth::util::semver::compare: words -> compares by byte, not by the locale" {
    # A shell puts a before B in most locales. The specification asks for
    # ASCII order, where B comes first.
    assert_nameref '-1' stealth::util::semver::compare '1.0.0-B' '1.0.0-a'
}

@test "stealth::util::semver::compare: the order in the specification -> holds all the way" {
    local -ra rising=(
        1.0.0-alpha 1.0.0-alpha.1 1.0.0-alpha.beta 1.0.0-beta
        1.0.0-beta.2 1.0.0-beta.11 1.0.0-rc.1 1.0.0
    )
    local -i i order

    for (( i = 1; i < ${#rising[@]}; i++ )); do
        stealth::util::semver::compare order "${rising[i - 1]}" "${rising[i]}"
        assert_equal "${order}" -1
    done
}

@test "stealth::util::semver::compare: a version that is not valid -> exits 1" {
    run stealth::util::semver::compare out 'banana' '1.0.0'
    assert_refused 'a version follows semver 2.0.0, and banana does not'
}

@test "stealth::util::semver::compare: a second version that is not valid -> exits 1" {
    run stealth::util::semver::compare out '1.0.0' '2.0'
    assert_refused 'a version follows semver 2.0.0, and 2.0 does not'
}

@test "stealth::util::semver::compare: no output variable -> exits 1" {
    run stealth::util::semver::compare ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::eq
# ------------------------------------------------------------------------------

@test "stealth::util::semver::eq: the same version -> returns 0" {
    run stealth::util::semver::eq '1.2.3' '1.2.3'
    assert_success
}

@test "stealth::util::semver::eq: build metadata that differs -> returns 0" {
    run stealth::util::semver::eq '1.2.3+a' '1.2.3+b'
    assert_success
}

@test "stealth::util::semver::eq: another version -> returns 1" {
    run stealth::util::semver::eq '1.2.3' '1.2.4'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::ne
# ------------------------------------------------------------------------------

@test "stealth::util::semver::ne: another version -> returns 0" {
    run stealth::util::semver::ne '1.2.3' '1.2.4'
    assert_success
}

@test "stealth::util::semver::ne: the same version -> returns 1" {
    run stealth::util::semver::ne '1.2.3' '1.2.3'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::lt
# ------------------------------------------------------------------------------

@test "stealth::util::semver::lt: a lower version -> returns 0" {
    run stealth::util::semver::lt '1.2.3' '1.3.0'
    assert_success
}

@test "stealth::util::semver::lt: the same version -> returns 1" {
    run stealth::util::semver::lt '1.2.3' '1.2.3'
    assert_failure 1
}

@test "stealth::util::semver::lt: a higher version -> returns 1" {
    run stealth::util::semver::lt '1.3.0' '1.2.3'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::lte
# ------------------------------------------------------------------------------

@test "stealth::util::semver::lte: a lower version -> returns 0" {
    run stealth::util::semver::lte '1.2.3' '1.3.0'
    assert_success
}

@test "stealth::util::semver::lte: the same version -> returns 0" {
    run stealth::util::semver::lte '1.2.3' '1.2.3'
    assert_success
}

@test "stealth::util::semver::lte: a higher version -> returns 1" {
    run stealth::util::semver::lte '1.3.0' '1.2.3'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::gt
# ------------------------------------------------------------------------------

@test "stealth::util::semver::gt: a higher version -> returns 0" {
    run stealth::util::semver::gt '1.3.0' '1.2.3'
    assert_success
}

@test "stealth::util::semver::gt: the same version -> returns 1" {
    run stealth::util::semver::gt '1.2.3' '1.2.3'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::gte
# ------------------------------------------------------------------------------

@test "stealth::util::semver::gte: a higher version -> returns 0" {
    run stealth::util::semver::gte '1.3.0' '1.2.3'
    assert_success
}

@test "stealth::util::semver::gte: the same version -> returns 0" {
    run stealth::util::semver::gte '1.2.3' '1.2.3'
    assert_success
}

@test "stealth::util::semver::gte: a lower version -> returns 1" {
    run stealth::util::semver::gte '1.2.3' '1.3.0'
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::semver::newest
# ------------------------------------------------------------------------------

@test "stealth::util::semver::newest: several versions -> gives the highest" {
    assert_nameref '2.0.0' stealth::util::semver::newest '1.9.9' '2.0.0' '1.10.0'
}

@test "stealth::util::semver::newest: one version -> gives it" {
    assert_nameref '1.0.0' stealth::util::semver::newest '1.0.0'
}

@test "stealth::util::semver::newest: a release and its pre-releases -> gives the release" {
    assert_nameref '1.0.0' stealth::util::semver::newest '1.0.0-rc.1' '1.0.0' '1.0.0-rc.2'
}

@test "stealth::util::semver::newest: no version -> exits 1" {
    run stealth::util::semver::newest out
    assert_refused 'at least one version is required'
}

@test "stealth::util::semver::newest: no output variable -> exits 1" {
    run stealth::util::semver::newest ''
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::sort
# ------------------------------------------------------------------------------

@test "stealth::util::semver::sort: versions -> newest first" {
    local ordered

    stealth::util::semver::sort ordered 1.0.0 1.10.0 1.2.0

    assert_array_equal ordered 1.10.0 1.2.0 1.0.0
}

@test "stealth::util::semver::sort: a prerelease -> is older than its release" {
    # sort -V gets this the wrong way round.
    local ordered

    stealth::util::semver::sort ordered 1.0.0-rc1 1.0.0 1.0.0-rc2

    assert_array_equal ordered 1.0.0 1.0.0-rc2 1.0.0-rc1
}

@test "stealth::util::semver::sort: a leading v -> is kept" {
    local ordered

    stealth::util::semver::sort ordered v1.0.0 v1.10.0

    assert_array_equal ordered v1.10.0 v1.0.0
}

@test "stealth::util::semver::sort: something that is not a version -> goes last" {
    local ordered

    stealth::util::semver::sort ordered nightly v1.0.0 latest v2.0.0

    assert_array_equal ordered v2.0.0 v1.0.0 nightly latest
}

@test "stealth::util::semver::sort: nothing but names -> they come back in order" {
    local ordered

    stealth::util::semver::sort ordered nightly latest

    assert_array_equal ordered nightly latest
}

@test "stealth::util::semver::sort: one version -> comes back on its own" {
    local ordered

    stealth::util::semver::sort ordered 1.2.3

    assert_array_equal ordered 1.2.3
}

@test "stealth::util::semver::sort: nothing at all -> an empty array" {
    local ordered=(stale)

    stealth::util::semver::sort ordered

    assert_array_empty ordered
}

@test "stealth::util::semver::sort: the same version twice -> comes back twice" {
    local ordered

    stealth::util::semver::sort ordered 1.0.0 1.0.0

    assert_array_length ordered 2
}

@test "stealth::util::semver::sort: no output array -> exits 1" {
    run stealth::util::semver::sort '' 1.0.0
    assert_refused 'an output array is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::satisfies
# ------------------------------------------------------------------------------

@test "stealth::util::semver::satisfies: at least, and it is higher -> returns 0" {
    run stealth::util::semver::satisfies '13.2.0' '>=13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: at least, and it is the same -> returns 0" {
    run stealth::util::semver::satisfies '13.0.0' '>=13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: at least, and it is lower -> returns 1" {
    run stealth::util::semver::satisfies '12.9.9' '>=13.0.0'
    assert_failure 1
}

@test "stealth::util::semver::satisfies: above, and it is the same -> returns 1" {
    run stealth::util::semver::satisfies '13.0.0' '>13.0.0'
    assert_failure 1
}

@test "stealth::util::semver::satisfies: at most, and it is lower -> returns 0" {
    run stealth::util::semver::satisfies '12.0.0' '<=13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: below, and it is lower -> returns 0" {
    run stealth::util::semver::satisfies '12.0.0' '<13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: not, and it differs -> returns 0" {
    run stealth::util::semver::satisfies '13.0.1' '!=13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: not, and it is the same -> returns 1" {
    run stealth::util::semver::satisfies '13.0.0' '!=13.0.0'
    assert_failure 1
}

@test "stealth::util::semver::satisfies: one equals sign -> asks for that version" {
    run stealth::util::semver::satisfies '13.0.0' '=13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: two equals signs -> asks for that version" {
    run stealth::util::semver::satisfies '13.0.0' '==13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: no sign -> asks for that version exactly" {
    run stealth::util::semver::satisfies '13.0.0' '13.0.0'
    assert_success
}

@test "stealth::util::semver::satisfies: no sign and another version -> returns 1" {
    run stealth::util::semver::satisfies '13.0.1' '13.0.0'
    assert_failure 1
}

@test "stealth::util::semver::satisfies: a caret -> exits 1, because ranges are not read" {
    run stealth::util::semver::satisfies '13.0.1' '^13.0.0'
    assert_refused 'a version follows semver 2.0.0, and ^13.0.0 does not'
}

@test "stealth::util::semver::satisfies: no constraint -> exits 1" {
    run stealth::util::semver::satisfies '13.0.0'
    assert_refused 'a constraint is required'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::_compare_text
# ------------------------------------------------------------------------------

@test "stealth::util::semver::_compare_text: an upper case letter -> sorts before a lower case one" {
    assert_nameref '-1' stealth::util::semver::_compare_text 'B' 'a'
}

@test "stealth::util::semver::_compare_text: a higher byte -> gives 1" {
    assert_nameref '1' stealth::util::semver::_compare_text 'beta' 'alpha'
}

@test "stealth::util::semver::_compare_text: the same string -> gives 0" {
    assert_nameref '0' stealth::util::semver::_compare_text 'alpha' 'alpha'
}

@test "stealth::util::semver::_compare_text: a string that starts the same -> the shorter is lower" {
    assert_nameref '-1' stealth::util::semver::_compare_text 'alpha' 'alphabet'
}

@test "stealth::util::semver::_compare_text: a longer string that starts the same -> gives 1" {
    assert_nameref '1' stealth::util::semver::_compare_text 'alphabet' 'alpha'
}

@test "stealth::util::semver::_compare_text: two empty strings -> gives 0" {
    assert_nameref '0' stealth::util::semver::_compare_text '' ''
}

# ------------------------------------------------------------------------------
# stealth::util::semver::_compare_number
# ------------------------------------------------------------------------------

@test "stealth::util::semver::_compare_number: a lower number -> gives -1" {
    assert_nameref '-1' stealth::util::semver::_compare_number '2' '11'
}

@test "stealth::util::semver::_compare_number: a higher number -> gives 1" {
    assert_nameref '1' stealth::util::semver::_compare_number '11' '2'
}

@test "stealth::util::semver::_compare_number: the same number -> gives 0" {
    assert_nameref '0' stealth::util::semver::_compare_number '7' '7'
}

# ------------------------------------------------------------------------------
# stealth::util::semver::_compare_part
# ------------------------------------------------------------------------------

@test "stealth::util::semver::_compare_part: two numbers -> compares by value" {
    assert_nameref '1' stealth::util::semver::_compare_part '11' '2'
}

@test "stealth::util::semver::_compare_part: two numbers that are the same -> gives 0" {
    assert_nameref '0' stealth::util::semver::_compare_part '7' '7'
}

@test "stealth::util::semver::_compare_part: a number against a word -> the number is lower" {
    assert_nameref '-1' stealth::util::semver::_compare_part '7' 'beta'
}

@test "stealth::util::semver::_compare_part: a word against a number -> the word is higher" {
    assert_nameref '1' stealth::util::semver::_compare_part 'beta' '7'
}

@test "stealth::util::semver::_compare_part: two words -> compares by byte" {
    assert_nameref '-1' stealth::util::semver::_compare_part 'alpha' 'beta'
}

# ------------------------------------------------------------------------------
# util/semver, the module itself
# ------------------------------------------------------------------------------

@test "util/semver: sourced twice -> returns before it declares anything" {
    load_lib util/semver

    run stealth::util::semver::gte '13.2.0' '13.0.0'
    assert_success
}
