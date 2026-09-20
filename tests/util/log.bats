#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# util/log - Test Suite
# ==============================================================================
# Both sinks write to a file descriptor, so every test binds them to files in
# the test's temporary directory and reads what was written.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    STEALTH_CONSOLE_FILE="${BATS_TEST_TMPDIR}/console.log"
    STEALTH_FILE_FILE="${BATS_TEST_TMPDIR}/file.log"

    load_lib util/log
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Fixtures
# ------------------------------------------------------------------------------

# Opens both sinks on files and initialises the logger. Every entry written
# after this lands in STEALTH_CONSOLE_FILE and STEALTH_FILE_FILE.
open_sinks() {
    exec {STEALTH_LOG_FD_CONSOLE}>"${STEALTH_CONSOLE_FILE}"
    exec {STEALTH_LOG_FD_FILE}>"${STEALTH_FILE_FILE}"
    stealth::util::log::init
}

# Opens the console sink only.
open_console() {
    exec {STEALTH_LOG_FD_CONSOLE}>"${STEALTH_CONSOLE_FILE}"
    stealth::util::log::init
}

# Reads what the console sink received.
console() {
    printf '%s' "$(< "${STEALTH_CONSOLE_FILE}")"
}

# Reads what the file sink received.
logfile() {
    printf '%s' "$(< "${STEALTH_FILE_FILE}")"
}

# A function with a namespace, so the caller columns have something to show.
stealth::sys::io::fs::atomic() {
    stealth::util::log::info 'writing %s' "${1}"
}

# ------------------------------------------------------------------------------
# stealth::util::log::init
# ------------------------------------------------------------------------------

@test "stealth::util::log::init: a level name -> converts it to its number" {
    STEALTH_LOG_LEVEL=debug
    open_console

    assert_var_equal STEALTH_LOG_LEVEL 4
}

@test "stealth::util::log::init: an unknown level name -> warns and uses INFO" {
    STEALTH_LOG_LEVEL=chatty

    run --separate-stderr open_console
    assert_success
    assert_equal "${stderr}" 'log: unknown level chatty, using INFO'
}

@test "stealth::util::log::init: a level number -> keeps it" {
    STEALTH_LOG_LEVEL=5
    open_console

    assert_var_equal STEALTH_LOG_LEVEL 5
}

@test "stealth::util::log::init: called twice -> binds the sinks once" {
    open_sinks
    local -r first="${_STEALTH_UTIL_LOG_FD_CONSOLE}"

    STEALTH_LOG_FD_CONSOLE=1
    stealth::util::log::init

    assert_equal "${_STEALTH_UTIL_LOG_FD_CONSOLE}" "${first}"
}

@test "stealth::util::log::init: no console descriptor -> uses stderr" {
    stealth::util::log::init

    refute_var_empty _STEALTH_UTIL_LOG_FD_CONSOLE
    assert_var_empty _STEALTH_UTIL_LOG_FD_FILE
}

@test "stealth::util::log::init: a console descriptor that is not a number -> fails" {
    STEALTH_LOG_FD_CONSOLE=stderr

    run --separate-stderr stealth::util::log::init
    assert_failure 1
    assert_equal "${stderr}" 'STEALTH_LOG_FD_CONSOLE is not a file descriptor: stderr'
}

@test "stealth::util::log::init: a file descriptor that is closed -> fails" {
    STEALTH_LOG_FD_FILE=42

    run --separate-stderr stealth::util::log::init
    assert_failure 1
    assert_equal "${stderr}" 'STEALTH_LOG_FD_FILE is not open for writing: 42'
}

# ------------------------------------------------------------------------------
# stealth::util::log::is_enabled
# ------------------------------------------------------------------------------

@test "stealth::util::log::is_enabled: a level at the threshold -> succeeds" {
    STEALTH_LOG_LEVEL=3

    run stealth::util::log::is_enabled 3
    assert_success
}

@test "stealth::util::log::is_enabled: a level above the threshold -> fails" {
    STEALTH_LOG_LEVEL=3

    run stealth::util::log::is_enabled 4
    assert_failure
}

@test "stealth::util::log::is_enabled: logging is off -> fails for every level" {
    STEALTH_LOG_LEVEL=0

    run stealth::util::log::is_enabled 1
    assert_failure
}

@test "stealth::util::log::is_enabled: no argument -> fails" {
    run stealth::util::log::is_enabled
    assert_failure
}

@test "stealth::util::log::is_enabled: a level that is not a number -> fails" {
    run stealth::util::log::is_enabled debug
    assert_failure
}

# ------------------------------------------------------------------------------
# stealth::util::log::error
# ------------------------------------------------------------------------------

@test "stealth::util::log::error: a message -> writes it with the FAIL badge and exits 1" {
    open_console

    run stealth::util::log::error 'no module %s' util/nowhere
    assert_failure 1

    run console
    assert_output --partial '[ FAIL ]'
    assert_output --partial 'no module util/nowhere'
}

@test "stealth::util::log::error: -c with a status -> exits with it" {
    open_console

    run -127 stealth::util::log::error -c 127 'command not found'
    assert_failure 127
}

@test "stealth::util::log::error: --code with a status -> exits with it" {
    open_console

    run stealth::util::log::error --code 12 'broke'
    assert_failure 12
}

@test "stealth::util::log::error: -c without a status -> exits 1 and keeps the message" {
    open_console

    run stealth::util::log::error -c 'plain message'
    assert_failure 1

    run console
    assert_output --partial 'plain message'
}

@test "stealth::util::log::error: logging is off -> still exits with the status" {
    STEALTH_LOG_LEVEL=0
    open_console

    run stealth::util::log::error -c 3 'silent'
    assert_failure 3

    run console
    assert_output ''
}

# ------------------------------------------------------------------------------
# stealth::util::log::warn
# ------------------------------------------------------------------------------

@test "stealth::util::log::warn: a message -> writes it with the WARN badge" {
    open_console
    stealth::util::log::warn 'no signature'

    run console
    assert_output --partial '[ WARN ]'
    assert_output --partial 'no signature'
}

# ------------------------------------------------------------------------------
# stealth::util::log::info
# ------------------------------------------------------------------------------

@test "stealth::util::log::info: a format and its arguments -> writes the message" {
    open_console
    stealth::util::log::info 'built %s in %d s' zlib 4

    run console
    assert_output --partial 'built zlib in 4 s'
    assert_output --partial '[ INFO ]'
}

# ------------------------------------------------------------------------------
# stealth::util::log::debug
# ------------------------------------------------------------------------------

@test "stealth::util::log::debug: the level is INFO -> writes nothing" {
    STEALTH_LOG_LEVEL=3
    open_console
    stealth::util::log::debug 'resolved %s' zlib

    run console
    assert_output ''
}

@test "stealth::util::log::debug: the level is DEBUG -> writes it with the DEBG badge" {
    STEALTH_LOG_LEVEL=4
    open_console
    stealth::util::log::debug 'resolved %s' zlib

    run console
    assert_output --partial '[ DEBG ]'
}

# ------------------------------------------------------------------------------
# stealth::util::log::trace
# ------------------------------------------------------------------------------

@test "stealth::util::log::trace: the level is TRACE -> writes it with the TRAC badge" {
    STEALTH_LOG_LEVEL=5
    open_console
    stealth::util::log::trace 'entering'

    run console
    assert_output --partial '[ TRAC ]'
}

# ------------------------------------------------------------------------------
# stealth::util::log::_is_terminal
# ------------------------------------------------------------------------------

@test "stealth::util::log::_is_terminal: the sink is a file -> fails" {
    run stealth::util::log::_is_terminal
    assert_failure
}

# ------------------------------------------------------------------------------
# stealth::util::log::_resolve_colors
# ------------------------------------------------------------------------------

@test "stealth::util::log::_resolve_colors: always -> fills the map with the codes" {
    STEALTH_LOG_COLOR=always
    stealth::util::log::_resolve_colors

    assert_equal "${_STEALTH_UTIL_LOG_COLORS[RED]}" $'\033[31m'
    assert_equal "${_STEALTH_UTIL_LOG_COLORS[RESET]}" $'\033[0m'
}

@test "stealth::util::log::_resolve_colors: never -> fills the map with empty values" {
    STEALTH_LOG_COLOR=never
    stealth::util::log::_resolve_colors

    assert_equal "${_STEALTH_UTIL_LOG_COLORS[RED]}" ''
    assert_array_has_key _STEALTH_UTIL_LOG_COLORS RED
}

@test "stealth::util::log::_resolve_colors: auto and a terminal -> fills the map with the codes" {
    STEALTH_LOG_COLOR=auto
    mock stealth::util::log::_is_terminal '*' 'return 0'
    stealth::util::log::_resolve_colors

    assert_equal "${_STEALTH_UTIL_LOG_COLORS[BLUE]}" $'\033[34m'
}

@test "stealth::util::log::_resolve_colors: auto and no terminal -> fills the map with empty values" {
    STEALTH_LOG_COLOR=auto
    stealth::util::log::_resolve_colors

    assert_equal "${_STEALTH_UTIL_LOG_COLORS[BLUE]}" ''
}

@test "stealth::util::log::_resolve_colors: auto, a terminal and NO_COLOR -> fills the map with empty values" {
    STEALTH_LOG_COLOR=auto
    NO_COLOR=1
    mock stealth::util::log::_is_terminal '*' 'return 0'
    stealth::util::log::_resolve_colors

    assert_equal "${_STEALTH_UTIL_LOG_COLORS[BLUE]}" ''
}

# ------------------------------------------------------------------------------
# stealth::util::log::_split_caller
# ------------------------------------------------------------------------------

@test "stealth::util::log::_split_caller: a namespaced function -> gives its module and name" {
    local mod='' fn=''
    stealth::util::log::_split_caller mod fn stealth::sys::io::fs::atomic

    assert_equal "${mod}" sys/io/fs
    assert_equal "${fn}" atomic
}

@test "stealth::util::log::_split_caller: a name without a module -> gives main and the name" {
    local mod='' fn=''
    stealth::util::log::_split_caller mod fn stealth::run

    assert_equal "${mod}" main
    assert_equal "${fn}" run
}

@test "stealth::util::log::_split_caller: a plain function -> gives main and the name" {
    local mod='' fn=''
    stealth::util::log::_split_caller mod fn setup

    assert_equal "${mod}" main
    assert_equal "${fn}" setup
}

@test "stealth::util::log::_split_caller: no name -> gives main twice" {
    local mod='' fn=''
    stealth::util::log::_split_caller mod fn ''

    assert_equal "${mod}" main
    assert_equal "${fn}" main
}

@test "stealth::util::log::_split_caller: the caller's own variable is named _mod -> is not shadowed" {
    # Defect 1 of the previous library: a local of this function shadowed the
    # caller's nameref target, and the caller then read an unbound variable.
    local _mod='' _fn=''
    stealth::util::log::_split_caller _mod _fn stealth::sys::cmd::run

    assert_equal "${_mod}" sys/cmd
    assert_equal "${_fn}" run
}

# ------------------------------------------------------------------------------
# stealth::util::log::_sanitize
# ------------------------------------------------------------------------------

@test "stealth::util::log::_sanitize: a carriage return -> replaces it" {
    local out=''
    stealth::util::log::_sanitize out $'done\rrewritten'

    assert_equal "${out}" 'done<CR>rewritten'
}

@test "stealth::util::log::_sanitize: an escape -> replaces it" {
    local out=''
    stealth::util::log::_sanitize out $'\033[2Jcleared'

    assert_equal "${out}" '<ESC>[2Jcleared'
}

# ------------------------------------------------------------------------------
# stealth::util::log::_escape
# ------------------------------------------------------------------------------

@test "stealth::util::log::_escape: a quote and a backslash -> escapes both" {
    local out=''
    stealth::util::log::_escape out 'a "quoted" c:\path'

    assert_equal "${out}" 'a \"quoted\" c:\\path'
}

@test "stealth::util::log::_escape: a line break and a tab -> escapes both" {
    local out=''
    stealth::util::log::_escape out $'one\ttwo\nthree'

    assert_equal "${out}" 'one\ttwo\nthree'
}

# ------------------------------------------------------------------------------
# stealth::util::log::_fmt_text
# ------------------------------------------------------------------------------

@test "stealth::util::log::_fmt_text: a long module and function -> truncates and keeps the line" {
    local file='' cons=''
    stealth::util::log::_fmt_text file cons 12:00:00 INFO \
        api/make/an/extremely/long/path buildeverythingnow 1234 body BLUE

    assert_contains "${file}" ':1234]'
    assert_contains "${file}" 'body'
}

@test "stealth::util::log::_fmt_text: a label that is not a level -> pads the badge to four" {
    local file='' cons=''
    stealth::util::log::_fmt_text file cons 12:00:00 AUDIT sys/cmd run 10 body BLUE

    assert_contains "${file}" '[ AUDI ]'
}

@test "stealth::util::log::_fmt_text: a message over two lines -> indents the second" {
    local file='' cons=''
    stealth::util::log::_fmt_text file cons 12:00:00 INFO sys/cmd run 10 $'one\ntwo' BLUE

    local -r second="${file#*$'\n'}"
    assert_starts_with "${second}" '                    '
    assert_ends_with "${second}" 'two'
}

# ------------------------------------------------------------------------------
# stealth::util::log::_wrapper
# ------------------------------------------------------------------------------

@test "stealth::util::log::_wrapper: a message on standard input -> writes it" {
    open_console
    printf 'from a pipe\n' | stealth::util::log::info

    run console
    assert_output --partial 'from a pipe'
}

@test "stealth::util::log::_wrapper: a block on standard input -> keeps its lines" {
    open_console
    printf 'first\nsecond\n' | stealth::util::log::info

    run console
    assert_output --partial 'first'
    assert_output --partial 'second'
}

@test "stealth::util::log::_wrapper: no message and nothing on standard input -> fails and names the level" {
    open_console

    run --separate-stderr stealth::util::log::info </dev/null
    assert_failure 1
    assert_equal "${stderr}" 'log: INFO called with no message'
}

@test "stealth::util::log::_wrapper: --frame -> names the caller of the caller" {
    open_console
    # A helper that logs for whoever called it, as util/assert does.
    helper() { stealth::util::log::info --frame 1 'from the helper'; }
    stealth::api::oci::store::put() { helper; }

    stealth::api::oci::store::put

    run console
    assert_output --partial 'api/oci/store @ put'
}

@test "stealth::util::log::_wrapper: no --frame -> names the direct caller" {
    open_console
    stealth::api::oci::store::put() { stealth::util::log::info 'direct'; }

    stealth::api::oci::store::put

    run console
    assert_output --partial 'api/oci/store @ put'
}

@test "stealth::util::log::_wrapper: --frame without a count -> reads it as the message" {
    open_console
    stealth::util::log::info --frame

    run console
    assert_output --partial '--frame'
}

@test "stealth::util::log::_wrapper: an empty pipe -> fails and names the level" {
    open_console

    run --separate-stderr bash -c \
        "source '${STEALTH_LIB_DIR}/util/log.sh'; printf '' | stealth::util::log::warn"
    assert_failure 1
    assert_equal "${stderr}" 'log: WARN called with no message'
}

# ------------------------------------------------------------------------------
# util/log, the module itself
# ------------------------------------------------------------------------------

@test "util/log: both sinks are open -> each receives the entry" {
    open_sinks
    stealth::util::log::info 'to both'

    run console
    assert_output --partial 'to both'

    run logfile
    assert_output --partial 'to both'
}

@test "util/log: the console is off -> only the file receives the entry" {
    open_sinks
    STEALTH_LOG_CONSOLE=0
    stealth::util::log::info 'file only'

    run console
    assert_output ''

    run logfile
    assert_output --partial 'file only'
}

@test "util/log: a log line from a namespaced function -> names the module and the function" {
    open_console
    stealth::sys::io::fs::atomic /etc/hosts

    run console
    assert_output --partial 'sys/io/fs @ atomic'
    assert_output --partial 'writing /etc/hosts'
}

@test "util/log: a message with an escape -> the sink receives it replaced" {
    open_console
    stealth::util::log::info $'\033[31mred'

    run console
    assert_output --partial '<ESC>[31mred'
}

@test "util/log: a message over two lines -> the sink receives both" {
    open_console
    stealth::util::log::info $'first\nsecond'

    run console
    assert_line --index 0 --partial 'first'
    assert_line --index 1 --partial 'second'
}

@test "util/log: the json format -> writes one object per entry" {
    STEALTH_LOG_FORMAT=json
    open_console
    stealth::sys::io::fs::atomic /etc/hosts

    run console
    assert_json_valid "${output}"
    assert_json_equal "${output}" .level INFO
    assert_json_equal "${output}" .module sys/io/fs
    assert_json_equal "${output}" .msg 'writing /etc/hosts'
}

@test "util/log: the json format and a message with a quote -> stays valid" {
    STEALTH_LOG_FORMAT=json
    open_console
    stealth::util::log::info 'said "%s"' hello

    run console
    assert_json_valid "${output}"
    assert_json_equal "${output}" .msg 'said "hello"'
}

@test "util/log: the logfmt format -> writes key-value pairs" {
    STEALTH_LOG_FORMAT=logfmt
    open_console
    stealth::sys::io::fs::atomic /etc/hosts

    run console
    assert_output --partial 'level=INFO'
    assert_output --partial 'module=sys/io/fs'
    assert_output --partial 'msg="writing /etc/hosts"'
}

@test "util/log: an unknown format -> falls back to text" {
    STEALTH_LOG_FORMAT=yaml
    open_console
    stealth::util::log::info 'plain'

    run console
    assert_output --partial '[ INFO ]'
}

@test "util/log: colour is on -> the console gets codes and the file does not" {
    STEALTH_LOG_COLOR=always
    open_sinks
    stealth::util::log::warn 'careful'

    run console
    assert_output --partial $'\033[33m'

    run logfile
    refute_output --partial $'\033'
}

@test "util/log: sourced twice -> returns before it declares anything" {
    STEALTH_LOG_LEVEL=5

    load_lib util/log

    assert_var_equal STEALTH_LOG_LEVEL 5
}
