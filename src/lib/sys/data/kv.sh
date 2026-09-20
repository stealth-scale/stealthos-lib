###############################################################################
# module: sys/data/kv
# layer: sys
# description: Files of KEY=VALUE lines, the shape /etc/os-release and
#              everything under /etc/sysconfig is written in.
#
#              Nothing here forks. A file of this shape is read and written by
#              bash alone, and the sed the obvious version reaches for is
#              where the bugs are: a value holding an ampersand or a vertical
#              bar is a replacement expression, not a value, and the file
#              comes back changed in ways nobody asked for.
#
#              A value is quoted on the way out when it needs to be, and
#              unquoted on the way in. These files are read by shells, so a
#              value with a space in it that goes in bare comes back as two
#              words, or as a command.
#
#              Comments, blank lines and the order of the keys survive a
#              change. A configuration file people edit is one they expect to
#              recognise afterwards.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_DATA_KV:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_DATA_KV=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a key is allowed to be, which is what a shell accepts as a name.
declare -gr _STEALTH_SYS_DATA_KV_KEY_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# A value made of these characters alone goes in without quotes. Anything
# else is quoted, because a shell reading the file would otherwise split it,
# expand it, or run it.
declare -gr _STEALTH_SYS_DATA_KV_BARE_RE='^[A-Za-z0-9_./:@%+-]*$'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Takes a line apart into the key it sets and the value it sets it to. A line
# that sets nothing is not one of these.
#
# Usage:
#   stealth::sys::data::kv::_split key value 'export NAME="Fedora Linux"'
#
# Arguments:
#   $1 (Nameref) - The output variable for the key
#   $2 (Nameref) - The output variable for the value
#   $3 (String)  - The line
# Globals:
#   _STEALTH_SYS_DATA_KV_KEY_RE (Read)
# Returns:
#   0 - It sets a key
#   1 - It is a comment, blank, or something else
#######################################
stealth::sys::data::kv::_split() {
    local -n _kv_split_key="${1}"
    local -n _kv_split_value="${2}"

    _kv_split_key=''
    _kv_split_value=''

    local _kv_split_line
    stealth::util::text::trim _kv_split_line "${3}"

    if [[ -z "${_kv_split_line}" || "${_kv_split_line}" == '#'* ]]; then
        return 1
    fi
    if [[ "${_kv_split_line}" != *'='* ]]; then
        return 1
    fi

    _kv_split_key="${_kv_split_line%%=*}"
    _kv_split_value="${_kv_split_line#*=}"

    _kv_split_key="${_kv_split_key#export }"
    stealth::util::text::trim _kv_split_key "${_kv_split_key}"

    if [[ ! "${_kv_split_key}" =~ ${_STEALTH_SYS_DATA_KV_KEY_RE} ]]; then
        return 1
    fi

    stealth::sys::data::kv::_unquote _kv_split_value "${_kv_split_value}"
    return 0
}

#######################################
# Takes the quotes off a value that has them. A value in double quotes has
# its backslash escapes undone, the way a shell reading the file would.
#
# Usage:
#   stealth::sys::data::kv::_unquote value '"Fedora Linux"'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value as it is written in the file
# Returns:
#   0 - Taken off, or there were none
#######################################
stealth::sys::data::kv::_unquote() {
    local -n _kv_unq_out="${1}"

    local _kv_unq_value
    stealth::util::text::trim _kv_unq_value "${2}"

    if [[ ${#_kv_unq_value} -ge 2 && "${_kv_unq_value}" == \'*\' ]]; then
        _kv_unq_out="${_kv_unq_value:1:${#_kv_unq_value}-2}"
        return 0
    fi

    if [[ ${#_kv_unq_value} -ge 2 && "${_kv_unq_value}" == \"*\" ]]; then
        _kv_unq_out="${_kv_unq_value:1:${#_kv_unq_value}-2}"
        _kv_unq_out="${_kv_unq_out//\\\"/\"}"
        _kv_unq_out="${_kv_unq_out//\\\$/\$}"
        _kv_unq_out="${_kv_unq_out//\\\`/\`}"
        _kv_unq_out="${_kv_unq_out//\\\\/\\}"
        return 0
    fi

    _kv_unq_out="${_kv_unq_value}"
    return 0
}

#######################################
# Writes a value the way it has to be written for a shell to read it back
# unchanged. A value of ordinary characters goes in bare, and anything else
# goes in double quotes with the four characters a shell still reads inside
# them escaped.
#
# Usage:
#   stealth::sys::data::kv::_quote written 'Fedora Linux 44'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
# Globals:
#   _STEALTH_SYS_DATA_KV_BARE_RE (Read)
# Returns:
#   0 - Written
#######################################
stealth::sys::data::kv::_quote() {
    local -n _kv_q_out="${1}"

    if [[ "${2}" =~ ${_STEALTH_SYS_DATA_KV_BARE_RE} ]]; then
        _kv_q_out="${2}"
        return 0
    fi

    local _kv_q_body="${2}"
    _kv_q_body="${_kv_q_body//\\/\\\\}"
    _kv_q_body="${_kv_q_body//\"/\\\"}"
    _kv_q_body="${_kv_q_body//\$/\\\$}"
    _kv_q_body="${_kv_q_body//\`/\\\`}"

    _kv_q_out="\"${_kv_q_body}\""
    return 0
}

#######################################
# Refuses a key that is not a key and a value that cannot be written on one
# line.
#
# Usage:
#   stealth::sys::data::kv::_check 'NAME' "${value}"
#
# Arguments:
#   $1 (String) - The key
#   $2 (String) - The value
# Globals:
#   _STEALTH_SYS_DATA_KV_KEY_RE (Read)
# Returns:
#   0 - Both are usable
#   Exits 1 when either is not
#######################################
stealth::sys::data::kv::_check() {
    if [[ ! "${1}" =~ ${_STEALTH_SYS_DATA_KV_KEY_RE} ]]; then
        stealth::util::assert::fail "${1} is not a key a shell can read"
    fi
    if [[ "${2}" == *$'\n'* ]]; then
        stealth::util::assert::fail \
            "the value of ${1} has a line break in it, which this file cannot hold"
    fi
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the value of a key. The last line setting it wins, which is what a
# shell reading the file would end up with.
#
# Usage:
#   stealth::sys::data::kv::read name /etc/os-release ID
#   stealth::sys::data::kv::read name "${file}" ID 'unknown'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The key
#   $4 (String)  - What to give back when the key is not there
# Returns:
#   0 - Found, or the default was used
#   1 - Not there and no default was given
#   Exits 1 when an output variable, a file or a key is missing
#######################################
stealth::sys::data::kv::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    stealth::util::assert::not_empty "${3:-}" 'a key is required'
    local -n _kv_read_out="${1}"

    local _kv_read_line _kv_read_key _kv_read_value
    local -i _kv_read_found=0

    while IFS= read -r _kv_read_line || [[ -n "${_kv_read_line}" ]]; do
        if ! stealth::sys::data::kv::_split _kv_read_key _kv_read_value \
            "${_kv_read_line}"; then
            continue
        fi
        if [[ "${_kv_read_key}" == "${3}" ]]; then
            _kv_read_out="${_kv_read_value}"
            _kv_read_found=1
        fi
    done < "${2}"

    if (( _kv_read_found == 1 )); then
        return 0
    fi

    _kv_read_out="${4:-}"
    if (( $# >= 4 )); then
        return 0
    fi
    return 1
}

#######################################
# Reports whether a file sets a key.
#
# Usage:
#   if stealth::sys::data::kv::has /etc/os-release VARIANT_ID; then ...
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The key
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::kv::has() {
    local _kv_has_value
    stealth::sys::data::kv::read _kv_has_value "${1:-}" "${2:-}"
}

#######################################
# Fills an array with the keys a file sets, in the order they appear. A key
# set more than once appears once.
#
# Usage:
#   stealth::sys::data::kv::keys names /etc/os-release
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
# Returns:
#   0 - Filled
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::kv::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _kv_keys_out="${1}"

    _kv_keys_out=()
    local -A _kv_keys_seen=()
    local _kv_keys_line _kv_keys_key _kv_keys_value

    while IFS= read -r _kv_keys_line || [[ -n "${_kv_keys_line}" ]]; do
        if ! stealth::sys::data::kv::_split _kv_keys_key _kv_keys_value \
            "${_kv_keys_line}"; then
            continue
        fi
        if [[ -v _kv_keys_seen["${_kv_keys_key}"] ]]; then
            continue
        fi
        _kv_keys_seen["${_kv_keys_key}"]=1
        _kv_keys_out+=("${_kv_keys_key}")
    done < "${2}"
    return 0
}

#######################################
# Fills an associative array with everything a file sets, which is one pass
# over the file rather than one pass for every key the caller wants.
#
# Usage:
#   local -A release=()
#   stealth::sys::data::kv::load release /etc/os-release
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The file
# Returns:
#   0 - Filled
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::kv::load() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _kv_load_out="${1}"

    _kv_load_out=()
    local _kv_load_line _kv_load_key _kv_load_value

    while IFS= read -r _kv_load_line || [[ -n "${_kv_load_line}" ]]; do
        if ! stealth::sys::data::kv::_split _kv_load_key _kv_load_value \
            "${_kv_load_line}"; then
            continue
        fi
        _kv_load_out["${_kv_load_key}"]="${_kv_load_value}"
    done < "${2}"
    return 0
}

#######################################
# Sets a key, in the line that already sets it or in a new line at the end.
# Comments, blank lines and the order of everything else are left as they
# were.
#
# Usage:
#   stealth::sys::data::kv::set "${file}" VARIANT_ID 'stealth'
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $2 (String) - The key
#   $3 (String) - The value
# Returns:
#   0 - The file sets the key to that value
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing, the key is not one a shell can
#   read, or the value has a line break in it
#######################################
stealth::sys::data::kv::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    stealth::util::assert::not_empty "${2:-}" 'a key is required'
    stealth::sys::data::kv::_check "${2}" "${3:-}"

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::kv::_edit "${2}" 'set' "${3:-}"
}

#######################################
# Takes a key out of a file, along with every line that set it.
#
# Usage:
#   stealth::sys::data::kv::delete "${file}" OLD_SETTING
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The key
# Returns:
#   0 - The file does not set the key
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::kv::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a key is required'

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::kv::_edit "${2}" 'delete' ''
}

#######################################
# Rewrites a staged file with one key set or taken out. This is the callback
# sys/io/fs::atomic runs, so the file the caller asked about is replaced in
# one step or not at all.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::kv::_edit 'ID' 'set' 'stealth'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The key
#   $3 (String) - set or delete
#   $4 (String) - The value, when setting
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::kv::_edit() {
    local -r _kv_edit_staged="${1}"
    local -r _kv_edit_key="${2}"
    local -r _kv_edit_what="${3}"
    local _kv_edit_written=''

    if [[ "${_kv_edit_what}" == 'set' ]]; then
        stealth::sys::data::kv::_quote _kv_edit_written "${4}"
    fi

    local -a _kv_edit_lines=()
    local _kv_edit_line _kv_edit_this _kv_edit_value
    local -i _kv_edit_done=0

    while IFS= read -r _kv_edit_line || [[ -n "${_kv_edit_line}" ]]; do
        if ! stealth::sys::data::kv::_split _kv_edit_this _kv_edit_value \
            "${_kv_edit_line}"; then
            _kv_edit_lines+=("${_kv_edit_line}")
            continue
        fi
        if [[ "${_kv_edit_this}" != "${_kv_edit_key}" ]]; then
            _kv_edit_lines+=("${_kv_edit_line}")
            continue
        fi
        if [[ "${_kv_edit_what}" == 'set' && _kv_edit_done -eq 0 ]]; then
            _kv_edit_lines+=("${_kv_edit_key}=${_kv_edit_written}")
            _kv_edit_done=1
        fi
    done < "${_kv_edit_staged}"

    if [[ "${_kv_edit_what}" == 'set' && _kv_edit_done -eq 0 ]]; then
        _kv_edit_lines+=("${_kv_edit_key}=${_kv_edit_written}")
    fi

    if (( ${#_kv_edit_lines[@]} == 0 )); then
        : > "${_kv_edit_staged}"
        return 0
    fi

    printf '%s\n' "${_kv_edit_lines[@]}" > "${_kv_edit_staged}"
    return 0
}

#######################################
# Puts everything one file sets into another, in one change rather than one
# change per key. A key the target already sets is given the source's value,
# and everything else the target holds is left alone.
#
# Usage:
#   stealth::sys::data::kv::merge /etc/os-release "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change, which is made when it is not there
#   $2 (String) - The file to take the settings from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, or the source is not there
#######################################
stealth::sys::data::kv::merge() {
    stealth::util::assert::not_empty "${1:-}" 'a file to change is required'
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    local -A _kv_merge_from=()
    stealth::sys::data::kv::load _kv_merge_from "${2}"

    if (( ${#_kv_merge_from[@]} == 0 )); then
        stealth::util::log::debug '%s sets nothing' "${2}"
        return 0
    fi

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::kv::_merge_into "${2}"
}

#######################################
# Rewrites a staged file with another file's settings applied. The callback
# sys/io/fs::atomic runs for merge.
#
# Usage:
#   stealth::sys::io::fs::atomic "${target}" -- \
#       stealth::sys::data::kv::_merge_into "${source}"
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The file to take the settings from
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::kv::_merge_into() {
    local -A _kv_mi_from=()
    stealth::sys::data::kv::load _kv_mi_from "${2}"

    local -a _kv_mi_lines=()
    local -A _kv_mi_written=()
    local _kv_mi_line _kv_mi_key _kv_mi_value _kv_mi_quoted

    while IFS= read -r _kv_mi_line || [[ -n "${_kv_mi_line}" ]]; do
        if ! stealth::sys::data::kv::_split _kv_mi_key _kv_mi_value \
            "${_kv_mi_line}"; then
            _kv_mi_lines+=("${_kv_mi_line}")
            continue
        fi
        if [[ ! -v _kv_mi_from["${_kv_mi_key}"] ]]; then
            _kv_mi_lines+=("${_kv_mi_line}")
            continue
        fi
        if [[ -v _kv_mi_written["${_kv_mi_key}"] ]]; then
            continue
        fi
        stealth::sys::data::kv::_quote _kv_mi_quoted "${_kv_mi_from[${_kv_mi_key}]}"
        _kv_mi_lines+=("${_kv_mi_key}=${_kv_mi_quoted}")
        _kv_mi_written["${_kv_mi_key}"]=1
    done < "${1}"

    for _kv_mi_key in "${!_kv_mi_from[@]}"; do
        if [[ -v _kv_mi_written["${_kv_mi_key}"] ]]; then
            continue
        fi
        stealth::sys::data::kv::_quote _kv_mi_quoted "${_kv_mi_from[${_kv_mi_key}]}"
        _kv_mi_lines+=("${_kv_mi_key}=${_kv_mi_quoted}")
    done

    printf '%s\n' "${_kv_mi_lines[@]}" > "${1}"
    return 0
}

#######################################
# Reports whether every line of a file is one this module understands: a
# comment, a blank line, or a key being set.
#
# Usage:
#   if ! stealth::sys::data::kv::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - Every line is
#   1 - One is not, or there is no such file
#######################################
stealth::sys::data::kv::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi
    local -r _kv_valid_file="${1}"

    local _kv_valid_line _kv_valid_key _kv_valid_value _kv_valid_trimmed
    local _kv_valid_bad=''

    while IFS= read -r _kv_valid_line || [[ -n "${_kv_valid_line}" ]]; do
        stealth::util::text::trim _kv_valid_trimmed "${_kv_valid_line}"
        if [[ -z "${_kv_valid_trimmed}" || "${_kv_valid_trimmed}" == '#'* ]]; then
            continue
        fi
        if ! stealth::sys::data::kv::_split _kv_valid_key _kv_valid_value \
            "${_kv_valid_line}"; then
            _kv_valid_bad="${_kv_valid_trimmed}"
            break
        fi
    done < "${_kv_valid_file}"

    if [[ -n "${_kv_valid_bad}" ]]; then
        stealth::util::log::debug 'a line of %s sets nothing: %s' \
            "${_kv_valid_file}" "${_kv_valid_bad}"
        return 1
    fi
    return 0
}
