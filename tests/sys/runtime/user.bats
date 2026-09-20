#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031,SC2016
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/runtime/user - Test Suite
# ==============================================================================
# The readers work on a passwd and a group file the test wrote, so an answer
# does not depend on who happens to have an account on the machine running
# the suite. Nothing here creates a real user: the writers are checked by
# what they hand shadow-utils, with cmd::run mocked.
#
# --root takes an absolute path, which is what shadow-utils takes, so the
# test directory is used as it stands.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/runtime/user
    load_mock util
    mock::stealth::util::log

    ROOT="${BATS_TEST_TMPDIR}/root"
    mkdir -p "${ROOT}/etc"

    {
        printf 'root:x:0:0:root:/root:/bin/bash\n'
        printf 'app:x:900:900::/var/lib/app:/usr/sbin/nologin\n'
        printf 'roy:x:1000:1000:Roy:/home/roy:/bin/bash\n'
    } > "${ROOT}/etc/passwd"

    {
        printf 'root:x:0:\n'
        printf 'app:x:900:\n'
        printf 'roy:x:1000:\n'
        printf 'wheel:x:10:roy,other\n'
        printf 'empty:x:11:\n'
    } > "${ROOT}/etc/group"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::exists
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::exists: an account in the file -> returns 0" {
    run stealth::sys::runtime::user::exists 'app' --root "${ROOT}"
    assert_success
}

@test "stealth::sys::runtime::user::exists: an account that is not -> returns 1" {
    run stealth::sys::runtime::user::exists 'nobody-here' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::exists: a name that is only a prefix -> returns 1" {
    run stealth::sys::runtime::user::exists 'ap' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::exists: no passwd file under the root -> returns 1" {
    run stealth::sys::runtime::user::exists 'app' --root "${BATS_TEST_TMPDIR}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::exists: no name -> exits 1" {
    run stealth::sys::runtime::user::exists '' --root "${ROOT}"
    assert_refused 'a user name is required'
}

@test "stealth::sys::runtime::user::exists: --root that is not absolute -> exits 1" {
    run stealth::sys::runtime::user::exists 'app' --root 'root'
    assert_refused '--root takes an absolute path, not root'
}

@test "stealth::sys::runtime::user::exists: --root with no directory -> exits 1" {
    run stealth::sys::runtime::user::exists 'app' --root
    assert_refused '--root takes a directory'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::group_exists
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::group_exists: a group in the file -> returns 0" {
    run stealth::sys::runtime::user::group_exists 'wheel' --root "${ROOT}"
    assert_success
}

@test "stealth::sys::runtime::user::group_exists: a group that is not -> returns 1" {
    run stealth::sys::runtime::user::group_exists 'docker' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::group_exists: no name -> exits 1" {
    run stealth::sys::runtime::user::group_exists '' --root "${ROOT}"
    assert_refused 'a group name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::uid
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::uid: an account -> its number" {
    local number

    stealth::sys::runtime::user::uid number 'app' --root "${ROOT}"

    assert_equal "${number}" '900'
}

@test "stealth::sys::runtime::user::uid: root -> zero" {
    local number

    stealth::sys::runtime::user::uid number 'root' --root "${ROOT}"

    assert_equal "${number}" '0'
}

@test "stealth::sys::runtime::user::uid: an account that is not there -> returns 1" {
    run stealth::sys::runtime::user::uid number 'nobody-here' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::uid: no output variable -> exits 1" {
    run stealth::sys::runtime::user::uid '' 'app' --root "${ROOT}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::runtime::user::uid: no name -> exits 1" {
    run stealth::sys::runtime::user::uid number --root "${ROOT}"
    assert_refused 'a user name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::gid
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::gid: a group -> its number" {
    local number

    stealth::sys::runtime::user::gid number 'wheel' --root "${ROOT}"

    assert_equal "${number}" '10'
}

@test "stealth::sys::runtime::user::gid: a group that is not there -> returns 1" {
    run stealth::sys::runtime::user::gid number 'docker' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::gid: no output variable -> exits 1" {
    run stealth::sys::runtime::user::gid '' 'wheel' --root "${ROOT}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::runtime::user::gid: no name -> exits 1" {
    run stealth::sys::runtime::user::gid number --root "${ROOT}"
    assert_refused 'a group name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::is_member
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::is_member: a user on the group's list -> returns 0" {
    run stealth::sys::runtime::user::is_member 'roy' 'wheel' --root "${ROOT}"
    assert_success
}

@test "stealth::sys::runtime::user::is_member: the group a user was given -> returns 0" {
    # roy is not on the list for his own group, and belongs to it all the same.
    run stealth::sys::runtime::user::is_member 'roy' 'roy' --root "${ROOT}"
    assert_success
}

@test "stealth::sys::runtime::user::is_member: a user in neither -> returns 1" {
    run stealth::sys::runtime::user::is_member 'app' 'wheel' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::is_member: a group with nobody on its list -> returns 1" {
    run stealth::sys::runtime::user::is_member 'roy' 'empty' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::is_member: a group that is not there -> returns 1" {
    run stealth::sys::runtime::user::is_member 'roy' 'docker' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::is_member: a name that is only part of one on the list -> returns 1" {
    run stealth::sys::runtime::user::is_member 'oth' 'wheel' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::is_member: no user -> exits 1" {
    run stealth::sys::runtime::user::is_member '' 'wheel' --root "${ROOT}"
    assert_refused 'a user name is required'
}

@test "stealth::sys::runtime::user::is_member: no group -> exits 1" {
    run stealth::sys::runtime::user::is_member 'roy' --root "${ROOT}"
    assert_refused 'a group name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::group_create
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::group_create: a new group -> groupadd is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::group_create 'docker' --root "${ROOT}"

    assert_called_with_args stealth::sys::cmd::run groupadd --root "${ROOT}" 'docker'
}

@test "stealth::sys::runtime::user::group_create: --gid -> is passed on" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::group_create 'docker' --gid 970 --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--gid 970*'
}

@test "stealth::sys::runtime::user::group_create: --system -> is passed on" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::group_create 'docker' --system --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--system*'
}

@test "stealth::sys::runtime::user::group_create: no root -> groupadd is run without one" {
    mock stealth::sys::cmd::run '*' 'return 0'
    STEALTH_USER_GROUP_FILE="${ROOT}/etc/group"

    stealth::sys::runtime::user::group_create 'docker'

    assert_called_with_args stealth::sys::cmd::run groupadd 'docker'
}

@test "stealth::sys::runtime::user::group_create: a group already there -> nothing is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::group_create 'wheel' --root "${ROOT}"

    refute_called stealth::sys::cmd::run
}

@test "stealth::sys::runtime::user::group_create: --gid that is not a number -> exits 1" {
    run stealth::sys::runtime::user::group_create 'docker' --gid nine --root "${ROOT}"
    assert_refused 'a group number is a whole number'
}

@test "stealth::sys::runtime::user::group_create: an option it does not take -> exits 1" {
    run stealth::sys::runtime::user::group_create 'docker' --force --root "${ROOT}"
    assert_refused 'group_create does not take --force'
}

@test "stealth::sys::runtime::user::group_create: no name -> exits 1" {
    run stealth::sys::runtime::user::group_create '' --root "${ROOT}"
    assert_refused 'a group name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::create
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::create: a new account -> useradd is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::create 'postgres' --root "${ROOT}"

    assert_called_with_args stealth::sys::cmd::run \
        useradd --root "${ROOT}" --create-home 'postgres'
}

@test "stealth::sys::runtime::user::create: every option -> is turned into useradd's" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::create 'postgres' --root "${ROOT}" \
        --uid 26 --group postgres --home /var/lib/pgsql --shell /bin/bash --system

    assert_called_with stealth::sys::cmd::run '*--uid 26*'
    assert_called_with stealth::sys::cmd::run '*--gid postgres*'
    assert_called_with stealth::sys::cmd::run '*--home-dir /var/lib/pgsql*'
    assert_called_with stealth::sys::cmd::run '*--shell /bin/bash*'
    assert_called_with stealth::sys::cmd::run '*--system*'
}

@test "stealth::sys::runtime::user::create: --no-home -> useradd is told not to make one" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::create 'postgres' --no-home --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--no-create-home*'
    refute_called_with stealth::sys::cmd::run '* --create-home *'
}

@test "stealth::sys::runtime::user::create: an account already there -> nothing is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::create 'app' --root "${ROOT}"

    refute_called stealth::sys::cmd::run
}

@test "stealth::sys::runtime::user::create: --uid that is not a number -> exits 1" {
    run stealth::sys::runtime::user::create 'postgres' --uid abc --root "${ROOT}"
    assert_refused 'a user number is a whole number'
}

@test "stealth::sys::runtime::user::create: --shell with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::create 'postgres' --shell --root "${ROOT}"
    assert_refused '--shell takes a program'
}

@test "stealth::sys::runtime::user::create: --group with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::create 'postgres' --group --root "${ROOT}"
    assert_refused '--group takes a group'
}

@test "stealth::sys::runtime::user::create: --home with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::create 'postgres' --home --root "${ROOT}"
    assert_refused '--home takes a directory'
}

@test "stealth::sys::runtime::user::create: an option it does not take -> exits 1" {
    run stealth::sys::runtime::user::create 'postgres' --expires --root "${ROOT}"
    assert_refused 'create does not take --expires'
}

@test "stealth::sys::runtime::user::create: no name -> exits 1" {
    run stealth::sys::runtime::user::create '' --root "${ROOT}"
    assert_refused 'a user name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::modify
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::modify: --add-group -> usermod appends" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'app' --add-group wheel --root "${ROOT}"

    assert_called_with_args stealth::sys::cmd::run \
        usermod --root "${ROOT}" --append --groups wheel 'app'
}

@test "stealth::sys::runtime::user::modify: --lock -> usermod locks" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'app' --lock --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--lock*'
}

@test "stealth::sys::runtime::user::modify: --unlock -> usermod unlocks" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'app' --unlock --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--unlock*'
}

@test "stealth::sys::runtime::user::modify: --shell -> usermod changes it" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'app' --shell /bin/bash --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--shell /bin/bash*'
}

@test "stealth::sys::runtime::user::modify: --home -> what is there moves with it" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'app' --home /srv/app --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--home /srv/app --move-home*'
}

@test "stealth::sys::runtime::user::modify: an account that is not there -> returns 1" {
    mock stealth::sys::cmd::run '*' 'return 0'

    run stealth::sys::runtime::user::modify 'nobody-here' --lock --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::modify: an account that is not there -> nothing is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::modify 'nobody-here' --lock --root "${ROOT}" || true

    refute_called stealth::sys::cmd::run
}

@test "stealth::sys::runtime::user::modify: nothing to change -> exits 1" {
    run stealth::sys::runtime::user::modify 'app' --root "${ROOT}"
    assert_refused 'something to change is required'
}

@test "stealth::sys::runtime::user::modify: --add-group with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::modify 'app' --add-group --root "${ROOT}"
    assert_refused '--add-group takes a group'
}

@test "stealth::sys::runtime::user::modify: --shell with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::modify 'app' --shell --root "${ROOT}"
    assert_refused '--shell takes a program'
}

@test "stealth::sys::runtime::user::modify: --home with nothing after it -> exits 1" {
    run stealth::sys::runtime::user::modify 'app' --home --root "${ROOT}"
    assert_refused '--home takes a directory'
}

@test "stealth::sys::runtime::user::modify: an option it does not take -> exits 1" {
    run stealth::sys::runtime::user::modify 'app' --expire --root "${ROOT}"
    assert_refused 'modify does not take --expire'
}

@test "stealth::sys::runtime::user::modify: no name -> exits 1" {
    run stealth::sys::runtime::user::modify '' --lock --root "${ROOT}"
    assert_refused 'a user name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::set_password
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::set_password: a hash -> chpasswd is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::set_password 'app' '$6$salt$hash' --root "${ROOT}"

    assert_called_with_args stealth::sys::cmd::run \
        chpasswd --root "${ROOT}" --encrypted
}

@test "stealth::sys::runtime::user::set_password: the hash -> is not in the command line" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::set_password 'app' '$6$salt$hash' --root "${ROOT}"

    refute_called_with stealth::sys::cmd::run '*$6$salt$hash*'
}

@test "stealth::sys::runtime::user::set_password: an account that is not there -> returns 1" {
    mock stealth::sys::cmd::run '*' 'return 0'

    run stealth::sys::runtime::user::set_password 'nobody-here' 'x' --root "${ROOT}"
    assert_failure 1
}

@test "stealth::sys::runtime::user::set_password: no hash -> exits 1" {
    run stealth::sys::runtime::user::set_password 'app' --root "${ROOT}"
    assert_refused 'a password hash is required'
}

@test "stealth::sys::runtime::user::set_password: no name -> exits 1" {
    run stealth::sys::runtime::user::set_password '' 'x' --root "${ROOT}"
    assert_refused 'a user name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::delete
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::delete: an account -> userdel is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::delete 'app' --root "${ROOT}"

    assert_called_with_args stealth::sys::cmd::run userdel --root "${ROOT}" 'app'
}

@test "stealth::sys::runtime::user::delete: --remove-home -> the home goes too" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::delete 'app' --remove-home --root "${ROOT}"

    assert_called_with stealth::sys::cmd::run '*--remove*'
}

@test "stealth::sys::runtime::user::delete: an account that is not there -> returns 0" {
    mock stealth::sys::cmd::run '*' 'return 0'

    run stealth::sys::runtime::user::delete 'nobody-here' --root "${ROOT}"
    assert_success
}

@test "stealth::sys::runtime::user::delete: an account that is not there -> nothing is run" {
    mock stealth::sys::cmd::run '*' 'return 0'

    stealth::sys::runtime::user::delete 'nobody-here' --root "${ROOT}"

    refute_called stealth::sys::cmd::run
}

@test "stealth::sys::runtime::user::delete: an option it does not take -> exits 1" {
    run stealth::sys::runtime::user::delete 'app' --force --root "${ROOT}"
    assert_refused 'delete does not take --force'
}

@test "stealth::sys::runtime::user::delete: no name -> exits 1" {
    run stealth::sys::runtime::user::delete '' --root "${ROOT}"
    assert_refused 'a user name is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::runtime::user::_field
# ------------------------------------------------------------------------------

@test "stealth::sys::runtime::user::_field: a last line with no break after it -> is read" {
    printf 'root:x:0:0::/root:/bin/sh\nlast:x:42:42::/last:/bin/sh' > "${ROOT}/etc/passwd"
    local number

    stealth::sys::runtime::user::uid number 'last' --root "${ROOT}"

    assert_equal "${number}" '42'
}

@test "stealth::sys::runtime::user::_field: a field that is not in the line -> is empty" {
    printf 'short:x\n' > "${ROOT}/etc/passwd"
    local number

    stealth::sys::runtime::user::uid number 'short' --root "${ROOT}"

    assert_equal "${number}" ''
}

# ------------------------------------------------------------------------------
# sys/runtime/user, the module itself
# ------------------------------------------------------------------------------

@test "sys/runtime/user: sourced twice -> returns before it declares anything" {
    run load_lib sys/runtime/user
    assert_success
}
