###############################################################################
# module: core/trap
# layer: core
# description: What happens when a run ends, however it ends: the handlers a
#              run registered, in the reverse of the order it registered them,
#              then the terminal put back the way it was found.
#
#              A handler is a function name and its arguments, not a string to
#              evaluate. The old module ran `eval` on whatever it was given,
#              so a path with a space in it became two arguments and a path
#              with a semicolon in it became a second command.
#
#              This module knows nothing about temporary files. Whatever
#              creates them registers its own cleanup. The old module deferred
#              the temporary-file cleanup itself, and that cleanup deleted the
#              flight recorder before the exit handler could print it, so a
#              failed run showed nothing.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_CORE_TRAP:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_CORE_TRAP=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a run exits with after a signal, by the convention of 128 plus the
# number of the signal.
declare -gri _STEALTH_CORE_TRAP_INTERRUPTED=130
declare -gri _STEALTH_CORE_TRAP_TERMINATED=143

# Separates a handler from its arguments in the stack. A unit separator cannot
# appear in a path or an argument that a shell would pass.
declare -gr _STEALTH_CORE_TRAP_UNIT=$'\037'

# =============================================================================
# STATE
# =============================================================================

declare -gi _STEALTH_CORE_TRAP_READY=0

# The handlers, in the order they were registered. They run in reverse.
declare -ga _STEALTH_CORE_TRAP_STACK=()

# Set once the run knows why it is ending, so the exit handler does not report
# a status that something else has already explained.
declare -gi _STEALTH_CORE_TRAP_REPORTED=0

# What a caller asked to happen once the handlers have run and before the
# process leaves. core/engine puts the flight recorder here.
declare -g _STEALTH_CORE_TRAP_LAST=""

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reports whether standard error is a terminal. It is a function of its own so
# that a test can answer for it; a test has no terminal.
#
# Usage:
#   if stealth::core::trap::_is_terminal; then ...
#
# Arguments:
#   None
# Returns:
#   0 - A terminal
#   1 - A file, a pipe or anything else
#######################################
stealth::core::trap::_is_terminal() {
    [[ -t 2 ]]
}

#######################################
# Puts the terminal back: the cursor visible and the colours off. A run that
# ends while a spinner or a colour is on would otherwise leave the shell it
# came from in that state.
#
# Usage:
#   stealth::core::trap::_reset_terminal
#
# Arguments:
#   None
# Outputs:
#   The sequences, to stderr, and nothing when stderr is not a terminal
# Returns:
#   0 - Done
#######################################
stealth::core::trap::_reset_terminal() {
    if stealth::core::trap::_is_terminal; then
        printf '\033[?25h\033[0m' >&2
    fi
    return 0
}

#######################################
# Runs one handler off the stack. A handler that fails is reported and the
# rest still run, because a run that is ending has to finish unwinding.
#
# Usage:
#   stealth::core::trap::_run_handler "${entry}"
#
# Arguments:
#   $1 (String) - The handler and its arguments, separated by the unit
#                 character
# Globals:
#   _STEALTH_CORE_TRAP_UNIT (Read)
# Returns:
#   0 - Ran, whether or not the handler itself succeeded
#######################################
stealth::core::trap::_run_handler() {
    local -a _trap_run_parts=()
    local _trap_run_rest="${1}"

    while [[ "${_trap_run_rest}" == *"${_STEALTH_CORE_TRAP_UNIT}"* ]]; do
        _trap_run_parts+=("${_trap_run_rest%%"${_STEALTH_CORE_TRAP_UNIT}"*}")
        _trap_run_rest="${_trap_run_rest#*"${_STEALTH_CORE_TRAP_UNIT}"}"
    done
    _trap_run_parts+=("${_trap_run_rest}")

    if ! declare -F "${_trap_run_parts[0]}" >/dev/null 2>&1; then
        stealth::util::log::warn 'no handler named %s to run at the end' \
            "${_trap_run_parts[0]}"
        return 0
    fi

    stealth::util::log::trace 'running handler %s' "${_trap_run_parts[0]}"
    if ! "${_trap_run_parts[@]}"; then
        stealth::util::log::warn 'the handler %s failed while the run was ending' \
            "${_trap_run_parts[0]}"
    fi
    return 0
}

#######################################
# The handler for the end of the process. It turns the traps off first, so a
# failure inside it cannot bring it back round, then runs the stack in
# reverse, then hands over to whatever was set as the last thing to do.
#
# Usage:
#   Registered by stealth::core::trap::init
#
# Arguments:
#   None. The status of the run is read from $?
# Globals:
#   _STEALTH_CORE_TRAP_STACK (Read)
#   _STEALTH_CORE_TRAP_LAST (Read)
#   _STEALTH_CORE_TRAP_REPORTED (Read)
# Outputs:
#   A line per handler at TRACE, and the status at WARN when nothing has
#   explained it
# Returns:
#   0 - Done. The shell exits with the status it already had
#######################################
stealth::core::trap::_on_exit() {
    local -ri _trap_exit_status=$?

    stealth::core::trap::disable

    local -i _trap_exit_i
    for (( _trap_exit_i = ${#_STEALTH_CORE_TRAP_STACK[@]} - 1; _trap_exit_i >= 0; _trap_exit_i-- )); do
        stealth::core::trap::_run_handler "${_STEALTH_CORE_TRAP_STACK[_trap_exit_i]}"
    done
    _STEALTH_CORE_TRAP_STACK=()

    if (( _trap_exit_status != 0 && _STEALTH_CORE_TRAP_REPORTED == 0 )); then
        stealth::util::log::warn 'the run ended with status %d' "${_trap_exit_status}"
    fi

    if [[ -n "${_STEALTH_CORE_TRAP_LAST}" ]]; then
        stealth::core::trap::_run_handler \
            "${_STEALTH_CORE_TRAP_LAST}${_STEALTH_CORE_TRAP_UNIT}${_trap_exit_status}"
    fi

    stealth::core::trap::_reset_terminal
    return 0
}

#######################################
# The handler for a command that failed where nothing was checking. It says
# where, and then ends the run with the status the command gave.
#
# Usage:
#   Registered by stealth::core::trap::init
#
# Arguments:
#   $1 (Integer) - The status of the command
#   $2 (Integer) - The line it was on
#   $3 (String)  - The command
#   $4 (String)  - The file it was in
# Globals:
#   _STEALTH_CORE_TRAP_REPORTED (Write)
# Outputs:
#   Where it happened and the call stack, to the sinks of util/log
# Returns:
#   Exits with the status of the command
#######################################
stealth::core::trap::_on_err() {
    trap - ERR
    _STEALTH_CORE_TRAP_REPORTED=1

    local -ri _trap_err_status="${1:-1}"

    stealth::util::log::warn '%s failed with status %d at %s line %s' \
        "${3:-a command}" "${_trap_err_status}" "${4:-an unknown file}" "${2:-0}"
    stealth::core::trap::print_stack

    stealth::util::log::error -c "${_trap_err_status}" \
        'the run stopped at a command that failed'
}

#######################################
# The handler for a signal. It says which signal, and ends the run with the
# status that signal conventionally gives.
#
# Usage:
#   Registered by stealth::core::trap::init
#
# Arguments:
#   $1 (String)  - The name of the signal
#   $2 (Integer) - The status to end with
# Globals:
#   _STEALTH_CORE_TRAP_REPORTED (Write)
# Outputs:
#   The signal, to the sinks of util/log
# Returns:
#   Exits with the status given
#######################################
stealth::core::trap::_on_signal() {
    trap - INT TERM
    _STEALTH_CORE_TRAP_REPORTED=1

    stealth::util::log::error -c "${2}" 'the run was stopped by %s' "${1}"
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Takes over the four things that end a run: a command that failed, the end of
# the process, an interrupt and a termination. It is idempotent.
#
# Usage:
#   stealth::core::trap::init
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_TRAP_READY (Read/Write)
# Returns:
#   0 - Ready
#######################################
stealth::core::trap::init() {
    if (( _STEALTH_CORE_TRAP_READY == 1 )); then
        return 0
    fi

    trap 'stealth::core::trap::_on_err "$?" "${LINENO}" "${BASH_COMMAND:-}" "${BASH_SOURCE[0]:-}"' ERR
    trap 'stealth::core::trap::_on_exit' EXIT
    trap 'stealth::core::trap::_on_signal SIGINT "${_STEALTH_CORE_TRAP_INTERRUPTED}"' INT
    trap 'stealth::core::trap::_on_signal SIGTERM "${_STEALTH_CORE_TRAP_TERMINATED}"' TERM

    _STEALTH_CORE_TRAP_READY=1
    stealth::util::log::trace 'traps are in place'
    return 0
}

#######################################
# Gives the four back to the shell. A subshell that wants the parent to do the
# reporting calls this first.
#
# Usage:
#   stealth::core::trap::disable
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_TRAP_READY (Write)
# Returns:
#   0 - Given back
#######################################
stealth::core::trap::disable() {
    trap - ERR EXIT INT TERM
    _STEALTH_CORE_TRAP_READY=0
    return 0
}

#######################################
# Registers a function to run when the run ends, whatever ends it. The
# handlers run in the reverse of the order they were registered, so a caller
# that takes two steps undoes them in the right order.
#
# The handler is a function name and its arguments. Nothing is evaluated, so
# an argument with a space or a semicolon in it stays one argument.
#
# Usage:
#   stealth::core::trap::defer stealth::sys::io::tmp::cleanup
#   stealth::core::trap::defer umount_quietly "${mountpoint}"
#
# Arguments:
#   $1 (String) - The name of a function
#   $@ (String) - Its arguments
# Globals:
#   _STEALTH_CORE_TRAP_STACK (Write)
#   _STEALTH_CORE_TRAP_UNIT (Read)
# Returns:
#   0 - Registered
#   Exits 1 when no function is named
#######################################
stealth::core::trap::defer() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a function is required'

    local _trap_defer_entry="${1}"
    shift

    local _trap_defer_arg
    for _trap_defer_arg in "$@"; do
        _trap_defer_entry+="${_STEALTH_CORE_TRAP_UNIT}${_trap_defer_arg}"
    done

    _STEALTH_CORE_TRAP_STACK+=("${_trap_defer_entry}")
    return 0
}

#######################################
# Sets the one thing that runs after every handler, with the status of the run
# as its last argument. core/engine uses it for the flight recorder, which has
# to outlive everything that might delete the file it is kept in.
#
# Usage:
#   stealth::core::trap::finally stealth::core::engine::_report
#
# Arguments:
#   $1 (String) - The name of a function
#   $@ (String) - Its arguments, before the status
# Globals:
#   _STEALTH_CORE_TRAP_LAST (Write)
#   _STEALTH_CORE_TRAP_UNIT (Read)
# Returns:
#   0 - Set
#   Exits 1 when no function is named
#######################################
stealth::core::trap::finally() {
    stealth::util::assert::not_empty "${1:-}" 'the name of a function is required'

    local _trap_finally_entry="${1}"
    shift

    local _trap_finally_arg
    for _trap_finally_arg in "$@"; do
        _trap_finally_entry+="${_STEALTH_CORE_TRAP_UNIT}${_trap_finally_arg}"
    done

    _STEALTH_CORE_TRAP_LAST="${_trap_finally_entry}"
    return 0
}

#######################################
# Reports that the reason the run is ending has already been explained, so the
# exit handler does not say it again.
#
# Usage:
#   stealth::core::trap::reported
#
# Arguments:
#   None
# Globals:
#   _STEALTH_CORE_TRAP_REPORTED (Write)
# Returns:
#   0 - Noted
#######################################
stealth::core::trap::reported() {
    _STEALTH_CORE_TRAP_REPORTED=1
    return 0
}

#######################################
# Writes the call stack to the log at DEBUG, innermost frame first. The frames
# of this module are left out, so the first line is the code that asked.
#
# Usage:
#   stealth::core::trap::print_stack
#
# Arguments:
#   None
# Globals:
#   FUNCNAME (Read)
#   BASH_SOURCE (Read)
#   BASH_LINENO (Read)
# Outputs:
#   A line per frame, to the sinks of util/log
# Returns:
#   0 - Written
#######################################
stealth::core::trap::print_stack() {
    local -i _trap_stack_i
    local -i _trap_stack_shown=0

    for (( _trap_stack_i = 1; _trap_stack_i < ${#FUNCNAME[@]}; _trap_stack_i++ )); do
        if [[ "${FUNCNAME[_trap_stack_i]}" == stealth::core::trap::* ]]; then
            continue
        fi
        stealth::util::log::debug '  at %s (%s line %s)' \
            "${FUNCNAME[_trap_stack_i]}" \
            "${BASH_SOURCE[_trap_stack_i]:-an unknown file}" \
            "${BASH_LINENO[_trap_stack_i - 1]:-0}"
        _trap_stack_shown=$(( _trap_stack_shown + 1 ))
    done

    if (( _trap_stack_shown == 0 )); then
        stealth::util::log::debug '  at the top level'
    fi
    return 0
}
