###############################################################################
# module: sys/cmd
# layer: sys
# description: Running a command. Five ways to do it, by what should happen to
#              the output and to a failure.
#
#              | Function | Output          | A command that fails      |
#              | -------- | --------------- | ------------------------- |
#              | run      | Held, then logged | Ends the run            |
#              | try      | Held, then logged | Gives the status back   |
#              | capture  | Into a variable | Gives the status back     |
#              | stream   | To the console  | Gives the status back     |
#              | silent   | Thrown away     | Gives the status back     |
#
#              This module imports util and nothing else, so sys/io can import
#              it without a cycle. It therefore keeps its own output buffers
#              rather than going through sys/io/tmp.
#
#              A buffer is made inside one directory per process, made by
#              mktemp and readable by nobody else. The old module built a
#              guessable path in the shared temporary directory and opened it
#              with a plain redirect, which follows a symlink: anyone could
#              put one there and take the output of a build running as root.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_CMD:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_CMD=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# How many lines of a command's output reach the log. A build tool that fails
# after ten thousand lines is read at its beginning and at its end.
declare -gri _STEALTH_SYS_CMD_LOG_LINES=20

# What a run reports when a command took longer than it was given.
declare -gri _STEALTH_SYS_CMD_TIMED_OUT=124

# A status above this is the shell reporting a signal, as 128 plus its number.
declare -gri _STEALTH_SYS_CMD_SIGNALLED=128

# =============================================================================
# CONFIGURATION
# =============================================================================

# Log what would run instead of running it. core/engine copies the dry_run
# setting here, because sys may not read the registry.
declare -gi STEALTH_DRY_RUN="${STEALTH_DRY_RUN:-0}"

# =============================================================================
# STATE
# =============================================================================

# The directory this process keeps its output buffers in.
declare -g _STEALTH_SYS_CMD_BUFFER_DIR=""

# How many buffers have been named, so the next name is not one in use.
declare -gi _STEALTH_SYS_CMD_BUFFER_N=0

# Command name -> 0 when it is on the path, 1 when it is not.
declare -gA _STEALTH_SYS_CMD_FOUND=()

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Makes the directory this process keeps its buffers in, the first time one is
# asked for. It is private to the user, so what a command writes cannot be
# read by anyone else on the machine.
#
# Usage:
#   stealth::sys::cmd::_buffer_dir
#
# Arguments:
#   None
# Globals:
#   _STEALTH_SYS_CMD_BUFFER_DIR (Read/Write)
#   TMPDIR (Read)
# Returns:
#   0 - Ready
#   Exits 1 when no directory can be made
#######################################
stealth::sys::cmd::_buffer_dir() {
    if [[ -n "${_STEALTH_SYS_CMD_BUFFER_DIR}" ]]; then
        return 0
    fi

    local _cmd_dir_made
    if ! _cmd_dir_made="$(mktemp -d -t 'stealth-cmd.XXXXXXXX')"; then
        stealth::util::log::error 'no directory could be made to hold command output'
    fi

    _STEALTH_SYS_CMD_BUFFER_DIR="${_cmd_dir_made}"
    return 0
}

#######################################
# Names a buffer for one command. Nothing else can put a file in the buffer
# directory, so a name in it only has to be different from the other names
# this process is using. A counter gives that, and a process of its own is
# what tells a subshell's buffers from its parent's.
#
# Usage:
#   stealth::sys::cmd::_open_buffer path
#
# Arguments:
#   $1 (Nameref) - The output variable for the path
# Globals:
#   _STEALTH_SYS_CMD_BUFFER_DIR (Read)
#   _STEALTH_SYS_CMD_BUFFER_N (Read/Write)
#   BASHPID (Read)
# Returns:
#   0 - Named
#######################################
stealth::sys::cmd::_open_buffer() {
    local -n _cmd_open_out="${1}"
    stealth::sys::cmd::_buffer_dir

    _STEALTH_SYS_CMD_BUFFER_N=$(( _STEALTH_SYS_CMD_BUFFER_N + 1 ))
    _cmd_open_out="${_STEALTH_SYS_CMD_BUFFER_DIR}/${BASHPID}-${_STEALTH_SYS_CMD_BUFFER_N}"
    return 0
}

#######################################
# Names the signal a status stands for, where the shell reports one as 128
# plus its number.
#
# Usage:
#   stealth::sys::cmd::_signal_name name 9
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The number of the signal
# Returns:
#   0 - Named
#######################################
stealth::sys::cmd::_signal_name() {
    local -n _cmd_sig_out="${1}"

    case "${2}" in
        1)  _cmd_sig_out='SIGHUP' ;;
        2)  _cmd_sig_out='SIGINT' ;;
        3)  _cmd_sig_out='SIGQUIT' ;;
        6)  _cmd_sig_out='SIGABRT' ;;
        9)  _cmd_sig_out='SIGKILL' ;;
        11) _cmd_sig_out='SIGSEGV' ;;
        13) _cmd_sig_out='SIGPIPE' ;;
        15) _cmd_sig_out='SIGTERM' ;;
        *)  _cmd_sig_out="signal ${2}" ;;
    esac
    return 0
}

#######################################
# Writes a buffer to the log at a level, with the middle left out when there
# is more of it than a person will read.
#
# Usage:
#   stealth::sys::cmd::_log_buffer warn "${buffer}" 'what it printed'
#
# Arguments:
#   $1 (String) - The level: warn, debug or trace
#   $2 (String) - The buffer
#   $3 (String) - What to call it
# Globals:
#   _STEALTH_SYS_CMD_LOG_LINES (Read)
# Outputs:
#   The buffer, to the sinks of util/log
# Returns:
#   0 - Written, or the buffer held nothing
#######################################
stealth::sys::cmd::_log_buffer() {
    if [[ ! -s "${2}" ]]; then
        return 0
    fi

    local -a _cmd_log_lines=()
    mapfile -t _cmd_log_lines < "${2}"

    local -ri _cmd_log_count="${#_cmd_log_lines[@]}"
    local _cmd_log_body
    local IFS=$'\n'

    if (( _cmd_log_count > _STEALTH_SYS_CMD_LOG_LINES )); then
        local -ri _cmd_log_half=$(( _STEALTH_SYS_CMD_LOG_LINES / 2 ))
        local -ri _cmd_log_from=$(( _cmd_log_count - _cmd_log_half ))
        _cmd_log_body="${_cmd_log_lines[*]:0:_cmd_log_half}
... ${_cmd_log_count} lines, ${_cmd_log_half} shown at each end ...
${_cmd_log_lines[*]:_cmd_log_from:_cmd_log_half}"
    else
        _cmd_log_body="${_cmd_log_lines[*]}"
    fi

    "stealth::util::log::${1}" '%s:\n%s' "${3}" "${_cmd_log_body}"
    return 0
}

#######################################
# Says what a command that failed did, at the level the caller asked for.
#
# Usage:
#   stealth::sys::cmd::_report_failure warn 2 "${buffer}" podman build
#
# Arguments:
#   $1 (String)  - The level: warn or debug
#   $2 (Integer) - The status it ended with
#   $3 (String)  - The buffer holding its output
#   $@ (String)  - The command and its arguments
# Globals:
#   _STEALTH_SYS_CMD_SIGNALLED (Read)
# Outputs:
#   What happened, to the sinks of util/log
# Returns:
#   0 - Said
#######################################
stealth::sys::cmd::_report_failure() {
    local -r _cmd_rep_level="${1}"
    local -ri _cmd_rep_status="${2}"
    local -r _cmd_rep_buffer="${3}"
    shift 3

    if (( _cmd_rep_status > _STEALTH_SYS_CMD_SIGNALLED )); then
        local _cmd_rep_signal
        stealth::sys::cmd::_signal_name _cmd_rep_signal \
            "$(( _cmd_rep_status - _STEALTH_SYS_CMD_SIGNALLED ))"
        "stealth::util::log::${_cmd_rep_level}" '%s was stopped by %s' \
            "${1}" "${_cmd_rep_signal}"
    else
        "stealth::util::log::${_cmd_rep_level}" '%s failed with status %d' \
            "${1}" "${_cmd_rep_status}"
    fi

    stealth::sys::cmd::_log_buffer "${_cmd_rep_level}" "${_cmd_rep_buffer}" \
        'what it printed'
    return 0
}

#######################################
# Reports whether this run is only saying what it would do.
#
# Usage:
#   if stealth::sys::cmd::_is_dry_run podman build; then return 0; fi
#
# Arguments:
#   $@ (String) - The command, for the line it logs
# Globals:
#   STEALTH_DRY_RUN (Read)
# Outputs:
#   The command it did not run, to the sinks of util/log
# Returns:
#   0 - Nothing was run
#   1 - The caller should run it
#######################################
stealth::sys::cmd::_is_dry_run() {
    if (( STEALTH_DRY_RUN != 1 )); then
        return 1
    fi

    stealth::util::log::info 'would run: %s' "$*"
    return 0
}

#######################################
# Runs a command with its output held in a buffer, and says what happened when
# it fails.
#
# Usage:
#   stealth::sys::cmd::_buffered warn podman build .
#
# Arguments:
#   $1 (String) - The level to report a failure at: warn or debug
#   $@ (String) - The command and its arguments
# Outputs:
#   What it printed, to the sinks of util/log, when it fails or at TRACE
# Returns:
#   0 - It succeeded
#   The status it ended with
#######################################
stealth::sys::cmd::_buffered() {
    local -r _cmd_buf_level="${1}"
    shift

    local _cmd_buf_file
    stealth::sys::cmd::_open_buffer _cmd_buf_file

    local -i _cmd_buf_status=0
    "$@" > "${_cmd_buf_file}" 2>&1 || _cmd_buf_status=$?

    if (( _cmd_buf_status != 0 )); then
        stealth::sys::cmd::_report_failure "${_cmd_buf_level}" \
            "${_cmd_buf_status}" "${_cmd_buf_file}" "$@"
    else
        stealth::sys::cmd::_log_buffer trace "${_cmd_buf_file}" \
            "what ${1} printed"
    fi

    rm -f -- "${_cmd_buf_file}"
    return "${_cmd_buf_status}"
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Runs a command and ends the run when it fails. Its output is held, and
# written to the log only when something goes wrong.
#
# Use it for the steps a run cannot go on without. A caller with somewhere
# else to go uses try.
#
# Usage:
#   stealth::sys::cmd::run tar -xf "${archive}" -C "${root}"
#
# Arguments:
#   $@ (String) - The command and its arguments
# Outputs:
#   What it printed, to the sinks of util/log, when it fails
# Returns:
#   0 - It succeeded, or the run is a dry run
#   Exits with the status of the command when it fails
#######################################
stealth::sys::cmd::run() {
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    if stealth::sys::cmd::_is_dry_run "$@"; then
        return 0
    fi

    stealth::util::log::debug 'running %s' "$*"

    local -i _cmd_run_status=0
    stealth::sys::cmd::_buffered warn "$@" || _cmd_run_status=$?

    if (( _cmd_run_status != 0 )); then
        stealth::util::log::error -c "${_cmd_run_status}" \
            'the run cannot go on without %s' "${1}"
    fi
    return 0
}

#######################################
# Runs a command and gives its status back, whatever it is. Its output is
# held, and written to the log at DEBUG when it fails, because a failure here
# is one the caller expects to handle.
#
# Usage:
#   if ! stealth::sys::cmd::try rpm -q "${package}"; then ...
#
# Arguments:
#   $@ (String) - The command and its arguments
# Outputs:
#   What it printed, to the sinks of util/log, when it fails
# Returns:
#   0 - It succeeded, or the run is a dry run
#   The status of the command
#######################################
stealth::sys::cmd::try() {
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    if stealth::sys::cmd::_is_dry_run "$@"; then
        return 0
    fi

    stealth::util::log::debug 'trying %s' "$*"
    stealth::sys::cmd::_buffered debug "$@"
}

#######################################
# Runs a command and puts what it wrote on standard output into a variable,
# with the trailing line breaks taken off. What it wrote on standard error
# reaches the log at DEBUG when it fails.
#
# DEBUG rather than WARN, for the same reason try uses it: a caller that
# takes the status back is a caller that expects to handle a failure. Asking
# git for a setting that is not there, or a resolver for a name that does not
# resolve, is an answer and not a fault. A caller that cannot carry on
# without the command wants run.
#
# Usage:
#   stealth::sys::cmd::capture digest podman inspect --format '{{.Id}}' "${image}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - The command and its arguments
# Outputs:
#   What it wrote on standard error, to the sinks of util/log at DEBUG, when
#   it fails
# Returns:
#   0 - It succeeded, or the run is a dry run
#   The status of the command
#   Exits 1 when no output variable or no command is given
#######################################
stealth::sys::cmd::capture() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _cmd_cap_out="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    if stealth::sys::cmd::_is_dry_run "$@"; then
        _cmd_cap_out=''
        return 0
    fi

    stealth::util::log::debug 'capturing %s' "$*"

    local _cmd_cap_out_file _cmd_cap_err_file
    stealth::sys::cmd::_open_buffer _cmd_cap_out_file
    stealth::sys::cmd::_open_buffer _cmd_cap_err_file

    local -i _cmd_cap_status=0
    "$@" > "${_cmd_cap_out_file}" 2> "${_cmd_cap_err_file}" || _cmd_cap_status=$?

    _cmd_cap_out="$(< "${_cmd_cap_out_file}")"

    if (( _cmd_cap_status != 0 )); then
        stealth::sys::cmd::_report_failure debug "${_cmd_cap_status}" \
            "${_cmd_cap_err_file}" "$@"
    fi

    rm -f -- "${_cmd_cap_out_file}" "${_cmd_cap_err_file}"
    return "${_cmd_cap_status}"
}

#######################################
# Runs a command with its output going to the console, for the ones a person
# watches. It is the one way out of the silence a run otherwise keeps.
#
# Usage:
#   stealth::sys::cmd::stream make -j"${jobs}"
#
# Arguments:
#   $@ (String) - The command and its arguments
# Globals:
#   _STEALTH_UTIL_LOG_FD_CONSOLE (Read)
# Outputs:
#   Everything the command writes, to the console sink
# Returns:
#   0 - It succeeded, or the run is a dry run
#   The status of the command
#######################################
stealth::sys::cmd::stream() {
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    if stealth::sys::cmd::_is_dry_run "$@"; then
        return 0
    fi

    stealth::util::log::debug 'streaming %s' "$*"
    "$@" >&"${_STEALTH_UTIL_LOG_FD_CONSOLE:-2}" 2>&1
}

#######################################
# Runs a command, throws its output away and gives its status back. Use it for
# a command asked as a question, where only the answer matters.
#
# A caller that wants the output tests it with capture. Reading from this
# function through a pipe gets nothing, because there is nothing to read.
#
# Usage:
#   if stealth::sys::cmd::silent systemctl is-active "${unit}"; then ...
#
# Arguments:
#   $@ (String) - The command and its arguments
# Returns:
#   0 - It succeeded, or the run is a dry run
#   The status of the command
#######################################
stealth::sys::cmd::silent() {
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    if stealth::sys::cmd::_is_dry_run "$@"; then
        return 0
    fi

    stealth::util::log::trace 'asking %s' "$*"
    "$@" >/dev/null 2>&1
}

#######################################
# Runs a command and stops it when it has taken too long. A command that was
# stopped reports 124, the status timeout itself uses, rather than ending the
# run. The old module went through run, which exits, so a caller could never
# tell a timeout from anything else.
#
# Usage:
#   if ! stealth::sys::cmd::timeout 30s curl -fsS "${url}"; then ...
#
# Arguments:
#   $1 (String) - How long to allow, as timeout reads it
#   $@ (String) - The command and its arguments
# Globals:
#   _STEALTH_SYS_CMD_TIMED_OUT (Read)
# Returns:
#   0 - It succeeded, or the run is a dry run
#   124 - It was stopped
#   The status of the command otherwise
#   Exits 1 when no duration or no command is given
#######################################
stealth::sys::cmd::timeout() {
    stealth::util::assert::not_empty "${1:-}" 'a duration is required'
    local -r _cmd_to_duration="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    local -i _cmd_to_status=0
    stealth::sys::cmd::try timeout "${_cmd_to_duration}" "$@" || _cmd_to_status=$?

    if (( _cmd_to_status == _STEALTH_SYS_CMD_TIMED_OUT )); then
        stealth::util::log::warn '%s did not finish within %s' \
            "${1}" "${_cmd_to_duration}"
    fi
    return "${_cmd_to_status}"
}

#######################################
# Reports whether a command is on the path, and remembers the answer.
#
# It looks for a file on the path. A shell function or a builtin of the same
# name does not count, because a caller asking this wants to know whether the
# program is installed.
#
# Usage:
#   if ! stealth::sys::cmd::exists crane; then ...
#
# Arguments:
#   $1 (String) - The name of the command
# Globals:
#   _STEALTH_SYS_CMD_FOUND (Read/Write)
# Returns:
#   0 - It is on the path
#   1 - It is not
#   Exits 1 when no name is given
#######################################
stealth::sys::cmd::exists() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a command is required'

    if [[ -v _STEALTH_SYS_CMD_FOUND["${1}"] ]]; then
        return "${_STEALTH_SYS_CMD_FOUND[${1}]}"
    fi

    if type -P "${1}" >/dev/null 2>&1; then
        _STEALTH_SYS_CMD_FOUND["${1}"]=0
        return 0
    fi

    _STEALTH_SYS_CMD_FOUND["${1}"]=1
    return 1
}

#######################################
# Removes the directory this process kept its output buffers in. core/engine
# registers it for the end of the run, by the name of this function.
#
# Usage:
#   stealth::sys::cmd::cleanup
#
# Arguments:
#   None
# Globals:
#   _STEALTH_SYS_CMD_BUFFER_DIR (Read/Write)
# Returns:
#   0 - Removed, or there was nothing to remove
#######################################
stealth::sys::cmd::cleanup() {
    if [[ -z "${_STEALTH_SYS_CMD_BUFFER_DIR}" ]]; then
        return 0
    fi

    rm -rf -- "${_STEALTH_SYS_CMD_BUFFER_DIR}"
    _STEALTH_SYS_CMD_BUFFER_DIR=''
    return 0
}
