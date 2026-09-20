###############################################################################
# module: sys/data/toml
# layer: sys
# description: TOML files, for the subset a machine's configuration is written
#              in: tables, keys, and values of one type each.
#
#              A table is [name] or [a.b] on a line of its own, and the keys
#              written before any table belong to the table named by the empty
#              string. That is the same shape sys/data/ini has, and a caller
#              that can read one can read the other.
#
#              TOML has types where INI has text. 30 is a number, "30" is a
#              string, and a file that confuses them is a file the program
#              reading it rejects. set works out which one a value is from how
#              it is written, and --string or --raw says so outright when the
#              guess would be wrong.
#
#              Writing keeps the file: comments, blank lines and the order of
#              everything are where they were.
#
#              An array of tables, written [[name]], is not part of the subset.
#              is_valid says so rather than letting a reader here take it for
#              an ordinary table and give back the wrong answer.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_DATA_TOML:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_DATA_TOML=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/io/fs"

# =============================================================================
# CONSTANTS
# =============================================================================

# What a bare key and a table name are allowed to be. TOML also allows a
# quoted key, which the subset here leaves out.
declare -gr _STEALTH_SYS_DATA_TOML_KEY_RE='^[A-Za-z0-9_-]+$'
declare -gr _STEALTH_SYS_DATA_TOML_TABLE_RE='^[A-Za-z0-9_.-]*$'

# What a value has to look like to go in without quotes.
declare -gr _STEALTH_SYS_DATA_TOML_INT_RE='^[+-]?[0-9][0-9_]*$'
declare -gr _STEALTH_SYS_DATA_TOML_FLOAT_RE='^[+-]?[0-9][0-9_]*\.[0-9][0-9_]*([eE][+-]?[0-9]+)?$'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Says whether a line opens a table, and which.
#
# The output variable is left alone when the line is not a table heading,
# because every reader here holds the table it is in in that variable.
#
# An array of tables, [[name]], opens one too, and the name it gives back
# still has its brackets: [name]. A caller cannot ask for a table by that
# name, because a bracket is not allowed in one, so the keys under it belong
# to nothing anybody can read. That is the point. Left as no heading at all,
# those keys would be read as part of the table before it, and the answer
# would be wrong rather than missing.
#
# Usage:
#   stealth::sys::data::toml::_table name '[engine.runtime]'
#
# Arguments:
#   $1 (Nameref) - The output variable for the table name
#   $2 (String)  - The line
# Returns:
#   0 - It opens one, and the name is in the output variable
#   1 - It does not
#######################################
stealth::sys::data::toml::_table() {
    local _toml_tbl_line
    stealth::util::text::trim _toml_tbl_line "${2}"

    if [[ "${_toml_tbl_line}" != '['*']' ]]; then
        return 1
    fi

    local -n _toml_tbl_out="${1}"
    _toml_tbl_out="${_toml_tbl_line:1:${#_toml_tbl_line}-2}"
    stealth::util::text::trim _toml_tbl_out "${_toml_tbl_out}"
    return 0
}

#######################################
# Counts how far a line leaves a bracket or a brace open, so that a value
# written across several lines can be put back together. Brackets inside a
# string are text and are not counted.
#
# Usage:
#   stealth::sys::data::toml::_depth open 'hosts = ["a",'
#
# Arguments:
#   $1 (Nameref) - The output variable, which the count is added to
#   $2 (String)  - The line
# Returns:
#   0 - Counted
#######################################
stealth::sys::data::toml::_depth() {
    local -n _toml_dep_out="${1}"

    local _toml_dep_quote='' _toml_dep_char
    local -i _toml_dep_at=0

    while (( _toml_dep_at < ${#2} )); do
        _toml_dep_char="${2:${_toml_dep_at}:1}"
        _toml_dep_at=$(( _toml_dep_at + 1 ))

        if [[ -n "${_toml_dep_quote}" ]]; then
            if [[ "${_toml_dep_char}" == "${_toml_dep_quote}" ]]; then
                _toml_dep_quote=''
            fi
            continue
        fi
        case "${_toml_dep_char}" in
            \"|\') _toml_dep_quote="${_toml_dep_char}" ;;
            '#') return 0 ;;
            '['|'{') _toml_dep_out=$(( _toml_dep_out + 1 )) ;;
            ']'|'}') _toml_dep_out=$(( _toml_dep_out - 1 )) ;;
            *) : ;;
        esac
    done
    return 0
}

#######################################
# Takes a line apart into the key it sets and the value it sets it to.
#
# Usage:
#   stealth::sys::data::toml::_split key value 'timeout = 30'
#
# Arguments:
#   $1 (Nameref) - The output variable for the key
#   $2 (Nameref) - The output variable for the value, as it is written
#   $3 (String)  - The line
# Globals:
#   _STEALTH_SYS_DATA_TOML_KEY_RE (Read)
# Returns:
#   0 - It sets a key
#   1 - It is a comment, blank, a table, or something else
#######################################
stealth::sys::data::toml::_split() {
    local -n _toml_split_key="${1}"
    local -n _toml_split_value="${2}"

    _toml_split_key=''
    _toml_split_value=''

    local _toml_split_line
    stealth::util::text::trim _toml_split_line "${3}"

    if [[ -z "${_toml_split_line}" || "${_toml_split_line}" == '#'* ]]; then
        return 1
    fi
    if [[ "${_toml_split_line}" == '['* ]]; then
        return 1
    fi
    if [[ "${_toml_split_line}" != *'='* ]]; then
        return 1
    fi

    stealth::util::text::trim _toml_split_key "${_toml_split_line%%=*}"
    if [[ ! "${_toml_split_key}" =~ ${_STEALTH_SYS_DATA_TOML_KEY_RE} ]]; then
        return 1
    fi

    stealth::util::text::trim _toml_split_value "${_toml_split_line#*=}"
    return 0
}

#######################################
# Gives back what a value means, rather than how it is written. A string
# loses its quotes and its escapes, and everything else is left as it stands
# because that is already what it says.
#
# Usage:
#   stealth::sys::data::toml::_parse value '"a string"'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value as it is written
# Returns:
#   0 - Read
#######################################
stealth::sys::data::toml::_parse() {
    local -n _toml_parse_out="${1}"

    local _toml_parse_raw
    stealth::sys::data::toml::_strip_comment _toml_parse_raw "${2}"

    if (( ${#_toml_parse_raw} >= 2 )) && [[ "${_toml_parse_raw}" == \'*\' ]]; then
        _toml_parse_out="${_toml_parse_raw:1:${#_toml_parse_raw}-2}"
        return 0
    fi

    if (( ${#_toml_parse_raw} >= 2 )) && [[ "${_toml_parse_raw}" == \"*\" ]]; then
        _toml_parse_out="${_toml_parse_raw:1:${#_toml_parse_raw}-2}"
        _toml_parse_out="${_toml_parse_out//\\\"/\"}"
        _toml_parse_out="${_toml_parse_out//\\n/$'\n'}"
        _toml_parse_out="${_toml_parse_out//\\t/$'\t'}"
        _toml_parse_out="${_toml_parse_out//\\\\/\\}"
        return 0
    fi

    _toml_parse_out="${_toml_parse_raw}"
    return 0
}

#######################################
# Takes the comment off the end of a value. A hash inside a string is part of
# the string and stays.
#
# Usage:
#   stealth::sys::data::toml::_strip_comment value '30  # seconds'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value as it is written
# Returns:
#   0 - Taken off, or there was none
#######################################
stealth::sys::data::toml::_strip_comment() {
    local -n _toml_sc_out="${1}"

    local _toml_sc_quote='' _toml_sc_char
    local -i _toml_sc_at=0

    while (( _toml_sc_at < ${#2} )); do
        _toml_sc_char="${2:${_toml_sc_at}:1}"

        if [[ -n "${_toml_sc_quote}" ]]; then
            if [[ "${_toml_sc_char}" == "${_toml_sc_quote}" ]]; then
                _toml_sc_quote=''
            fi
        elif [[ "${_toml_sc_char}" == '"' || "${_toml_sc_char}" == "'" ]]; then
            _toml_sc_quote="${_toml_sc_char}"
        elif [[ "${_toml_sc_char}" == '#' ]]; then
            break
        fi
        _toml_sc_at=$(( _toml_sc_at + 1 ))
    done

    stealth::util::text::trim _toml_sc_out "${2:0:${_toml_sc_at}}"
    return 0
}

#######################################
# Works out how to write a value, from how the caller wrote it. A value that
# reads as a number, a boolean, an array or an inline table goes in as it
# stands, and anything else goes in as a string.
#
# Usage:
#   stealth::sys::data::toml::_write written '30'       # 30
#   stealth::sys::data::toml::_write written 'a name'   # "a name"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - --string to write it as one whatever it looks like, --raw
#                  to write it as it stands
# Globals:
#   _STEALTH_SYS_DATA_TOML_INT_RE (Read)
#   _STEALTH_SYS_DATA_TOML_FLOAT_RE (Read)
# Returns:
#   0 - Written
#######################################
stealth::sys::data::toml::_write() {
    local -n _toml_w_out="${1}"

    if [[ "${3:-}" == '--raw' ]]; then
        _toml_w_out="${2}"
        return 0
    fi

    if [[ "${3:-}" != '--string' ]]; then
        if [[ "${2}" == 'true' || "${2}" == 'false' ]] || \
           [[ "${2}" =~ ${_STEALTH_SYS_DATA_TOML_INT_RE} ]] || \
           [[ "${2}" =~ ${_STEALTH_SYS_DATA_TOML_FLOAT_RE} ]] || \
           [[ "${2}" == '['*']' ]] || [[ "${2}" == '{'*'}' ]]; then
            _toml_w_out="${2}"
            return 0
        fi
    fi

    local _toml_w_body="${2}"
    _toml_w_body="${_toml_w_body//\\/\\\\}"
    _toml_w_body="${_toml_w_body//\"/\\\"}"
    _toml_w_body="${_toml_w_body//$'\n'/\\n}"
    _toml_w_body="${_toml_w_body//$'\t'/\\t}"

    _toml_w_out="\"${_toml_w_body}\""
    return 0
}

#######################################
# Refuses a table, a key or an option that cannot be written to one of these
# files.
#
# Usage:
#   stealth::sys::data::toml::_check 'engine' 'timeout' '--string'
#
# Arguments:
#   $1 (String) - The table
#   $2 (String) - The key
#   $3 (String) - The option, which may be empty
# Globals:
#   _STEALTH_SYS_DATA_TOML_KEY_RE (Read)
#   _STEALTH_SYS_DATA_TOML_TABLE_RE (Read)
# Returns:
#   0 - All three are usable
#   Exits 1 when one is not
#######################################
stealth::sys::data::toml::_check() {
    if [[ ! "${1}" =~ ${_STEALTH_SYS_DATA_TOML_TABLE_RE} ]]; then
        stealth::util::assert::fail "${1} is not a table name this file can hold"
    fi
    if [[ ! "${2}" =~ ${_STEALTH_SYS_DATA_TOML_KEY_RE} ]]; then
        stealth::util::assert::fail "${2} is not a key this file can hold"
    fi
    if [[ -n "${3}" && "${3}" != '--string' && "${3}" != '--raw' ]]; then
        stealth::util::assert::fail "set does not take ${3}"
    fi
    return 0
}

#######################################
# Reads a file line by line, putting a value written across several lines
# back together, and calls a function with the table, the key and the value
# for every setting it finds.
#
# The function is called with the table, the key, what the value means, and
# the value as it is written. A caller that wants to know what kind of value
# it is needs the second of those, because the kind is a question about how
# it was written.
#
# Usage:
#   stealth::sys::data::toml::_walk "${file}" collect
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The function, called with the table, the key, the value and
#                 the value as written
#   $@ (String) - Anything else to pass the function first
# Returns:
#   0 - Walked to the end
#######################################
stealth::sys::data::toml::_walk() {
    local -r _toml_walk_file="${1}"
    local -r _toml_walk_fn="${2}"
    shift 2

    local _toml_walk_line _toml_walk_at='' _toml_walk_name
    local _toml_walk_held='' _toml_walk_key _toml_walk_value
    local _toml_walk_meant _toml_walk_raw
    local -i _toml_walk_depth=0

    while IFS= read -r _toml_walk_line || [[ -n "${_toml_walk_line}" ]]; do
        if (( _toml_walk_depth > 0 )); then
            _toml_walk_held+=" ${_toml_walk_line}"
            stealth::sys::data::toml::_depth _toml_walk_depth "${_toml_walk_line}"
            if (( _toml_walk_depth > 0 )); then
                continue
            fi
            _toml_walk_line="${_toml_walk_held}"
            _toml_walk_held=''
        else
            _toml_walk_depth=0
            stealth::sys::data::toml::_depth _toml_walk_depth "${_toml_walk_line}"
            if (( _toml_walk_depth > 0 )); then
                _toml_walk_held="${_toml_walk_line}"
                continue
            fi
            _toml_walk_depth=0
        fi

        if stealth::sys::data::toml::_table _toml_walk_name "${_toml_walk_line}"; then
            _toml_walk_at="${_toml_walk_name}"
            continue
        fi
        if ! stealth::sys::data::toml::_split _toml_walk_key _toml_walk_value \
            "${_toml_walk_line}"; then
            continue
        fi

        stealth::sys::data::toml::_parse _toml_walk_meant "${_toml_walk_value}"
        stealth::sys::data::toml::_strip_comment _toml_walk_raw "${_toml_walk_value}"
        "${_toml_walk_fn}" "$@" "${_toml_walk_at}" "${_toml_walk_key}" \
            "${_toml_walk_meant}" "${_toml_walk_raw}"
    done < "${_toml_walk_file}"
    return 0
}

#######################################
# Keeps the value of one key while a walk goes past it. The last one wins,
# which is what a reader of the whole file would end up with.
#
# Usage:
#   stealth::sys::data::toml::_take value found 'engine' 'timeout' ...
#
# Arguments:
#   $1 (Nameref) - The output variable for the value
#   $2 (Nameref) - The output variable set to 1 when it was found
#   $3 (String)  - The table wanted
#   $4 (String)  - The key wanted
#   $5 (String)  - The table this setting is in
#   $6 (String)  - The key
#   $7 (String)  - The value
#   $8 (String)  - The value as it is written
# Returns:
#   0 - Go on walking
#######################################
stealth::sys::data::toml::_take() {
    local -n _toml_take_out="${1}"
    local -n _toml_take_found="${2}"

    if [[ "${5}" == "${3}" && "${6}" == "${4}" ]]; then
        _toml_take_out="${7}"
        _toml_take_found=1
    fi
    return 0
}

#######################################
# Keeps the value of one key as it is written, while a walk goes past it.
#
# Usage:
#   stealth::sys::data::toml::_take_raw written found 'engine' 'timeout' ...
#
# Arguments:
#   $1 (Nameref) - The output variable for the value as written
#   $2 (Nameref) - The output variable set to 1 when it was found
#   $3 (String)  - The table wanted
#   $4 (String)  - The key wanted
#   $5 (String)  - The table this setting is in
#   $6 (String)  - The key
#   $7 (String)  - The value
#   $8 (String)  - The value as it is written
# Returns:
#   0 - Go on walking
#######################################
stealth::sys::data::toml::_take_raw() {
    local -n _toml_tr_out="${1}"
    local -n _toml_tr_found="${2}"

    if [[ "${5}" == "${3}" && "${6}" == "${4}" ]]; then
        _toml_tr_out="${8}"
        _toml_tr_found=1
    fi
    return 0
}

#######################################
# Puts one table's settings into an associative array while a walk goes past
# them.
#
# Usage:
#   stealth::sys::data::toml::_collect out 'engine' 'engine' 'timeout' '30' '30'
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The table wanted
#   $3 (String)  - The table this setting is in
#   $4 (String)  - The key
#   $5 (String)  - The value
#   $6 (String)  - The value as it is written
# Returns:
#   0 - Go on walking
#######################################
stealth::sys::data::toml::_collect() {
    local -n _toml_col_out="${1}"

    if [[ "${3}" == "${2}" ]]; then
        _toml_col_out["${4}"]="${5}"
    fi
    return 0
}

#######################################
# Adds a key to an array the first time a walk goes past it, so the keys come
# back in the order they are written in.
#
# Usage:
#   stealth::sys::data::toml::_collect_keys out seen 'engine' 'engine' 'timeout' '30' '30'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (Nameref) - The keys already added
#   $3 (String)  - The table wanted
#   $4 (String)  - The table this setting is in
#   $5 (String)  - The key
#   $6 (String)  - The value
#   $7 (String)  - The value as it is written
# Returns:
#   0 - Go on walking
#######################################
stealth::sys::data::toml::_collect_keys() {
    local -n _toml_ck_out="${1}"
    local -n _toml_ck_seen="${2}"

    if [[ "${4}" != "${3}" ]]; then
        return 0
    fi
    if [[ -v _toml_ck_seen["${5}"] ]]; then
        return 0
    fi

    _toml_ck_seen["${5}"]=1
    _toml_ck_out+=("${5}")
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the value of a key in a table. The empty string names the keys
# written before any table opens.
#
# Usage:
#   stealth::sys::data::toml::read value "${file}" engine timeout
#   stealth::sys::data::toml::read value "${file}" '' name
#   stealth::sys::data::toml::read value "${file}" engine timeout 30
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The table, empty for the keys before any table
#   $4 (String)  - The key
#   $5 (String)  - What to give back when the key is not there
# Returns:
#   0 - Found, or the default was used
#   1 - Not there and no default was given
#   Exits 1 when an output variable, a file or a key is missing
#######################################
stealth::sys::data::toml::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    stealth::util::assert::not_empty "${4:-}" 'a key is required'
    local -n _toml_read_out="${1}"

    local -i _toml_read_found=0
    stealth::sys::data::toml::_walk "${2}" stealth::sys::data::toml::_take \
        "${1}" _toml_read_found "${3:-}" "${4}"

    if (( _toml_read_found == 1 )); then
        return 0
    fi

    _toml_read_out="${5:-}"
    if (( $# >= 5 )); then
        return 0
    fi
    return 1
}

#######################################
# Reports whether a file sets a key in a table.
#
# Usage:
#   if stealth::sys::data::toml::has "${file}" engine timeout; then ...
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The table
#   $3 (String) - The key
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::toml::has() {
    local _toml_has_value
    stealth::sys::data::toml::read _toml_has_value "${1:-}" "${2:-}" "${3:-}"
}

#######################################
# Reports whether a file opens a table.
#
# Usage:
#   if stealth::sys::data::toml::has_table "${file}" engine; then ...
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The table
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when no file is given
#######################################
stealth::sys::data::toml::has_table() {
    stealth::util::assert::is_file "${1:-}" "no file to read at ${1:-}"

    local -a _toml_ht_names=()
    stealth::sys::data::toml::tables _toml_ht_names "${1}"

    local _toml_ht_name
    for _toml_ht_name in "${_toml_ht_names[@]}"; do
        if [[ "${_toml_ht_name}" == "${2:-}" ]]; then
            return 0
        fi
    done
    return 1
}

#######################################
# Fills an array with the tables a file opens, in the order they appear. The
# keys before any table are not one, and nothing is reported for them. An
# array of tables is not one either, because nothing here can read it.
#
# Usage:
#   stealth::sys::data::toml::tables names "${file}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
# Globals:
#   _STEALTH_SYS_DATA_TOML_TABLE_RE (Read)
# Returns:
#   0 - Filled
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::toml::tables() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _toml_tabs_out="${1}"

    _toml_tabs_out=()
    local -A _toml_tabs_seen=()
    local _toml_tabs_line _toml_tabs_name

    while IFS= read -r _toml_tabs_line || [[ -n "${_toml_tabs_line}" ]]; do
        if ! stealth::sys::data::toml::_table _toml_tabs_name "${_toml_tabs_line}"; then
            continue
        fi
        if [[ ! "${_toml_tabs_name}" =~ ${_STEALTH_SYS_DATA_TOML_TABLE_RE} ]]; then
            continue
        fi
        if [[ -v _toml_tabs_seen["${_toml_tabs_name}"] ]]; then
            continue
        fi
        _toml_tabs_seen["${_toml_tabs_name}"]=1
        _toml_tabs_out+=("${_toml_tabs_name}")
    done < "${2}"
    return 0
}

#######################################
# Fills an array with the keys of one table, in the order they appear.
#
# Usage:
#   stealth::sys::data::toml::keys names "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $3 (String)  - The table, empty for the keys before any table
# Returns:
#   0 - Filled, and empty when the table is not there
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::toml::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _toml_keys_out="${1}"

    _toml_keys_out=()
    local -A _toml_keys_seen=()
    stealth::sys::data::toml::_walk "${2}" stealth::sys::data::toml::_collect_keys \
        "${1}" _toml_keys_seen "${3:-}"
    return 0
}

#######################################
# Fills an associative array with one whole table, which is one pass over the
# file rather than one pass for every key the caller wants.
#
# Usage:
#   local -A engine=()
#   stealth::sys::data::toml::load engine "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The file
#   $3 (String)  - The table, empty for the keys before any table
# Returns:
#   0 - Filled, and empty when the table is not there
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::toml::load() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _toml_load_out="${1}"

    _toml_load_out=()
    stealth::sys::data::toml::_walk "${2}" stealth::sys::data::toml::_collect \
        "${1}" "${3:-}"
    return 0
}

#######################################
# Says what kind of value a key holds, as TOML counts kinds.
#
# Usage:
#   stealth::sys::data::toml::type kind "${file}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable: string, integer, float, boolean,
#                  array or table
#   $2 (String)  - The file
#   $3 (String)  - The table
#   $4 (String)  - The key
# Globals:
#   _STEALTH_SYS_DATA_TOML_INT_RE (Read)
#   _STEALTH_SYS_DATA_TOML_FLOAT_RE (Read)
# Returns:
#   0 - Said
#   1 - There is no such key
#   Exits 1 when an output variable, a file or a key is missing
#######################################
stealth::sys::data::toml::type() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _toml_type_out="${1}"

    local _toml_type_raw
    if ! stealth::sys::data::toml::_raw _toml_type_raw "${2:-}" "${3:-}" "${4:-}"; then
        _toml_type_out=''
        return 1
    fi

    if [[ "${_toml_type_raw}" == 'true' || "${_toml_type_raw}" == 'false' ]]; then
        _toml_type_out='boolean'
    elif [[ "${_toml_type_raw}" =~ ${_STEALTH_SYS_DATA_TOML_INT_RE} ]]; then
        _toml_type_out='integer'
    elif [[ "${_toml_type_raw}" =~ ${_STEALTH_SYS_DATA_TOML_FLOAT_RE} ]]; then
        _toml_type_out='float'
    elif [[ "${_toml_type_raw}" == '['*']' ]]; then
        _toml_type_out='array'
    elif [[ "${_toml_type_raw}" == '{'*'}' ]]; then
        _toml_type_out='table'
    else
        _toml_type_out='string'
    fi
    return 0
}

#######################################
# Reads the value of a key as it is written, quotes and all. type works out
# what kind a value is from this, because what kind it is is a question about
# how it was written.
#
# Usage:
#   stealth::sys::data::toml::_raw written "${file}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The table
#   $4 (String)  - The key
# Returns:
#   0 - Found
#   1 - There is no such key
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::toml::_raw() {
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    stealth::util::assert::not_empty "${4:-}" 'a key is required'
    local -n _toml_raw_out="${1}"

    _toml_raw_out=''
    local -i _toml_raw_found=0
    stealth::sys::data::toml::_walk "${2}" stealth::sys::data::toml::_take_raw \
        "${1}" _toml_raw_found "${3}" "${4}"

    (( _toml_raw_found == 1 ))
}

#######################################
# Sets a key in a table, where it already stands or at the end of that table.
# A table that is not there yet is opened at the end of the file.
#
# Usage:
#   stealth::sys::data::toml::set "${file}" engine timeout 30
#   stealth::sys::data::toml::set "${file}" engine name build --string
#   stealth::sys::data::toml::set "${file}" engine hosts '["a", "b"]' --raw
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $2 (String) - The table, empty for the keys before any table
#   $3 (String) - The key
#   $4 (String) - The value
#   $5 (String) - --string to write it as one whatever it looks like, --raw to
#                 write it as it stands
# Returns:
#   0 - The file sets the key to that value
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing, or one of them cannot be written
#   to a file of this kind
#######################################
stealth::sys::data::toml::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    stealth::util::assert::not_empty "${3:-}" 'a key is required'
    stealth::sys::data::toml::_check "${2:-}" "${3}" "${5:-}"

    local _toml_set_written
    stealth::sys::data::toml::_write _toml_set_written "${4:-}" "${5:-}"

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::toml::_edit "${2:-}" "${3}" 'set' "${_toml_set_written}"
}

#######################################
# Takes a key out of a table, along with every line that set it. The table
# itself stays, even when nothing is left in it.
#
# Usage:
#   stealth::sys::data::toml::delete "${file}" engine timeout
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The table
#   $3 (String) - The key
# Returns:
#   0 - The table does not set the key
#   1 - It could not be put in place
#   Exits 1 when a file or a key is missing
#######################################
stealth::sys::data::toml::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${3:-}" 'a key is required'

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::toml::_edit "${2:-}" "${3}" 'delete' ''
}

#######################################
# Rewrites a staged file with one key set or taken out, keeping every line
# that is not the one in question. This is the callback sys/io/fs::atomic
# runs, so the file the caller asked about is replaced in one step or not at
# all.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::toml::_edit 'engine' 'timeout' 'set' '30'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The table
#   $3 (String) - The key
#   $4 (String) - set or delete
#   $5 (String) - The value as it is to be written, when setting
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::toml::_edit() {
    local -r _toml_edit_staged="${1}"
    local -r _toml_edit_table="${2}"
    local -r _toml_edit_key="${3}"
    local -r _toml_edit_what="${4}"
    local -r _toml_edit_line_new="${3} = ${5}"

    local -a _toml_edit_out=() _toml_edit_held=()
    local _toml_edit_line _toml_edit_at='' _toml_edit_name
    local _toml_edit_this _toml_edit_value
    local -i _toml_edit_done=0 _toml_edit_seen=0
    local -i _toml_edit_depth=0 _toml_edit_dropping=0

    if [[ -z "${_toml_edit_table}" ]]; then
        _toml_edit_seen=1
    fi

    while IFS= read -r _toml_edit_line || [[ -n "${_toml_edit_line}" ]]; do
        # A value left open on the line before runs on into this one. Whether
        # those lines are kept depends on whose value it is, which is what
        # dropping remembers: the key being replaced or taken out loses its
        # own continuation lines, and every other key keeps them.
        if (( _toml_edit_depth > 0 )); then
            stealth::sys::data::toml::_depth _toml_edit_depth "${_toml_edit_line}"
            if (( _toml_edit_dropping == 0 )); then
                _toml_edit_out+=("${_toml_edit_line}")
            fi
            if (( _toml_edit_depth <= 0 )); then
                _toml_edit_depth=0
                _toml_edit_dropping=0
            fi
            continue
        fi

        if stealth::sys::data::toml::_table _toml_edit_name "${_toml_edit_line}"; then
            if [[ "${_toml_edit_at}" == "${_toml_edit_table}" && \
                  "${_toml_edit_what}" == 'set' && _toml_edit_seen -eq 1 && \
                  _toml_edit_done -eq 0 ]]; then
                _toml_edit_out+=("${_toml_edit_line_new}")
                _toml_edit_done=1
            fi
            _toml_edit_out+=("${_toml_edit_held[@]}" "${_toml_edit_line}")
            _toml_edit_held=()
            _toml_edit_at="${_toml_edit_name}"
            if [[ "${_toml_edit_at}" == "${_toml_edit_table}" ]]; then
                _toml_edit_seen=1
            fi
            continue
        fi

        if [[ -z "${_toml_edit_line//[[:space:]]/}" ]]; then
            _toml_edit_held+=("${_toml_edit_line}")
            continue
        fi

        _toml_edit_depth=0
        stealth::sys::data::toml::_depth _toml_edit_depth "${_toml_edit_line}"

        if [[ "${_toml_edit_at}" != "${_toml_edit_table}" ]] || \
           ! stealth::sys::data::toml::_split _toml_edit_this _toml_edit_value \
               "${_toml_edit_line}" || \
           [[ "${_toml_edit_this}" != "${_toml_edit_key}" ]]; then
            _toml_edit_out+=("${_toml_edit_held[@]}" "${_toml_edit_line}")
            _toml_edit_held=()
            continue
        fi

        if [[ "${_toml_edit_what}" == 'set' && _toml_edit_done -eq 0 ]]; then
            _toml_edit_out+=("${_toml_edit_held[@]}" "${_toml_edit_line_new}")
            _toml_edit_held=()
            _toml_edit_done=1
        fi
        if (( _toml_edit_depth > 0 )); then
            _toml_edit_dropping=1
        fi
    done < "${_toml_edit_staged}"

    stealth::sys::data::toml::_finish _toml_edit_out _toml_edit_held \
        "${_toml_edit_table}" "${_toml_edit_line_new}" "${_toml_edit_what}" \
        "${_toml_edit_done}" "${_toml_edit_seen}" "${_toml_edit_at}"

    if (( ${#_toml_edit_out[@]} == 0 )); then
        : > "${_toml_edit_staged}"
        return 0
    fi

    printf '%s\n' "${_toml_edit_out[@]}" > "${_toml_edit_staged}"
    return 0
}

#######################################
# Puts the last lines of an edited file together: the key that has not been
# written yet, the table to open for it when there is none, and the blank
# lines that were held back.
#
# Usage:
#   stealth::sys::data::toml::_finish out held 'engine' 'timeout = 30' set 0 0 ''
#
# Arguments:
#   $1 (Nameref) - The array of lines so far
#   $2 (Nameref) - The blank lines held back
#   $3 (String)  - The table
#   $4 (String)  - The line to write for the key
#   $5 (String)  - set or delete
#   $6 (Integer) - 1 when the key has already been written
#   $7 (Integer) - 1 when the table was seen
#   $8 (String)  - The table the file ended in
# Returns:
#   0 - Put together
#######################################
stealth::sys::data::toml::_finish() {
    local -n _toml_fin_out="${1}"
    local -n _toml_fin_held="${2}"

    if [[ "${5}" != 'set' || "${6}" -eq 1 ]]; then
        _toml_fin_out+=("${_toml_fin_held[@]}")
        return 0
    fi

    if (( ${7} == 1 )) && [[ "${8}" == "${3}" ]]; then
        _toml_fin_out+=("${4}" "${_toml_fin_held[@]}")
        return 0
    fi

    _toml_fin_out+=("${_toml_fin_held[@]}")
    if [[ -n "${3}" ]]; then
        if (( ${#_toml_fin_out[@]} > 0 )); then
            _toml_fin_out+=('')
        fi
        _toml_fin_out+=("[${3}]")
    fi
    _toml_fin_out+=("${4}")
    return 0
}

#######################################
# Takes a whole table out of a file, its heading and everything in it.
#
# Usage:
#   stealth::sys::data::toml::delete_table "${file}" engine
#
# Arguments:
#   $1 (String) - The file
#   $2 (String) - The table
# Returns:
#   0 - The file does not hold the table
#   1 - It could not be put in place
#   Exits 1 when a file or a table is missing
#######################################
stealth::sys::data::toml::delete_table() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a table is required'

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::toml::_drop_table "${2}"
}

#######################################
# Rewrites a staged file without one table. The callback sys/io/fs::atomic
# runs for delete_table.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::toml::_drop_table 'engine'
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The table
# Returns:
#   0 - Rewritten
#######################################
stealth::sys::data::toml::_drop_table() {
    local -a _toml_drop_out=()
    local _toml_drop_line _toml_drop_at='' _toml_drop_name

    while IFS= read -r _toml_drop_line || [[ -n "${_toml_drop_line}" ]]; do
        if stealth::sys::data::toml::_table _toml_drop_name "${_toml_drop_line}"; then
            _toml_drop_at="${_toml_drop_name}"
        fi
        if [[ "${_toml_drop_at}" == "${2}" ]]; then
            continue
        fi
        _toml_drop_out+=("${_toml_drop_line}")
    done < "${1}"

    if (( ${#_toml_drop_out[@]} == 0 )); then
        : > "${1}"
        return 0
    fi

    printf '%s\n' "${_toml_drop_out[@]}" > "${1}"
    return 0
}

#######################################
# Puts everything one file holds into another, table by table and key by key,
# keeping how each value was written. What the target holds and the source
# does not is left alone.
#
# Usage:
#   stealth::sys::data::toml::merge "${config}" "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change, which is made when it is not there
#   $2 (String) - The file to take the settings from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, or the source is not there
#######################################
stealth::sys::data::toml::merge() {
    stealth::util::assert::not_empty "${1:-}" 'a file to change is required'
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    local -a _toml_merge_tables=()
    stealth::sys::data::toml::tables _toml_merge_tables "${2}"

    local -a _toml_merge_top=()
    stealth::sys::data::toml::keys _toml_merge_top "${2}" ''
    if (( ${#_toml_merge_top[@]} > 0 )); then
        _toml_merge_tables=('' "${_toml_merge_tables[@]}")
    fi

    if (( ${#_toml_merge_tables[@]} == 0 )); then
        stealth::util::log::debug '%s holds nothing to merge' "${2}"
        return 0
    fi

    local _toml_merge_table _toml_merge_key _toml_merge_written
    local -a _toml_merge_keys=()

    for _toml_merge_table in "${_toml_merge_tables[@]}"; do
        stealth::sys::data::toml::keys _toml_merge_keys "${2}" "${_toml_merge_table}"
        for _toml_merge_key in "${_toml_merge_keys[@]}"; do
            stealth::sys::data::toml::_raw _toml_merge_written "${2}" \
                "${_toml_merge_table}" "${_toml_merge_key}"
            stealth::sys::data::toml::set "${1}" "${_toml_merge_table}" \
                "${_toml_merge_key}" "${_toml_merge_written}" --raw
        done
    done
    return 0
}

#######################################
# Reports whether every line of a file is one this module understands: a
# blank line, a comment, a table heading, or a key being set.
#
# An array of tables, written [[name]], makes this say no. It is valid TOML
# and it is not part of the subset here, and a reader that took it for an
# ordinary table would give back an answer that is wrong rather than missing.
#
# A bracket or a brace that is never closed makes this say no as well. A
# reader here joins the lines of a value until the brackets balance, so an
# unbalanced one swallows the rest of the file.
#
# Usage:
#   if ! stealth::sys::data::toml::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - Every line is
#   1 - One is not, or there is no such file
#######################################
stealth::sys::data::toml::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi
    local -r _toml_valid_file="${1}"

    local _toml_valid_line _toml_valid_trimmed _toml_valid_name
    local _toml_valid_key _toml_valid_value _toml_valid_bad=''
    local -i _toml_valid_depth=0

    while IFS= read -r _toml_valid_line || [[ -n "${_toml_valid_line}" ]]; do
        if (( _toml_valid_depth > 0 )); then
            stealth::sys::data::toml::_depth _toml_valid_depth "${_toml_valid_line}"
            continue
        fi

        stealth::util::text::trim _toml_valid_trimmed "${_toml_valid_line}"
        if [[ -z "${_toml_valid_trimmed}" || "${_toml_valid_trimmed}" == '#'* ]]; then
            continue
        fi
        if [[ "${_toml_valid_trimmed}" == '[['*']]' ]]; then
            _toml_valid_bad="${_toml_valid_trimmed}"
            break
        fi
        if stealth::sys::data::toml::_table _toml_valid_name "${_toml_valid_line}"; then
            continue
        fi
        if ! stealth::sys::data::toml::_split _toml_valid_key _toml_valid_value \
            "${_toml_valid_line}"; then
            _toml_valid_bad="${_toml_valid_trimmed}"
            break
        fi
        stealth::sys::data::toml::_depth _toml_valid_depth "${_toml_valid_line}"
    done < "${_toml_valid_file}"

    if [[ -z "${_toml_valid_bad}" ]] && (( _toml_valid_depth > 0 )); then
        _toml_valid_bad='a value left open at the end of the file'
    fi

    if [[ -n "${_toml_valid_bad}" ]]; then
        stealth::util::log::debug 'a line of %s is not one this reader knows: %s' \
            "${_toml_valid_file}" "${_toml_valid_bad}"
        return 1
    fi
    return 0
}
