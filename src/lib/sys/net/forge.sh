###############################################################################
# module: sys/net/forge
# layer: sys
# description: Asking a code forge what the latest version is and where to
#              get it.
#
#              GitHub and GitLab answer the same four questions in different
#              shapes, so one module asks them and a small table holds what
#              differs. Two modules holding one idea drift, and the second
#              one is always the one nobody fixed.
#
#              An asset is found by walking the list and matching each name
#              with the shell's own patterns. The obvious way is to hand the
#              pattern to jq inside a test(), and that is wrong twice over: a
#              pattern with a quote in it rewrites the program, and test()
#              reads a regular expression while every caller writes a glob,
#              so tool-linux-amd64.tar.gz quietly matches tool-linux-amd64
#              followed by any character at all.
#
#              A project with tags and no releases is the common case, not an
#              edge. The release endpoint answers with nothing for those, so
#              the tags are asked for instead and the newest is worked out
#              with util/semver, which knows that 1.0.0 comes after 1.0.0-rc1
#              and sort -V does not.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_NET_FORGE:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_FORGE=1

stealth::util::import "util/assert" "util/log" "util/semver"
stealth::util::import "sys/io/tmp" "sys/data/json" "sys/net/fetch"

# =============================================================================
# CONSTANTS
# =============================================================================

# Which forge a host belongs to, for a reference that names one.
declare -grA _STEALTH_SYS_NET_FORGE_BY_HOST=([github.com]=github [api.github.com]=github [raw.githubusercontent.com]=github [gitlab.com]=gitlab)

# The forge a reference belongs to when it names no host.
declare -gr _STEALTH_SYS_NET_FORGE_DEFAULT='github'

# Where each forge answers questions, and where it serves files. GitHub keeps
# the two on different hosts and GitLab keeps them on one. Neither is
# readonly: a self-hosted forge is pointed at by changing these, and a test
# points them at itself.
declare -gA STEALTH_FORGE_API=([github]=https://api.github.com [gitlab]=https://gitlab.com)
declare -gA STEALTH_FORGE_RAW=([github]=https://raw.githubusercontent.com [gitlab]=https://gitlab.com)

# Where in a release the assets are, what each one is called, and where its
# address is. GitLab answers with a list of releases, so its assets are one
# step further in.
declare -grA _STEALTH_SYS_NET_FORGE_ASSETS=([github]='assets' [gitlab]='0 assets links')

# Where they are when one release was asked for by name rather than the
# latest. GitLab answers with that release rather than a list of them, so its
# assets move one step closer.
declare -grA _STEALTH_SYS_NET_FORGE_ASSETS_AT=([github]='assets' [gitlab]='assets links')
declare -grA _STEALTH_SYS_NET_FORGE_ASSET_NAME=([github]='name' [gitlab]='name')
declare -grA _STEALTH_SYS_NET_FORGE_ASSET_URL=([github]='browser_download_url' [gitlab]='url')

# Where the tag of a release is, and where the name of a tag is.
declare -grA _STEALTH_SYS_NET_FORGE_TAG=([github]='tag_name' [gitlab]='0 tag_name')
declare -grA _STEALTH_SYS_NET_FORGE_TAG_NAME=([github]='name' [gitlab]='name')

# What a ref is when the caller does not say which one to read a file at.
declare -gr _STEALTH_SYS_NET_FORGE_REF='HEAD'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Takes the options every function here understands off the arguments.
#
# Usage:
#   stealth::sys::net::forge::_take_options which instance ref tag rest "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for --forge, empty when not given
#   $2 (Nameref) - The output variable for --instance, empty when not given
#   $3 (Nameref) - The output variable for --ref
#   $4 (Nameref) - The output variable for --tag
#   $5 (Nameref) - The output array for everything that was not an option
#   $@ (String)  - The arguments
# Globals:
#   _STEALTH_SYS_NET_FORGE_REF (Read)
# Returns:
#   0 - Taken
#   Exits 1 when an option is given nothing, or --forge names one nothing
#   here knows
#######################################
stealth::sys::net::forge::_take_options() {
    local -n _forge_opt_which="${1}"
    local -n _forge_opt_instance="${2}"
    local -n _forge_opt_ref="${3}"
    local -n _forge_opt_tag="${4}"
    local -n _forge_opt_rest="${5}"
    shift 5

    _forge_opt_which=''
    _forge_opt_instance=''
    _forge_opt_ref="${_STEALTH_SYS_NET_FORGE_REF}"
    _forge_opt_tag=''
    _forge_opt_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --forge)
                stealth::util::assert::enum "${2:-}" github gitlab
                _forge_opt_which="${2}"
                shift 2
                ;;
            --instance)
                stealth::util::assert::not_empty "${2:-}" '--instance takes an address'
                _forge_opt_instance="${2%/}"
                shift 2
                ;;
            --ref)
                stealth::util::assert::not_empty "${2:-}" '--ref takes a branch, a tag or a commit'
                _forge_opt_ref="${2}"
                shift 2
                ;;
            --tag)
                stealth::util::assert::not_empty "${2:-}" '--tag takes a tag'
                _forge_opt_tag="${2}"
                shift 2
                ;;
            *)
                _forge_opt_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

#######################################
# Works out which forge a reference belongs to and what the project is
# called there, so that github.com/org/repo and org/repo mean the same
# thing.
#
# Usage:
#   stealth::sys::net::forge::_resolve which project 'github.com/org/repo' '' ''
#
# Arguments:
#   $1 (Nameref) - The output variable for the forge
#   $2 (Nameref) - The output variable for the project
#   $3 (String)  - The reference
#   $4 (String)  - What --forge said, or empty
#   $5 (String)  - What --instance said, or empty
# Globals:
#   _STEALTH_SYS_NET_FORGE_BY_HOST (Read)
#   _STEALTH_SYS_NET_FORGE_DEFAULT (Read)
# Returns:
#   0 - Worked out
#   Exits 1 when the reference names no project
#######################################
stealth::sys::net::forge::_resolve() {
    local -n _forge_res_which="${1}"
    local -n _forge_res_project="${2}"

    local _forge_res_rest="${3}"
    _forge_res_rest="${_forge_res_rest#*://}"
    _forge_res_rest="${_forge_res_rest%.git}"

    _forge_res_which="${4}"

    # The host is looked for before the trailing slash comes off, so that a
    # reference naming a host and nothing else is a reference to no project
    # rather than to a project called github.com.
    local _forge_res_host=''
    if [[ "${_forge_res_rest}" == *.*/* ]]; then
        _forge_res_host="${_forge_res_rest%%/*}"
        _forge_res_rest="${_forge_res_rest#*/}"
    fi
    _forge_res_rest="${_forge_res_rest%/}"

    if [[ -z "${_forge_res_which}" ]]; then
        if [[ -n "${_forge_res_host}" ]] && \
           [[ -v _STEALTH_SYS_NET_FORGE_BY_HOST["${_forge_res_host}"] ]]; then
            _forge_res_which="${_STEALTH_SYS_NET_FORGE_BY_HOST[${_forge_res_host}]}"
        else
            _forge_res_which="${_STEALTH_SYS_NET_FORGE_DEFAULT}"
        fi
    fi

    stealth::util::assert::not_empty "${_forge_res_rest}" \
        "${3} names no project"
    _forge_res_project="${_forge_res_rest}"
    return 0
}

#######################################
# Says where a forge answers questions: what --instance said, or where that
# forge usually does.
#
# Usage:
#   stealth::sys::net::forge::_api where github "${given}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The forge
#   $3 (String)  - What --instance said, or empty
# Globals:
#   STEALTH_FORGE_API (Read)
# Returns:
#   0 - Said
#######################################
stealth::sys::net::forge::_api() {
    local -n _forge_api_out="${1}"

    if [[ -n "${3}" ]]; then
        _forge_api_out="${3}"
        return 0
    fi

    _forge_api_out="${STEALTH_FORGE_API[${2}]}"
    return 0
}

#######################################
# Says where a forge serves the files in a project.
#
# Usage:
#   stealth::sys::net::forge::_raw where github "${given}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The forge
#   $3 (String)  - What --instance said, or empty
# Globals:
#   STEALTH_FORGE_RAW (Read)
# Returns:
#   0 - Said
#######################################
stealth::sys::net::forge::_raw() {
    local -n _forge_rawbase_out="${1}"

    if [[ -n "${3}" ]]; then
        _forge_rawbase_out="${3}"
        return 0
    fi

    _forge_rawbase_out="${STEALTH_FORGE_RAW[${2}]}"
    return 0
}

#######################################
# Builds the address of one of a forge's answers. The two forges name things
# differently enough that a table of patterns would say less than this does.
#
# Usage:
#   stealth::sys::net::forge::_url where github release '' 'org/repo'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The forge
#   $3 (String)  - Which answer: release, at, tags or raw
#   $4 (String)  - What --instance said, or empty
#   $5 (String)  - The project
#   $6 (String)  - The ref for raw, or the tag for at
#   $7 (String)  - The file, for raw
# Returns:
#   0 - Built
#######################################
stealth::sys::net::forge::_url() {
    local -n _forge_url_out="${1}"
    local -r _forge_url_project="${5}"

    local _forge_url_encoded="${_forge_url_project//\//%2F}"
    local _forge_url_base

    case "${2}:${3}" in
        github:release)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/repos/${_forge_url_project}/releases/latest"
            ;;
        github:at)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/repos/${_forge_url_project}/releases/tags/${6}"
            ;;
        github:tags)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/repos/${_forge_url_project}/tags"
            ;;
        github:raw)
            stealth::sys::net::forge::_raw _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/${_forge_url_project}/${6}/${7}"
            ;;
        gitlab:release)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/api/v4/projects/${_forge_url_encoded}/releases"
            ;;
        gitlab:at)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/api/v4/projects/${_forge_url_encoded}/releases/${6}"
            ;;
        gitlab:tags)
            stealth::sys::net::forge::_api _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/api/v4/projects/${_forge_url_encoded}/repository/tags"
            ;;
        *)
            stealth::sys::net::forge::_raw _forge_url_base "${2}" "${4}"
            _forge_url_out="${_forge_url_base}/${_forge_url_project}/-/raw/${6}/${7}"
            ;;
    esac
    return 0
}

#######################################
# Gets a forge's answer into a temporary file, for the questions that need
# more than one thing out of it.
#
# Usage:
#   stealth::sys::net::forge::_answer file "${url}"
#
# Arguments:
#   $1 (Nameref) - The output variable for the path of the file
#   $2 (String)  - The address
#   $@ (String)  - Anything else, passed to sys/net/fetch
# Returns:
#   0 - It answered
#   1 - It did not
#######################################
stealth::sys::net::forge::_answer() {
    local -n _forge_ans_out="${1}"
    local -r _forge_ans_url="${2}"
    shift 2

    stealth::sys::io::tmp::file _forge_ans_out 'forge.XXXXXXXX.json'

    if ! stealth::sys::net::fetch::download "${_forge_ans_url}" "${_forge_ans_out}" \
        --no-cache --header 'Accept: application/json' "$@"; then
        stealth::sys::io::tmp::remove "${_forge_ans_out}"
        return 1
    fi
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says which forge a reference belongs to, without asking anybody.
#
# Usage:
#   stealth::sys::net::forge::which where 'gitlab.com/group/project'
#
# Arguments:
#   $1 (Nameref) - The output variable: github or gitlab
#   $2 (String)  - The reference
# Returns:
#   0 - Said
#   Exits 1 when no output variable is given, or the reference names no
#   project
#######################################
stealth::sys::net::forge::which() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a project is required'

    local _forge_which_project
    stealth::sys::net::forge::_resolve "${1}" _forge_which_project "${2}" '' ''
    return 0
}

#######################################
# Fills an array with the tags a project has, newest first.
#
# The order is worked out with util/semver rather than taken from the forge,
# because a forge lists tags by when they were made. A patch to an old branch
# is made after the newest release and is not newer than it.
#
# Usage:
#   stealth::sys::net::forge::tags names 'org/repo'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The project
#   $@ (String)  - --forge github or gitlab, --instance URL, and anything
#                  sys/net/fetch takes
# Globals:
#   _STEALTH_SYS_NET_FORGE_TAG_NAME (Read)
# Returns:
#   0 - Filled
#   1 - The forge did not answer, or the project has no tags
#   Exits 1 when an output array or a project is missing
#######################################
stealth::sys::net::forge::tags() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::not_empty "${2:-}" 'a project is required'
    local -n _forge_tags_out="${1}"
    local -r _forge_tags_ref="${2}"
    shift 2

    local _forge_tags_which _forge_tags_instance _forge_tags_r _forge_tags_t
    local -a _forge_tags_rest=()
    stealth::sys::net::forge::_take_options _forge_tags_which \
        _forge_tags_instance _forge_tags_r _forge_tags_t _forge_tags_rest "$@"

    local _forge_tags_project _forge_tags_url
    stealth::sys::net::forge::_resolve _forge_tags_which _forge_tags_project \
        "${_forge_tags_ref}" "${_forge_tags_which}" "${_forge_tags_instance}"
    stealth::sys::net::forge::_url _forge_tags_url "${_forge_tags_which}" tags \
        "${_forge_tags_instance}" "${_forge_tags_project}" '' ''

    _forge_tags_out=()

    local _forge_tags_file
    if ! stealth::sys::net::forge::_answer _forge_tags_file \
        "${_forge_tags_url}" "${_forge_tags_rest[@]}"; then
        return 1
    fi

    local -a _forge_tags_found=()
    stealth::sys::net::forge::_collect _forge_tags_found "${_forge_tags_file}" \
        '' "${_STEALTH_SYS_NET_FORGE_TAG_NAME[${_forge_tags_which}]}" ''
    stealth::sys::io::tmp::remove "${_forge_tags_file}"

    if (( ${#_forge_tags_found[@]} == 0 )); then
        stealth::util::log::debug '%s has no tags' "${_forge_tags_ref}"
        return 1
    fi

    stealth::util::semver::sort _forge_tags_out "${_forge_tags_found[@]}"
    return 0
}

#######################################
# Walks a list in an answer and keeps one field of every entry, or the field
# of the entry whose name matches a pattern.
#
# The matching is done here rather than by jq, with the shell's own patterns.
# A pattern handed to jq is part of a program, and jq matches a regular
# expression where every caller writes a glob.
#
# Usage:
#   stealth::sys::net::forge::_collect found "${file}" 'assets' 'name' ''
#   stealth::sys::net::forge::_collect found "${file}" 'assets' 'browser_download_url' '*amd64*' 'name'
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - The file the forge answered with
#   $3 (String)  - Where the list is, as steps separated by spaces
#   $4 (String)  - The field to keep
#   $5 (String)  - The pattern an entry has to match, or empty for all
#   $6 (String)  - The field the pattern is matched against
# Returns:
#   0 - Walked
#######################################
stealth::sys::net::forge::_collect() {
    local -n _forge_col_out="${1}"
    local -r _forge_col_file="${2}"
    local -r _forge_col_keep="${4}"
    local -r _forge_col_pattern="${5}"
    local -r _forge_col_against="${6:-}"

    local -a _forge_col_at=()
    if [[ -n "${3}" ]]; then
        read -r -a _forge_col_at <<< "${3}"
    fi

    _forge_col_out=()

    local _forge_col_count
    if ! stealth::sys::data::json::length _forge_col_count \
        "${_forge_col_file}" "${_forge_col_at[@]}"; then
        return 0
    fi

    local _forge_col_name _forge_col_value
    local -i _forge_col_i=0
    while (( _forge_col_i < _forge_col_count )); do
        if [[ -n "${_forge_col_pattern}" ]]; then
            if ! stealth::sys::data::json::read _forge_col_name \
                "${_forge_col_file}" "${_forge_col_at[@]}" "${_forge_col_i}" \
                "${_forge_col_against}"; then
                _forge_col_i=$(( _forge_col_i + 1 ))
                continue
            fi
            # shellcheck disable=SC2053
            # The pattern is a glob on purpose. Quoting it would make it text.
            if [[ "${_forge_col_name}" != ${_forge_col_pattern} ]]; then
                _forge_col_i=$(( _forge_col_i + 1 ))
                continue
            fi
        fi

        if stealth::sys::data::json::read _forge_col_value \
            "${_forge_col_file}" "${_forge_col_at[@]}" "${_forge_col_i}" \
            "${_forge_col_keep}"; then
            _forge_col_out+=("${_forge_col_value}")
        fi
        _forge_col_i=$(( _forge_col_i + 1 ))
    done
    return 0
}

#######################################
# Says the latest version of a project.
#
# The release is asked for first. A project that tags and never cuts a
# release answers with nothing, which is common enough that the tags are
# asked for next rather than treated as a failure.
#
# Usage:
#   stealth::sys::net::forge::version tag 'org/repo'
#   stealth::sys::net::forge::version tag 'group/project' --forge gitlab
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The project
#   $@ (String)  - --forge github or gitlab, --instance URL, and anything
#                  sys/net/fetch takes
# Globals:
#   _STEALTH_SYS_NET_FORGE_TAG (Read)
# Returns:
#   0 - Said
#   1 - The forge did not answer, or the project has no releases and no tags
#   Exits 1 when an output variable or a project is missing
#######################################
stealth::sys::net::forge::version() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a project is required'
    local -r _forge_ver_var="${1}"
    local -n _forge_ver_out="${1}"
    local -r _forge_ver_ref="${2}"
    shift 2

    local _forge_ver_which _forge_ver_instance _forge_ver_r _forge_ver_t
    local -a _forge_ver_rest=()
    stealth::sys::net::forge::_take_options _forge_ver_which \
        _forge_ver_instance _forge_ver_r _forge_ver_t _forge_ver_rest "$@"

    local _forge_ver_project _forge_ver_url
    stealth::sys::net::forge::_resolve _forge_ver_which _forge_ver_project \
        "${_forge_ver_ref}" "${_forge_ver_which}" "${_forge_ver_instance}"
    stealth::sys::net::forge::_url _forge_ver_url "${_forge_ver_which}" release \
        "${_forge_ver_instance}" "${_forge_ver_project}" '' ''

    local -a _forge_ver_at=()
    read -r -a _forge_ver_at <<< "${_STEALTH_SYS_NET_FORGE_TAG[${_forge_ver_which}]}"

    if stealth::sys::net::fetch::json "${_forge_ver_var}" "${_forge_ver_url}" \
        --header 'Accept: application/json' "${_forge_ver_rest[@]}" \
        "${_forge_ver_at[@]}"; then
        if [[ -n "${_forge_ver_out}" && "${_forge_ver_out}" != 'null' ]]; then
            return 0
        fi
    fi

    stealth::util::log::debug '%s has no release, asking for its tags' \
        "${_forge_ver_ref}"

    local -a _forge_ver_tags=()
    if ! stealth::sys::net::forge::tags _forge_ver_tags "${_forge_ver_ref}" "$@"; then
        return 1
    fi

    _forge_ver_out="${_forge_ver_tags[0]}"
    return 0
}

#######################################
# Says where to get the file of a release whose name matches a pattern.
#
# The pattern is a shell pattern, so tool-*-linux-amd64.tar.gz means what it
# looks like. Nothing is handed to jq to match.
#
# Without --tag the latest release is asked for. With one, that release is,
# which is what a build pinning a version wants.
#
# Usage:
#   stealth::sys::net::forge::asset url 'org/repo' '*linux-amd64.tar.gz'
#   stealth::sys::net::forge::asset url 'org/repo' '*.tar.gz' --tag v1.2.3
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The project
#   $3 (String)  - The pattern the file is named by
#   $@ (String)  - --tag TAG, --forge github or gitlab, --instance URL
# Globals:
#   _STEALTH_SYS_NET_FORGE_ASSETS (Read)
#   _STEALTH_SYS_NET_FORGE_ASSETS_AT (Read)
#   _STEALTH_SYS_NET_FORGE_ASSET_NAME (Read)
#   _STEALTH_SYS_NET_FORGE_ASSET_URL (Read)
# Returns:
#   0 - Said
#   1 - The forge did not answer, or nothing in the release matches
#   Exits 1 when an output variable, a project or a pattern is missing
#######################################
stealth::sys::net::forge::asset() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'a project is required'
    stealth::util::assert::not_empty "${3:-}" 'a pattern is required'
    local -n _forge_as_out="${1}"
    local -r _forge_as_ref="${2}"
    local -r _forge_as_pattern="${3}"
    shift 3

    local _forge_as_which _forge_as_instance _forge_as_r _forge_as_t
    local -a _forge_as_rest=()
    stealth::sys::net::forge::_take_options _forge_as_which _forge_as_instance \
        _forge_as_r _forge_as_t _forge_as_rest "$@"

    local _forge_as_project _forge_as_url
    stealth::sys::net::forge::_resolve _forge_as_which _forge_as_project \
        "${_forge_as_ref}" "${_forge_as_which}" "${_forge_as_instance}"
    local _forge_as_kind='release'
    local _forge_as_at="${_STEALTH_SYS_NET_FORGE_ASSETS[${_forge_as_which}]}"
    if [[ -n "${_forge_as_t}" ]]; then
        _forge_as_kind='at'
        _forge_as_at="${_STEALTH_SYS_NET_FORGE_ASSETS_AT[${_forge_as_which}]}"
    fi

    stealth::sys::net::forge::_url _forge_as_url "${_forge_as_which}" \
        "${_forge_as_kind}" "${_forge_as_instance}" "${_forge_as_project}" \
        "${_forge_as_t}" ''

    local _forge_as_file
    if ! stealth::sys::net::forge::_answer _forge_as_file \
        "${_forge_as_url}" "${_forge_as_rest[@]}"; then
        return 1
    fi

    local -a _forge_as_found=()
    stealth::sys::net::forge::_collect _forge_as_found "${_forge_as_file}" \
        "${_forge_as_at}" \
        "${_STEALTH_SYS_NET_FORGE_ASSET_URL[${_forge_as_which}]}" \
        "${_forge_as_pattern}" \
        "${_STEALTH_SYS_NET_FORGE_ASSET_NAME[${_forge_as_which}]}"
    stealth::sys::io::tmp::remove "${_forge_as_file}"

    if (( ${#_forge_as_found[@]} == 0 )); then
        stealth::util::log::debug 'nothing in the release of %s is named like %s' \
            "${_forge_as_ref}" "${_forge_as_pattern}"
        return 1
    fi

    _forge_as_out="${_forge_as_found[0]}"
    return 0
}

#######################################
# Gets a file out of a project as it stands at a ref.
#
# Usage:
#   stealth::sys::net::forge::raw 'org/repo' 'README.md' "${dest}"
#   stealth::sys::net::forge::raw 'org/repo' 'x.yaml' "${dest}" --ref v1.2.3
#
# Arguments:
#   $1 (String) - The project
#   $2 (String) - The file, from the top of the project
#   $3 (String) - Where to put it
#   $@ (String) - --ref BRANCH, --forge github or gitlab, --instance URL,
#                 and anything sys/net/fetch takes
# Returns:
#   0 - It is there
#   1 - It could not be got
#   Exits 1 when a project, a file or a destination is missing
#######################################
stealth::sys::net::forge::raw() {
    stealth::util::assert::not_empty "${1:-}" 'a project is required'
    stealth::util::assert::not_empty "${2:-}" 'a file is required'
    stealth::util::assert::not_empty "${3:-}" 'somewhere to put it is required'
    local -r _forge_raw_ref="${1}"
    local -r _forge_raw_file="${2}"
    local -r _forge_raw_dest="${3}"
    shift 3

    local _forge_raw_which _forge_raw_instance _forge_raw_at _forge_raw_t
    local -a _forge_raw_rest=()
    stealth::sys::net::forge::_take_options _forge_raw_which \
        _forge_raw_instance _forge_raw_at _forge_raw_t _forge_raw_rest "$@"

    local _forge_raw_project _forge_raw_url
    stealth::sys::net::forge::_resolve _forge_raw_which _forge_raw_project \
        "${_forge_raw_ref}" "${_forge_raw_which}" "${_forge_raw_instance}"
    stealth::sys::net::forge::_url _forge_raw_url "${_forge_raw_which}" raw \
        "${_forge_raw_instance}" "${_forge_raw_project}" "${_forge_raw_at}" \
        "${_forge_raw_file}"

    stealth::sys::net::fetch::download "${_forge_raw_url}" "${_forge_raw_dest}" \
        "${_forge_raw_rest[@]}"
}
