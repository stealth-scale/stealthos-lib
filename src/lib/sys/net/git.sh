###############################################################################
# module: sys/net/git
# layer: sys
# description: Getting source out of a git repository, at a commit that was
#              asked for by name.
#
#              A build that verifies a tarball by its digest and then clones
#              a branch has checked nothing. A branch moves. Only a commit
#              identifier names one tree for ever, and git clone --branch
#              does not accept one: it looks for a branch or a tag of that
#              name and fails. clone here starts an empty repository, fetches
#              the one commit, and checks it out, which is the only shape
#              that pins.
#
#              --expect is for the other case. A caller cloning a branch on
#              purpose can still say which commit it believes that branch is
#              at, and find out here rather than three steps later.
#
#              Tags are put in order with util/semver rather than sort -V,
#              which puts a release candidate after its release.
#
#              There is no mirror cache. A caller that wants one keeps a
#              clone and calls fetch, which is the same saving with none of
#              the ways a shared mirror goes wrong.
#
#              Nothing here writes to a repository's own configuration to get
#              its work done. Who the run commits as travels in the
#              environment, the directories it is allowed to touch travel on
#              the command line, and a token stays in a file of its own that
#              git is merely told the name of. A build that leaves settings
#              behind in a checkout has changed something the next build will
#              read.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_NET_GIT:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_NET_GIT=1

stealth::util::import "util/assert" "util/log" "util/semver"
stealth::util::import "sys/cmd" "sys/io/fs" "sys/io/tmp"

# =============================================================================
# CONSTANTS
# =============================================================================

# What git is told every time: never stop to ask a person anything. A build
# that is waiting for a password nobody will type has stopped, not failed,
# and a stopped build looks like a slow one.
declare -gra _STEALTH_SYS_NET_GIT_QUIET=(-c 'advice.detachedHead=false' -c 'core.askPass=')

# Who the run commits as. Empty means git works it out for itself, which on
# a build host means it cannot and refuses to commit.
declare -g STEALTH_GIT_NAME="${STEALTH_GIT_NAME:-}"
declare -g STEALTH_GIT_EMAIL="${STEALTH_GIT_EMAIL:-}"

# Where git reads credentials, and which key it offers over ssh. Both are
# file names rather than secrets, so both are safe to pass on a command line.
declare -g STEALTH_GIT_CREDENTIALS="${STEALTH_GIT_CREDENTIALS:-}"
declare -g STEALTH_GIT_SSH_KEY="${STEALTH_GIT_SSH_KEY:-}"

# The directories this run may work in whoever owns them. git refuses a
# repository owned by somebody else, which is the right default and the wrong
# one for a build container working on a checkout it was handed.
declare -ga _STEALTH_SYS_NET_GIT_TRUSTED=()

# The mode a file of credentials is kept at.
declare -gr _STEALTH_SYS_NET_GIT_CREDENTIALS_MODE='0600'

# What ssh is told when nothing else is said.
declare -gr _STEALTH_SYS_NET_GIT_SSH='ssh -oBatchMode=yes'

# How much history to take when the caller does not say. One commit is what
# a build needs, and everything else is bandwidth.
declare -gri _STEALTH_SYS_NET_GIT_DEPTH=1

# What a commit identifier looks like written out in full. A short one is not
# accepted: it names one commit today and may name two later.
declare -gr _STEALTH_SYS_NET_GIT_SHA_RE='^[0-9a-f]{40}$'

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Builds the settings git is called with: the ones that keep it from asking
# anybody anything, the directories this run is allowed to work in, and where
# to read credentials.
#
# These go on the command line rather than into a repository's own
# configuration, so nothing is left behind in a checkout.
#
# Usage:
#   stealth::sys::net::git::_settings args
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   _STEALTH_SYS_NET_GIT_QUIET (Read)
#   _STEALTH_SYS_NET_GIT_TRUSTED (Read)
#   STEALTH_GIT_CREDENTIALS (Read)
# Returns:
#   0 - Built
#######################################
stealth::sys::net::git::_settings() {
    local -n _git_set_out="${1}"

    _git_set_out=("${_STEALTH_SYS_NET_GIT_QUIET[@]}")

    local _git_set_dir
    for _git_set_dir in "${_STEALTH_SYS_NET_GIT_TRUSTED[@]}"; do
        _git_set_out+=(-c "safe.directory=${_git_set_dir}")
    done

    if [[ -n "${STEALTH_GIT_CREDENTIALS}" ]]; then
        _git_set_out+=(-c "credential.helper=store --file=${STEALTH_GIT_CREDENTIALS}")
    else
        _git_set_out+=(-c 'credential.helper=')
    fi
    return 0
}

#######################################
# Builds the environment git is called with: never prompt, who to commit as,
# and which key to offer over ssh.
#
# Usage:
#   stealth::sys::net::git::_environment vars
#
# Arguments:
#   $1 (Nameref) - The output array
# Globals:
#   STEALTH_GIT_NAME (Read)
#   STEALTH_GIT_EMAIL (Read)
#   STEALTH_GIT_SSH_KEY (Read)
#   _STEALTH_SYS_NET_GIT_SSH (Read)
# Returns:
#   0 - Built
#######################################
stealth::sys::net::git::_environment() {
    local -n _git_env_out="${1}"

    _git_env_out=(GIT_TERMINAL_PROMPT=0)

    local _git_env_ssh="${_STEALTH_SYS_NET_GIT_SSH}"
    if [[ -n "${STEALTH_GIT_SSH_KEY}" ]]; then
        _git_env_ssh+=" -i ${STEALTH_GIT_SSH_KEY} -oIdentitiesOnly=yes"
    fi
    _git_env_out+=("GIT_SSH_COMMAND=${_git_env_ssh}")

    if [[ -n "${STEALTH_GIT_NAME}" ]]; then
        _git_env_out+=("GIT_AUTHOR_NAME=${STEALTH_GIT_NAME}")
        _git_env_out+=("GIT_COMMITTER_NAME=${STEALTH_GIT_NAME}")
    fi
    if [[ -n "${STEALTH_GIT_EMAIL}" ]]; then
        _git_env_out+=("GIT_AUTHOR_EMAIL=${STEALTH_GIT_EMAIL}")
        _git_env_out+=("GIT_COMMITTER_EMAIL=${STEALTH_GIT_EMAIL}")
    fi
    return 0
}

#######################################
# Runs git with the settings that keep it from asking anybody anything.
#
# Usage:
#   stealth::sys::net::git::_run -C "${dir}" status --porcelain
#
# Arguments:
#   $@ (String) - What to pass git
# Returns:
#   0 - It ran
#   Exits 1 when it failed
#######################################
stealth::sys::net::git::_run() {
    local -a _git_run_settings=() _git_run_env=()
    stealth::sys::net::git::_settings _git_run_settings
    stealth::sys::net::git::_environment _git_run_env

    stealth::sys::cmd::run env "${_git_run_env[@]}" git \
        "${_git_run_settings[@]}" "$@"
}

#######################################
# Runs git and gives its status back, for the questions where failing is an
# answer.
#
# Usage:
#   stealth::sys::net::git::_try -C "${dir}" fetch --depth 1 origin "${sha}"
#
# Arguments:
#   $@ (String) - What to pass git
# Returns:
#   The status git gave
#######################################
stealth::sys::net::git::_try() {
    local -a _git_try_settings=() _git_try_env=()
    stealth::sys::net::git::_settings _git_try_settings
    stealth::sys::net::git::_environment _git_try_env

    stealth::sys::cmd::try env "${_git_try_env[@]}" git \
        "${_git_try_settings[@]}" "$@"
}

#######################################
# Runs git and keeps what it printed.
#
# Usage:
#   stealth::sys::net::git::_read out -C "${dir}" rev-parse HEAD
#
# Arguments:
#   $1 (String) - The output variable
#   $@ (String) - What to pass git
# Returns:
#   The status git gave
#######################################
stealth::sys::net::git::_read() {
    local -r _git_read_var="${1}"
    shift

    local -a _git_read_settings=() _git_read_env=()
    stealth::sys::net::git::_settings _git_read_settings
    stealth::sys::net::git::_environment _git_read_env

    stealth::sys::cmd::capture "${_git_read_var}" env "${_git_read_env[@]}" \
        git "${_git_read_settings[@]}" "$@"
}

#######################################
# Takes the options clone and fetch understand off the arguments.
#
# Usage:
#   stealth::sys::net::git::_take_options ref depth subs expect "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for --ref
#   $2 (Nameref) - The output variable for the depth, empty for all of it
#   $3 (Nameref) - The output variable set to 1 by --submodules
#   $4 (Nameref) - The output variable for --expect
#   $@ (String)  - The arguments
# Globals:
#   _STEALTH_SYS_NET_GIT_DEPTH (Read)
# Returns:
#   0 - Taken
#   Exits 1 when an option is given nothing, or is one nothing here takes
#######################################
stealth::sys::net::git::_take_options() {
    local -n _git_opt_ref="${1}"
    local -n _git_opt_depth="${2}"
    local -n _git_opt_subs="${3}"
    local -n _git_opt_expect="${4}"
    shift 4

    _git_opt_ref=''
    _git_opt_depth="${_STEALTH_SYS_NET_GIT_DEPTH}"
    _git_opt_subs=0
    _git_opt_expect=''

    while (( $# > 0 )); do
        case "${1}" in
            --ref)
                stealth::util::assert::not_empty "${2:-}" \
                    '--ref takes a branch, a tag or a commit'
                _git_opt_ref="${2}"
                shift 2
                ;;
            --depth)
                stealth::util::assert::is_int "${2:-}" \
                    "--depth takes a whole number, not ${2:-}"
                _git_opt_depth="${2}"
                shift 2
                ;;
            --full)
                _git_opt_depth=''
                shift
                ;;
            --submodules)
                _git_opt_subs=1
                shift
                ;;
            --expect)
                stealth::util::assert::match "${2:-}" \
                    "${_STEALTH_SYS_NET_GIT_SHA_RE}" \
                    "--expect takes a commit written out in full, not ${2:-}"
                _git_opt_expect="${2}"
                shift 2
                ;;
            *)
                stealth::util::assert::fail "git does not take ${1}"
                ;;
        esac
    done
    return 0
}

#######################################
# Fetches one commit by name into a repository that has just been started,
# which is the only way to get a commit that is not the tip of anything.
#
# A server may refuse to hand over a commit nobody asked for by branch. The
# whole history is fetched instead when that happens, which is slower and
# always works.
#
# Usage:
#   stealth::sys::net::git::_pin "${dir}" "${url}" "${sha}" 1
#
# Arguments:
#   $1 (String) - The repository
#   $2 (String) - Where to fetch from
#   $3 (String) - The commit
#   $4 (String) - How deep, or empty for all of it
# Returns:
#   0 - That commit is checked out
#   Exits 1 when it could not be got
#######################################
stealth::sys::net::git::_pin() {
    stealth::sys::net::git::_run -C "${1}" remote add origin "${2}"

    local -a _git_pin_depth=()
    if [[ -n "${4}" ]]; then
        _git_pin_depth=(--depth "${4}")
    fi

    if stealth::sys::net::git::_try -C "${1}" fetch \
        "${_git_pin_depth[@]}" origin "${3}"; then
        stealth::sys::net::git::_run -C "${1}" checkout --detach FETCH_HEAD
        return 0
    fi

    # The whole history instead, and then the commit by name. FETCH_HEAD
    # after an ordinary fetch is where the default branch is, which is not
    # what was asked for.
    stealth::util::log::debug \
        '%s will not hand over %s on its own, taking the history' "${2}" "${3}"
    stealth::sys::net::git::_run -C "${1}" fetch origin
    stealth::sys::net::git::_run -C "${1}" checkout --detach "${3}"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Says who the run commits as, for the whole run rather than for one
# repository.
#
# This travels in the environment, so no checkout is changed by it. A build
# that wrote user.name into a repository would leave it there for whatever
# looks at that repository next.
#
# Usage:
#   stealth::sys::net::git::identify 'Stealth Build' build@stealthscale.io
#
# Arguments:
#   $1 (String) - The name
#   $2 (String) - The address
# Globals:
#   STEALTH_GIT_NAME (Write)
#   STEALTH_GIT_EMAIL (Write)
# Returns:
#   0 - Said
#   Exits 1 when a name or an address is missing
#######################################
stealth::sys::net::git::identify() {
    stealth::util::assert::not_empty "${1:-}" 'a name is required'
    stealth::util::assert::not_empty "${2:-}" 'an address is required'

    STEALTH_GIT_NAME="${1}"
    STEALTH_GIT_EMAIL="${2}"

    stealth::util::log::debug 'this run commits as %s <%s>' "${1}" "${2}"
    return 0
}

#######################################
# Says where git reads credentials, and writes them there.
#
# git is told the name of the file and never the token, so the token is in
# no command line and in no repository's configuration. The file is nobody
# else's to read.
#
# Usage:
#   stealth::sys::net::git::authorize github.com "${user}" "${token}"
#
# Arguments:
#   $1 (String) - The host
#   $2 (String) - The login
#   $3 (String) - The password or token
#   $4 (String) - The file to keep them in. Default: one in the run's
#                 temporary directory
# Globals:
#   STEALTH_GIT_CREDENTIALS (Read/Write)
#   _STEALTH_SYS_NET_GIT_CREDENTIALS_MODE (Read)
# Returns:
#   0 - Written, and git will read it
#   Exits 1 when a host, a login or a password is missing
#######################################
stealth::sys::net::git::authorize() {
    stealth::util::assert::not_empty "${1:-}" 'a host is required'
    stealth::util::assert::not_empty "${2:-}" 'a login is required'
    stealth::util::assert::not_empty "${3:-}" 'a password is required'

    local _git_auth_file="${4:-${STEALTH_GIT_CREDENTIALS}}"
    if [[ -z "${_git_auth_file}" ]]; then
        stealth::sys::io::tmp::file _git_auth_file 'credentials.XXXXXXXX'
    fi

    stealth::sys::io::fs::write "${_git_auth_file}" \
        "https://${2}:${3}@${1}" \
        --mode "${_STEALTH_SYS_NET_GIT_CREDENTIALS_MODE}"

    STEALTH_GIT_CREDENTIALS="${_git_auth_file}"
    stealth::util::log::debug 'credentials for %s are in %s' "${1}" "${_git_auth_file}"
    return 0
}

#######################################
# Says that this run may work in a directory whoever owns it.
#
# git refuses a repository owned by somebody else, because a repository can
# carry hooks. That is the right default everywhere except a build container
# working on a checkout somebody handed it, where the owner is another user
# number for the same person.
#
# The directory is named on the command line of every call rather than
# written into anybody's configuration, so nothing is loosened for anything
# but this run.
#
# Usage:
#   stealth::sys::net::git::trust "${checkout}"
#
# Arguments:
#   $1 (String) - The directory
# Globals:
#   _STEALTH_SYS_NET_GIT_TRUSTED (Read/Write)
# Returns:
#   0 - It is trusted for the rest of the run
#   Exits 1 when no directory is given
#######################################
stealth::sys::net::git::trust() {
    stealth::util::assert::not_empty "${1:-}" 'a directory is required'

    local _git_trust_one
    for _git_trust_one in "${_STEALTH_SYS_NET_GIT_TRUSTED[@]}"; do
        if [[ "${_git_trust_one}" == "${1}" ]]; then
            return 0
        fi
    done

    _STEALTH_SYS_NET_GIT_TRUSTED+=("${1}")
    stealth::util::log::debug 'this run may work in %s' "${1}"
    return 0
}

#######################################
# Reads a setting out of a repository.
#
# Usage:
#   stealth::sys::net::git::config where "${dir}" remote.origin.url
#   stealth::sys::net::git::config name "${dir}" user.name 'nobody'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The repository
#   $3 (String)  - The setting
#   $4 (String)  - What to give back when it is not set
# Returns:
#   0 - Read, or the default was used
#   1 - It is not set and there was no default
#   Exits 1 when an output variable, a repository or a setting is missing
#######################################
stealth::sys::net::git::config() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_dir "${2:-}" "no repository at ${2:-}"
    stealth::util::assert::not_empty "${3:-}" 'a setting is required'
    local -n _git_cfg_out="${1}"

    if stealth::sys::net::git::_read "${1}" -C "${2}" config --get "${3}"; then
        return 0
    fi

    _git_cfg_out="${4:-}"
    if (( $# >= 4 )); then
        return 0
    fi
    return 1
}

#######################################
# Writes a setting into a repository, where it stays after the run.
#
# Most of what this module needs is said on the command line instead, and
# does not outlive the call. This is for the settings that are meant to
# outlive it, such as the address a checkout is to be pushed to.
#
# Usage:
#   stealth::sys::net::git::set_config "${dir}" remote.origin.url "${url}"
#
# Arguments:
#   $1 (String) - The repository
#   $2 (String) - The setting
#   $3 (String) - The value
# Returns:
#   0 - Written
#   Exits 1 when a repository, a setting or a value is missing, or git failed
#######################################
stealth::sys::net::git::set_config() {
    stealth::util::assert::is_dir "${1:-}" "no repository at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a setting is required'
    stealth::util::assert::not_empty "${3:-}" 'a value is required'

    stealth::sys::net::git::_run -C "${1}" config --local "${2}" "${3}"
    return 0
}

#######################################
# Reports whether a directory is a git repository.
#
# Usage:
#   if stealth::sys::net::git::is_repo "${dir}"; then ...
#
# Arguments:
#   $1 (String) - The directory
# Returns:
#   0 - It is
#   1 - It is not, or it is not there
#   Exits 1 when no directory is given
#######################################
stealth::sys::net::git::is_repo() {
    stealth::util::assert::not_empty "${1:-}" 'a directory is required'

    if [[ ! -d "${1}" ]]; then
        return 1
    fi

    local _git_isrepo_answer
    stealth::sys::net::git::_read _git_isrepo_answer -C "${1}" rev-parse \
        --is-inside-work-tree 2>/dev/null || return 1

    [[ "${_git_isrepo_answer}" == 'true' ]]
}

#######################################
# Makes a copy of a repository at a ref.
#
# A ref that is a commit written out in full is fetched as that commit. A ref
# that is a branch or a tag is cloned in the ordinary way. Without a ref the
# default branch is taken.
#
# Usage:
#   stealth::sys::net::git::clone "${url}" "${dir}" --ref v1.2.3
#   stealth::sys::net::git::clone "${url}" "${dir}" --ref "${sha}"
#   stealth::sys::net::git::clone "${url}" "${dir}" --full --submodules
#
# Arguments:
#   $1 (String) - Where to get it from
#   $2 (String) - Where to put it
#   $@ (String) - --ref R, --depth N, --full, --submodules, --expect SHA
# Globals:
#   _STEALTH_SYS_NET_GIT_SHA_RE (Read)
# Returns:
#   0 - It is there, at the ref that was asked for
#   Exits 1 when an address or a destination is missing, the clone failed, or
#   what arrived is not what --expect named
#######################################
stealth::sys::net::git::clone() {
    stealth::util::assert::not_empty "${1:-}" 'an address is required'
    stealth::util::assert::not_empty "${2:-}" 'somewhere to put it is required'
    local -r _git_cl_url="${1}"
    local -r _git_cl_dest="${2}"
    shift 2

    local _git_cl_ref _git_cl_depth _git_cl_expect
    local -i _git_cl_subs
    stealth::sys::net::git::_take_options _git_cl_ref _git_cl_depth \
        _git_cl_subs _git_cl_expect "$@"

    stealth::util::log::info 'cloning %s into %s' "${_git_cl_url}" "${_git_cl_dest}"

    if [[ "${_git_cl_ref}" =~ ${_STEALTH_SYS_NET_GIT_SHA_RE} ]]; then
        stealth::sys::io::fs::mkdir "${_git_cl_dest}"
        stealth::sys::net::git::_run -C "${_git_cl_dest}" init --quiet
        stealth::sys::net::git::_pin "${_git_cl_dest}" "${_git_cl_url}" \
            "${_git_cl_ref}" "${_git_cl_depth}"
    else
        stealth::sys::net::git::_plain "${_git_cl_url}" "${_git_cl_dest}" \
            "${_git_cl_ref}" "${_git_cl_depth}"
    fi

    if (( _git_cl_subs == 1 )); then
        stealth::sys::net::git::_run -C "${_git_cl_dest}" submodule update \
            --init --recursive
    fi

    stealth::sys::net::git::_confirm "${_git_cl_dest}" "${_git_cl_expect}"
    return 0
}

#######################################
# Clones a branch, a tag, or whatever the remote says is its default.
#
# Usage:
#   stealth::sys::net::git::_plain "${url}" "${dir}" v1.2.3 1
#
# Arguments:
#   $1 (String) - Where to get it from
#   $2 (String) - Where to put it
#   $3 (String) - The branch or tag, or empty for the default
#   $4 (String) - How deep, or empty for all of it
# Returns:
#   0 - Cloned
#   Exits 1 when it failed
#######################################
stealth::sys::net::git::_plain() {
    local -a _git_plain_args=(clone --quiet)

    if [[ -n "${4}" ]]; then
        _git_plain_args+=(--depth "${4}")
    fi
    if [[ -n "${3}" ]]; then
        _git_plain_args+=(--branch "${3}")
    fi

    stealth::sys::net::git::_run "${_git_plain_args[@]}" "${1}" "${2}"
    return 0
}

#######################################
# Refuses a checkout that is not at the commit the caller said it would be.
#
# Usage:
#   stealth::sys::net::git::_confirm "${dir}" "${sha}"
#
# Arguments:
#   $1 (String) - The repository
#   $2 (String) - The commit expected, or empty to check nothing
# Returns:
#   0 - It is at that commit, or nothing was expected
#   Exits 1 when it is at another one
#######################################
stealth::sys::net::git::_confirm() {
    if [[ -z "${2}" ]]; then
        return 0
    fi

    local _git_conf_at
    stealth::sys::net::git::head _git_conf_at "${1}"

    if [[ "${_git_conf_at}" != "${2}" ]]; then
        stealth::util::assert::fail \
            "${1} is at ${_git_conf_at}, and was expected to be at ${2}"
    fi
    return 0
}

#######################################
# Brings a repository up to date with where it came from.
#
# Usage:
#   stealth::sys::net::git::fetch "${dir}"
#   stealth::sys::net::git::fetch "${dir}" --ref v2.0.0 --full
#
# Arguments:
#   $1 (String) - The repository
#   $@ (String) - --ref R, --depth N, --full
# Returns:
#   0 - Fetched
#   Exits 1 when no repository is given, it is not one, or git failed
#######################################
stealth::sys::net::git::fetch() {
    stealth::util::assert::is_dir "${1:-}" "no repository at ${1:-}"
    local -r _git_fe_dir="${1}"
    shift

    local _git_fe_ref _git_fe_depth _git_fe_expect
    local -i _git_fe_subs
    stealth::sys::net::git::_take_options _git_fe_ref _git_fe_depth \
        _git_fe_subs _git_fe_expect "$@"

    local -a _git_fe_args=(fetch --tags)
    if [[ -n "${_git_fe_depth}" ]]; then
        _git_fe_args+=(--depth "${_git_fe_depth}")
    fi
    _git_fe_args+=(origin)
    if [[ -n "${_git_fe_ref}" ]]; then
        _git_fe_args+=("${_git_fe_ref}")
    fi

    stealth::sys::net::git::_run -C "${_git_fe_dir}" "${_git_fe_args[@]}"
    return 0
}

#######################################
# Moves a repository to a ref that it already has.
#
# Usage:
#   stealth::sys::net::git::checkout "${dir}" v2.0.0
#
# Arguments:
#   $1 (String) - The repository
#   $2 (String) - The branch, tag or commit
# Returns:
#   0 - It is there
#   Exits 1 when a repository or a ref is missing, or git failed
#######################################
stealth::sys::net::git::checkout() {
    stealth::util::assert::is_dir "${1:-}" "no repository at ${1:-}"
    stealth::util::assert::not_empty "${2:-}" 'a ref is required'

    stealth::sys::net::git::_run -C "${1}" checkout --detach "${2}"
    return 0
}

#######################################
# Says which commit a repository is at, written out in full.
#
# Usage:
#   stealth::sys::net::git::head at "${dir}"
#   stealth::sys::net::git::head at "${dir}" v1.2.3
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The repository
#   $3 (String)  - Which ref to ask about. Default: where it is now
# Returns:
#   0 - Said
#   1 - There is no such ref
#   Exits 1 when an output variable or a repository is missing
#######################################
stealth::sys::net::git::head() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::is_dir "${2:-}" "no repository at ${2:-}"

    if ! stealth::sys::net::git::_read "${1}" -C "${2}" rev-parse "${3:-HEAD}"; then
        stealth::util::log::debug '%s has no ref called %s' "${2}" "${3:-HEAD}"
        return 1
    fi
    return 0
}

#######################################
# Reports whether a repository has nothing changed and nothing untracked.
#
# Usage:
#   if ! stealth::sys::net::git::is_clean "${dir}"; then ...
#
# Arguments:
#   $1 (String) - The repository
# Returns:
#   0 - Nothing has been touched
#   1 - Something has, or it is not a repository
#   Exits 1 when no repository is given
#######################################
stealth::sys::net::git::is_clean() {
    stealth::util::assert::is_dir "${1:-}" "no repository at ${1:-}"

    local _git_clean_status
    if ! stealth::sys::net::git::_read _git_clean_status -C "${1}" status \
        --porcelain; then
        return 1
    fi

    [[ -z "${_git_clean_status}" ]]
}

#######################################
# Fills an array with the tags a repository has, newest first, without
# cloning it.
#
# Usage:
#   stealth::sys::net::git::tags names "${url}"
#
# Arguments:
#   $1 (Nameref) - The output array
#   $2 (String)  - Where the repository is
# Returns:
#   0 - Filled
#   1 - It could not be asked, or it has no tags
#   Exits 1 when an output array or an address is missing
#######################################
stealth::sys::net::git::tags() {
    stealth::util::assert::not_empty "${1:-}" 'an output array is required'
    stealth::util::assert::not_empty "${2:-}" 'an address is required'
    local -n _git_tags_out="${1}"

    _git_tags_out=()

    local _git_tags_text
    if ! stealth::sys::net::git::_read _git_tags_text ls-remote --tags \
        --refs "${2}"; then
        return 1
    fi
    if [[ -z "${_git_tags_text}" ]]; then
        stealth::util::log::debug '%s has no tags' "${2}"
        return 1
    fi

    local -a _git_tags_lines=()
    mapfile -t _git_tags_lines <<< "${_git_tags_text}"

    local -a _git_tags_found=()
    local _git_tags_line _git_tags_ref
    for _git_tags_line in "${_git_tags_lines[@]}"; do
        _git_tags_ref="${_git_tags_line#*"${_git_tags_line%%[[:space:]]*}"}"
        _git_tags_ref="${_git_tags_ref#"${_git_tags_ref%%[![:space:]]*}"}"
        _git_tags_found+=("${_git_tags_ref#refs/tags/}")
    done

    stealth::util::semver::sort _git_tags_out "${_git_tags_found[@]}"
    return 0
}

#######################################
# Says the newest tag a repository has.
#
# Usage:
#   stealth::sys::net::git::latest tag "${url}"
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - Where the repository is
# Returns:
#   0 - Said
#   1 - It could not be asked, or it has no tags
#   Exits 1 when an output variable or an address is missing
#######################################
stealth::sys::net::git::latest() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    local -n _git_lat_out="${1}"

    local -a _git_lat_tags=()
    if ! stealth::sys::net::git::tags _git_lat_tags "${2:-}"; then
        return 1
    fi

    _git_lat_out="${_git_lat_tags[0]}"
    return 0
}

#######################################
# Says which commit a ref stands for, without cloning anything. This is how
# a build turns a branch or a tag into something it can pin to.
#
# Usage:
#   stealth::sys::net::git::resolve at "${url}" v1.2.3
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - Where the repository is
#   $3 (String)  - The branch or tag. Default: HEAD
# Returns:
#   0 - Said
#   1 - It could not be asked, or there is no such ref
#   Exits 1 when an output variable or an address is missing
#######################################
stealth::sys::net::git::resolve() {
    stealth::util::assert::not_empty "${1:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${2:-}" 'an address is required'
    local -n _git_res_out="${1}"

    _git_res_out=''

    local _git_res_text
    if ! stealth::sys::net::git::_read _git_res_text ls-remote "${2}" \
        "${3:-HEAD}"; then
        return 1
    fi
    if [[ -z "${_git_res_text}" ]]; then
        stealth::util::log::debug '%s has no ref called %s' "${2}" "${3:-HEAD}"
        return 1
    fi

    _git_res_out="${_git_res_text%%[[:space:]]*}"
    return 0
}
