###############################################################################
# module: sys/io/fs
# layer: sys
# description: Changing a file without anyone ever seeing it half changed.
#
#              Every write goes the same way. A staged file is made in the
#              directory the target is in, the change is made to that, and the
#              staged file is renamed over the target. A rename within one
#              directory is one step as far as anything reading the file is
#              concerned: a reader sees the old file or the new one, never a
#              part of either, and never an empty one.
#
#              The staged file is made in the target's own directory because a
#              rename is only one step within a single filesystem. Staging in
#              the system temporary directory, as is tempting, turns the
#              rename into a copy the moment /tmp is a mount of its own.
#
#              What a target already is carries over to what replaces it: its
#              mode, its owner and its security context. A write that does not
#              say otherwise leaves all three as they were, so writing a line
#              to a file that nobody else may read does not open it up.
#
#              Atomic is not the same as durable. The rename means a reader
#              never sees half a file. It does not mean the bytes reached the
#              disk: after a power cut the directory entry can be there with
#              nothing behind it. Ask for that with --sync, or set io_sync,
#              where losing the write would matter more than the wait.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_IO_FS:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_IO_FS=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/cmd" "sys/io/tmp"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a file and a directory are made with when the caller does not say.
declare -gr _STEALTH_SYS_IO_FS_FILE_MODE='0644'
declare -gr _STEALTH_SYS_IO_FS_DIR_MODE='0755'

# =============================================================================
# CONFIGURATION
# =============================================================================

# Wait for a write to reach the disk before saying it is done. core/engine
# copies the io_sync setting here.
declare -gi STEALTH_IO_SYNC="${STEALTH_IO_SYNC:-0}"

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Reads the options a write takes, and leaves the rest in an array for the
# caller to go on with.
#
# Usage:
#   stealth::sys::io::fs::_take_options rest --mode 0600 -- "$@"
#
# Every value goes to a variable of the caller's own. They used to be
# variables of the module, and mkdir reads options too: a write that made a
# directory on its way had its own mode read a second time and lost.
#
# Arguments:
#   $1 (Nameref) - The output variable for the mode
#   $2 (Nameref) - The output variable for the owner
#   $3 (Nameref) - The output variable for whether to wait for the disk
#   $4 (Nameref) - The output array for what is not an option
#   $@ (String)  - --mode M, --owner O, --sync, then the rest
# Globals:
#   STEALTH_IO_SYNC (Read)
# Returns:
#   0 - Read
#   Exits 1 when an option is given without its value
#######################################
stealth::sys::io::fs::_take_options() {
    local -n _fs_opt_mode="${1}"
    local -n _fs_opt_owner="${2}"
    local -n _fs_opt_sync="${3}"
    local -n _fs_opt_rest="${4}"
    shift 4

    _fs_opt_mode=''
    _fs_opt_owner=''
    _fs_opt_sync="${STEALTH_IO_SYNC}"
    _fs_opt_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --mode)
                stealth::util::assert::not_empty "${2:-}" '--mode takes a mode'
                _fs_opt_mode="${2}"
                shift 2
                ;;
            --owner)
                stealth::util::assert::not_empty "${2:-}" '--owner takes an owner'
                _fs_opt_owner="${2}"
                shift 2
                ;;
            --sync)
                _fs_opt_sync=1
                shift
                ;;
            --)
                shift
                _fs_opt_rest+=("$@")
                return 0
                ;;
            *)
                _fs_opt_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

#######################################
# Waits for a path to reach the disk. A file is asked for its data, and a
# directory for the names it holds, which is what makes a rename survive a
# power cut.
#
# Usage:
#   stealth::sys::io::fs::_flush "${staged}"
#
# Arguments:
#   $1 (String)  - The path
#   $2 (Integer) - 1 to wait, 0 to return at once
# Returns:
#   0 - It is on the disk, or the wait is not asked for
#######################################
stealth::sys::io::fs::_flush() {
    if (( ${2} != 1 )); then
        return 0
    fi

    if ! stealth::sys::cmd::try sync --data "${1}"; then
        stealth::util::log::warn '%s may not have reached the disk' "${1}"
    fi
    return 0
}

#######################################
# Makes the staged file a write will be built in, in the directory the target
# is in. What the target already is carries over to it: its mode, its owner
# and its security context, copied without copying what is in it.
#
# A target that is not there yet gives a staged file only its maker may read,
# which the mode of the write then opens as far as it should go and no
# further.
#
# What is in the target comes along only when the caller asks. A function
# given to atomic edits what is already there, so it needs the content. A
# write replaces it, so copying it first would be work thrown away.
#
# Usage:
#   stealth::sys::io::fs::_stage staged /etc/hosts 0
#   stealth::sys::io::fs::_stage staged /etc/hosts 1
#
# Arguments:
#   $1 (Nameref) - The output variable for the staged path
#   $2 (String)  - The target
#   $3 (Integer) - 1 to bring the content along, 0 for the attributes alone
# Returns:
#   0 - Staged
#   Exits 1 when the staged file cannot be made
#######################################
stealth::sys::io::fs::_stage() {
    local -n _fs_stage_out="${1}"
    local -r _fs_stage_target="${2}"
    local _fs_stage_dir="${_fs_stage_target%/*}"

    if [[ "${_fs_stage_dir}" == "${_fs_stage_target}" ]]; then
        _fs_stage_dir='.'
    fi

    stealth::sys::io::fs::mkdir "${_fs_stage_dir}"
    stealth::sys::io::tmp::file_in _fs_stage_out "${_fs_stage_dir}"

    if [[ ! -f "${_fs_stage_target}" ]]; then
        return 0
    fi

    local -a _fs_stage_cp=(cp --preserve=all)
    if (( ${3} != 1 )); then
        _fs_stage_cp+=(--attributes-only)
    fi

    if ! stealth::sys::cmd::try "${_fs_stage_cp[@]}" \
            "${_fs_stage_target}" "${_fs_stage_out}"; then
        stealth::util::log::warn 'what %s is could not be carried over' \
            "${_fs_stage_target}"
        stealth::sys::io::tmp::remove "${_fs_stage_out}"
        return 1
    fi
    return 0
}

#######################################
# Puts a staged file in place of the target, in one step. A staged file that
# holds what the target already holds is dropped instead, so a write that
# changes nothing leaves the time of the file alone and nothing downstream
# rebuilds.
#
# Usage:
#   stealth::sys::io::fs::_commit /etc/hosts "${staged}"
#
# Arguments:
#   $1 (String)  - The target
#   $2 (String)  - The staged file
#   $3 (String)  - The mode to set, or empty to keep what the target had
#   $4 (String)  - The owner to set, or empty to keep what the target had
#   $5 (Integer) - 1 to wait for the disk
# Globals:
#   _STEALTH_SYS_IO_FS_FILE_MODE (Read)
# Returns:
#   0 - In place, or it held nothing new
#   1 - The rename did not happen, and the target is as it was
#######################################
stealth::sys::io::fs::_commit() {
    local -r _fs_com_target="${1}"
    local -r _fs_com_staged="${2}"
    local -r _fs_com_mode="${3}"
    local -r _fs_com_owner="${4}"
    local -ri _fs_com_sync="${5}"

    if [[ -n "${_fs_com_mode}" ]]; then
        stealth::sys::cmd::run chmod "${_fs_com_mode}" "${_fs_com_staged}"
    elif [[ ! -e "${_fs_com_target}" ]]; then
        stealth::sys::cmd::run chmod "${_STEALTH_SYS_IO_FS_FILE_MODE}" "${_fs_com_staged}"
    fi

    if [[ -n "${_fs_com_owner}" ]]; then
        stealth::sys::cmd::run chown "${_fs_com_owner}" "${_fs_com_staged}"
    fi

    if ! stealth::sys::io::fs::differs "${_fs_com_target}" "${_fs_com_staged}"; then
        stealth::util::log::debug '%s already holds this' "${_fs_com_target}"
        stealth::sys::io::tmp::remove "${_fs_com_staged}"

        # The bytes are the same and the mode may not be. Dropping the staged
        # file here would drop the mode that was asked for with it, and the
        # caller would be told the write succeeded.
        if [[ -n "${_fs_com_mode}" ]]; then
            stealth::sys::cmd::run chmod "${_fs_com_mode}" "${_fs_com_target}"
        fi
        if [[ -n "${_fs_com_owner}" ]]; then
            stealth::sys::cmd::run chown "${_fs_com_owner}" "${_fs_com_target}"
        fi
        return 0
    fi

    stealth::sys::io::fs::_flush "${_fs_com_staged}" "${_fs_com_sync}"

    # A target that is new takes the context its directory gives it, and one
    # that is already there keeps the context carried over by the staging.
    # -T names the target exactly. Without it a target that is a directory is
    # not replaced at all: the staged file is moved inside it under the name
    # it was staged with, and the caller is told the write succeeded.
    local -a _fs_com_mv=(mv -T -f)
    if [[ ! -e "${_fs_com_target}" ]]; then
        _fs_com_mv=(mv -Z -T -f)
    fi

    if ! stealth::sys::cmd::try "${_fs_com_mv[@]}" \
            "${_fs_com_staged}" "${_fs_com_target}"; then
        stealth::util::log::warn '%s could not be put in place' "${_fs_com_target}"
        stealth::sys::io::tmp::remove "${_fs_com_staged}"
        return 1
    fi

    stealth::sys::io::tmp::forget "${_fs_com_staged}"

    local _fs_com_dir="${_fs_com_target%/*}"
    stealth::sys::io::fs::_flush "${_fs_com_dir:-/}" "${_fs_com_sync}"

    stealth::util::log::debug 'wrote %s' "${_fs_com_target}"
    return 0
}

#######################################
# Writes a line to a staged file, for line to build on.
#
# Usage:
#   stealth::sys::io::fs::_put "${staged}" 'the contents'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - What to write
# Returns:
#   0 - Written
#######################################
stealth::sys::io::fs::_put() {
    printf '%s\n' "${2}" > "${1}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether two files hold different things. A file that is not there is
# different from one that is.
#
# Usage:
#   if stealth::sys::io::fs::differs /etc/hosts "${staged}"; then ...
#
# Arguments:
#   $1 (String) - One file
#   $2 (String) - The other
# Returns:
#   0 - They differ, or one of them is not there
#   1 - They hold the same thing
#######################################
stealth::sys::io::fs::differs() {
    if [[ ! -f "${1:-}" || ! -f "${2:-}" ]]; then
        return 0
    fi

    ! stealth::sys::cmd::silent cmp -s "${1}" "${2}"
}

#######################################
# Makes a directory and the ones above it. A directory that is already there
# is left as it is, mode and all.
#
# Usage:
#   stealth::sys::io::fs::mkdir /var/lib/stealth
#   stealth::sys::io::fs::mkdir /var/lib/stealth --mode 0700
#
# Arguments:
#   $1 (String) - The directory
#   $@ (String) - --mode M, --owner O
# Globals:
#   _STEALTH_SYS_IO_FS_DIR_MODE (Read)
# Returns:
#   0 - It is there
#   Exits 1 when no directory is given, or it cannot be made
#######################################
stealth::sys::io::fs::mkdir() {
    local _fs_mkdir_mode='' _fs_mkdir_owner=''
    local -i _fs_mkdir_sync=0
    local -a _fs_mkdir_rest=()
    stealth::sys::io::fs::_take_options _fs_mkdir_mode _fs_mkdir_owner \
        _fs_mkdir_sync _fs_mkdir_rest "$@"
    stealth::util::assert::not_empty "${_fs_mkdir_rest[0]:-}" 'a directory is required'

    local -r _fs_mkdir_path="${_fs_mkdir_rest[0]}"
    if [[ -d "${_fs_mkdir_path}" ]]; then
        return 0
    fi

    stealth::sys::cmd::run mkdir -p "${_fs_mkdir_path}"
    stealth::sys::cmd::run chmod \
        "${_fs_mkdir_mode:-${_STEALTH_SYS_IO_FS_DIR_MODE}}" "${_fs_mkdir_path}"

    if [[ -n "${_fs_mkdir_owner}" ]]; then
        stealth::sys::cmd::run chown "${_fs_mkdir_owner}" "${_fs_mkdir_path}"
    fi
    return 0
}

#######################################
# Changes a file through a function of the caller's, without anyone seeing it
# half changed. The function is given the staged file to work on, and what it
# leaves there is what the target becomes.
#
# A function that fails leaves the target as it was.
#
# Usage:
#   sort_it() { sort -u "${1}" -o "${1}"; }
#   stealth::sys::io::fs::atomic /etc/hosts sort_it
#   stealth::sys::io::fs::atomic /etc/hosts --mode 0600 -- sort_it
#
# Arguments:
#   $1 (String) - The target
#   $@ (String) - --mode M, --owner O, --sync, then the function and its
#                 arguments after the staged file
# Returns:
#   0 - The target holds what the function left
#   1 - The function failed, or the rename did not happen
#   Exits 1 when no target or no function is given
#######################################
stealth::sys::io::fs::atomic() {
    local _fs_atom_mode='' _fs_atom_owner=''
    local -i _fs_atom_sync=0
    local -a _fs_atom_rest=()
    stealth::sys::io::fs::_take_options _fs_atom_mode _fs_atom_owner \
        _fs_atom_sync _fs_atom_rest "$@"
    stealth::util::assert::not_empty "${_fs_atom_rest[0]:-}" 'a target is required'
    stealth::util::assert::not_empty "${_fs_atom_rest[1]:-}" 'a function is required'

    local -r _fs_atom_target="${_fs_atom_rest[0]}"
    local -r _fs_atom_fn="${_fs_atom_rest[1]}"
    local _fs_atom_staged

    if ! stealth::sys::io::fs::_stage _fs_atom_staged "${_fs_atom_target}" 1; then
        return 1
    fi

    if ! "${_fs_atom_fn}" "${_fs_atom_staged}" "${_fs_atom_rest[@]:2}"; then
        stealth::util::log::warn '%s left %s as it was' \
            "${_fs_atom_fn}" "${_fs_atom_target}"
        stealth::sys::io::tmp::remove "${_fs_atom_staged}"
        return 1
    fi

    stealth::sys::io::fs::_commit "${_fs_atom_target}" "${_fs_atom_staged}" \
        "${_fs_atom_mode}" "${_fs_atom_owner}" "${_fs_atom_sync}"
}

#######################################
# Writes text to a file, all of it or none of it. A file that already holds
# this text is left alone, time of change and all.
#
# Usage:
#   stealth::sys::io::fs::write /etc/hostname 'buildhost'
#   stealth::sys::io::fs::write /root/.netrc "${secret}" --mode 0600
#   stealth::sys::io::fs::write "${store}/index.json" "${json}" --sync
#
# Arguments:
#   $1 (String) - The target
#   $2 (String) - The text, which a line break is added to
#   $@ (String) - --mode M, --owner O, --sync
# Returns:
#   0 - The target holds the text
#   1 - It could not be put in place
#   Exits 1 when no target is given
#######################################
stealth::sys::io::fs::write() {
    local _fs_write_mode='' _fs_write_owner=''
    local -i _fs_write_sync=0
    local -a _fs_write_rest=()
    stealth::sys::io::fs::_take_options _fs_write_mode _fs_write_owner \
        _fs_write_sync _fs_write_rest "$@"
    stealth::util::assert::not_empty "${_fs_write_rest[0]:-}" 'a target is required'

    local _fs_write_staged
    if ! stealth::sys::io::fs::_stage _fs_write_staged "${_fs_write_rest[0]}" 0; then
        return 1
    fi
    stealth::sys::io::fs::_put "${_fs_write_staged}" "${_fs_write_rest[1]:-}"

    stealth::sys::io::fs::_commit "${_fs_write_rest[0]}" "${_fs_write_staged}" \
        "${_fs_write_mode}" "${_fs_write_owner}" "${_fs_write_sync}"
}

#######################################
# Reads a whole file into a variable, with the line breaks at the end taken
# off.
#
# Usage:
#   stealth::sys::io::fs::read hostname /etc/hostname
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
# Returns:
#   0 - Read
#   1 - There is no such file, or it cannot be read
#   Exits 1 when no output variable or no file is given
#######################################
stealth::sys::io::fs::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a file is required'
    local -n _fs_read_out="${1}"

    if [[ ! -r "${2}" || ! -f "${2}" ]]; then
        stealth::util::log::debug 'nothing to read at %s' "${2}"
        _fs_read_out=''
        return 1
    fi

    _fs_read_out="$(< "${2}")"
    return 0
}

#######################################
# Makes sure a file holds a line, without anyone seeing it half changed. A
# line that is already there is left where it is. Giving --match replaces the
# first line that matches instead of adding one, which is how a setting is
# changed rather than repeated.
#
# The target comes first, as it does for every other function here. The old
# module took it in a different place from mkdir and touch, and callers got it
# the wrong way round.
#
# Usage:
#   stealth::sys::io::fs::line /etc/fstab "${entry}"
#   stealth::sys::io::fs::line /etc/ssh/sshd_config 'PermitRootLogin no' \
#       --match '^#?PermitRootLogin'
#
# Arguments:
#   $1 (String) - The target
#   $2 (String) - The line
#   $@ (String) - --match REGEX, --mode M, --owner O, --sync
# Returns:
#   0 - The target holds the line
#   1 - It could not be put in place
#   Exits 1 when no target or no line is given
#######################################
stealth::sys::io::fs::line() {
    local _fs_line_match=''
    local -a _fs_line_args=()

    while (( $# > 0 )); do
        if [[ "${1}" == '--match' ]]; then
            stealth::util::assert::not_empty "${2:-}" '--match takes an expression'
            _fs_line_match="${2}"
            shift 2
        else
            _fs_line_args+=("${1}")
            shift
        fi
    done

    local _fs_line_mode='' _fs_line_owner=''
    local -i _fs_line_sync=0
    local -a _fs_line_rest=()
    stealth::sys::io::fs::_take_options _fs_line_mode _fs_line_owner \
        _fs_line_sync _fs_line_rest "${_fs_line_args[@]}"
    stealth::util::assert::not_empty "${_fs_line_rest[0]:-}" 'a target is required'
    stealth::util::assert::not_empty "${_fs_line_rest[1]:-}" 'a line is required'

    local -a _fs_line_opts=()
    if [[ -n "${_fs_line_mode}" ]]; then
        _fs_line_opts+=(--mode "${_fs_line_mode}")
    fi
    if [[ -n "${_fs_line_owner}" ]]; then
        _fs_line_opts+=(--owner "${_fs_line_owner}")
    fi
    if (( _fs_line_sync == 1 )); then
        _fs_line_opts+=(--sync)
    fi

    stealth::sys::io::fs::atomic "${_fs_line_rest[0]}" "${_fs_line_opts[@]}" -- \
        stealth::sys::io::fs::_edit_line "${_fs_line_rest[1]}" "${_fs_line_match}"
}

#######################################
# Puts a line in a staged file: in place of the first line that matches when
# there is an expression, and at the end otherwise. A line that is already
# there, word for word, is left where it is.
#
# Usage:
#   stealth::sys::io::fs::_edit_line "${staged}" 'PermitRootLogin no' '^PermitRoot'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The line
#   $3 (String) - The expression to replace, or empty to add at the end
# Returns:
#   0 - It is in there
#######################################
stealth::sys::io::fs::_edit_line() {
    local -a _fs_el_lines=()
    if [[ -s "${1}" ]]; then
        mapfile -t _fs_el_lines < "${1}"
    fi

    local -i _fs_el_i
    local -i _fs_el_done=0
    for (( _fs_el_i = 0; _fs_el_i < ${#_fs_el_lines[@]}; _fs_el_i++ )); do
        if [[ "${_fs_el_lines[_fs_el_i]}" == "${2}" ]]; then
            return 0
        fi
        if [[ -n "${3}" && _fs_el_done -eq 0 &&
              "${_fs_el_lines[_fs_el_i]}" =~ ${3} ]]; then
            _fs_el_lines[_fs_el_i]="${2}"
            _fs_el_done=1
        fi
    done

    if (( _fs_el_done == 0 )); then
        _fs_el_lines+=("${2}")
    fi

    printf '%s\n' "${_fs_el_lines[@]}" > "${1}"
    return 0
}

#######################################
# Copies a file, without anyone seeing the destination half written. What the
# destination already is carries over unless the caller says otherwise.
#
# Usage:
#   stealth::sys::io::fs::cp "${source}" /usr/local/bin/stealth --mode 0755
#
# Arguments:
#   $1 (String) - The file to copy
#   $2 (String) - Where it goes
#   $@ (String) - --mode M, --owner O, --sync
# Returns:
#   0 - The destination holds the file
#   1 - It could not be put in place
#   Exits 1 when the source is not a file, or no destination is given
#######################################
stealth::sys::io::fs::cp() {
    local _fs_cp_mode='' _fs_cp_owner=''
    local -i _fs_cp_sync=0
    local -a _fs_cp_rest=()
    stealth::sys::io::fs::_take_options _fs_cp_mode _fs_cp_owner \
        _fs_cp_sync _fs_cp_rest "$@"
    stealth::util::assert::is_file "${_fs_cp_rest[0]:-}" \
        "no file to copy at ${_fs_cp_rest[0]:-}"
    stealth::util::assert::not_empty "${_fs_cp_rest[1]:-}" 'a destination is required'

    local _fs_cp_staged
    if ! stealth::sys::io::fs::_stage _fs_cp_staged "${_fs_cp_rest[1]}" 0; then
        return 1
    fi
    stealth::sys::cmd::run cp -- "${_fs_cp_rest[0]}" "${_fs_cp_staged}"

    stealth::sys::io::fs::_commit "${_fs_cp_rest[1]}" "${_fs_cp_staged}" \
        "${_fs_cp_mode}" "${_fs_cp_owner}" "${_fs_cp_sync}"
}

#######################################
# Makes sure a file is there, without changing one that already is.
#
# Usage:
#   stealth::sys::io::fs::touch /var/log/stealth/stealth.log --mode 0640
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - --mode M, --owner O
# Returns:
#   0 - It is there
#   Exits 1 when no file is given
#######################################
stealth::sys::io::fs::touch() {
    local _fs_touch_mode='' _fs_touch_owner=''
    local -i _fs_touch_sync=0
    local -a _fs_touch_rest=()
    stealth::sys::io::fs::_take_options _fs_touch_mode _fs_touch_owner \
        _fs_touch_sync _fs_touch_rest "$@"
    stealth::util::assert::not_empty "${_fs_touch_rest[0]:-}" 'a file is required'

    if [[ -e "${_fs_touch_rest[0]}" ]]; then
        return 0
    fi

    # _stage only fails when it has a target to carry attributes over from,
    # and there is none here: anything already at the path returned above.
    local _fs_touch_staged
    stealth::sys::io::fs::_stage _fs_touch_staged "${_fs_touch_rest[0]}" 0

    stealth::sys::io::fs::_commit "${_fs_touch_rest[0]}" "${_fs_touch_staged}" \
        "${_fs_touch_mode}" "${_fs_touch_owner}" "${_fs_touch_sync}"
}

#######################################
# Removes paths, and what is inside a directory along with it. A path that is
# not there is no trouble.
#
# The path has to be one that may be removed: absolute, at least two levels
# below the root, and not reached through a parent component. A variable that
# expanded to nothing therefore cannot take out a directory of the system.
#
# Usage:
#   stealth::sys::io::fs::rm "${root}/var/cache"
#
# Arguments:
#   $@ (String) - The paths
# Returns:
#   0 - They are gone
#   Exits 1 when no path is given, or one of them may not be removed
#######################################
stealth::sys::io::fs::rm() {
    stealth::util::assert::not_empty "${1:-}" 'a path is required'

    local _fs_rm_path
    for _fs_rm_path in "$@"; do
        stealth::util::assert::is_safe_path "${_fs_rm_path}"
    done

    stealth::sys::cmd::run rm -rf -- "$@"
    return 0
}

#######################################
# Makes a symbolic link, replacing one that is already there. The link is put
# in place with a rename, so nothing ever sees the name missing.
#
# Usage:
#   stealth::sys::io::fs::link /usr/lib/stealth /opt/stealth/lib
#
# Arguments:
#   $1 (String) - What the link points at
#   $2 (String) - The link
# Returns:
#   0 - The link is there
#   1 - It could not be put in place
#   Exits 1 when either is not given
#######################################
stealth::sys::io::fs::link() {
    stealth::util::assert::not_empty "${1:-}" 'something for the link to point at is required'
    stealth::util::assert::not_empty "${2:-}" 'a link is required'

    local _fs_link_dir="${2%/*}"
    if [[ "${_fs_link_dir}" == "${2}" ]]; then
        _fs_link_dir='.'
    fi
    stealth::sys::io::fs::mkdir "${_fs_link_dir}"

    local _fs_link_points_at=''
    if [[ -L "${2}" ]]; then
        _fs_link_points_at="$(readlink -- "${2}")"
    fi
    if [[ "${_fs_link_points_at}" == "${1}" && -L "${2}" ]]; then
        return 0
    fi

    local _fs_link_staged
    stealth::sys::io::tmp::file_in _fs_link_staged "${_fs_link_dir}"
    stealth::sys::io::tmp::remove "${_fs_link_staged}"

    stealth::sys::cmd::run ln -s -- "${1}" "${_fs_link_staged}"

    if ! stealth::sys::cmd::try mv -f -T "${_fs_link_staged}" "${2}"; then
        stealth::util::log::warn 'the link %s could not be put in place' "${2}"
        stealth::sys::io::tmp::remove "${_fs_link_staged}"
        return 1
    fi
    return 0
}

#######################################
# Reports whether a file is there and holds nothing.
#
# Usage:
#   if stealth::sys::io::fs::is_empty "${log}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - It is there and holds nothing
#   1 - It holds something, or is not there
#######################################
stealth::sys::io::fs::is_empty() {
    [[ -f "${1:-}" && ! -s "${1:-}" ]]
}
