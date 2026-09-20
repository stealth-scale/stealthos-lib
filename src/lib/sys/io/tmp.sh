###############################################################################
# module: sys/io/tmp
# layer: sys
# description: Temporary files and directories that are removed when the run
#              ends, however it ends.
#
#              Everything made here is written down, and cleanup removes what
#              is left. core/engine calls cleanup at the end of a run, because
#              it looks for a cleanup function in every library it loaded. A
#              run that is killed still unwinds through the trap stack, so the
#              only way to leave something behind is to be killed with a
#              signal no handler can catch.
#
#              A caller that wants a file to outlive the run says so with
#              forget, which leaves the file where it is.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_IO_TMP:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_IO_TMP=1

stealth::util::import "util/assert" "util/log"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a temporary file is called when the caller does not say. The X's are
# what mktemp replaces, and there have to be at least six of them.
declare -gr _STEALTH_SYS_IO_TMP_TEMPLATE='stealth.XXXXXXXX'

# =============================================================================
# STATE
# =============================================================================

# Path -> 1, for everything made here that is still to be removed.
declare -gA _STEALTH_SYS_IO_TMP_MADE=()

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Makes a temporary file or directory and writes it down.
#
# Usage:
#   stealth::sys::io::tmp::_make path --tmpdir=/srv 'stealth.XXXXXXXX' ''
#
# Arguments:
#   $1 (Nameref) - The output variable for the path
#   $2 (String)  - Where to make it, as mktemp takes it
#   $3 (String)  - The template
#   $4 (String)  - -d to make a directory, empty to make a file
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Write)
# Returns:
#   0 - Made
#   Exits 1 when nothing could be made
#######################################
stealth::sys::io::tmp::_make() {
    local -n _tmp_make_out="${1}"
    local -a _tmp_make_args=("${2}" "${3}")

    if [[ -n "${4}" ]]; then
        _tmp_make_args+=("${4}")
    fi

    local _tmp_make_path
    if ! _tmp_make_path="$(mktemp "${_tmp_make_args[@]}")"; then
        stealth::util::log::error 'nothing temporary could be made from %s' "${3}"
    fi

    _STEALTH_SYS_IO_TMP_MADE["${_tmp_make_path}"]=1
    _tmp_make_out="${_tmp_make_path}"

    stealth::util::log::trace 'made %s' "${_tmp_make_path}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Makes a temporary file where the system keeps them, and writes it down so
# the end of the run removes it.
#
# Usage:
#   stealth::sys::io::tmp::file manifest
#   stealth::sys::io::tmp::file layer 'layer.XXXXXXXX.tar'
#
# Arguments:
#   $1 (Nameref) - The output variable for the path
#   $2 (String)  - The template. Default: stealth.XXXXXXXX
# Globals:
#   TMPDIR (Read)
#   _STEALTH_SYS_IO_TMP_TEMPLATE (Read)
# Returns:
#   0 - Made
#   Exits 1 when no output variable is given, or nothing could be made
#######################################
stealth::sys::io::tmp::file() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    stealth::sys::io::tmp::_make "${1}" '-t' \
        "${2:-${_STEALTH_SYS_IO_TMP_TEMPLATE}}" ''
    return 0
}

#######################################
# Makes a temporary file in a directory of the caller's choosing, and writes
# it down. sys/io/fs stages a write in the directory it is writing to, because
# a rename is only atomic within one filesystem.
#
# Usage:
#   stealth::sys::io::tmp::file_in staged /etc
#
# Arguments:
#   $1 (Nameref) - The output variable for the path
#   $2 (String)  - The directory
#   $3 (String)  - The template. Default: stealth.XXXXXXXX
# Globals:
#   _STEALTH_SYS_IO_TMP_TEMPLATE (Read)
# Returns:
#   0 - Made
#   Exits 1 when no output variable or no directory is given, or nothing could
#   be made
#######################################
stealth::sys::io::tmp::file_in() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_dir "${2:-}" "no directory to make a file in at ${2:-}"

    stealth::sys::io::tmp::_make "${1}" "--tmpdir=${2}" \
        "${3:-${_STEALTH_SYS_IO_TMP_TEMPLATE}}" ''
    return 0
}

#######################################
# Makes a temporary directory where the system keeps them, and writes it down.
# Removing it at the end takes what is inside with it.
#
# Usage:
#   stealth::sys::io::tmp::dir workspace
#
# Arguments:
#   $1 (Nameref) - The output variable for the path
#   $2 (String)  - The template. Default: stealth.XXXXXXXX
# Globals:
#   TMPDIR (Read)
#   _STEALTH_SYS_IO_TMP_TEMPLATE (Read)
# Returns:
#   0 - Made
#   Exits 1 when no output variable is given, or nothing could be made
#######################################
stealth::sys::io::tmp::dir() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'

    stealth::sys::io::tmp::_make "${1}" '-t' \
        "${2:-${_STEALTH_SYS_IO_TMP_TEMPLATE}}" '-d'
    return 0
}

#######################################
# Writes down something the caller made itself, so the end of the run removes
# it along with everything else.
#
# Usage:
#   stealth::sys::io::tmp::keep "${mountpoint}"
#
# Arguments:
#   $1 (String) - The path
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Write)
# Returns:
#   0 - Written down
#   Exits 1 when no path is given
#######################################
stealth::sys::io::tmp::keep() {
    stealth::util::assert::not_empty "${1:-}" 'a path is required'

    _STEALTH_SYS_IO_TMP_MADE["${1}"]=1
    return 0
}

#######################################
# Takes a path off the list without removing it, for something that is to
# outlive the run. sys/io/fs does this to a staged file the moment it becomes
# the file it was staging.
#
# Usage:
#   stealth::sys::io::tmp::forget "${staged}"
#
# Arguments:
#   $1 (String) - The path
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Write)
# Returns:
#   0 - Taken off, or it was never on
#   Exits 1 when no path is given
#######################################
stealth::sys::io::tmp::forget() {
    stealth::util::assert::not_empty "${1:-}" 'a path is required'

    unset "_STEALTH_SYS_IO_TMP_MADE[${1}]"
    return 0
}

#######################################
# Removes paths now and takes them off the list. A path that is already gone
# is no trouble.
#
# Usage:
#   stealth::sys::io::tmp::remove "${staged}"
#
# Arguments:
#   $@ (String) - The paths
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Write)
# Returns:
#   0 - Removed
#   Exits 1 when no path is given
#######################################
stealth::sys::io::tmp::remove() {
    stealth::util::assert::not_empty "${1:-}" 'a path is required'

    local _tmp_rm_path
    for _tmp_rm_path in "$@"; do
        rm -rf -- "${_tmp_rm_path}"
        unset "_STEALTH_SYS_IO_TMP_MADE[${_tmp_rm_path}]"
    done
    return 0
}

#######################################
# Reports whether a path is on the list.
#
# Usage:
#   if stealth::sys::io::tmp::is_kept "${path}"; then ...
#
# Arguments:
#   $1 (String) - The path
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Read)
# Returns:
#   0 - On the list
#   1 - Not on it
#######################################
stealth::sys::io::tmp::is_kept() {
    [[ -v _STEALTH_SYS_IO_TMP_MADE["${1:-}"] ]]
}

#######################################
# Removes everything still on the list. core/engine registers this to run at
# the end of a run, by looking for a cleanup function in each library it
# loaded, so nothing here has to know about core.
#
# Usage:
#   stealth::sys::io::tmp::cleanup
#
# Arguments:
#   None
# Globals:
#   _STEALTH_SYS_IO_TMP_MADE (Read/Write)
# Returns:
#   0 - Removed
#######################################
stealth::sys::io::tmp::cleanup() {
    local -ri _tmp_clean_count="${#_STEALTH_SYS_IO_TMP_MADE[@]}"

    if (( _tmp_clean_count == 0 )); then
        return 0
    fi

    stealth::util::log::debug 'removing %d temporary paths' "${_tmp_clean_count}"

    local _tmp_clean_path
    for _tmp_clean_path in "${!_STEALTH_SYS_IO_TMP_MADE[@]}"; do
        rm -rf -- "${_tmp_clean_path}"
    done

    _STEALTH_SYS_IO_TMP_MADE=()
    return 0
}
