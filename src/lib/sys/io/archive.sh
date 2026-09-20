###############################################################################
# module: sys/io/archive
# layer: sys
# description: Tar archives, and the compression around them.
#
#              An archive made here is the same bytes every time it is made
#              from the same files. A layer of an image is a tar, and the
#              digest of that tar is the name the layer is stored under. Two
#              machines building the same package have to arrive at the same
#              name. Nothing downstream can share a layer they disagree on.
#
#              Four things make a tar differ between two runs of the same
#              build: the order the names come out of the directory, the time
#              each file was last changed, who owns it, and the headers tar
#              writes about itself. create settles all four. There is no way
#              to ask it for an archive that does not, because an archive that
#              does not is of no use to anything above this module.
#
#              Compression is held to the same rule. gzip writes the name and
#              the time of the original into its header unless told not to,
#              which is enough on its own to give two different digests for
#              one tar.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_IO_ARCHIVE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_IO_ARCHIVE=1

stealth::util::import "util/assert" "util/log" "util/list"
stealth::util::import "sys/cmd" "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# What makes a tar the same every time it is made. Each of these settles one
# thing that would otherwise be decided by the machine that ran the build.
#
# --sort=name sorts the members, because the order of a directory is not an
# order at all. --owner=0 --group=0 gives them to nobody, and --numeric-owner
# keeps tar from looking a name up in the builder's own passwd file.
# --format=pax is the one format that holds a long name without guessing, and
# --pax-option deletes the access and change times that pax otherwise writes
# in headers of its own. --no-acls and --no-selinux drop what the builder's
# filesystem happened to carry.
#
# The declaration is one line because kcov counts the lines of a declaration
# that spans several as never run.
declare -gra _STEALTH_SYS_IO_ARCHIVE_REPRODUCIBLE=(--sort=name --owner=0 --group=0 --numeric-owner --format=pax '--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime' --no-acls --no-selinux)

# The time every file in an archive is given when the caller does not say.
declare -gri _STEALTH_SYS_IO_ARCHIVE_EPOCH=0

# How each kind of compression is recognised, as the bytes it begins with.
declare -grA _STEALTH_SYS_IO_ARCHIVE_MAGIC=([gzip]=$'\x1f\x8b' [bzip2]=$'\x42\x5a\x68' [xz]=$'\xfd\x37\x7a\x58\x5a' [zstd]=$'\x28\xb5\x2f\xfd')

# What compresses each kind. gzip writes the name and the time of the original
# into its header without -n, which gives one tar two digests.
declare -grA _STEALTH_SYS_IO_ARCHIVE_PACK=([gzip]='gzip -n -c' [bzip2]='bzip2 -c' [xz]='xz -T0 -c' [zstd]='zstd -q -T0 -c')

# What decompresses each kind.
declare -grA _STEALTH_SYS_IO_ARCHIVE_UNPACK=([gzip]='gzip -d -c' [bzip2]='bzip2 -d -c' [xz]='xz -d -c' [zstd]='zstd -d -q -c')

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads the first bytes of a file.
#
# Usage:
#   stealth::sys::io::archive::_head start "${path}" 4
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (Integer) - How many bytes
# Returns:
#   0 - Read, and empty when there was nothing to read
#######################################
stealth::sys::io::archive::_head() {
    local -n _ar_head_out="${1}"

    _ar_head_out=''
    if [[ ! -r "${2}" ]]; then
        return 0
    fi

    LC_ALL=C read -r -N "${3}" _ar_head_out < "${2}" || true
    return 0
}

#######################################
# Splits a command written as a string into the words that run it.
#
# Usage:
#   stealth::sys::io::archive::_words parts 'gzip -n -c'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The command
# Returns:
#   0 - Split
#######################################
stealth::sys::io::archive::_words() {
    local -n _ar_words_out="${1}"

    # The words are this module's own constants, never anything a caller
    # passed, so splitting them on spaces is safe.
    # shellcheck disable=SC2206  # the value is a constant of this module
    _ar_words_out=(${2})
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says how a file is compressed, by the bytes it begins with rather than by
# what it is called. A file named .tar.gz that is not gzip is read correctly,
# and one named .bin that is gzip is too.
#
# Usage:
#   stealth::sys::io::archive::kind how "${blob}"
#   if [[ "${how}" == 'zstd' ]]; then ...
#
# Arguments:
#   $1 (Nameref) - The output variable: gzip, bzip2, xz, zstd or none
#   $2 (String)  - The file
# Globals:
#   _STEALTH_SYS_IO_ARCHIVE_MAGIC (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable or no file is given
#######################################
stealth::sys::io::archive::kind() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to look at in ${2:-}"
    local -n _ar_kind_out="${1}"

    local _ar_kind_start
    stealth::sys::io::archive::_head _ar_kind_start "${2}" 6

    local _ar_kind_name
    for _ar_kind_name in "${!_STEALTH_SYS_IO_ARCHIVE_MAGIC[@]}"; do
        if [[ "${_ar_kind_start}" == "${_STEALTH_SYS_IO_ARCHIVE_MAGIC[${_ar_kind_name}]}"* ]]; then
            _ar_kind_out="${_ar_kind_name}"
            return 0
        fi
    done

    _ar_kind_out='none'
    return 0
}

#######################################
# Makes a tar of a directory, the same bytes every time from the same files.
#
# Everything in the archive is given one time, owned by nobody, and comes in
# the order of its name. The files alone decide what the archive holds, which
# is what lets the digest of it be the name a layer is stored under.
#
# Extended attributes are left out unless asked for. They carry the
# capabilities a binary needs, so a root filesystem wants them. Everywhere
# else they are noise.
#
# Usage:
#   stealth::sys::io::archive::create "${layer}" "${rootfs}"
#   stealth::sys::io::archive::create "${layer}" "${rootfs}" --xattrs
#   stealth::sys::io::archive::create "${layer}" "${rootfs}" --exclude './var/cache'
#
# Arguments:
#   $1 (String) - The tar to write
#   $2 (String) - The directory whose contents go in it
#   $@ (String) - --epoch N to set the time, --xattrs to keep them,
#                 --exclude PATTERN, which may be given more than once
# Globals:
#   SOURCE_DATE_EPOCH (Read)
#   _STEALTH_SYS_IO_ARCHIVE_REPRODUCIBLE (Read)
#   _STEALTH_SYS_IO_ARCHIVE_EPOCH (Read)
# Returns:
#   0 - The tar is written
#   Exits 1 when the tar or the directory is not given, or tar fails
#######################################
stealth::sys::io::archive::create() {
    stealth::util::assert::not_empty "${1:-}" 'an archive to write is required'
    local -r _ar_new_tar="${1}"
    shift
    stealth::util::assert::is_dir "${1:-}" "no directory to archive at ${1:-}"
    local -r _ar_new_root="${1}"
    shift

    local _ar_new_epoch="${SOURCE_DATE_EPOCH:-${_STEALTH_SYS_IO_ARCHIVE_EPOCH}}"
    local -a _ar_new_extra=()

    while (( $# > 0 )); do
        case "${1}" in
            --epoch)
                stealth::util::assert::is_int "${2:-}" \
                    "--epoch takes a whole number of seconds, not ${2:-}"
                _ar_new_epoch="${2}"
                shift 2
                ;;
            --xattrs)
                _ar_new_extra+=(--xattrs)
                shift
                ;;
            --exclude)
                stealth::util::assert::not_empty "${2:-}" '--exclude takes a pattern'
                _ar_new_extra+=("--exclude=${2}")
                shift 2
                ;;
            *)
                stealth::util::assert::fail "create does not take ${1}"
                ;;
        esac
    done

    if ! stealth::util::list::contains _ar_new_extra '--xattrs'; then
        _ar_new_extra+=(--no-xattrs)
    fi

    local _ar_new_dir="${_ar_new_tar%/*}"
    if [[ "${_ar_new_dir}" != "${_ar_new_tar}" ]]; then
        stealth::sys::io::fs::mkdir "${_ar_new_dir}"
    fi

    stealth::sys::cmd::run tar --create --file "${_ar_new_tar}" \
        --directory "${_ar_new_root}" \
        "${_STEALTH_SYS_IO_ARCHIVE_REPRODUCIBLE[@]}" \
        "--mtime=@${_ar_new_epoch}" \
        "${_ar_new_extra[@]}" .

    stealth::util::log::debug 'archived %s into %s' "${_ar_new_root}" "${_ar_new_tar}"
    return 0
}

#######################################
# Unpacks an archive into a directory, whatever it is compressed with. The
# directory is made when it is not there.
#
# Nothing is unpacked outside the directory: a member whose name climbs out
# through a parent component, or begins at the root, is refused by tar itself.
#
# Usage:
#   stealth::sys::io::archive::extract "${tarball}" "${sources}"
#   stealth::sys::io::archive::extract "${tarball}" "${sources}" --strip 1
#
# Arguments:
#   $1 (String) - The archive
#   $2 (String) - Where to unpack it
#   $@ (String) - --strip N to drop that many leading path components,
#                 --xattrs to keep them
# Returns:
#   0 - Unpacked
#   Exits 1 when the archive or the directory is not given, or tar fails
#######################################
stealth::sys::io::archive::extract() {
    stealth::util::assert::is_file "${1:-}" "no archive to unpack at ${1:-}"
    local -r _ar_ex_tar="${1}"
    shift
    stealth::util::assert::not_empty "${1:-}" 'a directory to unpack into is required'
    local -r _ar_ex_dir="${1}"
    shift

    local -a _ar_ex_extra=()
    while (( $# > 0 )); do
        case "${1}" in
            --strip)
                stealth::util::assert::is_int "${2:-}" \
                    "--strip takes a whole number, not ${2:-}"
                _ar_ex_extra+=("--strip-components=${2}")
                shift 2
                ;;
            --xattrs)
                _ar_ex_extra+=(--xattrs)
                shift
                ;;
            *)
                stealth::util::assert::fail "extract does not take ${1}"
                ;;
        esac
    done

    stealth::sys::io::fs::mkdir "${_ar_ex_dir}"

    # tar refuses a member that would land outside the directory, and says so
    # rather than writing it somewhere else.
    stealth::sys::cmd::run tar --extract --file "${_ar_ex_tar}" \
        --directory "${_ar_ex_dir}" --no-same-owner \
        "${_ar_ex_extra[@]}"

    stealth::util::log::debug 'unpacked %s into %s' "${_ar_ex_tar}" "${_ar_ex_dir}"
    return 0
}

#######################################
# Fills an array with the names an archive holds, in the order they are in it.
#
# Usage:
#   stealth::sys::io::archive::list members "${layer}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The archive
# Returns:
#   0 - Filled
#   Exits 1 when no output variable or no archive is given, or tar fails
#######################################
stealth::sys::io::archive::list() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no archive to read at ${2:-}"
    local -n _ar_list_out="${1}"

    local _ar_list_text
    stealth::sys::cmd::capture _ar_list_text tar --list --file "${2}"

    _ar_list_out=()
    if [[ -n "${_ar_list_text}" ]]; then
        mapfile -t _ar_list_out <<< "${_ar_list_text}"
    fi
    return 0
}

#######################################
# Reports whether an archive reads from end to end. Every member is unpacked
# to nowhere, so the cost is the cost of unpacking it. Listing an archive
# would be cheaper and would prove less: tar seeks past the contents of a
# member to reach the next header, and never finds out that the contents are
# not there.
#
# What this does not catch is an archive cut short inside its first record.
# tar reads a record of 10240 bytes at a time and pads a short one with
# zeroes, and a block of zeroes is how an archive ends. A digest of the whole
# file is what tells a small archive from the front of a large one.
#
# Usage:
#   if ! stealth::sys::io::archive::is_whole "${blob}"; then ...
#
# Arguments:
#   $1 (String) - The archive
# Returns:
#   0 - It reads through
#   1 - It does not, or there is no such file
#######################################
stealth::sys::io::archive::is_whole() {
    if [[ ! -f "${1:-}" ]]; then
        return 1
    fi

    if ! stealth::sys::cmd::try tar --extract --to-stdout --file "${1}" > /dev/null; then
        return 1
    fi
    return 0
}

#######################################
# Compresses a file, the same bytes every time from the same input.
#
# gzip writes the name and the time of the original into its header unless it
# is told not to, and that alone gives one tar two different digests. The
# others carry nothing of the kind.
#
# Usage:
#   stealth::sys::io::archive::compress "${tar}" "${tar}.zst" zstd
#
# Arguments:
#   $1 (String) - The file to compress
#   $2 (String) - Where to write it
#   $3 (String) - gzip, bzip2, xz or zstd. Default: zstd
# Globals:
#   _STEALTH_SYS_IO_ARCHIVE_PACK (Read)
# Returns:
#   0 - Written
#   Exits 1 when a file is missing, or the kind is not one of the four
#######################################
stealth::sys::io::archive::compress() {
    stealth::util::assert::is_file "${1:-}" "no file to compress at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'somewhere to write it is required'
    local -r _ar_pack_how="${3:-zstd}"

    if [[ ! -v _STEALTH_SYS_IO_ARCHIVE_PACK["${_ar_pack_how}"] ]]; then
        stealth::util::assert::fail \
            "nothing here compresses with ${_ar_pack_how}"
    fi

    local -a _ar_pack_cmd=()
    stealth::sys::io::archive::_words _ar_pack_cmd \
        "${_STEALTH_SYS_IO_ARCHIVE_PACK[${_ar_pack_how}]}"

    stealth::sys::io::fs::atomic "${2}" -- \
        stealth::sys::io::archive::_through "${1}" "${_ar_pack_cmd[@]}"
}

#######################################
# Decompresses a file, reading what it is compressed with from the file
# itself. A file that is not compressed is copied as it is.
#
# Usage:
#   stealth::sys::io::archive::decompress "${blob}" "${tar}"
#
# Arguments:
#   $1 (String) - The file to decompress
#   $2 (String) - Where to write it
# Globals:
#   _STEALTH_SYS_IO_ARCHIVE_UNPACK (Read)
# Returns:
#   0 - Written
#   Exits 1 when a file is missing
#######################################
stealth::sys::io::archive::decompress() {
    stealth::util::assert::is_file "${1:-}" "no file to decompress at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'somewhere to write it is required'

    local _ar_unpack_how
    stealth::sys::io::archive::kind _ar_unpack_how "${1}"

    if [[ "${_ar_unpack_how}" == 'none' ]]; then
        stealth::sys::io::fs::cp "${1}" "${2}"
        return 0
    fi

    local -a _ar_unpack_cmd=()
    stealth::sys::io::archive::_words _ar_unpack_cmd \
        "${_STEALTH_SYS_IO_ARCHIVE_UNPACK[${_ar_unpack_how}]}"

    stealth::sys::io::fs::atomic "${2}" -- \
        stealth::sys::io::archive::_through "${1}" "${_ar_unpack_cmd[@]}"
}

#######################################
# Runs a file through a command and leaves the result in the staged file that
# sys/io/fs is holding. compress and decompress both work this way, so
# neither ever leaves a half written file where the whole one goes.
#
# Usage:
#   stealth::sys::io::archive::_through "${staged}" "${source}" zstd -q -c
#
# Arguments:
#   $1 (String) - The staged file to write to
#   $2 (String) - The file to read
#   $@ (String) - The command and its arguments
# Returns:
#   0 - Written
#   1 - The command failed
#######################################
stealth::sys::io::archive::_through() {
    local -r _ar_thru_staged="${1}"
    local -r _ar_thru_source="${2}"
    shift 2

    "$@" < "${_ar_thru_source}" > "${_ar_thru_staged}"
}
