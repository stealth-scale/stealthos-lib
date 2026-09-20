###############################################################################
# module: sys/runtime/arch
# layer: sys
# description: The names one machine goes by.
#
#              A build calls the same processor four things. The kernel says
#              x86_64, an image manifest says amd64, podman wants linux/amd64,
#              and a compiler wants x86_64-pc-linux-gnu. Anything that has to
#              hand one tool a name it got from another has to translate, and
#              a translation written at the call site is a translation written
#              again at the next call site.
#
#              kernel is the name this module counts from. Everything else
#              takes that name and gives it back in the spelling one tool
#              wants.
#
#              A name this module does not know is refused rather than passed
#              through. A typo that goes through becomes a compiler triple
#              that fails an hour into a build, and the message at that point
#              names the compiler.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_ARCH:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_ARCH=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# Every spelling this module answers to, against the kernel name it means.
# A kernel name maps to itself, so normalize can be given one of its own
# answers. Written on one line because kcov counts the lines of a declaration
# that spans several as never run.
declare -grA _STEALTH_SYS_RUNTIME_ARCH_ALIAS=([x86_64]=x86_64 [amd64]=x86_64 [x86-64]=x86_64 [x64]=x86_64 [aarch64]=aarch64 [arm64]=aarch64 [armv8l]=aarch64 [riscv64]=riscv64 [ppc64le]=ppc64le [ppc64el]=ppc64le [s390x]=s390x)

# The kernel name against the name an image manifest uses. These are Go's
# GOARCH values, which the OCI image specification takes as its own.
declare -grA _STEALTH_SYS_RUNTIME_ARCH_OCI=([x86_64]=amd64 [aarch64]=arm64 [riscv64]=riscv64 [ppc64le]=ppc64le [s390x]=s390x)

# The middle field of a compiler triple when the caller does not say. It names
# who made the machine and no tool reads it, but config.sub wants it there.
declare -gr _STEALTH_SYS_RUNTIME_ARCH_VENDOR='pc'

# The operating system this library builds for, as the two tools spell it.
declare -gr _STEALTH_SYS_RUNTIME_ARCH_OS='linux'
declare -gr _STEALTH_SYS_RUNTIME_ARCH_SYSTEM='linux-gnu'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Gives back the kernel name for an argument the caller may have left out,
# which means this machine.
#
# Usage:
#   stealth::sys::runtime::arch::_or_mine name "${1:-}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - A name in any spelling, or empty for this machine
# Returns:
#   0 - Resolved
#   Exits 1 when the name is one this module does not know
#######################################
stealth::sys::runtime::arch::_or_mine() {
    if [[ -z "${2}" ]]; then
        stealth::sys::runtime::arch::kernel "${1}"
        return 0
    fi

    stealth::sys::runtime::arch::normalize "${1}" "${2}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether this module knows a name, in any of its spellings.
#
# Usage:
#   if ! stealth::sys::runtime::arch::is_known "${wanted}"; then ...
#
# Arguments:
#   $1 (String) - The name
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_ALIAS (Read)
# Returns:
#   0 - Known
#   1 - Not known
#######################################
stealth::sys::runtime::arch::is_known() {
    [[ -v _STEALTH_SYS_RUNTIME_ARCH_ALIAS["${1:-}"] ]]
}

#######################################
# Turns any spelling of an architecture into the name the kernel uses, which
# is the name the rest of this module counts from.
#
# Usage:
#   stealth::sys::runtime::arch::normalize name 'arm64'   # aarch64
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The name in any spelling
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_ALIAS (Read)
# Returns:
#   0 - Translated
#   Exits 1 when no output variable is given, or the name is not known
#######################################
stealth::sys::runtime::arch::normalize() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _arch_norm_out="${1}"

    if ! stealth::sys::runtime::arch::is_known "${2:-}"; then
        stealth::util::assert::fail "no architecture goes by the name ${2:-}"
    fi

    _arch_norm_out="${_STEALTH_SYS_RUNTIME_ARCH_ALIAS[${2}]}"
    return 0
}

#######################################
# Says what this machine is, as the kernel names it. STEALTH_ARCH says
# otherwise, for a build whose target is not the machine running it.
#
# Nothing is cached. bash sets HOSTTYPE at startup, so the usual answer costs
# no fork at all, and a cache would only hide a STEALTH_ARCH that changed.
#
# Usage:
#   stealth::sys::runtime::arch::kernel mine
#
# Arguments:
#   $1 (Nameref) - The output variable
# Globals:
#   STEALTH_ARCH (Read)
#   HOSTTYPE (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, or the machine is one this
#   module does not know
#######################################
stealth::sys::runtime::arch::kernel() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    local _arch_kern_raw="${STEALTH_ARCH:-${HOSTTYPE:-}}"
    if [[ -z "${_arch_kern_raw}" ]]; then
        _arch_kern_raw="$(uname -m)"
    fi

    stealth::sys::runtime::arch::normalize "${1}" "${_arch_kern_raw}"
    stealth::util::log::trace 'architecture %s' "${_arch_kern_raw}"
    return 0
}

#######################################
# Says what an image manifest calls an architecture. Go calls the same thing
# GOARCH, and a container runtime agrees with both.
#
# Usage:
#   stealth::sys::runtime::arch::oci goarch            # this machine
#   stealth::sys::runtime::arch::oci goarch 'aarch64'  # arm64
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The architecture in any spelling. Default: this machine
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_OCI (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, or the architecture is not known
#######################################
stealth::sys::runtime::arch::oci() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _arch_oci_out="${1}"

    local _arch_oci_kernel
    stealth::sys::runtime::arch::_or_mine _arch_oci_kernel "${2:-}"

    _arch_oci_out="${_STEALTH_SYS_RUNTIME_ARCH_OCI[${_arch_oci_kernel}]}"
    return 0
}

#######################################
# Says what a container runtime wants on its --platform, which is the
# operating system and the manifest name with a slash between them.
#
# Usage:
#   stealth::sys::runtime::arch::platform target 'aarch64'  # linux/arm64
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The architecture in any spelling. Default: this machine
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_OS (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, or the architecture is not known
#######################################
stealth::sys::runtime::arch::platform() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _arch_plat_out="${1}"

    local _arch_plat_oci
    stealth::sys::runtime::arch::oci _arch_plat_oci "${2:-}"

    _arch_plat_out="${_STEALTH_SYS_RUNTIME_ARCH_OS}/${_arch_plat_oci}"
    return 0
}

#######################################
# Builds the triple a compiler is configured with. The vendor field is the
# caller's, because that is where a toolchain marks itself: the Linux From
# Scratch build gives its cross compiler the vendor lfs so that a binary made
# by it cannot be confused with one made by the host compiler.
#
# Usage:
#   stealth::sys::runtime::arch::triple build           # x86_64-pc-linux-gnu
#   stealth::sys::runtime::arch::triple target '' lfs   # x86_64-lfs-linux-gnu
#   stealth::sys::runtime::arch::triple cross 'arm64'   # aarch64-pc-linux-gnu
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The architecture in any spelling. Default: this machine
#   $3 (String)  - The vendor field. Default: pc
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_VENDOR (Read)
#   _STEALTH_SYS_RUNTIME_ARCH_SYSTEM (Read)
# Returns:
#   0 - Built
#   Exits 1 when no output variable is given, or the architecture is not known
#######################################
stealth::sys::runtime::arch::triple() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _arch_trip_out="${1}"

    local _arch_trip_kernel
    stealth::sys::runtime::arch::_or_mine _arch_trip_kernel "${2:-}"

    local -r _arch_trip_vendor="${3:-${_STEALTH_SYS_RUNTIME_ARCH_VENDOR}}"
    _arch_trip_out="${_arch_trip_kernel}-${_arch_trip_vendor}-${_STEALTH_SYS_RUNTIME_ARCH_SYSTEM}"
    return 0
}

#######################################
# Reports whether this machine is the architecture named, in any spelling.
#
# Usage:
#   if stealth::sys::runtime::arch::is 'amd64'; then ...
#
# Arguments:
#   $1 (String) - The architecture in any spelling
# Globals:
#   _STEALTH_SYS_RUNTIME_ARCH_ALIAS (Read)
# Returns:
#   0 - It is
#   1 - It is not, or the name is one this module does not know
#######################################
stealth::sys::runtime::arch::is() {
    if ! stealth::sys::runtime::arch::is_known "${1:-}"; then
        return 1
    fi

    local _arch_is_mine
    stealth::sys::runtime::arch::kernel _arch_is_mine

    [[ "${_arch_is_mine}" == "${_STEALTH_SYS_RUNTIME_ARCH_ALIAS[${1}]}" ]]
}
