###############################################################################
# module: sys/system
# layer: sys
# description: What the machine has: processors, memory, and the number of
#              jobs a build should run at once.
#
#              A container gets what its cgroup allows, not what the host
#              owns. nproc reports the host's processors to a container that
#              was given two, and a build that reads it starts sixty-four
#              compilers inside a two-processor box. The limit is read first,
#              and the machine only when there is no limit.
#
#              jobs is the reason the other two are here. Concurrency picked
#              from processors alone runs a machine out of memory, because a
#              compiler holds far more than a processor does.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_SYSTEM:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_SYSTEM=1

stealth::util::import "util/assert" "util/log" "util/math" "util/text"

# =============================================================================
# CONSTANTS
# =============================================================================

# How much memory one compiler is given before another is started. A link of a
# large program is what sets this, not the average.
declare -gr _STEALTH_SYS_SYSTEM_PER_JOB='2G'

# What to answer with when nothing can be read.
declare -gri _STEALTH_SYS_SYSTEM_ONE_CPU=1
declare -gri _STEALTH_SYS_SYSTEM_SOME_MEMORY=1073741824

# =============================================================================
# CONFIGURATION
# =============================================================================

# Where the answers are read from. A test points these at files of its own.
declare -g STEALTH_SYSTEM_CPU_MAX="${STEALTH_SYSTEM_CPU_MAX:-/sys/fs/cgroup/cpu.max}"
declare -g STEALTH_SYSTEM_MEMORY_MAX="${STEALTH_SYSTEM_MEMORY_MAX:-/sys/fs/cgroup/memory.max}"
declare -g STEALTH_SYSTEM_MEMINFO="${STEALTH_SYSTEM_MEMINFO:-/proc/meminfo}"
declare -g STEALTH_SYSTEM_CPUINFO="${STEALTH_SYSTEM_CPUINFO:-/proc/cpuinfo}"

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads a file into a variable, and gives back nothing when there is no such
# file. A missing file under /proc or /sys is an answer, not a failure.
#
# Usage:
#   stealth::sys::system::_read text "${STEALTH_SYSTEM_CPU_MAX}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
# Returns:
#   0 - Read, or there was nothing to read
#######################################
stealth::sys::system::_read() {
    local -n _sys_read_out="${1}"

    _sys_read_out=''
    if [[ -r "${2}" ]]; then
        _sys_read_out="$(< "${2}")"
    fi
    return 0
}

#######################################
# Reads how many processors the cgroup allows, from the quota and the period
# it is given. A cgroup with no limit says max, and this gives nothing back.
#
# Usage:
#   stealth::sys::system::_cpu_limit allowed
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   STEALTH_SYSTEM_CPU_MAX (Read)
# Returns:
#   0 - There is a limit
#   1 - There is none
#######################################
stealth::sys::system::_cpu_limit() {
    local -n _sys_cpul_out="${1}"
    local _sys_cpul_line

    stealth::sys::system::_read _sys_cpul_line "${STEALTH_SYSTEM_CPU_MAX}"
    if [[ ! "${_sys_cpul_line}" =~ ^([0-9]+)[[:space:]]+([0-9]+) ]]; then
        return 1
    fi

    local -ri _sys_cpul_quota="${BASH_REMATCH[1]}"
    local -ri _sys_cpul_period="${BASH_REMATCH[2]}"
    if (( _sys_cpul_period == 0 )); then
        return 1
    fi

    stealth::util::math::div_ceil _sys_cpul_out \
        "${_sys_cpul_quota}" "${_sys_cpul_period}"
    stealth::util::math::max _sys_cpul_out "${_sys_cpul_out}" 1
    return 0
}

#######################################
# Counts the processors the machine reports.
#
# Usage:
#   stealth::sys::system::_cpu_count found
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   STEALTH_SYSTEM_CPUINFO (Read)
#   _STEALTH_SYS_SYSTEM_ONE_CPU (Read)
# Returns:
#   0 - Counted
#######################################
stealth::sys::system::_cpu_count() {
    local -n _sys_cpuc_out="${1}"
    local _sys_cpuc_text

    stealth::sys::system::_read _sys_cpuc_text "${STEALTH_SYSTEM_CPUINFO}"

    local -a _sys_cpuc_lines=()
    mapfile -t _sys_cpuc_lines <<< "${_sys_cpuc_text}"

    _sys_cpuc_out=0
    local _sys_cpuc_line
    for _sys_cpuc_line in "${_sys_cpuc_lines[@]}"; do
        if [[ "${_sys_cpuc_line}" == processor*:* ]]; then
            _sys_cpuc_out=$(( _sys_cpuc_out + 1 ))
        fi
    done

    if (( _sys_cpuc_out < 1 )); then
        _sys_cpuc_out="${_STEALTH_SYS_SYSTEM_ONE_CPU}"
    fi
    return 0
}

#######################################
# Reads how much memory the cgroup allows. A cgroup with no limit says max,
# and this gives nothing back.
#
# Usage:
#   stealth::sys::system::_memory_limit allowed
#
# Arguments:
#   $1 (Nameref) - The output variable, in bytes
# Globals:
#   STEALTH_SYSTEM_MEMORY_MAX (Read)
# Returns:
#   0 - There is a limit
#   1 - There is none
#######################################
stealth::sys::system::_memory_limit() {
    local -n _sys_meml_out="${1}"
    local _sys_meml_line

    stealth::sys::system::_read _sys_meml_line "${STEALTH_SYSTEM_MEMORY_MAX}"
    if [[ ! "${_sys_meml_line}" =~ ^([0-9]+)$ ]]; then
        return 1
    fi

    _sys_meml_out="${BASH_REMATCH[1]}"
    return 0
}

#######################################
# Reads how much memory the machine reports, from the total it lists in
# kibibytes.
#
# Usage:
#   stealth::sys::system::_memory_total bytes
#
# Arguments:
#   $1 (Nameref) - The output variable, in bytes
# Globals:
#   STEALTH_SYSTEM_MEMINFO (Read)
#   _STEALTH_SYS_SYSTEM_SOME_MEMORY (Read)
# Returns:
#   0 - Read
#######################################
stealth::sys::system::_memory_total() {
    local -n _sys_memt_out="${1}"
    local _sys_memt_text

    stealth::sys::system::_read _sys_memt_text "${STEALTH_SYSTEM_MEMINFO}"

    if [[ "${_sys_memt_text}" =~ MemTotal:[[:space:]]+([0-9]+) ]]; then
        _sys_memt_out=$(( BASH_REMATCH[1] * 1024 ))
        return 0
    fi

    _sys_memt_out="${_STEALTH_SYS_SYSTEM_SOME_MEMORY}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says how many processors this run may use: what the cgroup allows when there
# is a limit, and what the machine has when there is not.
#
# Usage:
#   stealth::sys::system::cpus available
#
# Arguments:
#   $1 (Nameref) - The output variable
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given
#######################################
stealth::sys::system::cpus() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    if stealth::sys::system::_cpu_limit "${1}"; then
        return 0
    fi

    stealth::sys::system::_cpu_count "${1}"
    return 0
}

#######################################
# Says how much memory this run may use, in bytes: what the cgroup allows when
# there is a limit, and what the machine has when there is not.
#
# Usage:
#   stealth::sys::system::memory bytes
#   stealth::util::math::human_size shown "${bytes}"
#
# Arguments:
#   $1 (Nameref) - The output variable, in bytes
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given
#######################################
stealth::sys::system::memory() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    if stealth::sys::system::_memory_limit "${1}"; then
        return 0
    fi

    stealth::sys::system::_memory_total "${1}"
    return 0
}

#######################################
# Says how many jobs to run at once: one per processor, but no more than the
# memory allows at the size a job is given.
#
# A build that takes its concurrency from the processor count alone runs a
# machine out of memory, because a compiler holds far more than a processor
# does. The answer is never below one.
#
# Usage:
#   stealth::sys::system::jobs at_once
#   make -j"${at_once}"
#   stealth::sys::system::jobs at_once 4G
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - How much memory to allow a job, as a size. Default: 2G
# Globals:
#   _STEALTH_SYS_SYSTEM_PER_JOB (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, or the size cannot be read
#######################################
stealth::sys::system::jobs() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _sys_jobs_out="${1}"

    local -i _sys_jobs_cpus _sys_jobs_memory _sys_jobs_each _sys_jobs_fit
    stealth::sys::system::cpus _sys_jobs_cpus
    stealth::sys::system::memory _sys_jobs_memory
    stealth::util::math::to_bytes _sys_jobs_each "${2:-${_STEALTH_SYS_SYSTEM_PER_JOB}}"

    if (( _sys_jobs_each < 1 )); then
        stealth::util::assert::fail 'a job is given more than nothing to work in'
    fi

    _sys_jobs_fit=$(( _sys_jobs_memory / _sys_jobs_each ))
    stealth::util::math::max _sys_jobs_fit "${_sys_jobs_fit}" 1
    stealth::util::math::min _sys_jobs_out "${_sys_jobs_cpus}" "${_sys_jobs_fit}"

    stealth::util::log::debug 'running %d jobs at once, for %d processors' \
        "${_sys_jobs_out}" "${_sys_jobs_cpus}"
    return 0
}
