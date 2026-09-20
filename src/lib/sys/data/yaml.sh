###############################################################################
# module: sys/data/yaml
# layer: sys
# description: YAML files, read through JSON and written with yq.
#
#              Reading turns the document into JSON and asks sys/data/json.
#              That module already knows how to reach a place by a path that
#              is data rather than program, and how to tell a key set to null
#              from a key that is not there. Comments do not matter to a
#              reader, so nothing is lost by going that way, and there is one
#              answer to every question instead of two that have to agree.
#
#              Writing goes to yq, because yq keeps the comments and the
#              layout of the file it changes. The path and the value reach it
#              through the environment, which is yq's way of taking something
#              as data: yq has no --args, and an expression built by pasting
#              a key into it is an expression the caller wrote.
#
#              set works out what kind a value is from how it is written, the
#              same way sys/data/json and sys/data/toml do. --string and
#              --yaml say so outright when the guess would be wrong.
# copyright: Stealth Scale B.V.
###############################################################################

# shellcheck disable=SC2016
# The single quotes here are deliberate. $ARGS is a variable of jq's and
# $item is one of yq's, and a program that let the shell expand either would
# be a program built out of whatever the caller passed.

if [[ -n "${_STEALTH_LIB_SYS_DATA_YAML:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_DATA_YAML=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs" "sys/io/tmp"
stealth::util::import "sys/data/json"

# =============================================================================
# CONSTANTS
# =============================================================================

# How yq is asked for JSON: one line, so that a converted document is one
# document and not a shape that depends on how deep it is.
declare -gra _STEALTH_SYS_DATA_YAML_TO_JSON=(--output-format=json --indent=0)

# How yq is asked for YAML back.
declare -gra _STEALTH_SYS_DATA_YAML_TO_YAML=(--prettyPrint --output-format=yaml)

# The environment variables a path and a value reach yq through. yq reads
# them with env, which parses what it finds, and strenv, which does not.
declare -gr _STEALTH_SYS_DATA_YAML_PATH_VAR='_STEALTH_YAML_PATH'
declare -gr _STEALTH_SYS_DATA_YAML_VALUE_VAR='_STEALTH_YAML_VALUE'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Writes a document out as JSON, to a temporary file the caller removes.
#
# Usage:
#   stealth::sys::data::yaml::_as_json converted "${file}"
#
# Arguments:
#   $1 (Nameref) - The output variable for the path of the JSON file
#   $2 (String)  - The YAML file
# Globals:
#   _STEALTH_SYS_DATA_YAML_TO_JSON (Read)
# Returns:
#   0 - Written
#   1 - yq would not read the document
#######################################
stealth::sys::data::yaml::_as_json() {
    local -n _yaml_aj_out="${1}"

    stealth::sys::io::tmp::file _yaml_aj_out 'yaml.XXXXXXXX.json'

    local _yaml_aj_text
    if ! stealth::sys::cmd::capture _yaml_aj_text yq \
        "${_STEALTH_SYS_DATA_YAML_TO_JSON[@]}" '.' "${2}"; then
        stealth::util::log::debug '%s is not YAML yq will read' "${2}"
        return 1
    fi

    printf '%s\n' "${_yaml_aj_text}" > "${_yaml_aj_out}"
    return 0
}

#######################################
# Turns a path into the JSON array yq reads it as, so that a key with a
# quote or a bracket in it stays one key.
#
# Usage:
#   stealth::sys::data::yaml::_path_json written engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Written
#######################################
stealth::sys::data::yaml::_path_json() {
    local -r _yaml_pj_var="${1}"
    shift

    stealth::sys::cmd::capture "${_yaml_pj_var}" \
        jq --compact-output --null-input '$ARGS.positional' --args "$@"
}

#######################################
# Runs a yq program that rewrites a file, with the path and the value in the
# environment, and leaves the result in the staged file sys/io/fs is holding.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::yaml::_rewrite "${program}" "${path}" "${value}"
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The program
#   $3 (String) - The path, as a JSON array
#   $4 (String) - The value, as yq is to read it
# Globals:
#   _STEALTH_SYS_DATA_YAML_TO_YAML (Read)
#   _STEALTH_SYS_DATA_YAML_PATH_VAR (Read)
#   _STEALTH_SYS_DATA_YAML_VALUE_VAR (Read)
# Returns:
#   0 - Rewritten
#   1 - yq refused the program or the document
#######################################
stealth::sys::data::yaml::_rewrite() {
    local -r _yaml_rw_staged="${1}"

    local _yaml_rw_text
    if ! stealth::sys::cmd::capture _yaml_rw_text \
        env "${_STEALTH_SYS_DATA_YAML_PATH_VAR}=${3}" \
            "${_STEALTH_SYS_DATA_YAML_VALUE_VAR}=${4:-}" \
        yq "${_STEALTH_SYS_DATA_YAML_TO_YAML[@]}" "${2}" "${_yaml_rw_staged}"; then
        return 1
    fi

    printf '%s\n' "${_yaml_rw_text}" > "${_yaml_rw_staged}"
    return 0
}

#######################################
# Asks sys/data/json a question about a document, by turning it into JSON
# first. The temporary file goes as soon as the answer is in.
#
# Usage:
#   stealth::sys::data::yaml::_ask stealth::sys::data::json::read \
#       value "${file}" engine timeout
#
# Arguments:
#   $1 (String) - The function of sys/data/json to call
#   $2 (String) - The output variable or array to pass it first
#   $3 (String) - The YAML file
#   $@ (String) - Everything else to pass it
# Returns:
#   The status that function gave
#   1 - yq would not read the document
#######################################
stealth::sys::data::yaml::_ask() {
    local -r _yaml_ask_fn="${1}"
    local -r _yaml_ask_var="${2}"
    local -r _yaml_ask_file="${3}"
    shift 3

    local _yaml_ask_json
    if ! stealth::sys::data::yaml::_as_json _yaml_ask_json "${_yaml_ask_file}"; then
        stealth::sys::io::tmp::remove "${_yaml_ask_json}"
        return 1
    fi

    local -i _yaml_ask_status=0
    "${_yaml_ask_fn}" "${_yaml_ask_var}" "${_yaml_ask_json}" "$@" \
        || _yaml_ask_status=$?

    stealth::sys::io::tmp::remove "${_yaml_ask_json}"
    return "${_yaml_ask_status}"
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the value at a path. A string comes back as itself and everything
# else comes back as the JSON it is, written on one line, which is what
# sys/data/json gives.
#
# Usage:
#   stealth::sys::data::yaml::read value "${file}" engine timeout
#   stealth::sys::data::yaml::read value "${file}" --default 30 engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $@ (String)  - --default X, then the path, one step per argument
# Returns:
#   0 - Found, or the default was used
#   1 - Not there, or the document is not YAML
#   Exits 1 when an output variable, a file or a path is missing
#######################################
stealth::sys::data::yaml::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"

    stealth::sys::data::yaml::_ask stealth::sys::data::json::read "$@"
}

#######################################
# Reports whether a path is there, which is not the same as whether it holds
# anything. A key set to null is there.
#
# Usage:
#   if stealth::sys::data::yaml::has "${file}" engine timeout; then ...
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Returns:
#   0 - It is there
#   1 - It is not, or the document is not YAML
#   Exits 1 when a file or a path is missing
#######################################
stealth::sys::data::yaml::has() {
    stealth::util::assert::is_file "${1:-}" "no file to read at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _yaml_has_file="${1}"
    shift

    local _yaml_has_json
    if ! stealth::sys::data::yaml::_as_json _yaml_has_json "${_yaml_has_file}"; then
        stealth::sys::io::tmp::remove "${_yaml_has_json}"
        return 1
    fi

    local -i _yaml_has_status=0
    stealth::sys::data::json::has "${_yaml_has_json}" "$@" || _yaml_has_status=$?

    stealth::sys::io::tmp::remove "${_yaml_has_json}"
    return "${_yaml_has_status}"
}

#######################################
# Fills an array with the keys of the mapping at a path, in the order the
# file writes them. Without a path that is the document itself.
#
# Usage:
#   stealth::sys::data::yaml::keys names "${file}"
#   stealth::sys::data::yaml::keys names "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Filled
#   1 - There is no mapping at that path, or the document is not YAML
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::yaml::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"

    stealth::sys::data::yaml::_ask stealth::sys::data::json::keys "$@"
}

#######################################
# Fills an associative array with the keys and values of the mapping at a
# path. A value that is not a scalar comes back as the JSON it is.
#
# Usage:
#   local -A engine=()
#   stealth::sys::data::yaml::load engine "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Filled
#   1 - There is no mapping at that path, or the document is not YAML
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::yaml::load() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"

    stealth::sys::data::yaml::_ask stealth::sys::data::json::load "$@"
}

#######################################
# Says what kind of value is at a path, in the words JSON uses for kinds
# rather than the tags YAML uses, so that a caller reading a .yaml and a
# caller reading a .json get the same answer.
#
# Usage:
#   stealth::sys::data::yaml::type kind "${file}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable: string, number, boolean, array,
#                  object or null
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Said
#   1 - There is nothing at that path, or the document is not YAML
#   Exits 1 when an output variable or a file is missing
#######################################
stealth::sys::data::yaml::type() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"

    stealth::sys::data::yaml::_ask stealth::sys::data::json::type "$@"
}

#######################################
# Sets the value at a path, making whatever mappings it takes to get there,
# and leaving the comments and the layout of the file as they were.
#
# The last argument is the value and everything before it is the path.
#
# Usage:
#   stealth::sys::data::yaml::set "${file}" engine timeout 30
#   stealth::sys::data::yaml::set "${file}" --string engine port 8080
#   stealth::sys::data::yaml::set "${file}" --yaml engine hosts '[a, b]'
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $@ (String) - --string or --yaml, then the path, then the value
# Globals:
#   _STEALTH_SYS_DATA_YAML_PATH_VAR (Read)
#   _STEALTH_SYS_DATA_YAML_VALUE_VAR (Read)
# Returns:
#   0 - The file holds that value at that path
#   1 - It could not be put in place
#   Exits 1 when a file, a path or a value is missing
#######################################
stealth::sys::data::yaml::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    local -r _yaml_set_file="${1}"
    shift

    local _yaml_set_how=''
    local -a _yaml_set_rest=()
    while (( $# > 0 )); do
        case "${1}" in
            --string|--yaml)
                _yaml_set_how="${1}"
                shift
                ;;
            *)
                _yaml_set_rest+=("${1}")
                shift
                ;;
        esac
    done

    if (( ${#_yaml_set_rest[@]} < 2 )); then
        stealth::util::assert::fail 'a path and a value are required'
    fi

    local -r _yaml_set_value="${_yaml_set_rest[-1]}"
    local _yaml_set_path
    stealth::sys::data::yaml::_path_json _yaml_set_path \
        "${_yaml_set_rest[@]:0:${#_yaml_set_rest[@]}-1}"

    # env parses what it reads, so a value that looks like a number goes in
    # as one. strenv does not, so a value goes in as the text it is.
    local _yaml_set_how_read='env'
    if [[ "${_yaml_set_how}" == '--string' ]]; then
        _yaml_set_how_read='strenv'
    fi

    if [[ ! -e "${_yaml_set_file}" ]]; then
        stealth::sys::io::fs::write "${_yaml_set_file}" '{}'
    fi

    stealth::sys::io::fs::atomic "${_yaml_set_file}" -- \
        stealth::sys::data::yaml::_rewrite \
        "setpath(env(${_STEALTH_SYS_DATA_YAML_PATH_VAR}); ${_yaml_set_how_read}(${_STEALTH_SYS_DATA_YAML_VALUE_VAR}))" \
        "${_yaml_set_path}" "${_yaml_set_value}"
}

#######################################
# Takes a path out of a file, leaving the comments and the layout of the rest
# as they were. A path that was never there is no trouble.
#
# Usage:
#   stealth::sys::data::yaml::delete "${file}" engine timeout
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_YAML_PATH_VAR (Read)
# Returns:
#   0 - The file does not hold that path
#   1 - It could not be put in place
#   Exits 1 when a file or a path is missing
#######################################
stealth::sys::data::yaml::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _yaml_del_file="${1}"
    shift

    local _yaml_del_paths
    stealth::sys::cmd::capture _yaml_del_paths \
        jq --compact-output --null-input '[$ARGS.positional]' --args "$@"

    stealth::sys::io::fs::atomic "${_yaml_del_file}" -- \
        stealth::sys::data::yaml::_rewrite \
        "delpaths(env(${_STEALTH_SYS_DATA_YAML_PATH_VAR}))" \
        "${_yaml_del_paths}" ''
}

#######################################
# Puts everything one document holds into another, one level inside the next,
# so that a mapping in both keeps the keys only the target has.
#
# Usage:
#   stealth::sys::data::yaml::merge "${config}" "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change
#   $2 (String) - The file to take the values from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, or the source is not there
#######################################
stealth::sys::data::yaml::merge() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::yaml::_merge_into "${2}"
}

#######################################
# Rewrites a staged file with another document merged into it. The callback
# sys/io/fs::atomic runs for merge.
#
# Usage:
#   stealth::sys::io::fs::atomic "${target}" -- \
#       stealth::sys::data::yaml::_merge_into "${source}"
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The file to take the values from
# Globals:
#   _STEALTH_SYS_DATA_YAML_TO_YAML (Read)
# Returns:
#   0 - Rewritten
#   1 - yq refused one of the documents
#######################################
stealth::sys::data::yaml::_merge_into() {
    local _yaml_mi_text
    if ! stealth::sys::cmd::capture _yaml_mi_text yq eval-all \
        "${_STEALTH_SYS_DATA_YAML_TO_YAML[@]}" \
        '. as $item ireduce ({}; . * $item)' "${1}" "${2}"; then
        return 1
    fi

    printf '%s\n' "${_yaml_mi_text}" > "${1}"
    return 0
}

#######################################
# Reports whether a file holds YAML that yq will read. An empty file does
# not, because a document with nothing in it is not one.
#
# Usage:
#   if ! stealth::sys::data::yaml::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - It does
#   1 - It does not, or there is no such file
#######################################
stealth::sys::data::yaml::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi

    if ! stealth::sys::cmd::try yq --exit-status '.' "${1}" > /dev/null; then
        stealth::util::log::debug '%s is not YAML yq will read' "${1}"
        return 1
    fi
    return 0
}
