###############################################################################
# module: sys/runtime/user
# layer: sys
# description: Local users and groups, on this machine or in a tree.
#
#              Every function takes --root, because the users an image needs
#              are created while the image is a directory and nothing in it is
#              running. shadow-utils takes --root for exactly this, and the
#              readers here go to the files under that root rather than
#              calling getent.
#
#              getent answers about the machine running the question. It
#              consults LDAP and whatever else the name service is configured
#              with, and it cannot be pointed at a tree. This module is about
#              local accounts in passwd and group, so it reads those files and
#              nothing else.
#
#              A password hash is given to chpasswd on its standard input.
#              usermod takes one as an argument, where it sits in the command
#              line for anyone who can list processes.
# copyright: Stealth Scale B.V.
###############################################################################

if [[ -n "${_STEALTH_LIB_SYS_RUNTIME_USER:-}" ]]; then return 0; fi
declare -gr _STEALTH_LIB_SYS_RUNTIME_USER=1

stealth::util::import "util/assert" "util/log" "util/text"
stealth::util::import "sys/cmd"

# =============================================================================
# CONSTANTS
# =============================================================================

# Where accounts are recorded, under whichever root is being worked on.
declare -g STEALTH_USER_PASSWD_FILE='/etc/passwd'
declare -g STEALTH_USER_GROUP_FILE='/etc/group'

# Which colon-separated field holds what. passwd is name, password, uid, gid,
# gecos, home, shell. group is name, password, gid, members.
declare -gri _STEALTH_SYS_RUNTIME_USER_UID_FIELD=3
declare -gri _STEALTH_SYS_RUNTIME_USER_GID_FIELD=4
declare -gri _STEALTH_SYS_RUNTIME_USER_GROUP_GID_FIELD=3
declare -gri _STEALTH_SYS_RUNTIME_USER_MEMBERS_FIELD=4

# =============================================================================
# INTERNAL
# =============================================================================

#######################################
# Takes --root off the arguments and gives back the root it names, which is
# empty when there is none. shadow-utils takes only an absolute path, so
# anything else is refused here rather than by useradd.
#
# Usage:
#   stealth::sys::runtime::user::_take_root root rest "$@"
#
# Arguments:
#   $1 (Nameref) - The output variable for the root
#   $2 (Nameref) - The output array for everything that was not --root
#   $@ (String)  - The arguments
# Returns:
#   0 - Taken
#   Exits 1 when --root is given nothing, or a path that is not absolute
#######################################
stealth::sys::runtime::user::_take_root() {
    local -n _user_root_out="${1}"
    local -n _user_root_rest="${2}"
    shift 2

    _user_root_out=''
    _user_root_rest=()

    while (( $# > 0 )); do
        case "${1}" in
            --root)
                stealth::util::assert::not_empty "${2:-}" '--root takes a directory'
                if [[ "${2}" != /* ]]; then
                    stealth::util::assert::fail \
                        "--root takes an absolute path, not ${2}"
                fi
                _user_root_out="${2%/}"
                shift 2
                ;;
            *)
                _user_root_rest+=("${1}")
                shift
                ;;
        esac
    done
    return 0
}

#######################################
# Finds the line for a name in a colon-separated account file and gives back
# one field of it.
#
# Usage:
#   stealth::sys::runtime::user::_field uid "${root}/etc/passwd" 'app' 3
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The file
#   $3 (String)  - The name in the first field
#   $4 (Integer) - Which field to give back, counting from one
# Returns:
#   0 - Found
#   1 - There is no such file, or no line for that name
#######################################
stealth::sys::runtime::user::_field() {
    local -n _user_field_out="${1}"

    _user_field_out=''
    if [[ ! -r "${2}" ]]; then
        return 1
    fi

    local -a _user_field_parts=()
    local _user_field_line
    while IFS= read -r _user_field_line || [[ -n "${_user_field_line}" ]]; do
        if [[ "${_user_field_line}" != "${3}:"* ]]; then
            continue
        fi
        IFS=':' read -r -a _user_field_parts <<< "${_user_field_line}"
        _user_field_out="${_user_field_parts[$(( ${4} - 1 ))]:-}"
        return 0
    done < "${2}"

    return 1
}

#######################################
# Runs one of the shadow-utils commands, with --root when there is one.
#
# Usage:
#   stealth::sys::runtime::user::_shadow "${root}" useradd --shell /bin/sh app
#
# Arguments:
#   $1 (String) - The root, or empty for this machine
#   $2 (String) - The command
#   $@ (String) - Its arguments
# Returns:
#   0 - It ran
#   Exits 1 when it failed
#######################################
stealth::sys::runtime::user::_shadow() {
    local -r _user_shadow_root="${1}"
    local -r _user_shadow_cmd="${2}"
    shift 2

    if [[ -n "${_user_shadow_root}" ]]; then
        stealth::sys::cmd::run "${_user_shadow_cmd}" --root "${_user_shadow_root}" "$@"
        return 0
    fi

    stealth::sys::cmd::run "${_user_shadow_cmd}" "$@"
    return 0
}

# =============================================================================
# PUBLIC API
# =============================================================================

#######################################
# Reports whether a local account exists.
#
# Usage:
#   if stealth::sys::runtime::user::exists 'app'; then ...
#   if stealth::sys::runtime::user::exists 'app' --root "${rootfs}"; then ...
#
# Arguments:
#   $1 (String) - The user name
#   $@ (String) - --root DIR to look in a tree that is not this machine
# Globals:
#   STEALTH_USER_PASSWD_FILE (Read)
# Returns:
#   0 - It exists
#   1 - It does not
#   Exits 1 when no name is given
#######################################
stealth::sys::runtime::user::exists() {
    local _user_ex_root
    local -a _user_ex_rest=()
    stealth::sys::runtime::user::_take_root _user_ex_root _user_ex_rest "$@"
    stealth::util::assert::not_empty "${_user_ex_rest[0]:-}" 'a user name is required'

    local _user_ex_found
    stealth::sys::runtime::user::_field _user_ex_found \
        "${_user_ex_root}${STEALTH_USER_PASSWD_FILE}" "${_user_ex_rest[0]}" 1
}

#######################################
# Reports whether a local group exists.
#
# Usage:
#   if stealth::sys::runtime::user::group_exists 'wheel'; then ...
#
# Arguments:
#   $1 (String) - The group name
#   $@ (String) - --root DIR to look in a tree that is not this machine
# Globals:
#   STEALTH_USER_GROUP_FILE (Read)
# Returns:
#   0 - It exists
#   1 - It does not
#   Exits 1 when no name is given
#######################################
stealth::sys::runtime::user::group_exists() {
    local _user_gex_root
    local -a _user_gex_rest=()
    stealth::sys::runtime::user::_take_root _user_gex_root _user_gex_rest "$@"
    stealth::util::assert::not_empty "${_user_gex_rest[0]:-}" 'a group name is required'

    local _user_gex_found
    stealth::sys::runtime::user::_field _user_gex_found \
        "${_user_gex_root}${STEALTH_USER_GROUP_FILE}" "${_user_gex_rest[0]}" 1
}

#######################################
# Says the number a user account has.
#
# Usage:
#   stealth::sys::runtime::user::uid number 'app'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The user name
#   $@ (String)  - --root DIR to look in a tree that is not this machine
# Globals:
#   STEALTH_USER_PASSWD_FILE (Read)
#   _STEALTH_SYS_RUNTIME_USER_UID_FIELD (Read)
# Returns:
#   0 - Said
#   1 - There is no such account
#   Exits 1 when no output variable or no name is given
#######################################
stealth::sys::runtime::user::uid() {
    local _user_uid_root
    local -a _user_uid_rest=()
    stealth::sys::runtime::user::_take_root _user_uid_root _user_uid_rest "$@"
    stealth::util::assert::not_empty "${_user_uid_rest[0]:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${_user_uid_rest[1]:-}" 'a user name is required'

    stealth::sys::runtime::user::_field "${_user_uid_rest[0]}" \
        "${_user_uid_root}${STEALTH_USER_PASSWD_FILE}" "${_user_uid_rest[1]}" \
        "${_STEALTH_SYS_RUNTIME_USER_UID_FIELD}"
}

#######################################
# Says the number a group has.
#
# Usage:
#   stealth::sys::runtime::user::gid number 'wheel'
#
# Arguments:
#   $1 (Nameref) - The output variable
#   $2 (String)  - The group name
#   $@ (String)  - --root DIR to look in a tree that is not this machine
# Globals:
#   STEALTH_USER_GROUP_FILE (Read)
#   _STEALTH_SYS_RUNTIME_USER_GROUP_GID_FIELD (Read)
# Returns:
#   0 - Said
#   1 - There is no such group
#   Exits 1 when no output variable or no name is given
#######################################
stealth::sys::runtime::user::gid() {
    local _user_gid_root
    local -a _user_gid_rest=()
    stealth::sys::runtime::user::_take_root _user_gid_root _user_gid_rest "$@"
    stealth::util::assert::not_empty "${_user_gid_rest[0]:-}" 'an output variable is required'
    stealth::util::assert::not_empty "${_user_gid_rest[1]:-}" 'a group name is required'

    stealth::sys::runtime::user::_field "${_user_gid_rest[0]}" \
        "${_user_gid_root}${STEALTH_USER_GROUP_FILE}" "${_user_gid_rest[1]}" \
        "${_STEALTH_SYS_RUNTIME_USER_GROUP_GID_FIELD}"
}

#######################################
# Reports whether a user is in a group, by the group's own list or by the
# group being the one the account was given to start with. A check that looks
# only at the list misses every user's own group.
#
# Usage:
#   if ! stealth::sys::runtime::user::is_member 'app' 'wheel'; then ...
#
# Arguments:
#   $1 (String) - The user name
#   $2 (String) - The group name
#   $@ (String) - --root DIR to look in a tree that is not this machine
# Globals:
#   STEALTH_USER_PASSWD_FILE (Read)
#   STEALTH_USER_GROUP_FILE (Read)
#   _STEALTH_SYS_RUNTIME_USER_GID_FIELD (Read)
#   _STEALTH_SYS_RUNTIME_USER_MEMBERS_FIELD (Read)
# Returns:
#   0 - It is
#   1 - It is not, or one of the two does not exist
#   Exits 1 when a name is missing
#######################################
stealth::sys::runtime::user::is_member() {
    local _user_mem_root
    local -a _user_mem_rest=()
    stealth::sys::runtime::user::_take_root _user_mem_root _user_mem_rest "$@"
    stealth::util::assert::not_empty "${_user_mem_rest[0]:-}" 'a user name is required'
    stealth::util::assert::not_empty "${_user_mem_rest[1]:-}" 'a group name is required'

    local -a _user_mem_root_opt=()
    if [[ -n "${_user_mem_root}" ]]; then
        _user_mem_root_opt=(--root "${_user_mem_root}")
    fi

    local _user_mem_group_gid _user_mem_user_gid
    if stealth::sys::runtime::user::gid _user_mem_group_gid \
        "${_user_mem_rest[1]}" "${_user_mem_root_opt[@]}"; then
        if stealth::sys::runtime::user::_field _user_mem_user_gid \
            "${_user_mem_root}${STEALTH_USER_PASSWD_FILE}" "${_user_mem_rest[0]}" \
            "${_STEALTH_SYS_RUNTIME_USER_GID_FIELD}"; then
            if [[ "${_user_mem_user_gid}" == "${_user_mem_group_gid}" ]]; then
                return 0
            fi
        fi
    fi

    local _user_mem_list
    if ! stealth::sys::runtime::user::_field _user_mem_list \
        "${_user_mem_root}${STEALTH_USER_GROUP_FILE}" "${_user_mem_rest[1]}" \
        "${_STEALTH_SYS_RUNTIME_USER_MEMBERS_FIELD}"; then
        return 1
    fi

    local -a _user_mem_names=()
    stealth::util::text::split _user_mem_names "${_user_mem_list}" ','

    local _user_mem_name
    for _user_mem_name in "${_user_mem_names[@]}"; do
        if [[ "${_user_mem_name}" == "${_user_mem_rest[0]}" ]]; then
            return 0
        fi
    done
    return 1
}

#######################################
# Makes a group, and does nothing when it is already there.
#
# Usage:
#   stealth::sys::runtime::user::group_create 'app'
#   stealth::sys::runtime::user::group_create 'app' --gid 900 --system
#
# Arguments:
#   $1 (String) - The group name
#   $@ (String) - --root DIR, --gid N, --system
# Returns:
#   0 - It is there
#   Exits 1 when no name is given, or groupadd failed
#######################################
stealth::sys::runtime::user::group_create() {
    local _user_gc_root
    local -a _user_gc_rest=()
    stealth::sys::runtime::user::_take_root _user_gc_root _user_gc_rest "$@"
    stealth::util::assert::not_empty "${_user_gc_rest[0]:-}" 'a group name is required'

    local -r _user_gc_name="${_user_gc_rest[0]}"
    local -a _user_gc_args=()
    local -i _user_gc_at=1

    while (( _user_gc_at < ${#_user_gc_rest[@]} )); do
        case "${_user_gc_rest[${_user_gc_at}]}" in
            --gid)
                stealth::util::assert::is_int "${_user_gc_rest[$(( _user_gc_at + 1 ))]:-}" \
                    'a group number is a whole number'
                _user_gc_args+=(--gid "${_user_gc_rest[$(( _user_gc_at + 1 ))]}")
                _user_gc_at=$(( _user_gc_at + 2 ))
                ;;
            --system)
                _user_gc_args+=(--system)
                _user_gc_at=$(( _user_gc_at + 1 ))
                ;;
            *)
                stealth::util::assert::fail \
                    "group_create does not take ${_user_gc_rest[${_user_gc_at}]}"
                ;;
        esac
    done

    local -a _user_gc_root_opt=()
    if [[ -n "${_user_gc_root}" ]]; then
        _user_gc_root_opt=(--root "${_user_gc_root}")
    fi

    if stealth::sys::runtime::user::group_exists "${_user_gc_name}" \
        "${_user_gc_root_opt[@]}"; then
        stealth::util::log::debug 'group %s is already there' "${_user_gc_name}"
        return 0
    fi

    stealth::util::log::info 'making group %s' "${_user_gc_name}"
    stealth::sys::runtime::user::_shadow "${_user_gc_root}" groupadd \
        "${_user_gc_args[@]}" "${_user_gc_name}"
    return 0
}

#######################################
# Makes a user account, and does nothing when it is already there.
#
# Usage:
#   stealth::sys::runtime::user::create 'app' --system --no-home
#   stealth::sys::runtime::user::create 'roy' --shell /bin/bash --group wheel
#
# Arguments:
#   $1 (String) - The user name
#   $@ (String) - --root DIR, --uid N, --group NAME, --home DIR, --shell PATH,
#                 --system, --no-home
# Returns:
#   0 - It is there
#   Exits 1 when no name is given, or useradd failed
#######################################
stealth::sys::runtime::user::create() {
    local _user_cr_root
    local -a _user_cr_rest=()
    stealth::sys::runtime::user::_take_root _user_cr_root _user_cr_rest "$@"
    stealth::util::assert::not_empty "${_user_cr_rest[0]:-}" 'a user name is required'

    local -r _user_cr_name="${_user_cr_rest[0]}"
    local -a _user_cr_args=(--create-home)
    local -i _user_cr_at=1

    while (( _user_cr_at < ${#_user_cr_rest[@]} )); do
        case "${_user_cr_rest[${_user_cr_at}]}" in
            --uid)
                stealth::util::assert::is_int "${_user_cr_rest[$(( _user_cr_at + 1 ))]:-}" \
                    'a user number is a whole number'
                _user_cr_args+=(--uid "${_user_cr_rest[$(( _user_cr_at + 1 ))]}")
                _user_cr_at=$(( _user_cr_at + 2 ))
                ;;
            --group)
                stealth::util::assert::not_empty "${_user_cr_rest[$(( _user_cr_at + 1 ))]:-}" \
                    '--group takes a group'
                _user_cr_args+=(--gid "${_user_cr_rest[$(( _user_cr_at + 1 ))]}")
                _user_cr_at=$(( _user_cr_at + 2 ))
                ;;
            --home)
                stealth::util::assert::not_empty "${_user_cr_rest[$(( _user_cr_at + 1 ))]:-}" \
                    '--home takes a directory'
                _user_cr_args+=(--home-dir "${_user_cr_rest[$(( _user_cr_at + 1 ))]}")
                _user_cr_at=$(( _user_cr_at + 2 ))
                ;;
            --shell)
                stealth::util::assert::not_empty "${_user_cr_rest[$(( _user_cr_at + 1 ))]:-}" \
                    '--shell takes a program'
                _user_cr_args+=(--shell "${_user_cr_rest[$(( _user_cr_at + 1 ))]}")
                _user_cr_at=$(( _user_cr_at + 2 ))
                ;;
            --system)
                _user_cr_args+=(--system)
                _user_cr_at=$(( _user_cr_at + 1 ))
                ;;
            --no-home)
                _user_cr_args=("${_user_cr_args[@]/--create-home/--no-create-home}")
                _user_cr_at=$(( _user_cr_at + 1 ))
                ;;
            *)
                stealth::util::assert::fail \
                    "create does not take ${_user_cr_rest[${_user_cr_at}]}"
                ;;
        esac
    done

    local -a _user_cr_root_opt=()
    if [[ -n "${_user_cr_root}" ]]; then
        _user_cr_root_opt=(--root "${_user_cr_root}")
    fi

    if stealth::sys::runtime::user::exists "${_user_cr_name}" \
        "${_user_cr_root_opt[@]}"; then
        stealth::util::log::debug 'user %s is already there' "${_user_cr_name}"
        return 0
    fi

    stealth::util::log::info 'making user %s' "${_user_cr_name}"
    stealth::sys::runtime::user::_shadow "${_user_cr_root}" useradd \
        "${_user_cr_args[@]}" "${_user_cr_name}"
    return 0
}

#######################################
# Changes an account that is already there.
#
# Usage:
#   stealth::sys::runtime::user::modify 'app' --add-group wheel
#   stealth::sys::runtime::user::modify 'app' --lock
#
# Arguments:
#   $1 (String) - The user name
#   $@ (String) - --root DIR, --add-group NAME, --shell PATH, --home DIR,
#                 --lock, --unlock
# Returns:
#   0 - Changed
#   1 - There is no such account
#   Exits 1 when no name or no change is given, or usermod failed
#######################################
stealth::sys::runtime::user::modify() {
    local _user_mod_root
    local -a _user_mod_rest=()
    stealth::sys::runtime::user::_take_root _user_mod_root _user_mod_rest "$@"
    stealth::util::assert::not_empty "${_user_mod_rest[0]:-}" 'a user name is required'

    local -r _user_mod_name="${_user_mod_rest[0]}"
    local -a _user_mod_args=()
    local -i _user_mod_at=1

    while (( _user_mod_at < ${#_user_mod_rest[@]} )); do
        case "${_user_mod_rest[${_user_mod_at}]}" in
            --add-group)
                stealth::util::assert::not_empty "${_user_mod_rest[$(( _user_mod_at + 1 ))]:-}" \
                    '--add-group takes a group'
                _user_mod_args+=(--append --groups "${_user_mod_rest[$(( _user_mod_at + 1 ))]}")
                _user_mod_at=$(( _user_mod_at + 2 ))
                ;;
            --shell)
                stealth::util::assert::not_empty "${_user_mod_rest[$(( _user_mod_at + 1 ))]:-}" \
                    '--shell takes a program'
                _user_mod_args+=(--shell "${_user_mod_rest[$(( _user_mod_at + 1 ))]}")
                _user_mod_at=$(( _user_mod_at + 2 ))
                ;;
            --home)
                stealth::util::assert::not_empty "${_user_mod_rest[$(( _user_mod_at + 1 ))]:-}" \
                    '--home takes a directory'
                _user_mod_args+=(--home "${_user_mod_rest[$(( _user_mod_at + 1 ))]}" --move-home)
                _user_mod_at=$(( _user_mod_at + 2 ))
                ;;
            --lock)
                _user_mod_args+=(--lock)
                _user_mod_at=$(( _user_mod_at + 1 ))
                ;;
            --unlock)
                _user_mod_args+=(--unlock)
                _user_mod_at=$(( _user_mod_at + 1 ))
                ;;
            *)
                stealth::util::assert::fail \
                    "modify does not take ${_user_mod_rest[${_user_mod_at}]}"
                ;;
        esac
    done

    stealth::util::assert::not_empty "${_user_mod_args[0]:-}" \
        'something to change is required'

    local -a _user_mod_root_opt=()
    if [[ -n "${_user_mod_root}" ]]; then
        _user_mod_root_opt=(--root "${_user_mod_root}")
    fi

    if ! stealth::sys::runtime::user::exists "${_user_mod_name}" \
        "${_user_mod_root_opt[@]}"; then
        stealth::util::log::warn 'there is no user %s to change' "${_user_mod_name}"
        return 1
    fi

    stealth::sys::runtime::user::_shadow "${_user_mod_root}" usermod \
        "${_user_mod_args[@]}" "${_user_mod_name}"
    return 0
}

#######################################
# Sets the password of an account from a hash that was made elsewhere.
#
# The hash goes to chpasswd on its standard input. usermod takes one as an
# argument, and an argument is in the command line for as long as the command
# runs, where anyone on the machine can read it.
#
# Usage:
#   stealth::sys::runtime::user::set_password 'app' "${hash}"
#
# Arguments:
#   $1 (String) - The user name
#   $2 (String) - The hash, as crypt writes it
#   $@ (String) - --root DIR to work on a tree that is not this machine
# Returns:
#   0 - Set
#   1 - There is no such account
#   Exits 1 when a name or a hash is missing, or chpasswd failed
#######################################
stealth::sys::runtime::user::set_password() {
    local _user_pw_root
    local -a _user_pw_rest=()
    stealth::sys::runtime::user::_take_root _user_pw_root _user_pw_rest "$@"
    stealth::util::assert::not_empty "${_user_pw_rest[0]:-}" 'a user name is required'
    stealth::util::assert::not_empty "${_user_pw_rest[1]:-}" 'a password hash is required'

    local -a _user_pw_root_opt=()
    if [[ -n "${_user_pw_root}" ]]; then
        _user_pw_root_opt=(--root "${_user_pw_root}")
    fi

    if ! stealth::sys::runtime::user::exists "${_user_pw_rest[0]}" \
        "${_user_pw_root_opt[@]}"; then
        stealth::util::log::warn 'there is no user %s to give a password' \
            "${_user_pw_rest[0]}"
        return 1
    fi

    stealth::sys::runtime::user::_shadow "${_user_pw_root}" chpasswd --encrypted \
        <<< "${_user_pw_rest[0]}:${_user_pw_rest[1]}"

    stealth::util::log::debug 'set the password of %s' "${_user_pw_rest[0]}"
    return 0
}

#######################################
# Removes an account. One that is not there is a success, because the caller
# wanted it gone and it is gone.
#
# Usage:
#   stealth::sys::runtime::user::delete 'app'
#   stealth::sys::runtime::user::delete 'app' --remove-home
#
# Arguments:
#   $1 (String) - The user name
#   $@ (String) - --root DIR, --remove-home to take the home directory too
# Returns:
#   0 - It is gone
#   Exits 1 when no name is given, or userdel failed
#######################################
stealth::sys::runtime::user::delete() {
    local _user_del_root
    local -a _user_del_rest=()
    stealth::sys::runtime::user::_take_root _user_del_root _user_del_rest "$@"
    stealth::util::assert::not_empty "${_user_del_rest[0]:-}" 'a user name is required'

    local -r _user_del_name="${_user_del_rest[0]}"
    local -a _user_del_args=()
    local -i _user_del_at=1

    while (( _user_del_at < ${#_user_del_rest[@]} )); do
        case "${_user_del_rest[${_user_del_at}]}" in
            --remove-home)
                _user_del_args+=(--remove)
                _user_del_at=$(( _user_del_at + 1 ))
                ;;
            *)
                stealth::util::assert::fail \
                    "delete does not take ${_user_del_rest[${_user_del_at}]}"
                ;;
        esac
    done

    local -a _user_del_root_opt=()
    if [[ -n "${_user_del_root}" ]]; then
        _user_del_root_opt=(--root "${_user_del_root}")
    fi

    if ! stealth::sys::runtime::user::exists "${_user_del_name}" \
        "${_user_del_root_opt[@]}"; then
        stealth::util::log::debug 'there is no user %s to remove' "${_user_del_name}"
        return 0
    fi

    stealth::util::log::info 'removing user %s' "${_user_del_name}"
    stealth::sys::runtime::user::_shadow "${_user_del_root}" userdel \
        "${_user_del_args[@]}" "${_user_del_name}"
    return 0
}
