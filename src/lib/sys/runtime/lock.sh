###############################################################################
# module: sys/runtime/lock
# layer: sys
# description: Named locks, so that two runs doing the same work do not do it
#              at the same time.
#
#              A lock is a file and an open descriptor on it. flock puts the
#              lock on the descriptor, and the kernel takes it off when the
#              descriptor closes. That is why nothing here has to clean up
#              after a run that was killed: the descriptors close when the
#              process ends, whether it ended well or not.
#
#              acquire waits, and waits with a limit when asked to. A wait
#              with no limit is how a build that will never finish looks the
#              same as a build that is still going.
#
#              run is the one to reach for. It holds the lock for exactly as
#              long as the command takes and gives it back afterwards, which
#              is the part a caller holding the lock itself forgets on the
#              path where the command failed.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_LOCK:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_LOCK=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where the lock files go. /run/lock belongs to root, so a run that is not
# root uses the directory the session manager gave it.
declare -g STEALTH_LOCK_DIR="${STEALTH_LOCK_DIR:-${XDG_RUNTIME_DIR:-/run/lock}/stealth}"

# What a lock file is called, and what it is allowed to be. A name goes into a
# path, so a name with a slash in it would put the lock somewhere else.
declare -gr _STEALTH_SYS_RUNTIME_LOCK_SUFFIX='.lock'
declare -gr _STEALTH_SYS_RUNTIME_LOCK_NAME_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# The mode of a lock file. Another user taking a lock of ours would stop work
# they know nothing about.
declare -gr _STEALTH_SYS_RUNTIME_LOCK_MODE='0600'

# =============================================================================
# STATE
# =============================================================================

# Name -> the descriptor the lock is held on.
declare -gA _STEALTH_SYS_RUNTIME_LOCK_HELD=()

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Opens a descriptor on the lock file for a name, making the file and the
# directory above it when they are not there.
#
# The file is made by the open itself. Anything that makes it by renaming
# another file into place would give two first-time contenders descriptors on
# two different inodes, and a lock on one of those is a lock on nothing.
#
# Usage:
#   stealth::sys::runtime::lock::_open fd 'sources'
#
# Arguments:
#   $1 (Nameref) - The output variable for the descriptor
#   $2 (String)  - The name
# Globals:
#   STEALTH_LOCK_DIR (Read)
#   _STEALTH_SYS_RUNTIME_LOCK_MODE (Read)
# Returns:
#   0 - Open
#   Exits 1 when the name is not one that makes a file, or it could not be
#   opened
#######################################
stealth::sys::runtime::lock::_open() {
    local -n _lock_open_out="${1}"

    if [[ ! "${2}" =~ ${_STEALTH_SYS_RUNTIME_LOCK_NAME_RE} ]]; then
        stealth::util::assert::fail "${2} is not a name a lock can have"
    fi

    stealth::sys::io::fs::mkdir "${STEALTH_LOCK_DIR}" --mode 0700

    local -r _lock_open_file="${STEALTH_LOCK_DIR}/${2}${_STEALTH_SYS_RUNTIME_LOCK_SUFFIX}"

    local _lock_open_fd
    if ! exec {_lock_open_fd}>>"${_lock_open_file}"; then
        stealth::util::log::error 'no descriptor could be opened on %s' \
            "${_lock_open_file}"
    fi

    stealth::sys::cmd::try chmod "${_STEALTH_SYS_RUNTIME_LOCK_MODE}" \
        "${_lock_open_file}" || true

    _lock_open_out="${_lock_open_fd}"
    return 0
}

#######################################
# Closes a descriptor, which is what gives a lock back.
#
# Usage:
#   stealth::sys::runtime::lock::_close "${fd}"
#
# Arguments:
#   $1 (Integer) - The descriptor
# Returns:
#   0 - Closed
#######################################
stealth::sys::runtime::lock::_close() {
    local _lock_close_fd="${1}"
    exec {_lock_close_fd}>&-
    return 0
}

#######################################
# Takes a lock, or does not. Everything both ways of asking have in common is
# here, and what differs is the arguments flock is given.
#
# Usage:
#   stealth::sys::runtime::lock::_take 'sources' -n
#   stealth::sys::runtime::lock::_take 'sources' -w 30
#
# Arguments:
#   $1 (String) - The name
#   $@ (String) - What to pass flock besides the descriptor
# Globals:
#   _STEALTH_SYS_RUNTIME_LOCK_HELD (Read/Write)
# Returns:
#   0 - Held, now or already
#   1 - Somebody else has it
#######################################
stealth::sys::runtime::lock::_take() {
    local -r _lock_take_name="${1}"
    shift

    if stealth::sys::runtime::lock::is_held "${_lock_take_name}"; then
        stealth::util::log::trace 'already holding %s' "${_lock_take_name}"
        return 0
    fi

    local _lock_take_fd
    stealth::sys::runtime::lock::_open _lock_take_fd "${_lock_take_name}"

    if ! stealth::sys::cmd::try flock -x "$@" "${_lock_take_fd}"; then
        stealth::sys::runtime::lock::_close "${_lock_take_fd}"
        stealth::util::log::debug 'somebody else holds %s' "${_lock_take_name}"
        return 1
    fi

    _STEALTH_SYS_RUNTIME_LOCK_HELD["${_lock_take_name}"]="${_lock_take_fd}"
    stealth::util::log::debug 'holding %s' "${_lock_take_name}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether this run holds a lock. It says nothing about another run,
# which is what try is for.
#
# Usage:
#   if stealth::sys::runtime::lock::is_held 'sources'; then ...
#
# Arguments:
#   $1 (String) - The name
# Globals:
#   _STEALTH_SYS_RUNTIME_LOCK_HELD (Read)
# Returns:
#   0 - This run holds it
#   1 - It does not
#######################################
stealth::sys::runtime::lock::is_held() {
    [[ -v _STEALTH_SYS_RUNTIME_LOCK_HELD["${1:-}"] ]]
}

#######################################
# Takes a lock, waiting for whoever has it. With --wait the wait has a limit
# and the call gives up when it runs out.
#
# Taking a lock this run already holds is not an error and does not take it
# twice. The one release still gives it back.
#
# Usage:
#   stealth::sys::runtime::lock::acquire 'sources'
#   stealth::sys::runtime::lock::acquire 'sources' --wait 30
#
# Arguments:
#   $1 (String) - The name
#   $@ (String) - --wait SECONDS, whole seconds, which is all flock takes
# Returns:
#   0 - Held
#   1 - The wait ran out
#   Exits 1 when no name is given, or --wait is given something that is not a
#   whole number
#######################################
stealth::sys::runtime::lock::acquire() {
    stealth::util::assert::not_empty "${1:-}" 'a lock name is required'
    local -r _lock_acq_name="${1}"
    shift

    local -a _lock_acq_flags=()
    while (( $# > 0 )); do
        case "${1}" in
            --wait)
                stealth::util::assert::is_int "${2:-}" \
                    "--wait takes whole seconds, not ${2:-}"
                _lock_acq_flags=(-w "${2}")
                shift 2
                ;;
            *)
                stealth::util::assert::fail "acquire does not take ${1}"
                ;;
        esac
    done

    stealth::sys::runtime::lock::_take "${_lock_acq_name}" "${_lock_acq_flags[@]}"
}

#######################################
# Takes a lock if it is free and says so if it is not. Nothing waits.
#
# Usage:
#   if ! stealth::sys::runtime::lock::try 'sources'; then ...
#
# Arguments:
#   $1 (String) - The name
# Returns:
#   0 - Held
#   1 - Somebody else has it
#   Exits 1 when no name is given
#######################################
stealth::sys::runtime::lock::try() {
    stealth::util::assert::not_empty "${1:-}" 'a lock name is required'

    stealth::sys::runtime::lock::_take "${1}" -n
}

#######################################
# Gives a lock back.
#
# Usage:
#   stealth::sys::runtime::lock::release 'sources'
#
# Arguments:
#   $1 (String) - The name
# Globals:
#   _STEALTH_SYS_RUNTIME_LOCK_HELD (Read/Write)
# Returns:
#   0 - Given back
#   1 - This run was not holding it
#   Exits 1 when no name is given
#######################################
stealth::sys::runtime::lock::release() {
    stealth::util::assert::not_empty "${1:-}" 'a lock name is required'

    if ! stealth::sys::runtime::lock::is_held "${1}"; then
        stealth::util::log::warn 'this run is not holding %s' "${1}"
        return 1
    fi

    stealth::sys::runtime::lock::_close \
        "${_STEALTH_SYS_RUNTIME_LOCK_HELD[${1}]}"
    unset "_STEALTH_SYS_RUNTIME_LOCK_HELD[${1}]"

    stealth::util::log::debug 'gave back %s' "${1}"
    return 0
}

#######################################
# Runs a command while holding a lock, and gives the lock back afterwards
# however the command ended.
#
# A lock the run was already holding before the call stays held afterwards.
# The caller that took it is the one that gives it back.
#
# Usage:
#   stealth::sys::runtime::lock::run 'sources' -- tar -xf "${tarball}"
#   stealth::sys::runtime::lock::run 'sources' --wait 30 -- ./build.sh
#
# Arguments:
#   $1 (String) - The name
#   $@ (String) - --wait SECONDS, then -- and the command
# Returns:
#   0 - The command succeeded
#   1 - The wait for the lock ran out
#   The status of the command
#   Exits 1 when no name or no command is given
#######################################
stealth::sys::runtime::lock::run() {
    stealth::util::assert::not_empty "${1:-}" 'a lock name is required'
    local -r _lock_run_name="${1}"
    shift

    local -a _lock_run_flags=()
    while (( $# > 0 )) && [[ "${1}" != '--' ]]; do
        _lock_run_flags+=("${1}")
        shift
    done
    shift || true

    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    local -i _lock_run_was_held=0
    if stealth::sys::runtime::lock::is_held "${_lock_run_name}"; then
        _lock_run_was_held=1
    fi

    if ! stealth::sys::runtime::lock::acquire "${_lock_run_name}" \
        "${_lock_run_flags[@]}"; then
        return 1
    fi

    local -i _lock_run_status=0
    stealth::sys::cmd::try "$@" || _lock_run_status=$?

    if (( _lock_run_was_held == 0 )); then
        stealth::sys::runtime::lock::release "${_lock_run_name}"
    fi
    return "${_lock_run_status}"
}

#######################################
# Gives back every lock this run is still holding. core/engine registers this
# to run at the end of a run, by looking for a cleanup function in each
# library it loaded.
#
# A run that was killed needs none of this. The descriptors close when the
# process ends and the kernel takes the locks off with them.
#
# Usage:
#   stealth::sys::runtime::lock::cleanup
#
# Arguments:
#   None
# Globals:
#   _STEALTH_SYS_RUNTIME_LOCK_HELD (Read/Write)
# Returns:
#   0 - Given back
#######################################
stealth::sys::runtime::lock::cleanup() {
    local -ri _lock_clean_count="${#_STEALTH_SYS_RUNTIME_LOCK_HELD[@]}"

    if (( _lock_clean_count == 0 )); then
        return 0
    fi

    stealth::util::log::debug 'giving back %d locks' "${_lock_clean_count}"

    local _lock_clean_name
    for _lock_clean_name in "${!_STEALTH_SYS_RUNTIME_LOCK_HELD[@]}"; do
        stealth::sys::runtime::lock::_close \
            "${_STEALTH_SYS_RUNTIME_LOCK_HELD[${_lock_clean_name}]}"
    done

    _STEALTH_SYS_RUNTIME_LOCK_HELD=()
    return 0
}
