###############################################################################
# module: sys/runtime/proc
# layer: sys
# description: Finding processes, signalling them, and waiting for them to go.
#
#              Whether a process exists is answered from /proc and not with
#              kill -0. kill -0 fails with a permission error for a process
#              belonging to somebody else, and a caller reading that status
#              cannot tell it apart from no such process. A directory under
#              /proc is there for every process on the machine, whoever owns
#              it, and reading it costs no fork.
#
#              stop is the one to reach for. It asks a process to go, waits
#              for it, and only then insists. Sending SIGKILL first leaves
#              whatever the process was writing half written, and sending
#              SIGTERM without waiting leaves the caller believing the work is
#              finished while it is still going on.
#
#              A pid file is read with the program it should belong to, when
#              the caller knows it. Process numbers are handed out again, and
#              a pid file left behind by a crash eventually names a process
#              that has nothing to do with it.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_PROC:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_PROC=1

stealth::util::import "util/assert" "util/log" "util/retry" "util/text"
stealth::util::import "sys/cmd" "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where the kernel says what is running. A test points this somewhere else.
declare -g STEALTH_PROC_DIR='/proc'

# How long stop waits after asking, before it insists, and how long it gives
# a process to go after SIGKILL before calling it stuck.
declare -gri _STEALTH_SYS_RUNTIME_PROC_WAIT=5
declare -gri _STEALTH_SYS_RUNTIME_PROC_KILL_WAIT=2

# How often a wait looks again. retry takes whole seconds.
declare -gri _STEALTH_SYS_RUNTIME_PROC_INTERVAL=1

# How much of a program's name the kernel keeps in comm. The rest is cut off,
# so a name longer than this is compared by its first characters only.
declare -gri _STEALTH_SYS_RUNTIME_PROC_COMM_MAX=15

# What a process number looks like.
declare -gr _STEALTH_SYS_RUNTIME_PROC_PID_RE='^[0-9]+$'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Runs pgrep and fills an array with the numbers it printed.
#
# Usage:
#   stealth::sys::runtime::proc::_pgrep pids -x 'qemu-system-x86_64'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $@ (String)  - What to pass pgrep
# Returns:
#   0 - It found something
#   1 - It found nothing
#######################################
stealth::sys::runtime::proc::_pgrep() {
    local -n _proc_pgrep_out="${1}"
    shift

    _proc_pgrep_out=()

    local _proc_pgrep_text
    if ! stealth::sys::cmd::capture _proc_pgrep_text pgrep "$@"; then
        return 1
    fi
    if [[ -z "${_proc_pgrep_text}" ]]; then
        return 1
    fi

    mapfile -t _proc_pgrep_out <<< "${_proc_pgrep_text}"
    return 0
}

#######################################
# Turns what the caller named into the process numbers it stands for. A
# number is itself, and anything else is a program name to look up.
#
# Usage:
#   stealth::sys::runtime::proc::_targets pids 'qemu-system-x86_64'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - A process number or a program name
# Returns:
#   0 - There is at least one
#   1 - Nothing is running under that name
#######################################
stealth::sys::runtime::proc::_targets() {
    local -n _proc_tgt_out="${1}"

    if [[ "${2}" =~ ${_STEALTH_SYS_RUNTIME_PROC_PID_RE} ]]; then
        _proc_tgt_out=("${2}")
        return 0
    fi

    stealth::sys::runtime::proc::_pgrep "${1}" -x "${2}"
}

#######################################
# Reports whether a process has gone, which is what a wait waits for.
#
# Usage:
#   stealth::util::retry::until 5 1 stealth::sys::runtime::proc::_is_gone 123
#
# Arguments:
#   $1 (Integer) - The process number
# Returns:
#   0 - It has gone
#   1 - It is still there
#######################################
stealth::sys::runtime::proc::_is_gone() {
    ! stealth::sys::runtime::proc::exists "${1}"
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether a process is there, whoever owns it.
#
# Usage:
#   if stealth::sys::runtime::proc::exists "${pid}"; then ...
#
# Arguments:
#   $1 (Integer) - The process number
# Globals:
#   STEALTH_PROC_DIR (Read)
# Returns:
#   0 - It is there
#   1 - It is not
#   Exits 1 when what was given is not a process number
#######################################
stealth::sys::runtime::proc::exists() {
    stealth::util::assert::match "${1:-}" "${_STEALTH_SYS_RUNTIME_PROC_PID_RE}" \
        "a process number is a whole number, not ${1:-}"

    [[ -d "${STEALTH_PROC_DIR}/${1}" ]]
}

#######################################
# Fills an array with the processes running a program. Without --full the
# name has to be the whole program name, and with it the pattern is matched
# against the command line, which is how a program run through an interpreter
# is found.
#
# Usage:
#   stealth::sys::runtime::proc::find pids 'qemu-system-x86_64'
#   stealth::sys::runtime::proc::find pids "monitor=${socket}" --full
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The name, or the pattern with --full
#   $@ (String)  - --full to match the whole command line
# Returns:
#   0 - It found something
#   1 - It found nothing
#   Exits 1 when no output array or no name is given
#######################################
stealth::sys::runtime::proc::find() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::not_empty "${2:-}" 'a name to look for is required'

    local _proc_find_how='-x'
    if [[ "${3:-}" == '--full' ]]; then
        _proc_find_how='-f'
    fi

    stealth::sys::runtime::proc::_pgrep "${1}" "${_proc_find_how}" "${2}"
}

#######################################
# Fills an array with the processes a process started. Only its own children,
# not their children.
#
# Usage:
#   stealth::sys::runtime::proc::children pids "${pid}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (Integer) - The process number of the parent
# Returns:
#   0 - It has children
#   1 - It has none
#   Exits 1 when no output array is given, or the parent is not a number
#######################################
stealth::sys::runtime::proc::children() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::match "${2:-}" "${_STEALTH_SYS_RUNTIME_PROC_PID_RE}" \
        "a process number is a whole number, not ${2:-}"

    stealth::sys::runtime::proc::_pgrep "${1}" -P "${2}"
}

#######################################
# Says what program a process is running, as the kernel records it. The
# kernel keeps 15 characters and cuts off the rest.
#
# Usage:
#   stealth::sys::runtime::proc::command name "${pid}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The process number
# Globals:
#   STEALTH_PROC_DIR (Read)
# Returns:
#   0 - Said
#   1 - There is no such process
#   Exits 1 when no output variable is given, or the number is not one
#######################################
stealth::sys::runtime::proc::command() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::match "${2:-}" "${_STEALTH_SYS_RUNTIME_PROC_PID_RE}" \
        "a process number is a whole number, not ${2:-}"
    local -n _proc_cmd_out="${1}"

    local -r _proc_cmd_file="${STEALTH_PROC_DIR}/${2}/comm"
    if [[ ! -r "${_proc_cmd_file}" ]]; then
        _proc_cmd_out=''
        return 1
    fi

    stealth::sys::io::fs::read _proc_cmd_out "${_proc_cmd_file}"
    stealth::util::text::trim _proc_cmd_out "${_proc_cmd_out}"
    return 0
}

#######################################
# Reports whether a process is running the program named. A name longer than
# the 15 characters the kernel keeps is compared by those 15, because that is
# all there is to compare against.
#
# Usage:
#   if ! stealth::sys::runtime::proc::is_named "${pid}" 'qemu-system-x86_64'; then ...
#
# Arguments:
#   $1 (Integer) - The process number
#   $2 (String)  - The program name
# Globals:
#   _STEALTH_SYS_RUNTIME_PROC_COMM_MAX (Read)
# Returns:
#   0 - It is
#   1 - It is not, or there is no such process
#   Exits 1 when the number is not one, or no name is given
#######################################
stealth::sys::runtime::proc::is_named() {
    stealth::util::assert::not_empty "${2:-}" 'a program name is required'

    local _proc_named_comm
    if ! stealth::sys::runtime::proc::command _proc_named_comm "${1:-}"; then
        return 1
    fi

    [[ "${_proc_named_comm}" == \
        "${2:0:${_STEALTH_SYS_RUNTIME_PROC_COMM_MAX}}" ]]
}

#######################################
# Sends a signal to whatever the caller named, which may be one process
# number or the name of a program several processes are running.
#
# Usage:
#   stealth::sys::runtime::proc::signal "${pid}"
#   stealth::sys::runtime::proc::signal 'nginx' --signal SIGHUP
#
# Arguments:
#   $1 (String) - A process number or a program name
#   $@ (String) - --signal NAME. Default: SIGTERM
# Returns:
#   0 - Sent to everything that was there
#   1 - Nothing is running under that name
#   Exits 1 when nothing is named, or --signal is given nothing
#######################################
stealth::sys::runtime::proc::signal() {
    stealth::util::assert::not_empty "${1:-}" 'a process number or a name is required'
    local -r _proc_sig_target="${1}"
    shift

    local _proc_sig_name='SIGTERM'
    while (( $# > 0 )); do
        case "${1}" in
            --signal)
                stealth::util::assert::not_empty "${2:-}" '--signal takes a signal'
                _proc_sig_name="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "signal does not take ${1}"
                ;;
        esac
    done

    local -a _proc_sig_pids=()
    if ! stealth::sys::runtime::proc::_targets _proc_sig_pids "${_proc_sig_target}"; then
        stealth::util::log::debug 'nothing is running as %s' "${_proc_sig_target}"
        return 1
    fi

    local _proc_sig_pid
    for _proc_sig_pid in "${_proc_sig_pids[@]}"; do
        if ! stealth::sys::runtime::proc::exists "${_proc_sig_pid}"; then
            continue
        fi
        stealth::util::log::debug 'sending %s to %s' \
            "${_proc_sig_name}" "${_proc_sig_pid}"
        stealth::sys::cmd::try kill -s "${_proc_sig_name}" "${_proc_sig_pid}" || true
    done
    return 0
}

#######################################
# Waits for a process to go, and says whether it did.
#
# Usage:
#   stealth::sys::runtime::proc::wait "${pid}"
#   stealth::sys::runtime::proc::wait "${pid}" --timeout 60
#
# Arguments:
#   $1 (Integer) - The process number
#   $@ (String)  - --timeout SECONDS. Default: 5
# Globals:
#   _STEALTH_SYS_RUNTIME_PROC_WAIT (Read)
#   _STEALTH_SYS_RUNTIME_PROC_INTERVAL (Read)
# Returns:
#   0 - It has gone
#   1 - It is still there
#   Exits 1 when the number is not one, or --timeout is given something that
#   is not a whole number
#######################################
stealth::sys::runtime::proc::wait() {
    stealth::util::assert::match "${1:-}" "${_STEALTH_SYS_RUNTIME_PROC_PID_RE}" \
        "a process number is a whole number, not ${1:-}"
    local -r _proc_wait_pid="${1}"
    shift

    local _proc_wait_limit="${_STEALTH_SYS_RUNTIME_PROC_WAIT}"
    while (( $# > 0 )); do
        case "${1}" in
            --timeout)
                stealth::util::assert::is_int "${2:-}" \
                    "--timeout takes whole seconds, not ${2:-}"
                _proc_wait_limit="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "wait does not take ${1}"
                ;;
        esac
    done

    if stealth::util::retry::until "${_proc_wait_limit}" \
        "${_STEALTH_SYS_RUNTIME_PROC_INTERVAL}" \
        stealth::sys::runtime::proc::_is_gone "${_proc_wait_pid}"; then
        return 0
    fi
    return 1
}

#######################################
# Asks everything the caller named to go, waits for it, and insists on the
# ones that stayed.
#
# A process that was not there to begin with is a success. The caller wanted
# it gone and it is gone.
#
# Usage:
#   stealth::sys::runtime::proc::stop "${pid}"
#   stealth::sys::runtime::proc::stop 'qemu-system-x86_64' --wait 30
#
# Arguments:
#   $1 (String) - A process number or a program name
#   $@ (String) - --wait SECONDS to give it before insisting. Default: 5
# Globals:
#   _STEALTH_SYS_RUNTIME_PROC_WAIT (Read)
#   _STEALTH_SYS_RUNTIME_PROC_KILL_WAIT (Read)
# Returns:
#   0 - Everything named has gone
#   1 - Something survived SIGKILL
#   Exits 1 when nothing is named, or --wait is given something that is not a
#   whole number
#######################################
stealth::sys::runtime::proc::stop() {
    stealth::util::assert::not_empty "${1:-}" 'a process number or a name is required'
    local -r _proc_stop_target="${1}"
    shift

    local _proc_stop_limit="${_STEALTH_SYS_RUNTIME_PROC_WAIT}"
    while (( $# > 0 )); do
        case "${1}" in
            --wait)
                stealth::util::assert::is_int "${2:-}" \
                    "--wait takes whole seconds, not ${2:-}"
                _proc_stop_limit="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "stop does not take ${1}"
                ;;
        esac
    done

    local -a _proc_stop_pids=()
    if ! stealth::sys::runtime::proc::_targets _proc_stop_pids "${_proc_stop_target}"; then
        stealth::util::log::debug 'nothing to stop as %s' "${_proc_stop_target}"
        return 0
    fi

    stealth::sys::runtime::proc::signal "${_proc_stop_target}" --signal SIGTERM || true

    local -a _proc_stop_left=()
    local _proc_stop_pid
    for _proc_stop_pid in "${_proc_stop_pids[@]}"; do
        if ! stealth::sys::runtime::proc::wait "${_proc_stop_pid}" \
            --timeout "${_proc_stop_limit}"; then
            _proc_stop_left+=("${_proc_stop_pid}")
        fi
    done

    if (( ${#_proc_stop_left[@]} == 0 )); then
        return 0
    fi

    stealth::sys::runtime::proc::_insist _proc_stop_left
}

#######################################
# Sends SIGKILL to processes that would not go, and reports the ones that
# still will not. A process that survives SIGKILL is waiting on the kernel
# for something, and nothing this library can send will move it.
#
# Usage:
#   stealth::sys::runtime::proc::_insist left
#
# Arguments:
#   $1 (Nameref) - The array of process numbers
# Globals:
#   _STEALTH_SYS_RUNTIME_PROC_KILL_WAIT (Read)
# Returns:
#   0 - They have all gone
#   1 - Something is still there
#######################################
stealth::sys::runtime::proc::_insist() {
    local -n _proc_insist_pids="${1}"

    local _proc_insist_pid
    for _proc_insist_pid in "${_proc_insist_pids[@]}"; do
        stealth::util::log::warn '%s did not go when asked, killing it' \
            "${_proc_insist_pid}"
        stealth::sys::cmd::try kill -s SIGKILL "${_proc_insist_pid}" || true
    done

    local -i _proc_insist_stuck=0
    for _proc_insist_pid in "${_proc_insist_pids[@]}"; do
        if ! stealth::sys::runtime::proc::wait "${_proc_insist_pid}" \
            --timeout "${_STEALTH_SYS_RUNTIME_PROC_KILL_WAIT}"; then
            stealth::util::log::warn '%s is still there after SIGKILL' \
                "${_proc_insist_pid}"
            _proc_insist_stuck=1
        fi
    done
    return "${_proc_insist_stuck}"
}

#######################################
# Writes a process number to a file, so that another run can find it.
#
# Usage:
#   stealth::sys::runtime::proc::pidfile_write "${run}/qemu.pid" "${pid}"
#
# Arguments:
#   $1 (String)  - The file
#   $2 (Integer) - The process number. Default: this shell
# Returns:
#   0 - Written
#   Exits 1 when no file is given, or the number is not one
#######################################
stealth::sys::runtime::proc::pidfile_write() {
    stealth::util::assert::not_empty "${1:-}" 'a pid file is required'
    local -r _proc_pidw_pid="${2:-$$}"
    stealth::util::assert::match "${_proc_pidw_pid}" \
        "${_STEALTH_SYS_RUNTIME_PROC_PID_RE}" \
        "a process number is a whole number, not ${_proc_pidw_pid}"

    stealth::sys::io::fs::write "${1}" "${_proc_pidw_pid}"
    return 0
}

#######################################
# Reads a process number from a file and says whether that process is still
# there. With --named the program it is running has to match too, because a
# process number left behind by a crash is handed out again to something
# else, and stopping that something else is worse than doing nothing.
#
# The three ways this can fail are told apart, so that a caller can clear a
# stale file and leave a missing one alone.
#
# Usage:
#   stealth::sys::runtime::proc::pidfile_read pid "${run}/qemu.pid"
#   stealth::sys::runtime::proc::pidfile_read pid "${file}" --named qemu-system-x86_64
#
# Arguments:
#   $1 (Nameref) - The output variable for the process number
#   $2 (String)  - The file
#   $@ (String)  - --named PROGRAM to check what it is running
# Returns:
#   0 - The process is there
#   1 - There is no such file, or nothing readable in it
#   2 - The file names a process that is gone or is something else
#   Exits 1 when no output variable or no file is given
#######################################
stealth::sys::runtime::proc::pidfile_read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a pid file is required'
    local -n _proc_pidr_out="${1}"
    local -r _proc_pidr_file="${2}"
    shift 2

    local _proc_pidr_named=''
    while (( $# > 0 )); do
        case "${1}" in
            --named)
                stealth::util::assert::not_empty "${2:-}" '--named takes a program'
                _proc_pidr_named="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "pidfile_read does not take ${1}"
                ;;
        esac
    done

    _proc_pidr_out=''
    if [[ ! -r "${_proc_pidr_file}" ]]; then
        return 1
    fi

    local _proc_pidr_text
    stealth::sys::io::fs::read _proc_pidr_text "${_proc_pidr_file}"
    stealth::util::text::trim _proc_pidr_text "${_proc_pidr_text}"

    if [[ ! "${_proc_pidr_text}" =~ ${_STEALTH_SYS_RUNTIME_PROC_PID_RE} ]]; then
        stealth::util::log::warn '%s holds %s, which is not a process number' \
            "${_proc_pidr_file}" "${_proc_pidr_text}"
        return 1
    fi

    if ! stealth::sys::runtime::proc::exists "${_proc_pidr_text}"; then
        stealth::util::log::debug '%s names %s, which has gone' \
            "${_proc_pidr_file}" "${_proc_pidr_text}"
        return 2
    fi

    if [[ -n "${_proc_pidr_named}" ]] && \
        ! stealth::sys::runtime::proc::is_named "${_proc_pidr_text}" "${_proc_pidr_named}"; then
        stealth::util::log::debug '%s names %s, which is not %s any more' \
            "${_proc_pidr_file}" "${_proc_pidr_text}" "${_proc_pidr_named}"
        return 2
    fi

    _proc_pidr_out="${_proc_pidr_text}"
    return 0
}

#######################################
# Removes a pid file. A file that is already gone is no trouble.
#
# Usage:
#   stealth::sys::runtime::proc::pidfile_clear "${run}/qemu.pid"
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - Gone
#   Exits 1 when no file is given
#######################################
stealth::sys::runtime::proc::pidfile_clear() {
    stealth::util::assert::not_empty "${1:-}" 'a pid file is required'

    stealth::sys::io::fs::rm "${1}"
    return 0
}
