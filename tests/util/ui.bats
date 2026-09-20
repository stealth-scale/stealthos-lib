#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/ui - Test Suite
# ==============================================================================
# Everything is drawn on the console sink of util/log, so setup binds that
# descriptor to a file and console reads it back. A test has no terminal, so a
# test that needs one mocks _is_terminal, and a test that needs a person to
# answer mocks _is_interactive and feeds standard input.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    STEALTH_CONSOLE_FILE="${BATS_TEST_TMPDIR}/console.log"

    load_lib util/import util/ui
    load_mock util
    mock::stealth::util::log

    # A fixed width and no colour, so a test reads the text and not the
    # terminal it happens to run under.
    STEALTH_LOG_COLOR=never
    STEALTH_UI_WIDTH=40

    exec {STEALTH_LOG_FD_CONSOLE}>"${STEALTH_CONSOLE_FILE}"
    stealth::util::log::init
    stealth::util::ui::init
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Reads what the console sink received.
console() {
    printf '%s' "$(< "${STEALTH_CONSOLE_FILE}")"
}

# Answers as a terminal for the drawing that only a terminal gets.
given_a_terminal() {
    mock stealth::util::ui::_is_terminal '*' 'return 0'
}

# Answers as a person who is there to be asked. A mock records what it was
# called with and leaves standard input alone, so the answer a test feeds to
# the prompt still reaches it.
given_someone_to_ask() {
    mock stealth::util::ui::_is_interactive '*' 'return 0'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::init
# ------------------------------------------------------------------------------

@test "stealth::util::ui::init: a width that is already set -> keeps it" {
    assert_var_equal STEALTH_UI_WIDTH 40
}

@test "stealth::util::ui::init: no width -> works one out" {
    _STEALTH_UTIL_UI_READY=0
    STEALTH_UI_WIDTH=0
    COLUMNS=72

    stealth::util::ui::init

    assert_var_equal STEALTH_UI_WIDTH 72
}

@test "stealth::util::ui::init: called twice -> the second call changes nothing" {
    STEALTH_UI_WIDTH=99

    stealth::util::ui::init

    assert_var_equal STEALTH_UI_WIDTH 99
}

@test "stealth::util::ui::init: colour is never -> the map holds nothing" {
    assert_equal "${_STEALTH_UTIL_UI_COLORS[RED]}" ''
}

@test "stealth::util::ui::init: colour is always -> the map holds the codes" {
    _STEALTH_UTIL_UI_READY=0
    STEALTH_LOG_COLOR=always

    stealth::util::ui::init

    assert_equal "${_STEALTH_UTIL_UI_COLORS[RED]}" $'\033[31m'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::rule
# ------------------------------------------------------------------------------

@test "stealth::util::ui::rule: no character -> draws hyphens across the width" {
    stealth::util::ui::rule

    run console
    assert_output '----------------------------------------'
}

@test "stealth::util::ui::rule: a character -> draws that one" {
    stealth::util::ui::rule '='

    run console
    assert_output '========================================'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::header
# ------------------------------------------------------------------------------

@test "stealth::util::ui::header: a title -> draws it between two lines" {
    stealth::util::ui::header 'Stage 0'

    run console
    assert_line --index 0 '========================================'
    assert_line --index 1 '  Stage 0'
    assert_line --index 2 '========================================'
}

@test "stealth::util::ui::header: no title -> exits 1" {
    run stealth::util::ui::header ''
    assert_refused 'a title is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::alert
# ------------------------------------------------------------------------------

@test "stealth::util::ui::alert: a title and a message -> draws both" {
    stealth::util::ui::alert 'No signature' 'the layer is not signed'

    run console
    assert_output --partial '  No signature: the layer is not signed'
    assert_output --partial '!!!!!!!!'
}

@test "stealth::util::ui::alert: no title -> exits 1" {
    run stealth::util::ui::alert ''
    assert_refused 'a title is required'
}

@test "stealth::util::ui::alert: no message -> exits 1" {
    run stealth::util::ui::alert 'No signature'
    assert_refused 'a message is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::kv
# ------------------------------------------------------------------------------

@test "stealth::util::ui::kv: a key and a value -> lines the value up" {
    stealth::util::ui::kv 'Target' 'x86_64'

    run console
    assert_output '  Target               : x86_64'
}

@test "stealth::util::ui::kv: a key longer than the column -> keeps it whole" {
    stealth::util::ui::kv 'A key that runs past the column' 'value'

    run console
    assert_output '  A key that runs past the column : value'
}

@test "stealth::util::ui::kv: no value -> draws the key alone" {
    stealth::util::ui::kv 'Target'

    run console
    assert_output '  Target               : '
}

@test "stealth::util::ui::kv: no key -> exits 1" {
    run stealth::util::ui::kv ''
    assert_refused 'a key is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::table
# ------------------------------------------------------------------------------

@test "stealth::util::ui::table: rows of columns -> lines the columns up" {
    stealth::util::ui::table \
        $'package\tstatus' \
        $'gcc-pass-one\tok' \
        $'zlib\tfailed'

    run console
    assert_line --index 0 '  package       status'
    assert_line --index 1 '  gcc-pass-one  ok'
    assert_line --index 2 '  zlib          failed'
}

@test "stealth::util::ui::table: a last column -> is not padded" {
    stealth::util::ui::table $'a\tbb'

    run console
    assert_output '  a  bb'
}

@test "stealth::util::ui::table: rows of different lengths -> draws each of them" {
    stealth::util::ui::table $'a\tb\tc' 'd'

    run console
    assert_line --index 0 '  a  b  c'
    assert_line --index 1 '  d'
}

@test "stealth::util::ui::table: one column -> draws it without padding" {
    stealth::util::ui::table 'only'

    run console
    assert_output '  only'
}

@test "stealth::util::ui::table: no row -> draws nothing" {
    stealth::util::ui::table

    run console
    assert_output ''
}

# ------------------------------------------------------------------------------
# stealth::util::ui::begin
# ------------------------------------------------------------------------------

@test "stealth::util::ui::begin: a terminal -> opens a line without a break" {
    given_a_terminal

    stealth::util::ui::begin 'building zlib'

    run console
    assert_output '[ .. ] building zlib'
}

@test "stealth::util::ui::begin: no terminal -> draws nothing" {
    stealth::util::ui::begin 'building zlib'

    run console
    assert_output ''
}

@test "stealth::util::ui::begin: a name -> is remembered as the open step" {
    stealth::util::ui::begin 'building zlib'

    assert_var_equal _STEALTH_UTIL_UI_STEP 'building zlib'
}

@test "stealth::util::ui::begin: a name longer than the column -> cuts it" {
    given_a_terminal

    stealth::util::ui::begin 'building a package with a very long name indeed'

    run console
    assert_output --partial 'building a package with a very ...'
}

@test "stealth::util::ui::begin: no name -> exits 1" {
    run stealth::util::ui::begin ''
    assert_refused 'the name of a step is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::end
# ------------------------------------------------------------------------------

@test "stealth::util::ui::end: a step that worked -> marks it ok" {
    stealth::util::ui::end 'building zlib' 0

    run console
    assert_output --partial '[ ok ] building zlib'
}

@test "stealth::util::ui::end: a step that failed -> marks it failed" {
    stealth::util::ui::end 'building zlib' 1

    run console
    assert_output --partial '[fail] building zlib'
}

@test "stealth::util::ui::end: a duration -> writes it the way a person reads it" {
    stealth::util::ui::end 'building zlib' 0 72

    run console
    assert_output --partial '1m 12s'
}

@test "stealth::util::ui::end: no duration -> leaves the column empty" {
    stealth::util::ui::end 'building zlib' 0

    run console
    refute_output --partial 's  '
}

@test "stealth::util::ui::end: a digest -> cuts it to the column" {
    stealth::util::ui::end 'building zlib' 0 12 'sha256:9f86d081884c7d659a2feaa0c55ad015'

    run console
    assert_output --partial 'sha256:9f86d0818...'
}

@test "stealth::util::ui::end: a terminal -> writes over the line begin opened" {
    given_a_terminal
    stealth::util::ui::begin 'building zlib'
    stealth::util::ui::end 'building zlib' 0

    run console
    assert_output --partial $'\033[2K\r'
}

@test "stealth::util::ui::end: no terminal -> writes no control sequence" {
    stealth::util::ui::end 'building zlib' 0

    run console
    refute_output --partial $'\033'
}

@test "stealth::util::ui::end: a step that ends -> clears the open step" {
    stealth::util::ui::begin 'building zlib'
    stealth::util::ui::end 'building zlib' 0

    assert_var_equal _STEALTH_UTIL_UI_STEP ''
}

@test "stealth::util::ui::end: no name -> exits 1" {
    run stealth::util::ui::end ''
    assert_refused 'the name of a step is required'
}

@test "stealth::util::ui::end: a status that is not a number -> exits 1" {
    run stealth::util::ui::end 'building zlib' broken
    assert_refused 'a status is a whole number, not broken'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::progress
# ------------------------------------------------------------------------------

@test "stealth::util::ui::progress: no terminal -> draws nothing" {
    stealth::util::ui::progress 1 4 packages

    run console
    assert_output ''
}

@test "stealth::util::ui::progress: a quarter done -> fills a quarter of the bar" {
    given_a_terminal

    stealth::util::ui::progress 1 4 packages

    run console
    assert_output --partial '[########                      ]  25% packages'
}

@test "stealth::util::ui::progress: nothing done -> draws an empty bar" {
    given_a_terminal

    stealth::util::ui::progress 0 4 packages

    run console
    assert_output --partial '[                              ]   0% packages'
}

@test "stealth::util::ui::progress: all done -> fills the bar and ends the line" {
    given_a_terminal

    stealth::util::ui::progress 4 4 packages

    run console
    assert_output --partial '[##############################] 100% packages'
}

@test "stealth::util::ui::progress: no description -> says it is working" {
    given_a_terminal

    stealth::util::ui::progress 1 4

    run console
    assert_output --partial 'working'
}

@test "stealth::util::ui::progress: more done than there are -> holds the bar at full" {
    given_a_terminal

    stealth::util::ui::progress 8 4 packages

    run console
    assert_output --partial '[##############################] 200%'
}

@test "stealth::util::ui::progress: a total of zero -> exits 1" {
    given_a_terminal

    run stealth::util::ui::progress 0 0
    assert_refused 'a whole is above zero, not 0'
}

@test "stealth::util::ui::progress: a count that is not a number -> exits 1" {
    run stealth::util::ui::progress some 4
    assert_refused 'a count is a whole number, not some'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::ask
# ------------------------------------------------------------------------------

@test "stealth::util::ui::ask: nobody to ask and the default is yes -> returns 0" {
    run stealth::util::ui::ask 'Wipe the store?'
    assert_success
}

@test "stealth::util::ui::ask: nobody to ask and the default is no -> returns 1" {
    run stealth::util::ui::ask 'Wipe the store?' N
    assert_failure 1
}

@test "stealth::util::ui::ask: nobody to ask -> says which default it took" {
    run stealth::util::ui::ask 'Wipe the store?' N

    assert_called_with_args stealth::util::log::info \
        'answering "%s" with the default of %s' 'Wipe the store?' 'n'
}

@test "stealth::util::ui::ask: an answer of yes -> returns 0" {
    given_someone_to_ask

    run stealth::util::ui::ask 'Wipe the store?' N <<< 'y'
    assert_success
}

@test "stealth::util::ui::ask: the word yes -> returns 0" {
    given_someone_to_ask

    run stealth::util::ui::ask 'Wipe the store?' N <<< 'yes'
    assert_success
}

@test "stealth::util::ui::ask: an answer in upper case -> returns 0" {
    given_someone_to_ask

    run stealth::util::ui::ask 'Wipe the store?' N <<< 'Y'
    assert_success
}

@test "stealth::util::ui::ask: an answer of no -> returns 1" {
    given_someone_to_ask

    run stealth::util::ui::ask 'Wipe the store?' Y <<< 'n'
    assert_failure 1
}

@test "stealth::util::ui::ask: no answer -> takes the default" {
    given_someone_to_ask

    run stealth::util::ui::ask 'Wipe the store?' Y <<< ''
    assert_success
}

@test "stealth::util::ui::ask: a default of yes -> shows which one it is" {
    given_someone_to_ask

    stealth::util::ui::ask 'Wipe the store?' Y <<< 'y'

    run console
    assert_output 'Wipe the store? [Y/n] '
}

@test "stealth::util::ui::ask: a default of no -> shows which one it is" {
    given_someone_to_ask

    stealth::util::ui::ask 'Wipe the store?' N <<< 'n' || true

    run console
    assert_output 'Wipe the store? [y/N] '
}

@test "stealth::util::ui::ask: no question -> exits 1" {
    run stealth::util::ui::ask ''
    assert_refused 'a question is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::read
# ------------------------------------------------------------------------------

@test "stealth::util::ui::read: nobody to ask and a default -> takes the default" {
    local answer

    stealth::util::ui::read answer 'Hostname' 'stealthos'

    assert_var_equal answer 'stealthos'
}

@test "stealth::util::ui::read: nobody to ask and no default -> returns 1" {
    run stealth::util::ui::read answer 'Hostname'
    assert_failure 1
}

@test "stealth::util::ui::read: nobody to ask and no default -> says so" {
    run stealth::util::ui::read answer 'Hostname'

    assert_called_with_args stealth::util::log::warn \
        'nobody can answer "%s" and it has no default' 'Hostname'
}

@test "stealth::util::ui::read: an answer -> gives it back" {
    given_someone_to_ask
    local answer

    stealth::util::ui::read answer 'Hostname' <<< 'buildhost'

    assert_var_equal answer 'buildhost'
}

@test "stealth::util::ui::read: no answer -> takes the default" {
    given_someone_to_ask
    local answer

    stealth::util::ui::read answer 'Hostname' 'stealthos' <<< ''

    assert_var_equal answer 'stealthos'
}

@test "stealth::util::ui::read: a default -> shows it in the question" {
    given_someone_to_ask
    local answer

    stealth::util::ui::read answer 'Hostname' 'stealthos' <<< 'x'

    run console
    assert_output 'Hostname [stealthos]: '
}

@test "stealth::util::ui::read: no default -> asks without one" {
    given_someone_to_ask
    local answer

    stealth::util::ui::read answer 'Hostname' <<< 'x'

    run console
    assert_output 'Hostname: '
}

@test "stealth::util::ui::read: no output variable -> exits 1" {
    run stealth::util::ui::read ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::ui::read: no question -> exits 1" {
    run stealth::util::ui::read answer ''
    assert_refused 'a question is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::read_secret
# ------------------------------------------------------------------------------

@test "stealth::util::ui::read_secret: nobody to ask -> returns 1" {
    run stealth::util::ui::read_secret secret 'Passphrase'
    assert_failure 1
}

@test "stealth::util::ui::read_secret: nobody to ask -> says so" {
    run stealth::util::ui::read_secret secret 'Passphrase'

    assert_called_with_args stealth::util::log::warn \
        'nobody can answer "%s", and a secret has no default' 'Passphrase'
}

@test "stealth::util::ui::read_secret: an answer -> gives it back" {
    given_someone_to_ask
    local secret

    stealth::util::ui::read_secret secret 'Passphrase' <<< 'correct horse'

    assert_var_equal secret 'correct horse'
}

@test "stealth::util::ui::read_secret: an answer -> does not draw it" {
    given_someone_to_ask
    local secret

    stealth::util::ui::read_secret secret 'Passphrase' <<< 'correct horse'

    run console
    refute_output --partial 'correct horse'
}

@test "stealth::util::ui::read_secret: no output variable -> exits 1" {
    run stealth::util::ui::read_secret ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::ui::read_secret: no question -> exits 1" {
    run stealth::util::ui::read_secret secret ''
    assert_refused 'a question is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::choose
# ------------------------------------------------------------------------------

@test "stealth::util::ui::choose: nobody to ask -> takes the first choice" {
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 aarch64

    assert_var_equal target 'x86_64'
}

@test "stealth::util::ui::choose: nobody to ask -> says which one it took" {
    run stealth::util::ui::choose target 'Which target?' x86_64 aarch64

    assert_called_with_args stealth::util::log::info \
        'answering "%s" with the first choice, %s' 'Which target?' 'x86_64'
}

@test "stealth::util::ui::choose: a number -> takes that choice" {
    given_someone_to_ask
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 aarch64 <<< '2'

    assert_var_equal target 'aarch64'
}

@test "stealth::util::ui::choose: the choices -> are numbered from one" {
    given_someone_to_ask
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 aarch64 <<< '1'

    run console
    assert_line --index 1 '  1) x86_64'
    assert_line --index 2 '  2) aarch64'
}

@test "stealth::util::ui::choose: a number that is not there -> asks again" {
    given_someone_to_ask
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 aarch64 <<< $'9\n1'

    assert_var_equal target 'x86_64'
}

@test "stealth::util::ui::choose: an answer that is not a number -> asks again" {
    given_someone_to_ask
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 aarch64 <<< $'no\n2'

    assert_var_equal target 'aarch64'
}

@test "stealth::util::ui::choose: an answer that is not there -> says so" {
    given_someone_to_ask
    local target

    stealth::util::ui::choose target 'Which target?' x86_64 <<< $'9\n1'

    run console
    assert_output --partial 'That is not one of them.'
}

@test "stealth::util::ui::choose: the input ends before an answer -> returns 1" {
    given_someone_to_ask

    run stealth::util::ui::choose target 'Which target?' x86_64 <<< '9'
    assert_failure 1
}

@test "stealth::util::ui::choose: the input ends before an answer -> says nothing answered" {
    given_someone_to_ask

    run stealth::util::ui::choose target 'Which target?' x86_64 <<< '9'

    assert_called_with_args stealth::util::log::warn \
        'nothing answered "%s"' 'Which target?'
}

@test "stealth::util::ui::choose: nothing to choose from -> exits 1" {
    run stealth::util::ui::choose target 'Which target?'
    assert_refused 'at least one choice is required'
}

@test "stealth::util::ui::choose: no output variable -> exits 1" {
    run stealth::util::ui::choose ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::ui::choose: no question -> exits 1" {
    run stealth::util::ui::choose target ''
    assert_refused 'a question is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::_detect_width
# ------------------------------------------------------------------------------

@test "stealth::util::ui::_detect_width: COLUMNS is set -> takes it" {
    COLUMNS=100

    stealth::util::ui::_detect_width

    assert_var_equal STEALTH_UI_WIDTH 100
}

@test "stealth::util::ui::_detect_width: COLUMNS is not a number -> asks tput" {
    COLUMNS=wide
    mock tput '*' 'printf 120'

    stealth::util::ui::_detect_width

    assert_var_equal STEALTH_UI_WIDTH 120
    assert_called_with_args tput cols
}

@test "stealth::util::ui::_detect_width: nothing answers -> takes the default" {
    COLUMNS=''
    mock tput '*' 'return 1'

    stealth::util::ui::_detect_width

    assert_var_equal STEALTH_UI_WIDTH 80
}

@test "stealth::util::ui::_detect_width: a console narrower than the minimum -> takes the default" {
    COLUMNS=10

    stealth::util::ui::_detect_width

    assert_var_equal STEALTH_UI_WIDTH 80
}

# ------------------------------------------------------------------------------
# stealth::util::ui::_resolve_colors
# ------------------------------------------------------------------------------

@test "stealth::util::ui::_resolve_colors: colour is always -> fills the map" {
    STEALTH_LOG_COLOR=always

    stealth::util::ui::_resolve_colors

    assert_equal "${_STEALTH_UTIL_UI_COLORS[GREEN]}" $'\033[32m'
}

@test "stealth::util::ui::_resolve_colors: colour is never -> empties the map" {
    STEALTH_LOG_COLOR=never

    stealth::util::ui::_resolve_colors

    assert_equal "${_STEALTH_UTIL_UI_COLORS[GREEN]}" ''
}

@test "stealth::util::ui::_resolve_colors: colour follows the terminal, and there is one -> fills the map" {
    STEALTH_LOG_COLOR=auto
    given_a_terminal

    stealth::util::ui::_resolve_colors

    assert_equal "${_STEALTH_UTIL_UI_COLORS[GREEN]}" $'\033[32m'
}

@test "stealth::util::ui::_resolve_colors: a terminal and NO_COLOR -> empties the map" {
    STEALTH_LOG_COLOR=auto
    NO_COLOR=1
    given_a_terminal

    stealth::util::ui::_resolve_colors

    assert_equal "${_STEALTH_UTIL_UI_COLORS[GREEN]}" ''
}

@test "stealth::util::ui::_resolve_colors: colour follows the terminal, and there is none -> empties the map" {
    STEALTH_LOG_COLOR=auto

    stealth::util::ui::_resolve_colors

    assert_equal "${_STEALTH_UTIL_UI_COLORS[GREEN]}" ''
}

# ------------------------------------------------------------------------------
# stealth::util::ui::_color
# ------------------------------------------------------------------------------

@test "stealth::util::ui::_color: a colour the map holds -> gives its code" {
    STEALTH_LOG_COLOR=always
    stealth::util::ui::_resolve_colors

    assert_nameref $'\033[31m' stealth::util::ui::_color red
}

@test "stealth::util::ui::_color: a name in upper case -> reads the same" {
    STEALTH_LOG_COLOR=always
    stealth::util::ui::_resolve_colors

    assert_nameref $'\033[31m' stealth::util::ui::_color RED
}

@test "stealth::util::ui::_color: a colour the map does not hold -> gives the reset" {
    STEALTH_LOG_COLOR=always
    stealth::util::ui::_resolve_colors

    assert_nameref $'\033[0m' stealth::util::ui::_color chartreuse
}

@test "stealth::util::ui::_color: no output variable -> exits 1" {
    run stealth::util::ui::_color ''
    assert_refused 'an output variable is required'
}

@test "stealth::util::ui::_color: no name -> exits 1" {
    run stealth::util::ui::_color out ''
    assert_refused 'a colour name is required'
}

# ------------------------------------------------------------------------------
# stealth::util::ui::_is_interactive
# ------------------------------------------------------------------------------

@test "stealth::util::ui::_is_interactive: no terminal on standard input -> returns 1" {
    run stealth::util::ui::_is_interactive < /dev/null
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::util::ui::_is_terminal
# ------------------------------------------------------------------------------

@test "stealth::util::ui::_is_terminal: the console is a file -> returns 1" {
    run stealth::util::ui::_is_terminal
    assert_failure 1
}

# ------------------------------------------------------------------------------
# util/ui, the module itself
# ------------------------------------------------------------------------------

@test "util/ui: every line -> goes to the console sink of util/log" {
    stealth::util::ui::kv 'Target' 'x86_64'

    run --separate-stderr console
    assert_output --partial 'Target'
}

@test "util/ui: sourced twice -> returns before it declares anything" {
    load_lib util/ui

    stealth::util::ui::rule '='

    run console
    assert_output '========================================'
}
