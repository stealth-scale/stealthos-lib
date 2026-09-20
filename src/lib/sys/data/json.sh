###############################################################################
# module: sys/data/json
# layer: sys
# description: JSON files, read and written with jq.
#
#              A place in the document is named by its path, one argument per
#              step: engine timeout, not .engine.timeout. The path reaches jq
#              through --args, so it arrives as data and is never part of the
#              program. A key built out of what a caller was given otherwise
#              becomes a jq expression, and a key with a dot or a bracket in
#              it means something other than itself.
#
#              JSON has types. set works out which one a value is from how it
#              is written, the same way sys/data/toml does, and --string or
#              --json says so outright when the guess would be wrong.
#
#              There are no comments in JSON, so nothing is lost by writing
#              the whole document back out. jq decides the layout, which means
#              a file this module has written is laid out the same way every
#              time whatever it looked like before.
# copyright: Stealth Scale B.V.
###############################################################################

# shellcheck disable=SC2016
# The single quotes here are deliberate. $ARGS is a variable of jq's, filled
# by --args, and a program that let the shell expand it would be a program
# built out of whatever the caller passed.

if [[ -n "${_STEALTH_LIB_SYS_DATA_JSON:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_DATA_JSON=1

stealth::util::import "util/assert" "util/log"
stealth::util::import "sys/cmd" "sys/io/fs" "sys/io/tmp"

# =============================================================================
# CONSTANTS
# =============================================================================

# Walks a path, step by step, taking the type of what it is standing on into
# account. A step against an array is an index and a step against an object
# is a key, so a document holding an object with the key "0" and a document
# holding an array both answer correctly for the step 0.
#
# The walk never fails. A step that leads nowhere gives null, which read and
# has tell apart from a value of null between them.
declare -gr _STEALTH_SYS_DATA_JSON_AT='def _at($s): reduce $s[] as $k (.; if . == null then null elif (type == "array") then (if ($k|test("^[0-9]+$")) then .[$k|tonumber] else null end) elif (type == "object") then .[$k] else null end);'

# Builds the path itself rather than walking it, for setpath and delpaths,
# which want a list of steps with the array indices already numbers. A step
# past the end of the document stays text, so writing to a path that is not
# there yet makes objects.
declare -gr _STEALTH_SYS_DATA_JSON_TYPED='def _typed($s): . as $doc | reduce $s[] as $k ({p:[],at:$doc}; if ((.at|type) == "array") and ($k|test("^[0-9]+$")) then {p:(.p+[$k|tonumber]), at:(.at[$k|tonumber])} else {p:(.p+[$k]), at:(if (.at|type)=="object" then .at[$k] else null end)} end) | .p;'

# Reads the value at a path. A string comes back as itself and everything
# else comes back as the JSON it is, written on one line, so that an array
# reaches the caller as a value and not as four lines of output.
#
# A path that is not there reads as null, which is also what a value of null
# reads as, so has asks a second question.
declare -gr _STEALTH_SYS_DATA_JSON_GET="${_STEALTH_SYS_DATA_JSON_AT}"' _at($ARGS.positional) | if type == "string" then . else tojson end'

# Whether a path is there at all, null or not. An empty path is the document
# itself, which is always there. A step into an array is there when it is a
# number the array is long enough for.
declare -gr _STEALTH_SYS_DATA_JSON_HAS="${_STEALTH_SYS_DATA_JSON_AT}"' if ($ARGS.positional | length) == 0 then true else (_at($ARGS.positional[:-1])) as $p | ($ARGS.positional[-1]) as $k | if ($p|type) == "object" then ($p|has($k)) elif ($p|type) == "array" then (($k|test("^[0-9]+$")) and (($k|tonumber) >= 0) and (($k|tonumber) < ($p|length))) else false end end'

# How jq is run: nothing from a terminal, no colour, and a status that says
# whether the answer was null.
declare -gra _STEALTH_SYS_DATA_JSON_FLAGS=(--monochrome-output)

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Runs a jq program over a file with a path as its positional arguments, and
# keeps what it printed.
#
# Usage:
#   stealth::sys::data::json::_jq out "${file}" '-r' "${program}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - Any one extra flag for jq, or empty
#   $4 (String)  - The program
#   $@ (String)  - The path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_JSON_FLAGS (Read)
# Returns:
#   The status jq gave
#######################################
stealth::sys::data::json::_jq() {
    local -r _json_jq_var="${1}"
    local -r _json_jq_file="${2}"
    local -r _json_jq_flag="${3}"
    local -r _json_jq_program="${4}"
    shift 4

    local -a _json_jq_cmd=(jq "${_STEALTH_SYS_DATA_JSON_FLAGS[@]}")
    if [[ -n "${_json_jq_flag}" ]]; then
        _json_jq_cmd+=("${_json_jq_flag}")
    fi
    _json_jq_cmd+=("${_json_jq_program}" "${_json_jq_file}" --args "$@")

    stealth::sys::cmd::capture "${_json_jq_var}" "${_json_jq_cmd[@]}"
}

#######################################
# Runs a jq program the way _jq does and fills an array with what it printed,
# one element per value jq emitted.
#
# jq separates the values with a null byte rather than a newline, so a key or
# a value that has a newline in it stays one element, and an empty value
# stays an element. Command substitution drops null bytes, so the output goes
# to a file and is read back from there.
#
# Usage:
#   stealth::sys::data::json::_jq0 out "${file}" "${program}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $3 (String)  - The program
#   $@ (String)  - The path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_JSON_FLAGS (Read)
# Returns:
#   0 - The array holds what jq printed
#   1 - jq refused the program or the document
#######################################
stealth::sys::data::json::_jq0() {
    local -n _json_jq0_out="${1}"
    local -r _json_jq0_file="${2}"
    local -r _json_jq0_program="${3}"
    shift 3

    _json_jq0_out=()

    local _json_jq0_buf
    stealth::sys::io::tmp::file _json_jq0_buf 'json.XXXXXXXX'

    local -i _json_jq0_gave=0
    jq "${_STEALTH_SYS_DATA_JSON_FLAGS[@]}" --raw-output0 \
        "${_json_jq0_program}" "${_json_jq0_file}" --args "$@" \
        > "${_json_jq0_buf}" 2>/dev/null || _json_jq0_gave=$?

    if (( _json_jq0_gave != 0 )); then
        stealth::sys::io::tmp::remove "${_json_jq0_buf}"
        stealth::util::log::debug 'jq gave %s for %s' \
            "${_json_jq0_gave}" "${_json_jq0_file}"
        return 1
    fi

    mapfile -t -d '' _json_jq0_out < "${_json_jq0_buf}"
    stealth::sys::io::tmp::remove "${_json_jq0_buf}"
    return 0
}

#######################################
# Runs a jq program that rewrites a file, and leaves the result in the staged
# file sys/io/fs is holding.
#
# Usage:
#   stealth::sys::io::fs::atomic "${file}" -- \
#       stealth::sys::data::json::_rewrite "${program}" engine timeout
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The program
#   $@ (String) - The path, one step per argument
# Returns:
#   0 - Rewritten
#   1 - jq refused the program or the document
#######################################
stealth::sys::data::json::_rewrite() {
    local -r _json_rw_staged="${1}"
    local -r _json_rw_program="${2}"
    shift 2

    local _json_rw_result
    if ! stealth::sys::cmd::capture _json_rw_result \
        jq "${_STEALTH_SYS_DATA_JSON_FLAGS[@]}" "${_json_rw_program}" \
        "${_json_rw_staged}" --args "$@"; then
        return 1
    fi

    printf '%s\n' "${_json_rw_result}" > "${_json_rw_staged}"
    return 0
}

#######################################
# Writes a value as the JSON it is to become. A value that reads as a number,
# a boolean, null, an array or an object goes in as it stands, and anything
# else goes in as a string.
#
# Usage:
#   stealth::sys::data::json::_encode written '30'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The value
#   $3 (String)  - --string to write it as one whatever it looks like, --json
#                  to write it as it stands
# Returns:
#   0 - Written
#   Exits 1 when --json is given something that is not JSON
#######################################
stealth::sys::data::json::_encode() {
    local -n _json_enc_out="${1}"
    local _json_enc_text

    # jq -e 'type' succeeds for anything that parses as JSON, null included,
    # and fails for a bare word or for nothing at all.
    if [[ "${3:-}" != '--string' ]] && \
        stealth::sys::cmd::try jq -e 'type' <<< "${2}" > /dev/null; then
        _json_enc_out="${2}"
        return 0
    fi

    if [[ "${3:-}" == '--json' ]]; then
        stealth::util::assert::fail "--json was given ${2}, which is not JSON"
    fi

    stealth::sys::cmd::capture _json_enc_text jq -n --arg v "${2}" '$v'
    _json_enc_out="${_json_enc_text}"
    return 0
}

#######################################
# Takes the options off the front of the arguments and gives back what was
# left, which is the path.
#
# Usage:
#   stealth::sys::data::json::_take_options how default rest "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for --string or --json
#   $2 (Nameref) - The output variable for --default, and whether there was one
#   $3 (Nameref) - The output array for the rest
#   $@ (String)  - The arguments
# Returns:
#   0 - Taken
#   Exits 1 when an option is given nothing
#######################################
stealth::sys::data::json::_take_options() {
    local -n _json_opt_how="${1}"
    local -n _json_opt_default="${2}"
    local -n _json_opt_rest="${3}"
    shift 3

    _json_opt_how=''
    _json_opt_default=''
    _json_opt_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --string|--json)
                _json_opt_how="${1}"
                shift
                ;;
            --default)
                stealth::util::assert::not_empty "${2:-}" '--default takes a value'
                _json_opt_default="${2}"
                shift 2
                ;;
            *)
                _json_opt_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reads the value at a path. A string comes back without its quotes and
# anything else comes back as it is written, so a number reads as a number
# and an object reads as JSON.
#
# Usage:
#   stealth::sys::data::json::read value "${file}" engine timeout
#   stealth::sys::data::json::read value "${file}" --default 30 engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $@ (String)  - --default X, then the path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_JSON_GET (Read)
# Returns:
#   0 - Found, or the default was used
#   1 - Not there and no default was given
#   Exits 1 when an output variable, a file or a path is missing
#######################################
stealth::sys::data::json::read() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -r _json_read_var="${1}"
    local -n _json_read_out="${1}"
    local -r _json_read_file="${2}"
    shift 2

    local _json_read_how _json_read_default
    local -a _json_read_path=()
    stealth::sys::data::json::_take_options _json_read_how _json_read_default \
        _json_read_path "$@"
    stealth::util::assert::not_empty "${_json_read_path[0]:-}" 'a path is required'

    if stealth::sys::data::json::has "${_json_read_file}" "${_json_read_path[@]}"; then
        stealth::sys::data::json::_jq "${_json_read_var}" "${_json_read_file}" \
            '-r' "${_STEALTH_SYS_DATA_JSON_GET}" "${_json_read_path[@]}" || true
        return 0
    fi

    _json_read_out="${_json_read_default}"
    if [[ -n "${_json_read_default}" ]]; then
        return 0
    fi
    return 1
}

#######################################
# Reports whether a path is there, which is not the same as whether it holds
# anything. A key set to null is there.
#
# Usage:
#   if stealth::sys::data::json::has "${file}" engine timeout; then ...
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_JSON_HAS (Read)
# Returns:
#   0 - It is there
#   1 - It is not, or the document is not JSON
#   Exits 1 when a file or a path is missing
#######################################
stealth::sys::data::json::has() {
    stealth::util::assert::is_file "${1:-}" "no file to read at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _json_has_file="${1}"
    shift

    local _json_has_answer
    if ! stealth::sys::data::json::_jq _json_has_answer "${_json_has_file}" '' \
        "${_STEALTH_SYS_DATA_JSON_HAS}" "$@"; then
        return 1
    fi

    [[ "${_json_has_answer}" == 'true' ]]
}

#######################################
# Fills an array with the keys of the object at a path, in the order the file
# writes them. Without a path that is the document itself.
#
# Usage:
#   stealth::sys::data::json::keys names "${file}"
#   stealth::sys::data::json::keys names "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Filled
#   1 - There is no object at that path
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::json::keys() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _json_keys_out="${1}"
    local -r _json_keys_file="${2}"
    shift 2

    _json_keys_out=()

    if ! stealth::sys::data::json::_jq0 _json_keys_out "${_json_keys_file}" \
        "${_STEALTH_SYS_DATA_JSON_AT}"' _at($ARGS.positional) | if type == "object" then keys_unsorted[] else empty end' \
        "$@"; then
        return 1
    fi

    return 0
}

#######################################
# Fills an associative array with the keys and values of the object at a
# path, which is one call rather than one call for every key the caller
# wants. A value that is not a scalar comes back as the JSON it is.
#
# Usage:
#   local -A engine=()
#   stealth::sys::data::json::load engine "${file}" engine
#
# Arguments:
#   $1 (Nameref) - The output associative array
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Filled
#   1 - There is no object at that path
#   Exits 1 when an output array or a file is missing
#######################################
stealth::sys::data::json::load() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _json_load_out="${1}"
    local -r _json_load_file="${2}"
    shift 2

    _json_load_out=()

    local -a _json_load_pairs=()
    if ! stealth::sys::data::json::_jq0 _json_load_pairs "${_json_load_file}" \
        "${_STEALTH_SYS_DATA_JSON_AT}"' _at($ARGS.positional) | if type == "object" then to_entries[] | .key, (.value | if type == "string" then . else tojson end) else empty end' \
        "$@"; then
        return 1
    fi

    local -i _json_load_at=0
    while (( _json_load_at + 1 < ${#_json_load_pairs[@]} )); do
        _json_load_out["${_json_load_pairs[${_json_load_at}]}"]="${_json_load_pairs[$(( _json_load_at + 1 ))]}"
        _json_load_at=$(( _json_load_at + 2 ))
    done

    return 0
}

#######################################
# Says what kind of value is at a path, as JSON counts kinds.
#
# Usage:
#   stealth::sys::data::json::type kind "${file}" engine timeout
#
# Arguments:
#   $1 (Nameref) - The output variable: string, number, boolean, array,
#                  object or null
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Returns:
#   0 - Said
#   1 - There is nothing at that path
#   Exits 1 when an output variable or a file is missing
#######################################
stealth::sys::data::json::type() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -r _json_type_var="${1}"
    local -n _json_type_out="${1}"
    local -r _json_type_file="${2}"
    shift 2

    _json_type_out=''
    if ! stealth::sys::data::json::has "${_json_type_file}" "$@"; then
        return 1
    fi

    stealth::sys::data::json::_jq "${_json_type_var}" "${_json_type_file}" '-r' \
        "${_STEALTH_SYS_DATA_JSON_AT}"' _at($ARGS.positional) | type' "$@"
    return 0
}

#######################################
# Sets the value at a path, making whatever objects it takes to get there.
# The last argument is the value and everything before it is the path.
#
# Usage:
#   stealth::sys::data::json::set "${file}" engine timeout 30
#   stealth::sys::data::json::set "${file}" --string engine port 8080
#   stealth::sys::data::json::set "${file}" --json engine hosts '["a","b"]'
#
# Arguments:
#   $1 (String) - The file, which is made when it is not there
#   $@ (String) - --string or --json, then the path, then the value
# Returns:
#   0 - The file holds that value at that path
#   1 - It could not be put in place
#   Exits 1 when a file, a path or a value is missing
#######################################
stealth::sys::data::json::set() {
    stealth::util::assert::not_empty "${1:-}" 'a file is required'
    local -r _json_set_file="${1}"
    shift

    local _json_set_how _json_set_default
    local -a _json_set_rest=()
    stealth::sys::data::json::_take_options _json_set_how _json_set_default \
        _json_set_rest "$@"

    if (( ${#_json_set_rest[@]} < 2 )); then
        stealth::util::assert::fail 'a path and a value are required'
    fi

    local -r _json_set_value="${_json_set_rest[-1]}"
    local -a _json_set_path=("${_json_set_rest[@]:0:${#_json_set_rest[@]}-1}")

    local _json_set_written
    stealth::sys::data::json::_encode _json_set_written "${_json_set_value}" \
        "${_json_set_how}"

    if [[ ! -e "${_json_set_file}" ]]; then
        stealth::sys::io::fs::write "${_json_set_file}" '{}'
    fi

    stealth::sys::io::fs::atomic "${_json_set_file}" -- \
        stealth::sys::data::json::_rewrite \
        "${_STEALTH_SYS_DATA_JSON_TYPED} setpath(_typed(\$ARGS.positional); ${_json_set_written})" \
        "${_json_set_path[@]}"
}

#######################################
# Takes a path out of a file. A path that was never there is no trouble.
#
# Usage:
#   stealth::sys::data::json::delete "${file}" engine timeout
#
# Arguments:
#   $1 (String) - The file
#   $@ (String) - The path, one step per argument
# Returns:
#   0 - The file does not hold that path
#   1 - It could not be put in place
#   Exits 1 when a file or a path is missing
#######################################
stealth::sys::data::json::delete() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a path is required'
    local -r _json_del_file="${1}"
    shift

    stealth::sys::io::fs::atomic "${_json_del_file}" -- \
        stealth::sys::data::json::_rewrite \
        "${_STEALTH_SYS_DATA_JSON_TYPED}"' delpaths([_typed($ARGS.positional)])' "$@"
}

#######################################
# Puts everything one document holds into another, one level inside the next,
# so that an object in both keeps the keys only the target has.
#
# Usage:
#   stealth::sys::data::json::merge "${config}" "${overrides}"
#
# Arguments:
#   $1 (String) - The file to change
#   $2 (String) - The file to take the values from
# Returns:
#   0 - The target holds both
#   1 - It could not be put in place
#   Exits 1 when a file is missing, or the source is not there
#######################################
stealth::sys::data::json::merge() {
    stealth::util::assert::is_file "${1:-}" "no file to change at ${1:-}"
    stealth::util::assert::is_file "${2:-}" "no file to merge in at ${2:-}"

    stealth::sys::io::fs::atomic "${1}" -- \
        stealth::sys::data::json::_merge_into "${2}"
}

#######################################
# Rewrites a staged file with another document merged into it. The callback
# sys/io/fs::atomic runs for merge.
#
# Usage:
#   stealth::sys::io::fs::atomic "${target}" -- \
#       stealth::sys::data::json::_merge_into "${source}"
#
# Arguments:
#   $1 (String) - The staged file
#   $2 (String) - The file to take the values from
# Returns:
#   0 - Rewritten
#   1 - jq refused one of the documents
#######################################
stealth::sys::data::json::_merge_into() {
    local _json_mi_result
    if ! stealth::sys::cmd::capture _json_mi_result \
        jq "${_STEALTH_SYS_DATA_JSON_FLAGS[@]}" -s '.[0] * .[1]' "${1}" "${2}"; then
        return 1
    fi

    printf '%s\n' "${_json_mi_result}" > "${1}"
    return 0
}

#######################################
# Says how many things are at a path: the elements of an array, the keys of
# an object, or the characters of a string.
#
# This is what makes an array walkable from bash. Ask how long it is, then
# read each place in turn, matching names with the shell's own patterns
# rather than handing a pattern to jq as part of a program.
#
# Usage:
#   stealth::sys::data::json::length count "${file}" assets
#   for (( i = 0; i < count; i++ )); do
#       stealth::sys::data::json::read name "${file}" assets "${i}" name
#   done
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $@ (String)  - The path, one step per argument
# Globals:
#   _STEALTH_SYS_DATA_JSON_AT (Read)
# Returns:
#   0 - Said
#   1 - There is nothing at that path, or it is something with no length
#   Exits 1 when an output variable or a file is missing
#######################################
stealth::sys::data::json::length() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_file "${2:-}" "no file to read at ${2:-}"
    local -n _json_len_out="${1}"
    local -r _json_len_var="${1}"
    local -r _json_len_file="${2}"
    shift 2

    _json_len_out=''
    if ! stealth::sys::data::json::_jq "${_json_len_var}" "${_json_len_file}" \
        '-r' "${_STEALTH_SYS_DATA_JSON_AT}"' _at($ARGS.positional) | if (type == "array") or (type == "object") or (type == "string") then length else empty end' \
        "$@"; then
        return 1
    fi

    [[ -n "${_json_len_out}" ]]
}

#######################################
# Reports whether a file holds JSON that jq will read.
#
# Usage:
#   if ! stealth::sys::data::json::is_valid "${file}"; then ...
#
# Arguments:
#   $1 (String) - The file
# Returns:
#   0 - It does
#   1 - It does not, or there is no such file
#######################################
stealth::sys::data::json::is_valid() {
    if [[ ! -r "${1:-}" ]]; then
        return 1
    fi

    # type rather than . because jq is happy to read nothing at all and print
    # nothing at all, and an empty file is not a JSON document.
    if ! stealth::sys::cmd::try jq "${_STEALTH_SYS_DATA_JSON_FLAGS[@]}" \
        -e 'type' "${1}" > /dev/null; then
        stealth::util::log::debug '%s is not JSON jq will read' "${1}"
        return 1
    fi
    return 0
}
