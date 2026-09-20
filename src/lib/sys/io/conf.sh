###############################################################################
# module: sys/io/conf
# layer: sys
# description: One way to read and write a configuration file, whatever it is
#              written in.
#
#              The name of the file says what it is: .json, .yaml, .toml,
#              .ini, and KEY=VALUE for everything else. A caller that knows
#              which one it has is better off calling that module, because
#              each has more to offer than what every one of them can do. A
#              caller handed a path by a configuration file cannot know, and
#              that is what this is for.
#
#              A place in the file is named by a path, one argument per step,
#              and each format takes as many steps as it has room for. A
#              KEY=VALUE file is flat, so it takes one. An INI or a TOML file
#              is a section and a key, so it takes two, and one step means a
#              key written before any section opens. JSON and YAML nest as
#              deep as they like and take as many as there are.
#
#              A step too many is refused rather than folded away. A caller
#              asking for engine.timeout in a file that has no sections is a
#              caller that thinks it has a different file.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_IO_CONF:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_IO_CONF=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/data/ini" "sys/data/json" "sys/data/kv"
stealth::util::import "sys/data/toml" "sys/data/yaml"

# =============================================================================
# CONSTANTS
# =============================================================================

# What each ending is read as. Anything not here is read as KEY=VALUE, which
# is what /etc/os-release, /etc/sysconfig and a .env file are.
declare -grA _STEALTH_SYS_IO_CONF_BY_SUFFIX=([json]=json [yaml]=yaml [yml]=yaml [toml]=toml [ini]=ini [cfg]=ini [conf]=kv [env]=kv)

# What a file is read as when its name says nothing.
declare -gr _STEALTH_SYS_IO_CONF_DEFAULT='kv'

# How many steps of a path each format has room for. Zero means as many as
# the caller likes.
declare -grA _STEALTH_SYS_IO_CONF_DEPTH=([kv]=1 [ini]=2 [toml]=2 [json]=0 [yaml]=0)

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Turns a path into the arguments the module for a format takes. A flat
# format gets the one key, a format of sections gets a section and a key, and
# a nesting format gets the path as it stands.
#
# Usage:
#   stealth::sys::io::conf::_spread args ini engine timeout
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The format
#   $@ (String)  - The path, one step per argument
# Globals:
#   _STEALTH_SYS_IO_CONF_DEPTH (Read)
# Returns:
#   0 - Spread
#   Exits 1 when the path has more steps than the format has room for
#######################################
stealth::sys::io::conf::_spread() {
    local -n _conf_spread_out="${1}"
    local -r _conf_spread_format="${2}"
    shift 2

    local -ri _conf_spread_room="${_STEALTH_SYS_IO_CONF_DEPTH[${_conf_spread_format}]}"

    if (( _conf_spread_room == 0 )); then
        _conf_spread_out=("$@")
        return 0
    fi

    if (( $# > _conf_spread_room )); then
        stealth::util::assert::fail \
            "a ${_conf_spread_format} file goes ${_conf_spread_room} deep, and this path goes $#"
    fi

    if (( _conf_spread_room == 2 && $# == 1 )); then
        _conf_spread_out=('' "${1}")
        return 0
    fi

    _conf_spread_out=("$@")
    return 0
}

#######################################
# Turns a path into the arguments a format's keys function takes. A path one
# step short of what a value needs names the thing whose keys are wanted.
#
# Usage:
#   stealth::sys::io::conf::_spread_keys args ini engine
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The format
#   $@ (String)  - The path, one step per argument
# Globals:
#   _STEALTH_SYS_IO_CONF_DEPTH (Read)
# Returns:
#   0 - Spread
#   Exits 1 when the path has more steps than the format has room for
#######################################
stealth::sys::io::conf::_spread_keys() {
    local -n _conf_sk_out="${1}"
    local -r _conf_sk_format="${2}"
    shift 2

    local -ri _conf_sk_room="${_STEALTH_SYS_IO_CONF_DEPTH[${_conf_sk_format}]}"

    if (( _conf_sk_room == 0 )); then
        _conf_sk_out=("$@")
        return 0
    fi

    if (( $# >= _conf_sk_room )); then
        stealth::util::assert::fail \
            "a ${_conf_sk_format} file has nothing under $*"
    fi

    if (( _conf_sk_room == 2 && $# == 0 )); then
        _conf_sk_out=('')
        return 0
    fi

    _conf_sk_out=("$@")
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says what a file is read as, from what it is called.
#
# Usage:
#   stealth::sys::io::conf::kind format /etc/containers/storage.conf
#
# Arguments:
#   $1 (Nameref) - The output variable: json, yaml, toml, ini or kv
#   $2 (String)  - The file, which need not be there
# Globals:
#   _STEALTH_SYS_IO_CONF_BY_SUFFIX (Read)
#   _STEALTH_SYS_IO_CONF_DEFAULT (Read)
# Returns:
#   0 - Said
#   Exits 1 when no output variable or no file is given
#######################################
stealth::sys::io::conf::kind() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a file is required'
    local -n _conf_kind_out="${1}"

    local -r _conf_kind_name="${2##*/}"
    local -r _conf_kind_suffix="${_conf_kind_name##*.}"

    if [[ "${_conf_kind_suffix}" != "${_conf_kind_name}" ]] && \
       [[ -v _STEALTH_SYS_IO_CONF_BY_SUFFIX["${_conf_kind_suffix,,}"] ]]; then
        _conf_kind_out="${_STEALTH_SYS_IO_CONF_BY_SUFFIX[${_conf_kind_suffix,,}]}"
        return 0
    fi

    _conf_kind_out="${_STEALTH_SYS_IO_CONF_DEFAULT}"
    return 0
}

#######################################
# Reads the value at a path, whatever the file is written in.
#
# Usage:
#   stealth::sys::io::conf::read value /etc/os-release ID
#   stealth::sys::io::conf::read value "${file}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Found
#   1 - Not there, or the file is not one this format can read
#   Exits 1 when an output variable, a file or a path is missing, or the path
#   has more steps than the format has room for
#######################################
stealth::sys::io::conf::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    stealth::util::assert::not_empty "${3:-}" 'a path is required'
    local -r _conf_read_var="${1}"
    local -r _conf_read_file="${2}"
    shift 2

    local _conf_read_format
    stealth::sys::io::conf::kind _conf_read_format "${_conf_read_file}"

    local -a _conf_read_args=()
    stealth::sys::io::conf::_spread _conf_read_args "${_conf_read_format}" "$@"

    "stealth::sys::data::${_conf_read_format}::read" "${_conf_read_var}" \
        "${_conf_read_file}" "${_conf_read_args[@]}"
}

#######################################
# Reports whether a file sets a path.
#
# Usage:
#   if stealth::sys::io::conf::has /etc/os-release VARIANT_ID; then ...
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Returns:
#   0 - It does
#   1 - It does not
#   Exits 1 when a file or a path is missing, or the path has more steps than
#   the format has room for
#######################################
stealth::sys::io::conf::has() {
    stealth::util::assert::is_file "${1:-}" "no file to read at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _conf_has_file="${1}"
    shift

    local _conf_has_format
    stealth::sys::io::conf::kind _conf_has_format "${_conf_has_file}"

    local -a _conf_has_args=()
    stealth::sys::io::conf::_spread _conf_has_args "${_conf_has_format}" "$@"

    "stealth::sys::data::${_conf_has_format}::has" "${_conf_has_file}" \
        "${_conf_has_args[@]}"
}

#######################################
# Fills an array with the keys under a path, in the order the file writes
# them. Without a path that is the top of the file.
#
# Usage:
#   stealth::sys::io::conf::keys names /etc/os-release
#   stealth::sys::io::conf::keys names "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Filled
#   1 - There is nothing to list at that path
#   Exits 1 when an output array or a file is missing, or the path is deeper
#   than the format has room for
#######################################
stealth::sys::io::conf::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -r _conf_keys_var="${1}"
    local -r _conf_keys_file="${2}"
    shift 2

    local _conf_keys_format
    stealth::sys::io::conf::kind _conf_keys_format "${_conf_keys_file}"

    local -a _conf_keys_args=()
    stealth::sys::io::conf::_spread_keys _conf_keys_args \
        "${_conf_keys_format}" "$@"

    "stealth::sys::data::${_conf_keys_format}::keys" "${_conf_keys_var}" \
        "${_conf_keys_file}" "${_conf_keys_args[@]}"
}

#######################################
# Sets the value at a path. The last argument is the value and everything
# before it is the path.
#
# A format that has types works out which one the value is from how it is
# written, and --string says it is a string whatever it looks like. A format
# that has no types pays no attention to either.
#
# Usage:
#   stealth::sys::io::conf::set /etc/os-release VARIANT_ID stealth
#   stealth::sys::io::conf::set "${file}" --string engine port 8080
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $@ (String) - --string, then the path, then the value
# Globals:
#   _STEALTH_SYS_IO_CONF_DEPTH (Read)
# Returns:
#   0 - The file holds that value at that path
#   1 - It could not be put in place
#   Exits 1 when a file, a path or a value is missing, or the path has more
#   steps than the format has room for
#######################################
stealth::sys::io::conf::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    local -r _conf_set_file="${1}"
    shift

    local -a _conf_set_rest=()
    local -i _conf_set_string=0
    while (( $# > 0 )); do
        case "${1}" in
            --string)
                _conf_set_string=1
                shift
                ;;
            *)
                _conf_set_rest+=("${1}")
                shift
                ;;
        esac
    done

    if (( ${#_conf_set_rest[@]} < 2 )); then
        stealth::util::assert::fail 'a path and a value are required'
    fi

    local _conf_set_format
    stealth::sys::io::conf::kind _conf_set_format "${_conf_set_file}"

    local -r _conf_set_value="${_conf_set_rest[-1]}"
    local -a _conf_set_args=()
    stealth::sys::io::conf::_spread _conf_set_args "${_conf_set_format}" \
        "${_conf_set_rest[@]:0:${#_conf_set_rest[@]}-1}"

    stealth::sys::io::conf::_set_one "${_conf_set_format}" "${_conf_set_file}" \
        "${_conf_set_value}" "${_conf_set_string}" "${_conf_set_args[@]}"
}

#######################################
# Calls the set of one format, with the value and the option where that
# format wants them. json and yaml take the option before the path, and toml
# takes it after the value.
#
# Usage:
#   stealth::sys::io::conf::_set_one toml "${file}" 30 0 engine timeout
#
# Arguments:
#   $1 (String)  - The format
#   $2 (String)  - The file
#   $3 (String)  - The value
#   $4 (Integer) - 1 when the value is to be a string whatever it looks like
#   $@ (String)  - The path, spread for that format
# Returns:
#   0 - Set
#   1 - It could not be put in place
#######################################
stealth::sys::io::conf::_set_one() {
    local -r _conf_so_format="${1}"
    local -r _conf_so_file="${2}"
    local -r _conf_so_value="${3}"
    local -ri _conf_so_string="${4}"
    shift 4

    case "${_conf_so_format}" in
        json|yaml)
            local -a _conf_so_opt=()
            if (( _conf_so_string == 1 )); then
                _conf_so_opt=(--string)
            fi
            "stealth::sys::data::${_conf_so_format}::set" "${_conf_so_file}" \
                "${_conf_so_opt[@]}" "$@" "${_conf_so_value}"
            ;;
        toml)
            local _conf_so_how=''
            if (( _conf_so_string == 1 )); then
                _conf_so_how='--string'
            fi
            stealth::sys::data::toml::set "${_conf_so_file}" "$@" \
                "${_conf_so_value}" "${_conf_so_how}"
            ;;
        *)
            "stealth::sys::data::${_conf_so_format}::set" "${_conf_so_file}" \
                "$@" "${_conf_so_value}"
            ;;
    esac
}

#######################################
# Takes a path out of a file.
#
# Usage:
#   stealth::sys::io::conf::delete /etc/os-release OLD_SETTING
#   stealth::sys::io::conf::delete "${file}" engine timeout
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Returns:
#   0 - The file does not hold that path
#   1 - It could not be put in place
#   Exits 1 when a file or a path is missing, or the path has more steps than
#   the format has room for
#######################################
stealth::sys::io::conf::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _conf_del_file="${1}"
    shift

    local _conf_del_format
    stealth::sys::io::conf::kind _conf_del_format "${_conf_del_file}"

    local -a _conf_del_args=()
    stealth::sys::io::conf::_spread _conf_del_args "${_conf_del_format}" "$@"

    "stealth::sys::data::${_conf_del_format}::delete" "${_conf_del_file}" \
        "${_conf_del_args[@]}"
}

#######################################
# Puts everything one file holds into another. Both have to be written in the
# same thing, because merging a YAML file into a KEY=VALUE one is not a
# question with an answer.
#
# Usage:
#   stealth::sys::io::conf::merge /etc/containers/storage.conf "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change
#   $2 (String) - The file to take the settings from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, the source is not there, or the two are
#   written in different things
#######################################
stealth::sys::io::conf::merge() {
    stealth::util::assert::not_empty "${1:-}" 'a file to change is required'
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    local _conf_merge_target _conf_merge_source
    stealth::sys::io::conf::kind _conf_merge_target "${1}"
    stealth::sys::io::conf::kind _conf_merge_source "${2}"

    if [[ "${_conf_merge_target}" != "${_conf_merge_source}" ]]; then
        stealth::util::assert::fail \
            "${1} is ${_conf_merge_target} and ${2} is ${_conf_merge_source}, which do not merge"
    fi

    "stealth::sys::data::${_conf_merge_target}::merge" "${1}" "${2}"
}

#######################################
# Reports whether a file is written the way its name says it is.
#
# Usage:
#   if ! stealth::sys::io::conf::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - It is
#   1 - It is not, or there is no such file
#######################################
stealth::sys::io::conf::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi

    local _conf_valid_format
    stealth::sys::io::conf::kind _conf_valid_format "${1}"

    "stealth::sys::data::${_conf_valid_format}::is_valid" "${1}"
}
