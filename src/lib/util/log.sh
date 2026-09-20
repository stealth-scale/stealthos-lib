###############################################################################
# module: util/log
# layer: util
# description: The logger. Five levels, three formats and two sinks: a console
#              and an optional file. A message is a printf format and its
#              arguments, or a block on standard input.
#
#              Every level function takes an optional --frame N before the
#              format. A helper that logs on behalf of its own caller passes
#              it, so the entry names the code that asked rather than the
#              helper. On error it follows -c.
#
#              The module imports nothing. util/assert and every layer above
#              it depend on the logger, so the logger depends on no one.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_LOG:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_LOG=1

# =============================================================================
# CONSTANTS
# =============================================================================

declare -gri STEALTH_LOG_LEVEL_OFF=0
declare -gri STEALTH_LOG_LEVEL_ERROR=1
declare -gri STEALTH_LOG_LEVEL_WARN=2
declare -gri STEALTH_LOG_LEVEL_INFO=3
declare -gri STEALTH_LOG_LEVEL_DEBUG=4
declare -gri STEALTH_LOG_LEVEL_TRACE=5

# The context column of the text format. A longer one is truncated, so the
# message starts at the same column on every line.
declare -gri _STEALTH_UTIL_LOG_CTX_WIDTH=30

declare -gr _STEALTH_UTIL_LOG_ANSI_RED=$'\033[31m'
declare -gr _STEALTH_UTIL_LOG_ANSI_YELLOW=$'\033[33m'
declare -gr _STEALTH_UTIL_LOG_ANSI_BLUE=$'\033[34m'
declare -gr _STEALTH_UTIL_LOG_ANSI_CYAN=$'\033[36m'
declare -gr _STEALTH_UTIL_LOG_ANSI_GRAY=$'\033[90m'
declare -gr _STEALTH_UTIL_LOG_ANSI_RESET=$'\033[0m'

# =============================================================================
# CONFIGURATION
# =============================================================================

# A caller sets these before init. core/engine fills them from the options and
# the configuration files.
declare -g STEALTH_LOG_LEVEL="${STEALTH_LOG_LEVEL:-3}"
declare -g STEALTH_LOG_FORMAT="${STEALTH_LOG_FORMAT:-text}"
declare -g STEALTH_LOG_COLOR="${STEALTH_LOG_COLOR:-auto}"
declare -gi STEALTH_LOG_CONSOLE="${STEALTH_LOG_CONSOLE:-1}"
declare -g STEALTH_LOG_FD_CONSOLE="${STEALTH_LOG_FD_CONSOLE:-}"
declare -g STEALTH_LOG_FD_FILE="${STEALTH_LOG_FD_FILE:-}"

# =============================================================================
# STATE
# =============================================================================

declare -gi _STEALTH_UTIL_LOG_READY=0
declare -g _STEALTH_UTIL_LOG_FD_CONSOLE=""
declare -g _STEALTH_UTIL_LOG_FD_FILE=""
declare -gA _STEALTH_UTIL_LOG_COLORS=()

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reports whether the console sink is a terminal. It is a function of its own
# so that a test can answer for it; a test has no terminal.
#
# Usage:
#   if stealth::util::log::_is_terminal; then ...
#
# Arguments:
#   None
# Returns:
#   0 - A terminal
#   1 - A file, a pipe or anything else
#######################################
stealth::util::log::_is_terminal() {
    [[ -t 2 ]]
}

#######################################
# Fills the colour map from STEALTH_LOG_COLOR. Every entry is empty when
# colour is off, so a formatter interpolates the map either way.
#
# Usage:
#   stealth::util::log::_resolve_colors
#
# Arguments:
#   None
# Globals:
#   STEALTH_LOG_COLOR (Read)
#   NO_COLOR (Read)
#   _STEALTH_UTIL_LOG_COLORS (Write)
# Returns:
#   0 - Filled
#######################################
stealth::util::log::_resolve_colors() {
    local -i _log_color_on=0

    case "${STEALTH_LOG_COLOR}" in
        always) _log_color_on=1 ;;
        never)  _log_color_on=0 ;;
        *)
            if stealth::util::log::_is_terminal && [[ -z "${NO_COLOR:-}" ]]; then
                _log_color_on=1
            fi
            ;;
    esac

    local _log_color_key _log_color_ref
    for _log_color_key in RED YELLOW BLUE CYAN GRAY RESET; do
        _log_color_ref="_STEALTH_UTIL_LOG_ANSI_${_log_color_key}"
        if (( _log_color_on == 1 )); then
            _STEALTH_UTIL_LOG_COLORS["${_log_color_key}"]="${!_log_color_ref}"
        else
            _STEALTH_UTIL_LOG_COLORS["${_log_color_key}"]=""
        fi
    done
    return 0
}

#######################################
# Validates a file descriptor and returns it. A descriptor that is not a
# number, or is not open for writing, is refused.
#
# Usage:
#   stealth::util::log::_bind_fd _fd 2 STEALTH_LOG_FD_CONSOLE
#
# Arguments:
#   $1 (Nameref) - The output variable for the descriptor
#   $2 (String)  - The descriptor
#   $3 (String)  - The name of the setting, for the message
# Outputs:
#   The reason, to stderr, when the descriptor is refused
# Returns:
#   0 - Bound
#   1 - Refused
#######################################
stealth::util::log::_bind_fd() {
    local -n _log_bind_out="${1}"
    local -r _log_bind_fd="${2}"
    local -r _log_bind_name="${3}"

    if [[ ! "${_log_bind_fd}" =~ ^[0-9]+$ ]]; then
        printf '%s is not a file descriptor: %s\n' "${_log_bind_name}" "${_log_bind_fd}" >&2
        return 1
    fi

    # The redirection fails before a redirection on the same command could
    # silence it, so the group carries the one that does.
    if ! { true >&"${_log_bind_fd}"; } 2>/dev/null; then
        printf '%s is not open for writing: %s\n' "${_log_bind_name}" "${_log_bind_fd}" >&2
        return 1
    fi

    _log_bind_out="${_log_bind_fd}"
    return 0
}

#######################################
# Splits a function name into its module path and its own name.
# stealth::sys::io::fs::atomic gives sys/io/fs and atomic.
#
# Every local here carries the function's prefix, because the caller passes
# the names of its own variables and a nameref resolves by name at each use.
#
# Usage:
#   stealth::util::log::_split_caller _mod _fn "${FUNCNAME[3]}"
#
# Arguments:
#   $1 (Nameref) - The output variable for the module path
#   $2 (Nameref) - The output variable for the function name
#   $3 (String)  - The function name, or empty for the top level
# Returns:
#   0 - Split
#######################################
stealth::util::log::_split_caller() {
    local -n _log_split_mod_out="${1}"
    local -n _log_split_fn_out="${2}"
    local -r _log_split_name="${3}"

    if [[ -z "${_log_split_name}" ]]; then
        _log_split_mod_out="main"
        _log_split_fn_out="main"
        return 0
    fi

    if [[ "${_log_split_name}" != *"::"* ]]; then
        _log_split_mod_out="main"
        _log_split_fn_out="${_log_split_name}"
        return 0
    fi

    # Drop the leading namespace, then split the module from the name.
    local _log_split_path="${_log_split_name#*::}"
    _log_split_fn_out="${_log_split_path##*::}"

    if [[ "${_log_split_path}" == *"::"* ]]; then
        _log_split_path="${_log_split_path%::*}"
        _log_split_mod_out="${_log_split_path//:://}"
    else
        _log_split_mod_out="main"
    fi
    return 0
}

#######################################
# Replaces the control characters that move a terminal cursor, so a message
# from a command cannot rewrite the lines above it.
#
# Usage:
#   stealth::util::log::_sanitize _clean "${raw}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The message
# Returns:
#   0 - Sanitised
#######################################
stealth::util::log::_sanitize() {
    local -n _log_san_out="${1}"
    local _log_san_msg="${2//$'\r'/<CR>}"

    _log_san_out="${_log_san_msg//$'\033'/<ESC>}"
    return 0
}

#######################################
# Escapes a message for a quoted string: the backslashes, the quotes and the
# line breaks.
#
# Usage:
#   stealth::util::log::_escape _quoted "${msg}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The message
# Returns:
#   0 - Escaped
#######################################
stealth::util::log::_escape() {
    local -n _log_esc_out="${1}"
    local _log_esc_msg="${2//\\/\\\\}"

    _log_esc_msg="${_log_esc_msg//\"/\\\"}"
    _log_esc_msg="${_log_esc_msg//$'\n'/\\n}"
    _log_esc_msg="${_log_esc_msg//$'\t'/\\t}"

    _log_esc_out="${_log_esc_msg}"
    return 0
}

#######################################
# Formats an entry as an aligned line, plain for the file and coloured for the
# console. A message that spans lines is indented to the first one.
#
# Usage:
#   stealth::util::log::_fmt_text _file _cons 12:00:00 INFO sys/cmd run 42 msg BLUE
#
# Arguments:
#   $1 (Nameref) - The output variable for the file
#   $2 (Nameref) - The output variable for the console
#   $3 (String)  - The timestamp
#   $4 (String)  - The level label
#   $5 (String)  - The module path
#   $6 (String)  - The function name
#   $7 (String)  - The line number
#   $8 (String)  - The message
#   $9 (String)  - The colour key of the level
# Globals:
#   _STEALTH_UTIL_LOG_COLORS (Read)
# Returns:
#   0 - Formatted
#######################################
stealth::util::log::_fmt_text() {
    local -n _log_text_file_out="${1}"
    local -n _log_text_cons_out="${2}"
    local -r _log_text_ts="${3}"
    local -r _log_text_label="${4}"
    local -r _log_text_mod="${5}"
    local -r _log_text_fn="${6}"
    local -r _log_text_line="${7}"
    local -r _log_text_msg="${8}"
    local -r _log_text_color="${9}"

    local _log_text_badge
    case "${_log_text_label}" in
        ERROR) _log_text_badge="FAIL" ;;
        DEBUG) _log_text_badge="DEBG" ;;
        TRACE) _log_text_badge="TRAC" ;;
        INFO|WARN) _log_text_badge="${_log_text_label}" ;;
        *)     printf -v _log_text_badge '%-4.4s' "${_log_text_label}" ;;
    esac

    # [module @ function:line], truncated from the left so the line survives.
    local -r _log_text_head="${_log_text_mod} @ ${_log_text_fn}"
    local -r _log_text_tail=":${_log_text_line}"
    local _log_text_ctx="${_log_text_head}${_log_text_tail}"

    if (( ${#_log_text_ctx} > _STEALTH_UTIL_LOG_CTX_WIDTH )); then
        local -i _log_text_room=$(( _STEALTH_UTIL_LOG_CTX_WIDTH - ${#_log_text_tail} ))
        (( _log_text_room < 0 )) && _log_text_room=0
        printf -v _log_text_ctx '%.*s%s' \
            "${_log_text_room}" "${_log_text_head}" "${_log_text_tail}"
    fi
    _log_text_ctx="[${_log_text_ctx}]"

    local _log_text_prefix
    printf -v _log_text_prefix '[ %s ] %s %-*s ' \
        "${_log_text_badge}" "${_log_text_ts}" \
        "$(( _STEALTH_UTIL_LOG_CTX_WIDTH + 2 ))" "${_log_text_ctx}"

    local _log_text_indent
    printf -v _log_text_indent '%*s' "${#_log_text_prefix}" ''
    local -r _log_text_body="${_log_text_msg//$'\n'/$'\n'${_log_text_indent}}"

    _log_text_file_out="${_log_text_prefix}${_log_text_body}"

    local -r _log_text_c="${_STEALTH_UTIL_LOG_COLORS[${_log_text_color}]:-}"
    local -r _log_text_gray="${_STEALTH_UTIL_LOG_COLORS[GRAY]:-}"
    local -r _log_text_reset="${_STEALTH_UTIL_LOG_COLORS[RESET]:-}"

    printf -v _log_text_cons_out '%s[ %s%s%s ] %s%s%s %-*s%s %s' \
        "${_log_text_gray}" "${_log_text_c}" "${_log_text_badge}" "${_log_text_gray}" \
        "${_log_text_ts}" "${_log_text_reset}" "${_log_text_gray}" \
        "$(( _STEALTH_UTIL_LOG_CTX_WIDTH + 2 ))" "${_log_text_ctx}" "${_log_text_reset}" \
        "${_log_text_body}"
    return 0
}

#######################################
# Formats an entry as one JSON object.
#
# Usage:
#   stealth::util::log::_fmt_json _out 12:00:00 INFO sys/cmd run 42 msg
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The timestamp
#   $3 (String)  - The level label
#   $4 (String)  - The module path
#   $5 (String)  - The function name
#   $6 (String)  - The line number
#   $7 (String)  - The message
# Returns:
#   0 - Formatted
#######################################
stealth::util::log::_fmt_json() {
    local -n _log_json_out="${1}"
    local _log_json_msg
    stealth::util::log::_escape _log_json_msg "${7}"

    printf -v _log_json_out \
        '{"time":"%s","level":"%s","module":"%s","caller":"%s:%s","msg":"%s"}' \
        "${2}" "${3}" "${4}" "${5}" "${6}" "${_log_json_msg}"
    return 0
}

#######################################
# Formats an entry as logfmt key-value pairs.
#
# Usage:
#   stealth::util::log::_fmt_logfmt _out 12:00:00 INFO sys/cmd run 42 msg
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The timestamp
#   $3 (String)  - The level label
#   $4 (String)  - The module path
#   $5 (String)  - The function name
#   $6 (String)  - The line number
#   $7 (String)  - The message
# Returns:
#   0 - Formatted
#######################################
stealth::util::log::_fmt_logfmt() {
    local -n _log_lf_out="${1}"
    local _log_lf_msg
    stealth::util::log::_escape _log_lf_msg "${7}"

    printf -v _log_lf_out 'time="%s" level=%s module=%s caller="%s:%s" msg="%s"' \
        "${2}" "${3}" "${4}" "${5}" "${6}" "${_log_lf_msg}"
    return 0
}

#######################################
# Formats one entry and writes it to the sinks. The caller is read from the
# call stack: this function, the wrapper, the level function, and then the
# caller. A helper that logs for someone else adds frames to skip.
#
# Usage:
#   stealth::util::log::_dispatch INFO BLUE 3 "the message" 0
#
# Arguments:
#   $1 (String)  - The level label
#   $2 (String)  - The colour key
#   $3 (Integer) - The level
#   $4 (String)  - The message
#   $5 (Integer) - The frames to skip above the level function. Default: 0
# Globals:
#   _STEALTH_UTIL_LOG_FD_CONSOLE (Read)
#   _STEALTH_UTIL_LOG_FD_FILE (Read)
# Globals:
#   STEALTH_LOG_LEVEL (Read)
#   STEALTH_LOG_FORMAT (Read)
#   STEALTH_LOG_CONSOLE (Read)
# Outputs:
#   The entry, to the file descriptor of each sink
# Returns:
#   0 - Written, or below the level
#######################################
stealth::util::log::_dispatch() {
    local -r _log_disp_label="${1}"
    local -r _log_disp_color="${2}"
    local -ri _log_disp_level="${3}"
    local -r _log_disp_raw="${4}"
    local -ri _log_disp_skip="${5:-0}"

    if ! stealth::util::log::is_enabled "${_log_disp_level}"; then
        return 0
    fi

    local _log_disp_ts
    printf -v _log_disp_ts '%(%H:%M:%S)T' -1

    local _log_disp_mod _log_disp_fn
    stealth::util::log::_split_caller _log_disp_mod _log_disp_fn \
        "${FUNCNAME[$(( 3 + _log_disp_skip ))]:-}"
    local -r _log_disp_line="${BASH_LINENO[$(( 2 + _log_disp_skip ))]:-0}"

    local _log_disp_msg
    stealth::util::log::_sanitize _log_disp_msg "${_log_disp_raw}"

    local _log_disp_file="" _log_disp_cons=""
    case "${STEALTH_LOG_FORMAT}" in
        json)
            stealth::util::log::_fmt_json _log_disp_file "${_log_disp_ts}" \
                "${_log_disp_label}" "${_log_disp_mod}" "${_log_disp_fn}" \
                "${_log_disp_line}" "${_log_disp_msg}"
            _log_disp_cons="${_log_disp_file}"
            ;;
        logfmt)
            stealth::util::log::_fmt_logfmt _log_disp_file "${_log_disp_ts}" \
                "${_log_disp_label}" "${_log_disp_mod}" "${_log_disp_fn}" \
                "${_log_disp_line}" "${_log_disp_msg}"
            _log_disp_cons="${_log_disp_file}"
            ;;
        *)
            stealth::util::log::_fmt_text _log_disp_file _log_disp_cons "${_log_disp_ts}" \
                "${_log_disp_label}" "${_log_disp_mod}" "${_log_disp_fn}" \
                "${_log_disp_line}" "${_log_disp_msg}" "${_log_disp_color}"
            ;;
    esac

    if [[ -n "${_STEALTH_UTIL_LOG_FD_FILE}" ]]; then
        printf '%s\n' "${_log_disp_file}" >&"${_STEALTH_UTIL_LOG_FD_FILE}"
    fi

    if (( STEALTH_LOG_CONSOLE == 1 )); then
        printf '%s\n' "${_log_disp_cons}" >&"${_STEALTH_UTIL_LOG_FD_CONSOLE:-2}"
    fi
    return 0
}

#######################################
# Takes the message from the arguments, or from standard input when there are
# none, and hands it to the dispatcher.
#
# Usage:
#   stealth::util::log::_wrapper INFO BLUE 3 "built %s" zlib
#
# Arguments:
#   $1 (String)  - The level label
#   $2 (String)  - The colour key
#   $3 (Integer) - The level
#   --frame (Integer) - The frames to skip, for a helper that logs for its
#                       own caller. Default: 0
#   $@ (String)  - The printf format and its arguments
# Returns:
#   0 - Handed over
#   Exits 1 when there is neither an argument nor input
#######################################
stealth::util::log::_wrapper() {
    local -r _log_wrap_label="${1}"
    local -r _log_wrap_color="${2}"
    local -ri _log_wrap_level="${3}"
    shift 3

    local -i _log_wrap_skip=0
    if [[ "${1:-}" == "--frame" ]] && (( $# >= 2 )); then
        _log_wrap_skip="${2}"
        shift 2
    fi

    local _log_wrap_msg=""

    if (( $# == 0 )); then
        # Reading a terminal would wait for a person, so only a pipe or a file
        # is read. Either way an empty message is a caller that has a bug.
        if [[ ! -t 0 ]]; then
            IFS= read -r -d '' _log_wrap_msg || true
            _log_wrap_msg="${_log_wrap_msg%$'\n'}"
        fi

        if [[ -z "${_log_wrap_msg}" ]]; then
            printf 'log: %s called with no message\n' "${_log_wrap_label}" >&2
            exit 1
        fi
    else
        # shellcheck disable=SC2059  # the format is this library's, never data
        printf -v _log_wrap_msg -- "$@"
    fi

    stealth::util::log::_dispatch "${_log_wrap_label}" "${_log_wrap_color}" \
        "${_log_wrap_level}" "${_log_wrap_msg}" "${_log_wrap_skip}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Prepares the logger: the level as a number, the colours, and the two sinks.
# It is idempotent, and logging works before it is called, on stderr.
#
# Usage:
#   stealth::util::log::init
#
# Arguments:
#   None
# Globals:
#   STEALTH_LOG_LEVEL (Read/Write)
#   STEALTH_LOG_FD_CONSOLE (Read)
#   STEALTH_LOG_FD_FILE (Read)
#   _STEALTH_UTIL_LOG_FD_CONSOLE (Write)
#   _STEALTH_UTIL_LOG_FD_FILE (Write)
#   _STEALTH_UTIL_LOG_READY (Write)
# Returns:
#   0 - Ready
#   1 - A configured file descriptor is not usable
#######################################
stealth::util::log::init() {
    if (( _STEALTH_UTIL_LOG_READY == 1 )); then
        return 0
    fi

    if [[ ! "${STEALTH_LOG_LEVEL}" =~ ^[0-9]+$ ]]; then
        local -r _log_init_name="STEALTH_LOG_LEVEL_${STEALTH_LOG_LEVEL^^}"
        if [[ -n "${!_log_init_name:-}" ]]; then
            STEALTH_LOG_LEVEL="${!_log_init_name}"
        else
            printf 'log: unknown level %s, using INFO\n' "${STEALTH_LOG_LEVEL}" >&2
            STEALTH_LOG_LEVEL="${STEALTH_LOG_LEVEL_INFO}"
        fi
    fi

    stealth::util::log::_resolve_colors

    if [[ -n "${STEALTH_LOG_FD_CONSOLE}" ]]; then
        stealth::util::log::_bind_fd _STEALTH_UTIL_LOG_FD_CONSOLE \
            "${STEALTH_LOG_FD_CONSOLE}" "STEALTH_LOG_FD_CONSOLE" || return 1
    else
        exec {_STEALTH_UTIL_LOG_FD_CONSOLE}>&2
    fi

    if [[ -n "${STEALTH_LOG_FD_FILE}" ]]; then
        stealth::util::log::_bind_fd _STEALTH_UTIL_LOG_FD_FILE \
            "${STEALTH_LOG_FD_FILE}" "STEALTH_LOG_FD_FILE" || return 1
    fi

    _STEALTH_UTIL_LOG_READY=1
    return 0
}

#######################################
# Reports whether a level would be written. Use it to skip building a message
# that costs something.
#
# Usage:
#   if stealth::util::log::is_enabled "${STEALTH_LOG_LEVEL_TRACE}"; then ...
#
# Arguments:
#   $1 (Integer) - The level
# Globals:
#   STEALTH_LOG_LEVEL (Read)
# Returns:
#   0 - Written
#   1 - Below the level, logging is off, or the level is not a number
#######################################
stealth::util::log::is_enabled() {
    if [[ ! "${1:-}" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    local -ri _log_en_level="${1}"

    (( STEALTH_LOG_LEVEL > STEALTH_LOG_LEVEL_OFF )) && (( _log_en_level <= STEALTH_LOG_LEVEL ))
}

#######################################
# Logs at ERROR and ends the process. Every fatal path of the library ends
# here, so a caller of a function that asserts does not check a status.
#
# Usage:
#   stealth::util::log::error "no module %s" "${name}"
#   stealth::util::log::error -c 127 "command not found: %s" "${cmd}"
#
# Arguments:
#   -c, --code (Integer) - The exit status. Default: 1
#   $@ (String)          - The printf format and its arguments
# Outputs:
#   The entry, to the sinks
# Returns:
#   Exits with the status
#######################################
stealth::util::log::error() {
    local -i _log_err_code=1

    if [[ "${1:-}" == "-c" || "${1:-}" == "--code" ]]; then
        if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
            _log_err_code="${2}"
            shift 2
        else
            shift
        fi
    fi

    stealth::util::log::_wrapper "ERROR" "RED" "${STEALTH_LOG_LEVEL_ERROR}" "$@"
    exit "${_log_err_code}"
}

#######################################
# Logs at WARN.
#
# Usage:
#   stealth::util::log::warn 'no signature for %s' "${name}"
#
# Arguments:
#   $@ (String) - The printf format and its arguments
# Outputs:
#   The entry, to the sinks
# Returns:
#   0 - Logged
#######################################
stealth::util::log::warn() {
    stealth::util::log::_wrapper "WARN" "YELLOW" "${STEALTH_LOG_LEVEL_WARN}" "$@"
}

#######################################
# Logs at INFO.
#
# Usage:
#   stealth::util::log::info 'built %s' "${name}"
#
# Arguments:
#   $@ (String) - The printf format and its arguments
# Outputs:
#   The entry, to the sinks
# Returns:
#   0 - Logged
#######################################
stealth::util::log::info() {
    stealth::util::log::_wrapper "INFO" "BLUE" "${STEALTH_LOG_LEVEL_INFO}" "$@"
}

#######################################
# Logs at DEBUG.
#
# Usage:
#   stealth::util::log::debug 'resolved %s' "${name}"
#
# Arguments:
#   $@ (String) - The printf format and its arguments
# Outputs:
#   The entry, to the sinks
# Returns:
#   0 - Logged
#######################################
stealth::util::log::debug() {
    stealth::util::log::_wrapper "DEBUG" "CYAN" "${STEALTH_LOG_LEVEL_DEBUG}" "$@"
}

#######################################
# Logs at TRACE.
#
# Usage:
#   stealth::util::log::trace 'entering %s' "${name}"
#
# Arguments:
#   $@ (String) - The printf format and its arguments
# Outputs:
#   The entry, to the sinks
# Returns:
#   0 - Logged
#######################################
stealth::util::log::trace() {
    stealth::util::log::_wrapper "TRACE" "GRAY" "${STEALTH_LOG_LEVEL_TRACE}" "$@"
}
