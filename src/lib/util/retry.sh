###############################################################################
# module: util/retry
# layer: util
# description: Running a command again after it fails: a fixed number of
#              attempts with a delay that grows, and a deadline that a
#              condition has to hold before.
#
#              Neither function ends the process. A caller that has somewhere
#              else to go, another mirror or another registry, needs the
#              status back rather than a dead build. The old module logged at
#              ERROR when it gave up, which exits, so its own documented
#              status of 1 was unreachable.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_UTIL_RETRY:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_UTIL_RETRY=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# The longest a delay grows to, however many attempts have failed.
declare -gri _STEALTH_UTIL_RETRY_CAP=60

# How much of a delay may be added at random, as a percentage. Parallel jobs
# that failed together would otherwise come back together.
declare -gri _STEALTH_UTIL_RETRY_JITTER=25

# The status a deadline that passed reports, the same one a timeout reports.
declare -gri _STEALTH_UTIL_RETRY_TIMEOUT=124

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Works out the next delay: twice the one before it, held at the cap, with a
# random part added on top.
#
# Usage:
#   stealth::util::retry::_backoff delay "${delay}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (Integer) - The delay that was just waited
# Globals:
#   _STEALTH_UTIL_RETRY_CAP (Read)
#   _STEALTH_UTIL_RETRY_JITTER (Read)
#   RANDOM (Read)
# Returns:
#   0 - Worked out
#######################################
stealth::util::retry::_backoff() {
    local -n _retry_back_out="${1}"
    local -i _retry_back_next=$(( ${2} * 2 ))

    if (( _retry_back_next > _STEALTH_UTIL_RETRY_CAP )); then
        _retry_back_next="${_STEALTH_UTIL_RETRY_CAP}"
    fi

    local -ri _retry_back_jitter="${_STEALTH_UTIL_RETRY_JITTER}"
    local -i _retry_back_spread=$(( _retry_back_next * _retry_back_jitter / 100 + 1 ))
    _retry_back_out=$(( _retry_back_next + RANDOM % _retry_back_spread ))
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Runs a command, and runs it again after a failure until the attempts run
# out. The first attempt is not a retry, so a maximum of three means up to
# four runs. The delay doubles after each failure, stops growing at a minute,
# and carries a random part.
#
# Usage:
#   if ! stealth::util::retry::run 3 1 curl -fsSL -o "${out}" "${url}"; then
#       stealth::util::log::warn 'the mirror did not answer, trying the next'
#   fi
#
# Arguments:
#   $1 (Integer) - How many retries after the first attempt, zero or above
#   $2 (Integer) - The first delay in seconds, zero or above
#   $@ (String)  - The command and its arguments
# Outputs:
#   A line per failed attempt, to the sinks of util/log
# Returns:
#   0 - An attempt succeeded
#   The status of the last attempt when they all failed
#   Exits 1 when an argument is missing or is not a whole number
#######################################
stealth::util::retry::run() {
    stealth::util::assert::match "${1:-}" '^[0-9]+$' \
        "a number of retries is a whole number, zero or above, not ${1:-}"
    stealth::util::assert::match "${2:-}" '^[0-9]+$' \
        "a delay in seconds is a whole number, zero or above, not ${2:-}"

    local -ri _retry_run_max="${1}"
    local -i _retry_run_delay="${2}"
    shift 2

    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    local -i _retry_run_attempt=1
    local -ri _retry_run_total=$(( _retry_run_max + 1 ))
    local -i _retry_run_status

    stealth::util::log::trace 'retrying %s up to %d times' "${1}" "${_retry_run_max}"

    while true; do
        _retry_run_status=0
        "$@" || _retry_run_status=$?

        if (( _retry_run_status == 0 )); then
            if (( _retry_run_attempt > 1 )); then
                stealth::util::log::debug 'attempt %d of %d succeeded' \
                    "${_retry_run_attempt}" "${_retry_run_total}"
            fi
            return 0
        fi

        if (( _retry_run_attempt >= _retry_run_total )); then
            stealth::util::log::warn '%s failed %d times, giving up' \
                "${1}" "${_retry_run_total}"
            return "${_retry_run_status}"
        fi

        stealth::util::log::warn 'attempt %d of %d failed with %d, waiting %ds' \
            "${_retry_run_attempt}" "${_retry_run_total}" \
            "${_retry_run_status}" "${_retry_run_delay}"

        sleep "${_retry_run_delay}"
        stealth::util::retry::_backoff _retry_run_delay "${_retry_run_delay}"
        _retry_run_attempt=$(( _retry_run_attempt + 1 ))
    done
}

#######################################
# Runs a command until it succeeds or the deadline passes. The command runs
# once before any waiting, so a deadline of zero still asks once, and there is
# no wait after the last attempt.
#
# Usage:
#   if ! stealth::util::retry::until 60 5 test -S /run/podman/podman.sock; then
#       stealth::util::log::error 'the container runtime did not come up'
#   fi
#
# Arguments:
#   $1 (Integer) - How long to keep asking, in seconds
#   $2 (Integer) - How long to wait between attempts, in seconds
#   $@ (String)  - The command and its arguments
# Globals:
#   SECONDS (Read)
#   _STEALTH_UTIL_RETRY_TIMEOUT (Read)
# Outputs:
#   A line when the deadline passes, to the sinks of util/log
# Returns:
#   0 - The command succeeded
#   124 - The deadline passed first
#   Exits 1 when an argument is missing or is not a whole number
#######################################
stealth::util::retry::until() {
    stealth::util::assert::match "${1:-}" '^[0-9]+$' \
        "a timeout in seconds is a whole number, zero or above, not ${1:-}"
    stealth::util::assert::match "${2:-}" '^[0-9]+$' \
        "an interval in seconds is a whole number, zero or above, not ${2:-}"

    local -ri _retry_until_timeout="${1}"
    local -ri _retry_until_interval="${2}"
    shift 2

    stealth::util::assert::not_empty "${1:-}" 'a command to run is required'

    local -ri _retry_until_deadline=$(( SECONDS + _retry_until_timeout ))

    stealth::util::log::trace 'waiting up to %ds for %s' \
        "${_retry_until_timeout}" "${1}"

    while true; do
        if "$@"; then
            return 0
        fi

        if (( SECONDS >= _retry_until_deadline )); then
            stealth::util::log::warn '%s did not succeed within %ds' \
                "${1}" "${_retry_until_timeout}"
            return "${_STEALTH_UTIL_RETRY_TIMEOUT}"
        fi

        sleep "${_retry_until_interval}"
    done
}
