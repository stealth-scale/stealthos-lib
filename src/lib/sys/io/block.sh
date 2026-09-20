###############################################################################
# module: sys/io/block
# layer: sys
# description: What a disk is, asked of lsblk.
#
#              Everything here asks about one device and not what is under
#              it. lsblk given a disk prints a line for the disk and a line
#              for every partition on it, so a caller asking a disk its size
#              is handed five numbers and has no way to tell which one it
#              wanted. --nodeps is what makes the answer one line.
#
#              A target is a block device or a plain file. A disk image being
#              built is a file until something loops it, and a module that
#              only works on block devices is of no use while the image is
#              being made.
#
#              Nothing here changes a disk. reread only tells the kernel to
#              look again at a partition table somebody else wrote.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_IO_BLOCK:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_IO_BLOCK=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd"

# =============================================================================
# CONSTANTS
# =============================================================================

# How lsblk is asked about one device: no heading, nothing under it, and the
# value on its own so that the whole line is the answer.
declare -gra _STEALTH_SYS_IO_BLOCK_FLAGS=(--noheadings --nodeps --raw)

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Asks lsblk for one column of one device.
#
# Usage:
#   stealth::sys::io::block::_column value UUID "${device}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The column
#   $3 (String)  - The device
#   $@ (String)  - Anything else to pass lsblk
# Globals:
#   _STEALTH_SYS_IO_BLOCK_FLAGS (Read)
# Returns:
#   0 - Asked, and the answer may be empty
#   1 - There is nothing there to ask about, or lsblk would not say
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::_column() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${3:-}" 'a device is required'
    local -r _block_col_var="${1}"
    local -r _block_col_name="${2}"
    local -r _block_col_dev="${3}"
    shift 3

    if ! stealth::sys::io::block::is_target "${_block_col_dev}"; then
        stealth::util::log::debug 'there is no disk at %s' "${_block_col_dev}"
        return 1
    fi

    stealth::sys::cmd::capture "${_block_col_var}" lsblk \
        "${_STEALTH_SYS_IO_BLOCK_FLAGS[@]}" "$@" \
        --output "${_block_col_name}" "${_block_col_dev}"
}

#######################################
# Asks lsblk for one column and refuses an empty answer, for the questions
# where nothing to say and no answer are the same thing.
#
# Usage:
#   stealth::sys::io::block::_filled value UUID "${device}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The column
#   $3 (String)  - The device
#   $@ (String)  - Anything else to pass lsblk
# Returns:
#   0 - There is an answer
#   1 - There is not
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::_filled() {
    local -n _block_fill_out="${1}"

    if ! stealth::sys::io::block::_column "$@"; then
        return 1
    fi

    [[ -n "${_block_fill_out}" ]]
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether there is something here this module can work on: a block
# device, or a plain file holding a disk image.
#
# Usage:
#   if ! stealth::sys::io::block::is_target "${device}"; then ...
#
# Arguments:
#   $1 (String) - The path
# Returns:
#   0 - There is
#   1 - There is not
#   Exits 1 when no path is given
#######################################
stealth::sys::io::block::is_target() {
    stealth::util::assert::not_empty "${1:-}" 'a device is required'

    [[ -b "${1}" || -f "${1}" ]]
}

#######################################
# Says the identifier a filesystem on a device was made with. A device with
# no filesystem on it has none.
#
# Usage:
#   stealth::sys::io::block::uuid value /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - There is none, or there is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::uuid() {
    stealth::sys::io::block::_filled "${1:-}" UUID "${2:-}"
}

#######################################
# Says the name a filesystem on a device was given.
#
# Usage:
#   stealth::sys::io::block::label value /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - There is none, or there is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::label() {
    stealth::sys::io::block::_filled "${1:-}" LABEL "${2:-}"
}

#######################################
# Says what kind of filesystem is on a device: ext4, xfs, vfat and the rest.
#
# Usage:
#   stealth::sys::io::block::fstype value /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - There is no filesystem on it, or there is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::fstype() {
    stealth::sys::io::block::_filled "${1:-}" FSTYPE "${2:-}"
}

#######################################
# Says how big a device is, in bytes. util/math has human_size for turning
# that into something to show somebody.
#
# Usage:
#   stealth::sys::io::block::size bytes /dev/sda
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - There is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::size() {
    stealth::sys::io::block::_filled "${1:-}" SIZE "${2:-}" --bytes
}

#######################################
# Says what a device is: a disk, a part of one, a loop, a volume of LVM, or
# something read-only.
#
# Usage:
#   stealth::sys::io::block::kind what /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - There is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::kind() {
    stealth::sys::io::block::_filled "${1:-}" TYPE "${2:-}"
}

#######################################
# Says which device a device is part of. A whole disk is part of nothing.
#
# Usage:
#   stealth::sys::io::block::parent disk /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable, which holds a kernel name and not a
#                  path: sda, not /dev/sda
#   $2 (String)  - The device
# Returns:
#   0 - Said
#   1 - It is part of nothing, or there is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::parent() {
    stealth::sys::io::block::_filled "${1:-}" PKNAME "${2:-}"
}

#######################################
# Says where a device is mounted. A device mounted in more than one place
# gives them all, one to a line, which is what lsblk reports.
#
# Usage:
#   stealth::sys::io::block::mountpoint where /dev/sda1
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The device
# Returns:
#   0 - It is mounted, and the output variable says where
#   1 - It is not, or there is nothing there
#   Exits 1 when no output variable or no device is given
#######################################
stealth::sys::io::block::mountpoint() {
    stealth::sys::io::block::_filled "${1:-}" MOUNTPOINTS "${2:-}"
}

#######################################
# Reports whether a device is mounted anywhere.
#
# Usage:
#   if stealth::sys::io::block::is_mounted "${device}"; then ...
#
# Arguments:
#   $1 (String) - The device
# Returns:
#   0 - It is
#   1 - It is not, or there is nothing there
#   Exits 1 when no device is given
#######################################
stealth::sys::io::block::is_mounted() {
    local _block_mnt_where
    stealth::sys::io::block::mountpoint _block_mnt_where "${1:-}"
}

#######################################
# Tells the kernel to read a partition table again, and waits for the device
# nodes to appear.
#
# Waiting is the part that is easy to leave out. partprobe asks the kernel to
# look again and returns, and udev makes the nodes some time after that. A
# caller that goes straight on to open the new partition opens nothing.
#
# Usage:
#   stealth::sys::io::block::reread /dev/sda
#
# Arguments:
#   $1 (String) - The device
# Returns:
#   0 - The kernel has looked again and the nodes are there
#   1 - There is nothing there
#   Exits 1 when no device is given, or partprobe failed
#######################################
stealth::sys::io::block::reread() {
    stealth::util::assert::not_empty "${1:-}" 'a device is required'

    if ! stealth::sys::io::block::is_target "${1}"; then
        stealth::util::log::warn 'there is no disk at %s to read again' "${1}"
        return 1
    fi

    stealth::util::log::debug 'reading the partition table of %s again' "${1}"
    stealth::sys::cmd::run partprobe "${1}"

    if stealth::sys::cmd::exists udevadm; then
        stealth::sys::cmd::try udevadm settle || true
    fi
    return 0
}
