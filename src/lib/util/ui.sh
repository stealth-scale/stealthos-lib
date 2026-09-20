###############################################################################
# module: util/ui
# layer: util
# description: What a person watching a run sees: headers, key and value
#              lines, tables, a status line per step, and the prompts a host
#              stage asks.
#
#              Everything is drawn on the console sink of util/log, so the UI
#              and the log lines share one descriptor and never interleave
#              with a redirected stdout.
#
#              No function here runs a command. A step's status line is two
#              calls, begin before the work and end after it, so running the
#              work stays with the caller and with sys/cmd. The old module ran
#              the command itself, in the background, with its output sent to
#              /dev/null, which threw away the one thing a failed step is
#              worth reading.
#
#              A step's line does not animate. A spinner needs a process of
#              its own, and a process of its own outlives a build that dies
#              between begin and end.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_UI:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_UI=1

stealth::util::import "util/assert" "util/log" "util/fmt" "util/text" "util/math"

# =============================================================================
# CONSTANTS
# =============================================================================

declare -gr _STEALTH_UTIL_UI_RED=$'\033[31m'
declare -gr _STEALTH_UTIL_UI_GREEN=$'\033[32m'
declare -gr _STEALTH_UTIL_UI_YELLOW=$'\033[33m'
declare -gr _STEALTH_UTIL_UI_BLUE=$'\033[34m'
declare -gr _STEALTH_UTIL_UI_MAGENTA=$'\033[35m'
declare -gr _STEALTH_UTIL_UI_CYAN=$'\033[36m'
declare -gr _STEALTH_UTIL_UI_GRAY=$'\033[90m'
declare -gr _STEALTH_UTIL_UI_BOLD=$'\033[1m'
declare -gr _STEALTH_UTIL_UI_RESET=$'\033[0m'

# Erases the line the cursor is on and puts the cursor back at its start.
declare -gr _STEALTH_UTIL_UI_CLEAR=$'\033[2K\r'

# The width a column is held to when a terminal is narrower than this.
declare -gri _STEALTH_UTIL_UI_MIN_WIDTH=40
declare -gri _STEALTH_UTIL_UI_DEFAULT_WIDTH=80

# How wide the name of a step is drawn, and how much of a digest is shown.
declare -gri _STEALTH_UTIL_UI_STEP_WIDTH=34
declare -gri _STEALTH_UTIL_UI_DIGEST_WIDTH=19

# How wide the bar of a progress line is drawn.
declare -gri _STEALTH_UTIL_UI_BAR_WIDTH=30

# What separates the columns of a row given to table.
declare -gr _STEALTH_UTIL_UI_COLUMN_SEPARATOR=$'\t'

# =============================================================================
# CONFIGURATION
# =============================================================================

# How wide the console is. init works it out; a caller may set it first.
declare -gi STEALTH_UI_WIDTH="${STEALTH_UI_WIDTH:-0}"

# The colour a header is drawn in.
declare -g STEALTH_UI_THEME="${STEALTH_UI_THEME:-blue}"

# =============================================================================
# STATE
# =============================================================================

declare -gi _STEALTH_UTIL_UI_READY=0
declare -gA _STEALTH_UTIL_UI_COLORS=()

# The name of the step whose line is open, and empty when none is.
declare -g _STEALTH_UTIL_UI_STEP=""

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reports whether the console is a terminal. It is a function of its own so
# that a test can answer for it; a test has no terminal.
#
# Usage:
#   if stealth::util::ui::_is_terminal; then ...
#
# Arguments:
#   None
# Returns:
#   0 - A terminal
#   1 - A file, a pipe or anything else
#######################################
stealth::util::ui::_is_terminal() {
    [[ -t 2 ]]
}

#######################################
# Reports whether a person is there to answer a prompt.
#
# Usage:
#   if ! stealth::util::ui::_is_interactive; then return 0; fi
#
# Arguments:
#   None
# Returns:
#   0 - Standard input and the console are both a terminal
#   1 - One of them is not
#######################################
stealth::util::ui::_is_interactive() {
    [[ -t 0 ]] && stealth::util::ui::_is_terminal
}

#######################################
# Writes to the console sink of util/log, or to stderr before the logger is
# started.
#
# Usage:
#   stealth::util::ui::_write '  %s\n' "${line}"
#
# Arguments:
#   $1 (String) - The printf format
#   $@ (String) - Its arguments
# Globals:
#   _STEALTH_UTIL_LOG_FD_CONSOLE (Read)
# Outputs:
#   The text, to the console sink
# Returns:
#   0 - Written
#######################################
stealth::util::ui::_write() {
    local -r _ui_write_format="${1}"
    shift

    # shellcheck disable=SC2059  # the format is this library's, never data
    printf -- "${_ui_write_format}" "$@" >&"${_STEALTH_UTIL_LOG_FD_CONSOLE:-2}"
    return 0
}

#######################################
# Works out how wide the console is. COLUMNS is asked first, because a shell
# keeps it without running anything, and tput only after that.
#
# Usage:
#   stealth::util::ui::_detect_width
#
# Arguments:
#   None
# Globals:
#   COLUMNS (Read)
#   STEALTH_UI_WIDTH (Write)
#   _STEALTH_UTIL_UI_MIN_WIDTH (Read)
#   _STEALTH_UTIL_UI_DEFAULT_WIDTH (Read)
# Returns:
#   0 - Worked out
#######################################
stealth::util::ui::_detect_width() {
    local _ui_width_found="${COLUMNS:-}"

    if [[ ! "${_ui_width_found}" =~ ^[0-9]+$ ]] && command -v tput >/dev/null 2>&1; then
        _ui_width_found="$(tput cols 2>/dev/null || true)"
    fi

    if [[ ! "${_ui_width_found}" =~ ^[0-9]+$ ]]; then
        _ui_width_found="${_STEALTH_UTIL_UI_DEFAULT_WIDTH}"
    fi

    STEALTH_UI_WIDTH="${_ui_width_found}"
    if (( STEALTH_UI_WIDTH < _STEALTH_UTIL_UI_MIN_WIDTH )); then
        STEALTH_UI_WIDTH="${_STEALTH_UTIL_UI_DEFAULT_WIDTH}"
    fi
    return 0
}

#######################################
# Fills the colour map. Colour follows the one setting the whole program uses,
# STEALTH_LOG_COLOR, so the UI and the log agree. Every entry is empty when
# colour is off, so a caller interpolates the map either way.
#
# Usage:
#   stealth::util::ui::_resolve_colors
#
# Arguments:
#   None
# Globals:
#   STEALTH_LOG_COLOR (Read)
#   NO_COLOR (Read)
#   _STEALTH_UTIL_UI_COLORS (Write)
# Returns:
#   0 - Filled
#######################################
stealth::util::ui::_resolve_colors() {
    local -i _ui_color_on=0

    case "${STEALTH_LOG_COLOR:-auto}" in
        always) _ui_color_on=1 ;;
        never)  _ui_color_on=0 ;;
        *)
            if stealth::util::ui::_is_terminal && [[ -z "${NO_COLOR:-}" ]]; then
                _ui_color_on=1
            fi
            ;;
    esac

    local _ui_color_key _ui_color_ref
    for _ui_color_key in RED GREEN YELLOW BLUE MAGENTA CYAN GRAY BOLD RESET; do
        _ui_color_ref="_STEALTH_UTIL_UI_${_ui_color_key}"
        if (( _ui_color_on == 1 )); then
            _STEALTH_UTIL_UI_COLORS["${_ui_color_key}"]="${!_ui_color_ref}"
        else
            _STEALTH_UTIL_UI_COLORS["${_ui_color_key}"]=""
        fi
    done
    return 0
}

#######################################
# Reads a colour out of the map by name. A name the map does not hold gives
# the sequence that resets, so a mistyped colour cannot leave the terminal in
# a colour it never gets out of.
#
# Usage:
#   stealth::util::ui::_color code green
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The colour name
# Globals:
#   _STEALTH_UTIL_UI_COLORS (Read)
# Returns:
#   0 - Read
#   Exits 1 when no output variable or no name is given
#######################################
stealth::util::ui::_color() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a colour name is required'
    local -n _ui_color_out="${1}"
    local _ui_color_name

    stealth::util::text::to_upper _ui_color_name "${2}"

    if [[ -v "_STEALTH_UTIL_UI_COLORS[${_ui_color_name}]" ]]; then
        _ui_color_out="${_STEALTH_UTIL_UI_COLORS[${_ui_color_name}]}"
    else
        _ui_color_out="${_STEALTH_UTIL_UI_COLORS[RESET]:-}"
    fi
    return 0
}

#######################################
# Splits a row into its columns.
#
# Usage:
#   stealth::util::ui::_columns cells "${row}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The row
# Globals:
#   _STEALTH_UTIL_UI_COLUMN_SEPARATOR (Read)
# Returns:
#   0 - Split
#######################################
stealth::util::ui::_columns() {
    stealth::util::text::split "${1}" "${2}" "${_STEALTH_UTIL_UI_COLUMN_SEPARATOR}"
    return 0
}

# =============================================================================
# PUBLIC API: SETTING UP
# =============================================================================

#######################################
# Prepares the UI: how wide the console is, and whether colour is drawn. It is
# idempotent, and drawing works before it is called, at the default width and
# without colour.
#
# Usage:
#   stealth::util::ui::init
#
# Arguments:
#   None
# Globals:
#   STEALTH_UI_WIDTH (Read/Write)
#   _STEALTH_UTIL_UI_READY (Write)
# Returns:
#   0 - Ready
#######################################
stealth::util::ui::init() {
    if (( _STEALTH_UTIL_UI_READY == 1 )); then
        return 0
    fi

    if (( STEALTH_UI_WIDTH <= 0 )); then
        stealth::util::ui::_detect_width
    fi
    stealth::util::ui::_resolve_colors

    _STEALTH_UTIL_UI_READY=1
    return 0
}

# =============================================================================
# PUBLIC API: DRAWING
# =============================================================================

#######################################
# Draws a line across the console.
#
# Usage:
#   stealth::util::ui::rule
#   stealth::util::ui::rule '='
#
# Arguments:
#   $1 (String) - The character to repeat. Default: a hyphen
# Globals:
#   STEALTH_UI_WIDTH (Read)
# Outputs:
#   One line, to the console sink
# Returns:
#   0 - Drawn
#######################################
stealth::util::ui::rule() {
    local _ui_rule_line

    stealth::util::fmt::repeat _ui_rule_line "${1:--}" "${STEALTH_UI_WIDTH}"
    stealth::util::ui::_write '%s\n' "${_ui_rule_line}"
    return 0
}

#######################################
# Draws the heading of a section, between two lines.
#
# Usage:
#   stealth::util::ui::header 'Stage 0: the seed toolchain'
#
# Arguments:
#   $1 (String) - The title
# Globals:
#   STEALTH_UI_THEME (Read)
# Outputs:
#   Four lines, to the console sink
# Returns:
#   0 - Drawn
#   Exits 1 when no title is given
#######################################
stealth::util::ui::header() {
    stealth::util::assert::not_empty "${1:-}" 'a title is required'
    local _ui_header_theme _ui_header_reset

    stealth::util::ui::_color _ui_header_theme "${STEALTH_UI_THEME}"
    stealth::util::ui::_color _ui_header_reset reset

    stealth::util::ui::_write '\n%s' "${_ui_header_theme}"
    stealth::util::ui::rule '='
    stealth::util::ui::_write '  %s\n' "${1}"
    stealth::util::ui::rule '='
    stealth::util::ui::_write '%s' "${_ui_header_reset}"
    return 0
}

#######################################
# Draws something that needs to be read, between two lines, in red.
#
# Usage:
#   stealth::util::ui::alert 'No signature' 'the layer is not signed'
#
# Arguments:
#   $1 (String) - The title
#   $2 (String) - The message
# Outputs:
#   Four lines, to the console sink
# Returns:
#   0 - Drawn
#   Exits 1 when no title or no message is given
#######################################
stealth::util::ui::alert() {
    stealth::util::assert::not_empty "${1:-}" 'a title is required'
    stealth::util::assert::not_empty "${2:-}" 'a message is required'
    local _ui_alert_red _ui_alert_reset

    stealth::util::ui::_color _ui_alert_red red
    stealth::util::ui::_color _ui_alert_reset reset

    stealth::util::ui::_write '\n%s' "${_ui_alert_red}"
    stealth::util::ui::rule '!'
    stealth::util::ui::_write '  %s: %s\n' "${1}" "${2}"
    stealth::util::ui::rule '!'
    stealth::util::ui::_write '%s' "${_ui_alert_reset}"
    return 0
}

#######################################
# Draws a key and its value, with the keys of a run lining up.
#
# Usage:
#   stealth::util::ui::kv 'Target' "${STEALTH_TARGET}"
#
# Arguments:
#   $1 (String) - The key
#   $2 (String) - The value. Default: empty
# Globals:
#   _STEALTH_UTIL_UI_STEP_WIDTH (Read)
# Outputs:
#   One line, to the console sink
# Returns:
#   0 - Drawn
#   Exits 1 when no key is given
#######################################
stealth::util::ui::kv() {
    stealth::util::assert::not_empty "${1:-}" 'a key is required'
    local _ui_kv_bold _ui_kv_reset _ui_kv_key

    stealth::util::ui::_color _ui_kv_bold bold
    stealth::util::ui::_color _ui_kv_reset reset
    stealth::util::fmt::pad_right _ui_kv_key "${1}" 20

    stealth::util::ui::_write '  %s%s%s : %s\n' \
        "${_ui_kv_bold}" "${_ui_kv_key}" "${_ui_kv_reset}" "${2:-}"
    return 0
}

#######################################
# Draws rows in columns that line up. A row is one argument, and a tab
# separates its columns. Every row is measured before any is drawn, so a
# column is as wide as its widest value.
#
# Usage:
#   stealth::util::ui::table \
#       "$(printf 'zlib\tok\t12s')" \
#       "$(printf 'gcc\tfailed\t3m 4s')"
#
# Arguments:
#   $@ (String) - The rows
# Globals:
#   _STEALTH_UTIL_UI_COLUMN_SEPARATOR (Read)
# Outputs:
#   A line per row, to the console sink
# Returns:
#   0 - Drawn, and nothing is drawn for no rows
#######################################
stealth::util::ui::table() {
    if (( $# == 0 )); then
        return 0
    fi

    local -a _ui_table_widths=() _ui_table_cells=()
    local _ui_table_row _ui_table_cell
    local -i _ui_table_i _ui_table_width

    for _ui_table_row in "$@"; do
        stealth::util::ui::_columns _ui_table_cells "${_ui_table_row}"
        for (( _ui_table_i = 0; _ui_table_i < ${#_ui_table_cells[@]}; _ui_table_i++ )); do
            stealth::util::fmt::width _ui_table_width "${_ui_table_cells[_ui_table_i]}"
            if (( _ui_table_i >= ${#_ui_table_widths[@]} )); then
                _ui_table_widths+=("${_ui_table_width}")
            elif (( _ui_table_width > _ui_table_widths[_ui_table_i] )); then
                _ui_table_widths[_ui_table_i]="${_ui_table_width}"
            fi
        done
    done

    local _ui_table_line _ui_table_padded
    for _ui_table_row in "$@"; do
        stealth::util::ui::_columns _ui_table_cells "${_ui_table_row}"
        _ui_table_line='  '
        for (( _ui_table_i = 0; _ui_table_i < ${#_ui_table_cells[@]}; _ui_table_i++ )); do
            _ui_table_cell="${_ui_table_cells[_ui_table_i]}"
            if (( _ui_table_i == ${#_ui_table_cells[@]} - 1 )); then
                _ui_table_line+="${_ui_table_cell}"
            else
                stealth::util::fmt::pad_right _ui_table_padded \
                    "${_ui_table_cell}" "${_ui_table_widths[_ui_table_i]}"
                _ui_table_line+="${_ui_table_padded}  "
            fi
        done
        stealth::util::ui::_write '%s\n' "${_ui_table_line}"
    done
    return 0
}

# =============================================================================
# PUBLIC API: THE LINE OF A STEP
# =============================================================================

#######################################
# Opens the line of a step. On a terminal the line stays open, and end writes
# over it. Anywhere else nothing is drawn, so a log holds one line per step
# rather than two.
#
# Usage:
#   stealth::util::ui::begin 'building zlib'
#   ...
#   stealth::util::ui::end 'building zlib' "${status}" "${SECONDS}"
#
# Arguments:
#   $1 (String) - The name of the step
# Globals:
#   _STEALTH_UTIL_UI_STEP (Write)
#   _STEALTH_UTIL_UI_STEP_WIDTH (Read)
# Outputs:
#   One line without a break, to the console sink of a terminal
# Returns:
#   0 - Opened
#   Exits 1 when no name is given
#######################################
stealth::util::ui::begin() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a step is required'
    _STEALTH_UTIL_UI_STEP="${1}"

    if ! stealth::util::ui::_is_terminal; then
        return 0
    fi

    local _ui_begin_gray _ui_begin_reset _ui_begin_name
    stealth::util::ui::_color _ui_begin_gray gray
    stealth::util::ui::_color _ui_begin_reset reset
    stealth::util::fmt::truncate _ui_begin_name "${1}" "${_STEALTH_UTIL_UI_STEP_WIDTH}"

    stealth::util::ui::_write '%s[ .. ]%s %s' \
        "${_ui_begin_gray}" "${_ui_begin_reset}" "${_ui_begin_name}"
    return 0
}

#######################################
# Closes the line of a step with how it went, how long it took and what it
# produced. On a terminal it writes over the line begin opened.
#
# Usage:
#   stealth::util::ui::end 'building zlib' 0 "${took}" "${digest}"
#
# Arguments:
#   $1 (String)  - The name of the step
#   $2 (Integer) - The status it ended with, zero for a step that worked
#   $3 (Integer) - How long it took, in seconds. Default: not shown
#   $4 (String)  - The digest of what it produced. Default: not shown
# Globals:
#   _STEALTH_UTIL_UI_STEP (Write)
#   _STEALTH_UTIL_UI_STEP_WIDTH (Read)
#   _STEALTH_UTIL_UI_DIGEST_WIDTH (Read)
#   _STEALTH_UTIL_UI_CLEAR (Read)
# Outputs:
#   One line, to the console sink
# Returns:
#   0 - Closed
#   Exits 1 when no name is given, or the status is not a whole number
#######################################
stealth::util::ui::end() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a step is required'
    stealth::util::assert::is_int "${2:-}" "a status is a whole number, not ${2:-}"
    _STEALTH_UTIL_UI_STEP=""

    local _ui_end_badge _ui_end_color _ui_end_reset
    if (( ${2} == 0 )); then
        _ui_end_badge=' ok '
        stealth::util::ui::_color _ui_end_color green
    else
        _ui_end_badge='fail'
        stealth::util::ui::_color _ui_end_color red
    fi
    stealth::util::ui::_color _ui_end_reset reset

    local _ui_end_took=''
    if [[ -n "${3:-}" ]]; then
        stealth::util::math::duration _ui_end_took "${3}"
    fi

    local _ui_end_digest=''
    if [[ -n "${4:-}" ]]; then
        stealth::util::fmt::truncate _ui_end_digest "${4}" \
            "${_STEALTH_UTIL_UI_DIGEST_WIDTH}"
    fi

    local _ui_end_name _ui_end_padded_took
    stealth::util::fmt::truncate _ui_end_name "${1}" "${_STEALTH_UTIL_UI_STEP_WIDTH}"
    stealth::util::fmt::pad_right _ui_end_name "${_ui_end_name}" \
        "${_STEALTH_UTIL_UI_STEP_WIDTH}"
    stealth::util::fmt::pad_left _ui_end_padded_took "${_ui_end_took}" 9

    if stealth::util::ui::_is_terminal; then
        stealth::util::ui::_write '%s' "${_STEALTH_UTIL_UI_CLEAR}"
    fi

    stealth::util::ui::_write '%s[%s]%s %s %s  %s\n' \
        "${_ui_end_color}" "${_ui_end_badge}" "${_ui_end_reset}" \
        "${_ui_end_name}" "${_ui_end_padded_took}" "${_ui_end_digest}"
    return 0
}

#######################################
# Draws how far along something is, as a bar and a percentage. Nothing is
# drawn anywhere but a terminal, because a log does not want a line per step
# of a thousand. The line ends with a break once it reaches the end.
#
# Usage:
#   stealth::util::ui::progress "${built}" "${total}" 'packages'
#
# Arguments:
#   $1 (Integer) - How many are done
#   $2 (Integer) - How many there are, above zero
#   $3 (String)  - What is being counted. Default: working
# Globals:
#   _STEALTH_UTIL_UI_BAR_WIDTH (Read)
# Outputs:
#   One line without a break, to the console sink of a terminal
# Returns:
#   0 - Drawn, or there is no terminal to draw on
#   Exits 1 when a count is not a whole number, or there are none of them
#######################################
stealth::util::ui::progress() {
    stealth::util::assert::is_int "${1:-}" "a count is a whole number, not ${1:-}"
    stealth::util::assert::is_int "${2:-}" "a total is a whole number, not ${2:-}"

    if ! stealth::util::ui::_is_terminal; then
        return 0
    fi

    local -i _ui_prog_percent _ui_prog_filled
    stealth::util::math::percent _ui_prog_percent "${1}" "${2}"
    stealth::util::math::div_round _ui_prog_filled \
        "$(( _ui_prog_percent * _STEALTH_UTIL_UI_BAR_WIDTH ))" 100
    stealth::util::math::clamp _ui_prog_filled "${_ui_prog_filled}" 0 \
        "${_STEALTH_UTIL_UI_BAR_WIDTH}"

    local _ui_prog_bar _ui_prog_rest
    stealth::util::fmt::repeat _ui_prog_bar '#' "${_ui_prog_filled}"
    stealth::util::fmt::repeat _ui_prog_rest ' ' \
        "$(( _STEALTH_UTIL_UI_BAR_WIDTH - _ui_prog_filled ))"

    stealth::util::ui::_write '\r[%s%s] %3d%% %s' \
        "${_ui_prog_bar}" "${_ui_prog_rest}" "${_ui_prog_percent}" "${3:-working}"

    if (( _ui_prog_percent >= 100 )); then
        stealth::util::ui::_write '\n'
    fi
    return 0
}

# =============================================================================
# PUBLIC API: ASKING
# =============================================================================

#######################################
# Asks a question that takes yes or no. With nobody there to answer, the
# default is taken and a line says so, because a build that waits for an
# answer in CI waits until it is killed.
#
# Usage:
#   if stealth::util::ui::ask 'Wipe the store?' N; then ...
#
# Arguments:
#   $1 (String) - The question
#   $2 (String) - The answer to take when none is given, Y or N. Default: Y
# Outputs:
#   The question, to the console sink
# Returns:
#   0 - Yes
#   1 - No
#   Exits 1 when no question is given
#######################################
stealth::util::ui::ask() {
    stealth::util::assert::not_empty "${1:-}" 'a question is required'
    local _ui_ask_default
    stealth::util::text::to_lower _ui_ask_default "${2:-Y}"

    if ! stealth::util::ui::_is_interactive; then
        stealth::util::log::info 'answering "%s" with the default of %s' \
            "${1}" "${_ui_ask_default}"
        [[ "${_ui_ask_default}" == 'y' ]]
        return
    fi

    local _ui_ask_choices='[y/N]'
    if [[ "${_ui_ask_default}" == 'y' ]]; then
        _ui_ask_choices='[Y/n]'
    fi

    local _ui_ask_answer=''
    stealth::util::ui::_write '%s %s ' "${1}" "${_ui_ask_choices}"
    read -r _ui_ask_answer || true

    if [[ -z "${_ui_ask_answer}" ]]; then
        _ui_ask_answer="${_ui_ask_default}"
    fi
    stealth::util::text::to_lower _ui_ask_answer "${_ui_ask_answer}"

    [[ "${_ui_ask_answer}" == 'y' || "${_ui_ask_answer}" == 'yes' ]]
}

#######################################
# Asks for a line of text. With nobody there to answer, the default is taken,
# and a question with no default cannot be answered at all.
#
# Usage:
#   stealth::util::ui::read hostname 'Hostname' 'stealthos'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The question
#   $3 (String)  - The answer to take when none is given. Default: empty
# Outputs:
#   The question, to the console sink
# Returns:
#   0 - Answered
#   1 - Nobody is there and there is no default
#   Exits 1 when no output variable or no question is given
#######################################
stealth::util::ui::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a question is required'
    local -n _ui_read_out="${1}"
    local -r _ui_read_default="${3:-}"

    if ! stealth::util::ui::_is_interactive; then
        if [[ -z "${_ui_read_default}" ]]; then
            stealth::util::log::warn 'nobody can answer "%s" and it has no default' "${2}"
            return 1
        fi
        _ui_read_out="${_ui_read_default}"
        return 0
    fi

    local _ui_read_shown=''
    if [[ -n "${_ui_read_default}" ]]; then
        _ui_read_shown=" [${_ui_read_default}]"
    fi

    stealth::util::ui::_write '%s%s: ' "${2}" "${_ui_read_shown}"
    read -r _ui_read_out || true

    if [[ -z "${_ui_read_out}" ]]; then
        _ui_read_out="${_ui_read_default}"
    fi
    return 0
}

#######################################
# Asks for something that must not appear on the screen. There is no default,
# because a secret that has one is not a secret.
#
# Usage:
#   stealth::util::ui::read_secret passphrase 'Passphrase for the signing key'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The question
# Outputs:
#   The question, to the console sink
# Returns:
#   0 - Answered
#   1 - Nobody is there to answer
#   Exits 1 when no output variable or no question is given
#######################################
stealth::util::ui::read_secret() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a question is required'
    local -n _ui_secret_out="${1}"

    if ! stealth::util::ui::_is_interactive; then
        stealth::util::log::warn 'nobody can answer "%s", and a secret has no default' "${2}"
        return 1
    fi

    stealth::util::ui::_write '%s: ' "${2}"
    read -rs _ui_secret_out || true
    stealth::util::ui::_write '\n'
    return 0
}

#######################################
# Asks which of a list to take. The list is numbered and read back, rather
# than drawn by the shell's own select, which writes to standard error
# whatever the console sink is set to.
#
# With nobody there to answer, the first of the list is taken.
#
# Usage:
#   stealth::util::ui::choose target 'Which target?' x86_64 aarch64
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The question
#   $@ (String)  - What there is to take, at least one
# Outputs:
#   The list and the question, to the console sink
# Returns:
#   0 - Taken
#   1 - Standard input ended before an answer came
#   Exits 1 when no output variable, no question or nothing to take is given
#######################################
stealth::util::ui::choose() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a question is required'
    local -n _ui_choose_out="${1}"
    local -r _ui_choose_question="${2}"
    shift 2

    stealth::util::assert::not_empty "${1:-}" 'at least one choice is required'
    local -ra _ui_choose_options=("$@")

    if ! stealth::util::ui::_is_interactive; then
        _ui_choose_out="${_ui_choose_options[0]}"
        stealth::util::log::info 'answering "%s" with the first choice, %s' \
            "${_ui_choose_question}" "${_ui_choose_out}"
        return 0
    fi

    local -i _ui_choose_i
    local _ui_choose_answer
    while true; do
        stealth::util::ui::_write '%s\n' "${_ui_choose_question}"
        for (( _ui_choose_i = 0; _ui_choose_i < ${#_ui_choose_options[@]}; _ui_choose_i++ )); do
            stealth::util::ui::_write '  %d) %s\n' \
                "$(( _ui_choose_i + 1 ))" "${_ui_choose_options[_ui_choose_i]}"
        done
        stealth::util::ui::_write 'Take which one? '

        _ui_choose_answer=''
        if ! read -r _ui_choose_answer && [[ -z "${_ui_choose_answer}" ]]; then
            # Standard input ended. Asking again would never get an answer,
            # and the loop would spin until something killed it.
            stealth::util::log::warn 'nothing answered "%s"' "${_ui_choose_question}"
            return 1
        fi

        if [[ "${_ui_choose_answer}" =~ ^[0-9]+$ ]] &&
           (( _ui_choose_answer >= 1 &&
              _ui_choose_answer <= ${#_ui_choose_options[@]} )); then
            _ui_choose_out="${_ui_choose_options[_ui_choose_answer - 1]}"
            return 0
        fi

        stealth::util::ui::_write 'That is not one of them.\n'
    done
}
