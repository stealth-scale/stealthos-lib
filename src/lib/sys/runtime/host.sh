###############################################################################
# module: sys/runtime/host
# layer: sys
# description: What a machine is called and what it is.
#
#              Every function here takes --root, because this library spends
#              most of its time working on a filesystem that is not the one it
#              is running on. Setting the name of an image under construction
#              and setting the name of the machine building it are the same
#              operation against different trees, and a module that can only
#              do the second is of no use to an image build.
#
#              A name is checked before it is written. A hostname that breaks
#              the rules is accepted by the file and rejected later by
#              whatever reads it, and the complaint comes from a program that
#              has no idea where the name came from.
#
#              reset_id empties the machine identifier rather than removing
#              it. systemd generates one at first boot either way, and the
#              machine-id manual page asks for an empty file because it lets a
#              temporary file be bind-mounted over the real one when the image
#              is read-only.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_HOST:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_HOST=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/cmd" "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where a name and an identifier live, under whichever root is being worked
# on. A test points these somewhere else.
declare -g STEALTH_HOST_NAME_FILE='/etc/hostname'
declare -g STEALTH_HOST_ID_FILE='/etc/machine-id'
declare -g STEALTH_HOST_DBUS_ID_FILE='/var/lib/dbus/machine-id'

# What a hostname is allowed to be. RFC 1123 lets a label start with a digit,
# which RFC 952 did not, and that is the rule every resolver follows now.
declare -gr _STEALTH_SYS_RUNTIME_HOST_LABEL_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

# How long a name and one of its labels may be.
declare -gri _STEALTH_SYS_RUNTIME_HOST_MAX=253
declare -gri _STEALTH_SYS_RUNTIME_HOST_LABEL_MAX=63

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Takes --root off the front of the arguments and gives back the root it
# names, which is empty when there is none.
#
# Usage:
#   stealth::sys::runtime::host::_take_root root rest "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for the root
#   $2 (Nameref) - The output array for everything that was not an option
#   $@ (String)  - The arguments
# Returns:
#   0 - Taken
#   Exits 1 when --root is given without a directory
#######################################
stealth::sys::runtime::host::_take_root() {
    local -n _host_root_out="${1}"
    local -n _host_root_rest="${2}"
    shift 2

    _host_root_out=''
    _host_root_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --root)
                stealth::util::assert::not_empty "${2:-}" '--root takes a directory'
                _host_root_out="${2%/}"
                shift 2
                ;;
            *)
                _host_root_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

#######################################
# Reads a file and gives back what is in it with the spaces taken off, or
# nothing at all when there is no such file.
#
# Usage:
#   stealth::sys::runtime::host::_read value "${root}/etc/machine-id"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
# Returns:
#   0 - Read something
#   1 - There was nothing to read
#######################################
stealth::sys::runtime::host::_read() {
    local -n _host_read_out="${1}"

    _host_read_out=''
    if [[ ! -r "${2}" ]]; then
        return 1
    fi

    stealth::sys::io::fs::read _host_read_out "${2}"
    stealth::util::text::trim _host_read_out "${_host_read_out}"

    [[ -n "${_host_read_out}" ]]
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether a name is one a resolver will accept: labels of letters,
# digits and hyphens, separated by dots, none of them starting or ending with
# a hyphen, none longer than 63 characters, and 253 for the whole name.
#
# Usage:
#   if ! stealth::sys::runtime::host::is_valid "${wanted}"; then ...
#
# Arguments:
#   $1 (String) - The name
# Globals:
#   _STEALTH_SYS_RUNTIME_HOST_LABEL_RE (Read)
#   _STEALTH_SYS_RUNTIME_HOST_MAX (Read)
#   _STEALTH_SYS_RUNTIME_HOST_LABEL_MAX (Read)
# Returns:
#   0 - It is
#   1 - It is not
#######################################
stealth::sys::runtime::host::is_valid() {
    local -r _host_val_name="${1:-}"

    if [[ -z "${_host_val_name}" ]]; then
        return 1
    fi
    if (( ${#_host_val_name} > _STEALTH_SYS_RUNTIME_HOST_MAX )); then
        return 1
    fi

    local -a _host_val_labels=()
    stealth::util::text::split _host_val_labels "${_host_val_name}" '.'

    local _host_val_label
    for _host_val_label in "${_host_val_labels[@]}"; do
        if (( ${#_host_val_label} > _STEALTH_SYS_RUNTIME_HOST_LABEL_MAX )); then
            return 1
        fi
        if [[ ! "${_host_val_label}" =~ ${_STEALTH_SYS_RUNTIME_HOST_LABEL_RE} ]]; then
            return 1
        fi
    done
    return 0
}

#######################################
# Says what a machine is called. Without --root that is this machine, and
# bash sets HOSTNAME at startup, so the usual answer costs no fork. With one
# it is whatever the file under that tree says, because a tree that is not
# running has no HOSTNAME to ask.
#
# Usage:
#   stealth::sys::runtime::host::name mine
#   stealth::sys::runtime::host::name built --root "${rootfs}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - --root DIR to read from a tree that is not this machine
# Globals:
#   HOSTNAME (Read)
#   STEALTH_HOST_NAME_FILE (Read)
# Returns:
#   0 - Said
#   1 - Nothing there says what it is called
#   Exits 1 when no output variable is given
#######################################
stealth::sys::runtime::host::name() {
    local _host_name_root
    local -a _host_name_rest=()
    stealth::sys::runtime::host::_take_root _host_name_root _host_name_rest "$@"

    stealth::util::assert::not_empty "${_host_name_rest[0]:-}" \
        'an output variable is required'

    if [[ -z "${_host_name_root}" && -n "${HOSTNAME:-}" ]]; then
        local -n _host_name_out="${_host_name_rest[0]}"
        _host_name_out="${HOSTNAME}"
        return 0
    fi

    if stealth::sys::runtime::host::_read "${_host_name_rest[0]}" \
        "${_host_name_root}${STEALTH_HOST_NAME_FILE}"; then
        return 0
    fi

    stealth::util::log::debug 'nothing under %s says what it is called' \
        "${_host_name_root:-/}"
    return 1
}

#######################################
# Gives a machine a name, in the file that survives a reboot. Without --root
# the running kernel is told as well, because a name that only takes effect
# at the next boot is not the name the caller asked for.
#
# Usage:
#   stealth::sys::runtime::host::set_name 'node-01'
#   stealth::sys::runtime::host::set_name 'node-01' --root "${rootfs}"
#
# Arguments:
#   $1 (String) - The name
#   $@ (String) - --root DIR to write into a tree that is not this machine
# Globals:
#   STEALTH_HOST_NAME_FILE (Read)
# Returns:
#   0 - Named
#   Exits 1 when no name is given, or the name is not one a resolver accepts
#######################################
stealth::sys::runtime::host::set_name() {
    local _host_set_root
    local -a _host_set_rest=()
    stealth::sys::runtime::host::_take_root _host_set_root _host_set_rest "$@"

    local -r _host_set_name="${_host_set_rest[0]:-}"
    stealth::util::assert::not_empty "${_host_set_name}" 'a hostname is required'

    if ! stealth::sys::runtime::host::is_valid "${_host_set_name}"; then
        stealth::util::assert::fail \
            "${_host_set_name} is not a hostname a resolver will accept"
    fi

    stealth::sys::io::fs::write "${_host_set_root}${STEALTH_HOST_NAME_FILE}" \
        "${_host_set_name}"

    if [[ -z "${_host_set_root}" ]]; then
        stealth::sys::runtime::host::_tell_kernel "${_host_set_name}"
    fi

    stealth::util::log::info 'hostname is now %s' "${_host_set_name}"
    return 0
}

#######################################
# Tells the running kernel a name, through hostnamectl where systemd is in
# charge and through hostname where it is not.
#
# Usage:
#   stealth::sys::runtime::host::_tell_kernel 'node-01'
#
# Arguments:
#   $1 (String) - The name
# Returns:
#   0 - Told
#   Exits 1 when the command failed
#######################################
stealth::sys::runtime::host::_tell_kernel() {
    if stealth::sys::cmd::exists hostnamectl; then
        stealth::sys::cmd::run hostnamectl set-hostname "${1}"
        return 0
    fi

    stealth::sys::cmd::run hostname "${1}"
    return 0
}

#######################################
# Says the identifier a machine is known by. systemd writes it to
# /etc/machine-id and falls back to the one D-Bus keeps, so this does too.
#
# An image that has not booted yet has no identifier, and this reports that
# rather than inventing one.
#
# Usage:
#   stealth::sys::runtime::host::id value
#   stealth::sys::runtime::host::id value --root "${rootfs}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - --root DIR to read from a tree that is not this machine
# Globals:
#   STEALTH_HOST_ID_FILE (Read)
#   STEALTH_HOST_DBUS_ID_FILE (Read)
# Returns:
#   0 - Said
#   1 - There is no identifier yet
#   Exits 1 when no output variable is given
#######################################
stealth::sys::runtime::host::id() {
    local _host_id_root
    local -a _host_id_rest=()
    stealth::sys::runtime::host::_take_root _host_id_root _host_id_rest "$@"

    stealth::util::assert::not_empty "${_host_id_rest[0]:-}" \
        'an output variable is required'

    if stealth::sys::runtime::host::_read "${_host_id_rest[0]}" \
        "${_host_id_root}${STEALTH_HOST_ID_FILE}"; then
        return 0
    fi

    if stealth::sys::runtime::host::_read "${_host_id_rest[0]}" \
        "${_host_id_root}${STEALTH_HOST_DBUS_ID_FILE}"; then
        return 0
    fi

    stealth::util::log::debug 'no machine identifier under %s' \
        "${_host_id_root:-/}"
    return 1
}

#######################################
# Empties the machine identifier, so that the first boot of the image makes
# one of its own. Two machines installed from an image that kept its
# identifier answer to the same one, and anything that counts machines by it
# sees one machine.
#
# The file is left in place and empty rather than removed. The machine-id
# manual page asks for that, because an empty file is something a temporary
# file can be bind-mounted over when /etc is read-only.
#
# Usage:
#   stealth::sys::runtime::host::reset_id --root "${rootfs}"
#
# Arguments:
#   $@ (String) - --root DIR to work on a tree that is not this machine
# Globals:
#   STEALTH_HOST_ID_FILE (Read)
# Returns:
#   0 - Emptied
#######################################
stealth::sys::runtime::host::reset_id() {
    local _host_reset_root
    local -a _host_reset_rest=()
    stealth::sys::runtime::host::_take_root _host_reset_root _host_reset_rest "$@"

    local -r _host_reset_file="${_host_reset_root}${STEALTH_HOST_ID_FILE}"
    stealth::sys::io::fs::atomic "${_host_reset_file}" -- \
        stealth::sys::runtime::host::_empty

    stealth::util::log::debug 'emptied %s' "${_host_reset_file}"
    return 0
}

#######################################
# Leaves a file holding nothing at all. fs::write would put a line break in
# it, and a machine identifier of one byte is not the empty file systemd
# looks for.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- stealth::sys::runtime::host::_empty
#
# Arguments:
#   $1 (String) - The staged file
# Returns:
#   0 - Emptied
#######################################
stealth::sys::runtime::host::_empty() {
    : > "${1}"
    return 0
}
