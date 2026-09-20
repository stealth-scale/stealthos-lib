###############################################################################
# module: sys/data/ini
# layer: sys
# description: INI files, read and written without losing what is in them.
#
#              A section is [name] on a line of its own and everything after
#              it belongs to that section until the next one. Keys written
#              before any section belong to the section named by the empty
#              string, which is how a caller reaches them.
#
#              Writing keeps the file. Comments, blank lines and the order of
#              the sections and the keys are all where they were, and a key
#              that is changed is changed where it stands. The obvious way to
#              write one of these is to parse the whole file and print it
#              back out, and what comes back has no comments in it at all.
#
#              A new key goes at the end of its section rather than at the end
#              of the file, because a key under the wrong heading means
#              something else.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_DATA_INI:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_DATA_INI=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# A key is anything without the characters that would make the line mean
# something else, and a section is anything that fits between brackets.
#
# The closing bracket comes first inside each set, where it is a character
# and not the end of the set, and the equals sign comes before the opening
# one, because [= starts an equivalence class and is not a set at all.
declare -gr _STEALTH_SYS_DATA_INI_KEY_RE='^[^]=[]+$'
declare -gr _STEALTH_SYS_DATA_INI_SECTION_RE='^[^][]*$'

# What starts a comment. Both are in use, and a writer here never adds one.
declare -gr _STEALTH_SYS_DATA_INI_COMMENT='#;'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Says whether a line opens a section, and which.
#
# The output variable is left alone when the line is not a section heading.
# Every reader here holds the section it is in in that variable, and clearing
# it on an ordinary line would lose track of where the reader was.
#
# Usage:
#   stealth::sys::data::ini::_section name '[network]'
#
# Arguments:
#   $1 (Nameref) - The output variable for the section name
#   $2 (String)  - The line
# Returns:
#   0 - It opens one, and the name is in the output variable
#   1 - It does not, and the output variable is as it was
#######################################
stealth::sys::data::ini::_section() {
    local _ini_sec_line
    stealth::util::text::trim _ini_sec_line "${2}"

    if [[ "${_ini_sec_line}" != '['*']' ]]; then
        return 1
    fi

    local -n _ini_sec_out="${1}"
    _ini_sec_out="${_ini_sec_line:1:${#_ini_sec_line}-2}"
    stealth::util::text::trim _ini_sec_out "${_ini_sec_out}"
    return 0
}

#######################################
# Takes a line apart into the key it sets and the value it sets it to.
#
# Usage:
#   stealth::sys::data::ini::_split key value 'timeout = 30'
#
# Arguments:
#   $1 (Nameref) - The output variable for the key
#   $2 (Nameref) - The output variable for the value
#   $3 (String)  - The line
# Globals:
#   _STEALTH_SYS_DATA_INI_COMMENT (Read)
# Returns:
#   0 - It sets a key
#   1 - It is a comment, blank, a section, or something else
#######################################
stealth::sys::data::ini::_split() {
    local -n _ini_split_key="${1}"
    local -n _ini_split_value="${2}"

    _ini_split_key=''
    _ini_split_value=''

    local _ini_split_line
    stealth::util::text::trim _ini_split_line "${3}"

    if [[ -z "${_ini_split_line}" ]]; then
        return 1
    fi
    if [[ "${_STEALTH_SYS_DATA_INI_COMMENT}" == *"${_ini_split_line:0:1}"* ]]; then
        return 1
    fi
    if [[ "${_ini_split_line}" != *'='* ]]; then
        return 1
    fi

    stealth::util::text::trim _ini_split_key "${_ini_split_line%%=*}"
    if [[ -z "${_ini_split_key}" ]]; then
        return 1
    fi

    stealth::util::text::trim _ini_split_value "${_ini_split_line#*=}"
    stealth::sys::data::ini::_unquote _ini_split_value "${_ini_split_value}"
    return 0
}

#######################################
# Takes the quotes off a value that is written with them. A value here runs
# to the end of the line, so the quotes are the writer's choice and not part
# of what was meant.
#
# Usage:
#   stealth::sys::data::ini::_unquote value '"a value"'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value as it is written
# Returns:
#   0 - Taken off, or there were none
#######################################
stealth::sys::data::ini::_unquote() {
    local -n _ini_unq_out="${1}"

    _ini_unq_out="${2}"
    if (( ${#2} < 2 )); then
        return 0
    fi
    if [[ "${2}" == \"*\" || "${2}" == \'*\' ]]; then
        _ini_unq_out="${2:1:${#2}-2}"
    fi
    return 0
}

#######################################
# Refuses a section, a key or a value that cannot be written to one of these
# files and read back as itself.
#
# Usage:
#   stealth::sys::data::ini::_check 'network' 'timeout' '30'
#
# Arguments:
#   $1 (String) - The section
#   $2 (String) - The key
#   $3 (String) - The value
# Globals:
#   _STEALTH_SYS_DATA_INI_KEY_RE (Read)
#   _STEALTH_SYS_DATA_INI_SECTION_RE (Read)
# Returns:
#   0 - All three are usable
#   Exits 1 when one is not
#######################################
stealth::sys::data::ini::_check() {
    if [[ ! "${1}" =~ ${_STEALTH_SYS_DATA_INI_SECTION_RE} ]]; then
        stealth::util::assert::fail "${1} is not a section name this file can hold"
    fi
    if [[ ! "${2}" =~ ${_STEALTH_SYS_DATA_INI_KEY_RE} ]]; then
        stealth::util::assert::fail "${2} is not a key this file can hold"
    fi
    if [[ "${3}" == *$'\n'* ]]; then
        stealth::util::assert::fail \
            "the value of ${2} has a line break in it, which this file cannot hold"
    fi
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the value of a key in a section. The empty string names the keys
# written before any section opens.
#
# Usage:
#   stealth::sys::data::ini::read value "${file}" network timeout
#   stealth::sys::data::ini::read value "${file}" '' name
#   stealth::sys::data::ini::read value "${file}" network timeout 30
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The section, empty for the keys before any section
#   $4 (String)  - The key
#   $5 (String)  - What to give back when the key is not there
# Returns:
#   0 - Found, or the default was used
#   1 - Not there and no default was given
#   Exits 1 when an output variable, a file or a key is missing
#######################################
stealth::sys::data::ini::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    stealth::util::assert::not_empty "${4:-}" 'a key is required'
    local -n _ini_read_out="${1}"

    local _ini_read_line _ini_read_at='' _ini_read_key _ini_read_value
    local -i _ini_read_found=0

    while IFS= read -r _ini_read_line || [[ -n "${_ini_read_line}" ]]; do
        if stealth::sys::data::ini::_section _ini_read_at "${_ini_read_line}"; then
            continue
        fi
        if [[ "${_ini_read_at}" != "${3}" ]]; then
            continue
        fi
        if ! stealth::sys::data::ini::_split _ini_read_key _ini_read_value \
            "${_ini_read_line}"; then
            continue
        fi
        if [[ "${_ini_read_key}" == "${4}" ]]; then
            _ini_read_out="${_ini_read_value}"
            _ini_read_found=1
        fi
    done < "${2}"

    if (( _ini_read_found == 1 )); then
        return 0
    fi

    _ini_read_out="${5:-}"
    if (( $# >= 5 )); then
        return 0
    fi
    return 1
}

#######################################
# Reports whether a file sets a key in a section.
#
# Usage:
#   if stealth::sys::data::ini::has "${file}" network timeout; then ...
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The section
#   $3 (String) - The key
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::ini::has() {
    local _ini_has_value
    stealth::sys::data::ini::read _ini_has_value "${1:-}" "${2:-}" "${3:-}"
}

#######################################
# Reports whether a file opens a section.
#
# Usage:
#   if stealth::sys::data::ini::has_section "${file}" network; then ...
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The section
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when no file is given
#######################################
stealth::sys::data::ini::has_section() {
    stealth::util::assert::is_file "${1:-}" "no file to read at ${1:-}"

    local _ini_hs_line _ini_hs_name

    while IFS= read -r _ini_hs_line || [[ -n "${_ini_hs_line}" ]]; do
        if ! stealth::sys::data::ini::_section _ini_hs_name "${_ini_hs_line}"; then
            continue
        fi
        if [[ "${_ini_hs_name}" == "${2:-}" ]]; then
            return 0
        fi
    done < "${1}"
    return 1
}

#######################################
# Fills an array with the sections a file opens, in the order they appear.
# The keys before any section are not one, and nothing is reported for them.
#
# Usage:
#   stealth::sys::data::ini::sections names "${file}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
# Returns:
#   0 - Filled
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::ini::sections() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _ini_secs_out="${1}"

    _ini_secs_out=()
    local -A _ini_secs_seen=()
    local _ini_secs_line _ini_secs_name

    while IFS= read -r _ini_secs_line || [[ -n "${_ini_secs_line}" ]]; do
        if ! stealth::sys::data::ini::_section _ini_secs_name "${_ini_secs_line}"; then
            continue
        fi
        if [[ -v _ini_secs_seen["${_ini_secs_name}"] ]]; then
            continue
        fi
        _ini_secs_seen["${_ini_secs_name}"]=1
        _ini_secs_out+=("${_ini_secs_name}")
    done < "${2}"
    return 0
}

#######################################
# Fills an array with the keys of one section, in the order they appear.
#
# Usage:
#   stealth::sys::data::ini::keys names "${file}" network
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $3 (String)  - The section, empty for the keys before any section
# Returns:
#   0 - Filled, and empty when the section is not there
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::ini::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _ini_keys_out="${1}"

    _ini_keys_out=()
    local -A _ini_keys_seen=()
    local _ini_keys_line _ini_keys_at='' _ini_keys_key _ini_keys_value

    while IFS= read -r _ini_keys_line || [[ -n "${_ini_keys_line}" ]]; do
        if stealth::sys::data::ini::_section _ini_keys_at "${_ini_keys_line}"; then
            continue
        fi
        if [[ "${_ini_keys_at}" != "${3:-}" ]]; then
            continue
        fi
        if ! stealth::sys::data::ini::_split _ini_keys_key _ini_keys_value \
            "${_ini_keys_line}"; then
            continue
        fi
        if [[ -v _ini_keys_seen["${_ini_keys_key}"] ]]; then
            continue
        fi
        _ini_keys_seen["${_ini_keys_key}"]=1
        _ini_keys_out+=("${_ini_keys_key}")
    done < "${2}"
    return 0
}

#######################################
# Fills an associative array with one whole section, which is one pass over
# the file rather than one pass for every key the caller wants.
#
# Usage:
#   local -A network=()
#   stealth::sys::data::ini::load network "${file}" network
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The file
#   $3 (String)  - The section, empty for the keys before any section
# Returns:
#   0 - Filled, and empty when the section is not there
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::ini::load() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _ini_load_out="${1}"

    _ini_load_out=()
    local _ini_load_line _ini_load_at='' _ini_load_key _ini_load_value

    while IFS= read -r _ini_load_line || [[ -n "${_ini_load_line}" ]]; do
        if stealth::sys::data::ini::_section _ini_load_at "${_ini_load_line}"; then
            continue
        fi
        if [[ "${_ini_load_at}" != "${3:-}" ]]; then
            continue
        fi
        if ! stealth::sys::data::ini::_split _ini_load_key _ini_load_value \
            "${_ini_load_line}"; then
            continue
        fi
        _ini_load_out["${_ini_load_key}"]="${_ini_load_value}"
    done < "${2}"
    return 0
}

#######################################
# Sets a key in a section, where it already stands or at the end of that
# section. A section that is not there yet is opened at the end of the file.
#
# Usage:
#   stealth::sys::data::ini::set "${file}" network timeout 30
#   stealth::sys::data::ini::set "${file}" '' name build
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $2 (String) - The section, empty for the keys before any section
#   $3 (String) - The key
#   $4 (String) - The value
# Returns:
#   0 - The file sets the key to that value
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing, or one of the three cannot be
#   written to a file of this kind
#######################################
stealth::sys::data::ini::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    stealth::util::assert::not_empty "${3:-}" 'a key is required'
    stealth::sys::data::ini::_check "${2:-}" "${3}" "${4:-}"

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::ini::_edit "${2:-}" "${3}" 'set' "${4:-}"
}

#######################################
# Takes a key out of a section, along with every line that set it. The
# section itself stays, even when nothing is left in it.
#
# Usage:
#   stealth::sys::data::ini::delete "${file}" network timeout
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The section
#   $3 (String) - The key
# Returns:
#   0 - The section does not set the key
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::ini::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${3:-}" 'a key is required'

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::ini::_edit "${2:-}" "${3}" 'delete' ''
}

#######################################
# Rewrites a staged file with one key set or taken out, keeping every line
# that is not the one in question. This is the callback sys/io/fs::atomic
# runs, so the file the caller asked about is replaced in one step or not at
# all.
#
# A key being added goes at the end of its section, after the last line that
# says anything and before the blank lines that follow it.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::ini::_edit 'network' 'timeout' 'set' '30'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The section
#   $3 (String) - The key
#   $4 (String) - set or delete
#   $5 (String) - The value, when setting
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::ini::_edit() {
    local -r _ini_edit_staged="${1}"
    local -r _ini_edit_section="${2}"
    local -r _ini_edit_key="${3}"
    local -r _ini_edit_what="${4}"
    local -r _ini_edit_line_new="${3} = ${5}"

    local -a _ini_edit_out=() _ini_edit_held=()
    local _ini_edit_line _ini_edit_at='' _ini_edit_name
    local _ini_edit_this _ini_edit_value
    local -i _ini_edit_done=0 _ini_edit_seen=0

    # The section named by the empty string is open before the file starts,
    # so a key going into it is already in a section that has been seen. Left
    # at zero, the key would be written at the end of the file, which is
    # inside whatever section happens to be last.
    if [[ -z "${_ini_edit_section}" ]]; then
        _ini_edit_seen=1
    fi

    while IFS= read -r _ini_edit_line || [[ -n "${_ini_edit_line}" ]]; do
        if stealth::sys::data::ini::_section _ini_edit_name "${_ini_edit_line}"; then
            if [[ "${_ini_edit_at}" == "${_ini_edit_section}" && \
                  "${_ini_edit_what}" == 'set' && _ini_edit_seen -eq 1 && \
                  _ini_edit_done -eq 0 ]]; then
                _ini_edit_out+=("${_ini_edit_line_new}")
                _ini_edit_done=1
            fi
            _ini_edit_out+=("${_ini_edit_held[@]}" "${_ini_edit_line}")
            _ini_edit_held=()
            _ini_edit_at="${_ini_edit_name}"
            if [[ "${_ini_edit_at}" == "${_ini_edit_section}" ]]; then
                _ini_edit_seen=1
            fi
            continue
        fi

        if [[ -z "${_ini_edit_line//[[:space:]]/}" ]]; then
            _ini_edit_held+=("${_ini_edit_line}")
            continue
        fi

        if [[ "${_ini_edit_at}" != "${_ini_edit_section}" ]] || \
           ! stealth::sys::data::ini::_split _ini_edit_this _ini_edit_value \
               "${_ini_edit_line}" || \
           [[ "${_ini_edit_this}" != "${_ini_edit_key}" ]]; then
            _ini_edit_out+=("${_ini_edit_held[@]}" "${_ini_edit_line}")
            _ini_edit_held=()
            continue
        fi

        if [[ "${_ini_edit_what}" == 'set' && _ini_edit_done -eq 0 ]]; then
            _ini_edit_out+=("${_ini_edit_held[@]}" "${_ini_edit_line_new}")
            _ini_edit_held=()
            _ini_edit_done=1
        fi
    done < "${_ini_edit_staged}"

    stealth::sys::data::ini::_finish _ini_edit_out _ini_edit_held \
        "${_ini_edit_section}" "${_ini_edit_line_new}" "${_ini_edit_what}" \
        "${_ini_edit_done}" "${_ini_edit_seen}" "${_ini_edit_at}"

    if (( ${#_ini_edit_out[@]} == 0 )); then
        : > "${_ini_edit_staged}"
        return 0
    fi

    printf '%s\n' "${_ini_edit_out[@]}" > "${_ini_edit_staged}"
    return 0
}

#######################################
# Puts the last lines of an edited file together: the key that has not been
# written yet, the section to open for it when there is none, and the blank
# lines that were held back.
#
# Usage:
#   stealth::sys::data::ini::_finish out held 'network' 'timeout = 30' set 0 0 ''
#
# Arguments:
#   $1 (Nameref) - The array of lines so far
#   $2 (Nameref) - The blank lines held back
#   $3 (String)  - The section
#   $4 (String)  - The line to write for the key
#   $5 (String)  - set or delete
#   $6 (Integer) - 1 when the key has already been written
#   $7 (Integer) - 1 when the section was seen
#   $8 (String)  - The section the file ended in
# Returns:
#   0 - Put together
#######################################
stealth::sys::data::ini::_finish() {
    local -n _ini_fin_out="${1}"
    local -n _ini_fin_held="${2}"

    if [[ "${5}" != 'set' || "${6}" -eq 1 ]]; then
        _ini_fin_out+=("${_ini_fin_held[@]}")
        return 0
    fi

    if (( ${7} == 1 )) && [[ "${8}" == "${3}" ]]; then
        _ini_fin_out+=("${4}" "${_ini_fin_held[@]}")
        return 0
    fi

    _ini_fin_out+=("${_ini_fin_held[@]}")
    if [[ -n "${3}" ]]; then
        if (( ${#_ini_fin_out[@]} > 0 )); then
            _ini_fin_out+=('')
        fi
        _ini_fin_out+=("[${3}]")
    fi
    _ini_fin_out+=("${4}")
    return 0
}

#######################################
# Takes a whole section out of a file, its heading and everything in it.
#
# Usage:
#   stealth::sys::data::ini::delete_section "${file}" network
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The section
# Returns:
#   0 - The file does not hold the section
#   1 - It could not be put in place
#   Exits 1 when a file or a section is missing
#######################################
stealth::sys::data::ini::delete_section() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a section is required'

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::ini::_drop_section "${2}"
}

#######################################
# Rewrites a staged file without one section. The callback
# sys/io/fs::atomic runs for delete_section.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::ini::_drop_section 'network'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The section
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::ini::_drop_section() {
    local -a _ini_drop_out=()
    local _ini_drop_line _ini_drop_at='' _ini_drop_name

    while IFS= read -r _ini_drop_line || [[ -n "${_ini_drop_line}" ]]; do
        if stealth::sys::data::ini::_section _ini_drop_name "${_ini_drop_line}"; then
            _ini_drop_at="${_ini_drop_name}"
        fi
        if [[ "${_ini_drop_at}" == "${2}" ]]; then
            continue
        fi
        _ini_drop_out+=("${_ini_drop_line}")
    done < "${1}"

    if (( ${#_ini_drop_out[@]} == 0 )); then
        : > "${1}"
        return 0
    fi

    printf '%s\n' "${_ini_drop_out[@]}" > "${1}"
    return 0
}

#######################################
# Puts everything one file holds into another, section by section and key by
# key, in one change rather than one change per key. What the target holds
# and the source does not is left alone.
#
# Usage:
#   stealth::sys::data::ini::merge "${config}" "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change, which is made when it is not there
#   $2 (String) - The file to take the settings from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, or the source is not there
#######################################
stealth::sys::data::ini::merge() {
    stealth::util::assert::not_empty "${1:-}" 'a file to change is required'
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    local -a _ini_merge_sections=()
    stealth::sys::data::ini::sections _ini_merge_sections "${2}"

    local -A _ini_merge_top=()
    stealth::sys::data::ini::load _ini_merge_top "${2}" ''
    if (( ${#_ini_merge_top[@]} > 0 )); then
        _ini_merge_sections=('' "${_ini_merge_sections[@]}")
    fi

    if (( ${#_ini_merge_sections[@]} == 0 )); then
        stealth::util::log::debug '%s holds nothing to merge' "${2}"
        return 0
    fi

    local _ini_merge_section _ini_merge_key
    local -a _ini_merge_keys=()

    for _ini_merge_section in "${_ini_merge_sections[@]}"; do
        stealth::sys::data::ini::keys _ini_merge_keys "${2}" "${_ini_merge_section}"
        for _ini_merge_key in "${_ini_merge_keys[@]}"; do
            local _ini_merge_value
            stealth::sys::data::ini::read _ini_merge_value "${2}" \
                "${_ini_merge_section}" "${_ini_merge_key}"
            stealth::sys::data::ini::set "${1}" "${_ini_merge_section}" \
                "${_ini_merge_key}" "${_ini_merge_value}"
        done
    done
    return 0
}

#######################################
# Reports whether every line of a file is one this module understands: a
# blank line, a comment, a section heading, or a key being set.
#
# Usage:
#   if ! stealth::sys::data::ini::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Globals:
#   _STEALTH_SYS_DATA_INI_COMMENT (Read)
# Returns:
#   0 - Every line is
#   1 - One is not, or there is no such file
#######################################
stealth::sys::data::ini::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi
    local -r _ini_valid_file="${1}"

    local _ini_valid_line _ini_valid_trimmed _ini_valid_name
    local _ini_valid_key _ini_valid_value _ini_valid_bad=''

    while IFS= read -r _ini_valid_line || [[ -n "${_ini_valid_line}" ]]; do
        stealth::util::text::trim _ini_valid_trimmed "${_ini_valid_line}"
        if [[ -z "${_ini_valid_trimmed}" ]]; then
            continue
        fi
        if [[ "${_STEALTH_SYS_DATA_INI_COMMENT}" == *"${_ini_valid_trimmed:0:1}"* ]]; then
            continue
        fi
        if stealth::sys::data::ini::_section _ini_valid_name "${_ini_valid_line}"; then
            continue
        fi
        if ! stealth::sys::data::ini::_split _ini_valid_key _ini_valid_value \
            "${_ini_valid_line}"; then
            _ini_valid_bad="${_ini_valid_trimmed}"
            break
        fi
    done < "${_ini_valid_file}"

    if [[ -n "${_ini_valid_bad}" ]]; then
        stealth::util::log::debug 'a line of %s is neither a section nor a setting: %s' \
            "${_ini_valid_file}" "${_ini_valid_bad}"
        return 1
    fi
    return 0
}
