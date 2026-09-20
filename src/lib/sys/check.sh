###############################################################################
# module: sys/check
# layer: sys
# description: Where a run finds itself: in a container, on a bootc system, in
#              CI, on a virtual machine, as root, at a terminal.
#
#              What is asked of the kernel is read, not grepped. Every one of
#              these answers is wanted at the start of a run, and a fork per
#              question is a fork a build does not need.
#
#              The paths are variables so a test can point them at files it
#              wrote, rather than at the machine the test happens to run on.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_CHECK:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_CHECK=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a container leaves behind, by the runtime that made it.
declare -gra _STEALTH_SYS_CHECK_CONTAINER_MARKS=(docker containerd podman libpod kubepods lxc)

# =============================================================================
# CONFIGURATION
# =============================================================================

# Where the answers are read from. A test points these at files of its own.
declare -g STEALTH_CHECK_DOCKERENV="${STEALTH_CHECK_DOCKERENV:-/.dockerenv}"
declare -g STEALTH_CHECK_CONTAINERENV="${STEALTH_CHECK_CONTAINERENV:-/run/.containerenv}"
declare -g STEALTH_CHECK_SYSTEMD="${STEALTH_CHECK_SYSTEMD:-/run/systemd/container}"
declare -g STEALTH_CHECK_CGROUP="${STEALTH_CHECK_CGROUP:-/proc/1/cgroup}"
declare -g STEALTH_CHECK_OSTREE="${STEALTH_CHECK_OSTREE:-/run/ostree-booted}"
declare -g STEALTH_CHECK_VERSION="${STEALTH_CHECK_VERSION:-/proc/version}"
declare -g STEALTH_CHECK_PRODUCT="${STEALTH_CHECK_PRODUCT:-/sys/class/dmi/id/product_name}"

# =============================================================================
# STATE
# =============================================================================

# What kind of machine this is, worked out once.
declare -g _STEALTH_SYS_CHECK_KIND=""

# Whether this is a virtual machine, worked out once, as yes or no.
declare -g _STEALTH_SYS_CHECK_VIRTUAL=""

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads a file into a variable, and gives back nothing when there is no such
# file or it cannot be read. A missing file under /proc or /sys is an answer,
# not a failure.
#
# Usage:
#   stealth::sys::check::_read text "${STEALTH_CHECK_CGROUP}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
# Returns:
#   0 - Read, or there was nothing to read
#######################################
stealth::sys::check::_read() {
    local -n _check_read_out="${1}"

    _check_read_out=''
    if [[ -r "${2}" ]]; then
        _check_read_out="$(< "${2}")"
    fi
    return 0
}

#######################################
# Reports whether this run is inside a container. The container variable that
# systemd sets is asked first, then the files a runtime leaves, then what the
# first process of the machine is in.
#
# Usage:
#   if stealth::sys::check::_in_container; then ...
#
# Arguments:
#   None
# Globals:
#   container (Read)
#   STEALTH_CHECK_DOCKERENV (Read)
#   STEALTH_CHECK_CONTAINERENV (Read)
#   STEALTH_CHECK_SYSTEMD (Read)
#   STEALTH_CHECK_CGROUP (Read)
#   _STEALTH_SYS_CHECK_CONTAINER_MARKS (Read)
# Returns:
#   0 - In a container
#   1 - Not in one
#######################################
stealth::sys::check::_in_container() {
    if [[ -n "${container:-}" ]]; then
        return 0
    fi

    if [[ -e "${STEALTH_CHECK_DOCKERENV}" || -e "${STEALTH_CHECK_CONTAINERENV}" || -e "${STEALTH_CHECK_SYSTEMD}" ]]; then
        return 0
    fi

    local _check_cont_cgroup
    stealth::sys::check::_read _check_cont_cgroup "${STEALTH_CHECK_CGROUP}"

    local _check_cont_mark
    for _check_cont_mark in "${_STEALTH_SYS_CHECK_CONTAINER_MARKS[@]}"; do
        if [[ "${_check_cont_cgroup}" == *"${_check_cont_mark}"* ]]; then
            return 0
        fi
    done
    return 1
}

#######################################
# Asks systemd whether this is a virtual machine. It is a function of its own
# so that a test can answer for it, rather than depend on the machine the test
# happens to run on.
#
# Usage:
#   if stealth::sys::check::_systemd_says_virtual; then ...
#
# Arguments:
#   None
# Returns:
#   0 - systemd is there and says it is virtual
#   1 - systemd is not there, or says it is not
#######################################
stealth::sys::check::_systemd_says_virtual() {
    type -P systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --quiet --vm 2>/dev/null
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says what kind of machine this is: container, bootc or plain. It is worked
# out once, because none of it changes while a run is going.
#
# Usage:
#   stealth::sys::check::kind where
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   _STEALTH_SYS_CHECK_KIND (Read/Write)
#   STEALTH_CHECK_OSTREE (Read)
# Returns:
#   0 - Worked out
#   Exits 1 when no output variable is given
#######################################
stealth::sys::check::kind() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _check_kind_out="${1}"

    if [[ -n "${_STEALTH_SYS_CHECK_KIND}" ]]; then
        _check_kind_out="${_STEALTH_SYS_CHECK_KIND}"
        return 0
    fi

    if stealth::sys::check::_in_container; then
        _STEALTH_SYS_CHECK_KIND='container'
    elif [[ -e "${STEALTH_CHECK_OSTREE}" ]]; then
        _STEALTH_SYS_CHECK_KIND='bootc'
    else
        _STEALTH_SYS_CHECK_KIND='plain'
    fi

    _check_kind_out="${_STEALTH_SYS_CHECK_KIND}"
    stealth::util::log::debug 'this is a %s machine' "${_STEALTH_SYS_CHECK_KIND}"
    return 0
}

#######################################
# Reports whether this run is inside a container.
#
# Usage:
#   if stealth::sys::check::is_container; then ...
#
# Arguments:
#   None
# Returns:
#   0 - In a container
#   1 - Not in one
#######################################
stealth::sys::check::is_container() {
    local _check_iscont_kind

    stealth::sys::check::kind _check_iscont_kind
    [[ "${_check_iscont_kind}" == 'container' ]]
}

#######################################
# Reports whether this run is on a system booted from an image, which is where
# the filesystem is read-only and a change goes through rpm-ostree or bootc.
#
# Usage:
#   if stealth::sys::check::is_bootc; then ...
#
# Arguments:
#   None
# Returns:
#   0 - Booted from an image
#   1 - Not
#######################################
stealth::sys::check::is_bootc() {
    local _check_isbootc_kind

    stealth::sys::check::kind _check_isbootc_kind
    [[ "${_check_isbootc_kind}" == 'bootc' ]]
}

#######################################
# Reports whether this run is a CI job. util/ui and api/ci use it to decide
# whether anything is watching.
#
# Usage:
#   if stealth::sys::check::is_ci; then ...
#
# Arguments:
#   None
# Globals:
#   CI (Read)
#   GITHUB_ACTIONS (Read)
#   GITLAB_CI (Read)
# Returns:
#   0 - A CI job
#   1 - Not one
#######################################
stealth::sys::check::is_ci() {
    [[ -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" || -n "${GITLAB_CI:-}" ]]
}

#######################################
# Reports whether this run is under the Windows subsystem for Linux, where a
# path that crosses to the host filesystem is slow and case-insensitive.
#
# Usage:
#   if stealth::sys::check::is_wsl; then ...
#
# Arguments:
#   None
# Globals:
#   STEALTH_CHECK_VERSION (Read)
# Returns:
#   0 - Under WSL
#   1 - Not
#######################################
stealth::sys::check::is_wsl() {
    local _check_wsl_version

    stealth::sys::check::_read _check_wsl_version "${STEALTH_CHECK_VERSION}"
    [[ "${_check_wsl_version,,}" == *microsoft* ]]
}

#######################################
# Reports whether this run is on a virtual machine. systemd answers when it is
# there, and the name the firmware reports answers when it is not. The answer
# is worked out once.
#
# Usage:
#   if stealth::sys::check::is_virtual; then ...
#
# Arguments:
#   None
# Globals:
#   _STEALTH_SYS_CHECK_VIRTUAL (Read/Write)
#   STEALTH_CHECK_PRODUCT (Read)
# Returns:
#   0 - A virtual machine
#   1 - Not one
#######################################
stealth::sys::check::is_virtual() {
    if [[ -n "${_STEALTH_SYS_CHECK_VIRTUAL}" ]]; then
        [[ "${_STEALTH_SYS_CHECK_VIRTUAL}" == 'yes' ]]
        return
    fi

    _STEALTH_SYS_CHECK_VIRTUAL='no'

    if stealth::sys::check::_systemd_says_virtual; then
        _STEALTH_SYS_CHECK_VIRTUAL='yes'
    else
        local _check_virt_product
        stealth::sys::check::_read _check_virt_product "${STEALTH_CHECK_PRODUCT}"
        case "${_check_virt_product}" in
            *KVM*|*QEMU*|*VirtualBox*|*VMware*|*Virtual\ Machine*)
                _STEALTH_SYS_CHECK_VIRTUAL='yes'
                ;;
            *)
                stealth::util::log::trace 'the firmware reports %s' \
                    "${_check_virt_product}"
                ;;
        esac
    fi

    [[ "${_STEALTH_SYS_CHECK_VIRTUAL}" == 'yes' ]]
}

#######################################
# Reports whether this run is root.
#
# core/state asks the same question of its own, because core may not import
# sys. One line of arithmetic in two places is the price of that rule.
#
# Usage:
#   if stealth::sys::check::is_root; then ...
#
# Arguments:
#   None
# Globals:
#   EUID (Read)
# Returns:
#   0 - Root
#   1 - Anyone else
#######################################
stealth::sys::check::is_root() {
    (( EUID == 0 ))
}

#######################################
# Reports whether a person is there to answer a prompt.
#
# Usage:
#   if stealth::sys::check::is_interactive; then ...
#
# Arguments:
#   None
# Returns:
#   0 - Standard input and standard output are both a terminal
#   1 - One of them is not
#######################################
stealth::sys::check::is_interactive() {
    [[ -t 0 && -t 1 ]]
}
