#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/git - Test Suite
# ==============================================================================
# These run against a real repository on the filesystem, reached over file://.
# git is in the image, so nothing has to be mocked and the answers are git's
# own.
#
# The test that matters is the one that clones a commit. git clone --branch
# refuses a commit identifier outright, so a module that pins by commit has
# to do something else, and the test proves it worked rather than that the
# right command was issued.
#
# GIT_CONFIG_GLOBAL points inside the test, so nothing here reads or writes
# the configuration of whoever is running it.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/git
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    export GIT_CONFIG_GLOBAL="${WORK}/gitconfig"
    export GIT_CONFIG_SYSTEM=/dev/null

    stealth::sys::net::git::identify 'Stealth Test' test@stealthscale.io

    ORIGIN="${WORK}/origin"
    URL="file://${ORIGIN}"
    make_origin
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Builds a repository with three commits and four tags, and remembers the
# commit of the first one so a test can ask for it by name.
make_origin() {
    stealth::sys::net::git::_run init --quiet --initial-branch=main "${ORIGIN}"

    printf 'one\n' > "${ORIGIN}/a"
    stealth::sys::net::git::_run -C "${ORIGIN}" add a
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -m one
    stealth::sys::net::git::_run -C "${ORIGIN}" tag v1.0.0
    stealth::sys::net::git::head FIRST "${ORIGIN}"

    printf 'two\n' > "${ORIGIN}/a"
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -am two
    stealth::sys::net::git::_run -C "${ORIGIN}" tag v1.10.0

    printf 'three\n' > "${ORIGIN}/a"
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -am three
    stealth::sys::net::git::_run -C "${ORIGIN}" tag v1.2.0
    stealth::sys::net::git::_run -C "${ORIGIN}" tag nightly
    stealth::sys::net::git::head TIP "${ORIGIN}"
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::identify
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::identify: a name -> is who a commit is by" {
    stealth::sys::net::git::identify 'Somebody Else' else@example.com
    printf 'four\n' > "${ORIGIN}/a"
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -am four
    local who

    stealth::sys::net::git::_read who -C "${ORIGIN}" log -1 --format='%an'

    assert_equal "${who}" 'Somebody Else'
}

@test "stealth::sys::net::git::identify: the repository -> is not changed by it" {
    # A build that wrote user.name into a checkout would leave it there for
    # whatever reads that checkout next.
    run stealth::sys::net::git::config who "${ORIGIN}" user.name
    assert_failure 1
}

@test "stealth::sys::net::git::identify: no name -> exits 1" {
    run stealth::sys::net::git::identify '' a@b
    assert_refused 'a name is required'
}

@test "stealth::sys::net::git::identify: no address -> exits 1" {
    run stealth::sys::net::git::identify 'A Name'
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::authorize
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::authorize: credentials -> are written where git reads them" {
    stealth::sys::net::git::authorize github.com someone 't0ken' "${WORK}/creds"

    assert_file_contains "${WORK}/creds" 'https://someone:t0ken@github.com'
}

@test "stealth::sys::net::git::authorize: the file -> is nobody else's to read" {
    stealth::sys::net::git::authorize github.com someone 't0ken' "${WORK}/creds"

    assert_file_permission 0600 "${WORK}/creds"
}

@test "stealth::sys::net::git::authorize: the token -> is not in what git is called with" {
    stealth::sys::net::git::authorize github.com someone 't0ken' "${WORK}/creds"
    local settings

    stealth::sys::net::git::_settings settings

    refute_contains "${settings[*]}" 't0ken'
    assert_contains "${settings[*]}" "${WORK}/creds"
}

@test "stealth::sys::net::git::authorize: nothing said about where -> a temporary file is used" {
    stealth::sys::net::git::authorize github.com someone 't0ken'

    assert_file_exists "${STEALTH_GIT_CREDENTIALS}"
    assert_file_permission 0600 "${STEALTH_GIT_CREDENTIALS}"
}

@test "stealth::sys::net::git::authorize: no credentials configured -> git is told to use none" {
    local settings

    stealth::sys::net::git::_settings settings

    assert_contains "${settings[*]}" 'credential.helper='
}

@test "stealth::sys::net::git::authorize: no host -> exits 1" {
    run stealth::sys::net::git::authorize '' someone token
    assert_refused 'a host is required'
}

@test "stealth::sys::net::git::authorize: no password -> exits 1" {
    run stealth::sys::net::git::authorize github.com someone ''
    assert_refused 'a password is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::trust
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::trust: a directory -> is named on every call" {
    stealth::sys::net::git::trust "${WORK}/somewhere"
    local settings

    stealth::sys::net::git::_settings settings

    assert_contains "${settings[*]}" "safe.directory=${WORK}/somewhere"
}

@test "stealth::sys::net::git::trust: the same directory twice -> is named once" {
    stealth::sys::net::git::trust "${WORK}/somewhere"
    stealth::sys::net::git::trust "${WORK}/somewhere"

    assert_array_length _STEALTH_SYS_NET_GIT_TRUSTED 1
}

@test "stealth::sys::net::git::trust: nothing trusted -> nothing is loosened" {
    local settings

    stealth::sys::net::git::_settings settings

    refute_contains "${settings[*]}" 'safe.directory'
}

@test "stealth::sys::net::git::trust: no directory -> exits 1" {
    run stealth::sys::net::git::trust ''
    assert_refused 'a directory is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::is_repo
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::is_repo: a repository -> returns 0" {
    run stealth::sys::net::git::is_repo "${ORIGIN}"
    assert_success
}

@test "stealth::sys::net::git::is_repo: an ordinary directory -> returns 1" {
    run stealth::sys::net::git::is_repo "${WORK}"
    assert_failure 1
}

@test "stealth::sys::net::git::is_repo: a directory that is not there -> returns 1" {
    run stealth::sys::net::git::is_repo "${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::net::git::is_repo: no directory -> exits 1" {
    run stealth::sys::net::git::is_repo ''
    assert_refused 'a directory is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::clone
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::clone: nothing said -> the default branch" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c"

    assert_file_contains "${WORK}/c/a" 'three'
}

@test "stealth::sys::net::git::clone: a tag -> that tag" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref v1.0.0

    assert_file_contains "${WORK}/c/a" 'one'
}

@test "stealth::sys::net::git::clone: a commit -> that commit" {
    # git clone --branch refuses a commit identifier outright, so this is
    # the whole reason the module does something else.
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref "${FIRST}"
    local at

    stealth::sys::net::git::head at "${WORK}/c"

    assert_equal "${at}" "${FIRST}"
}

@test "stealth::sys::net::git::clone: a commit -> the tree is that commit's" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref "${FIRST}"

    assert_file_contains "${WORK}/c/a" 'one'
}

@test "stealth::sys::net::git::clone: --expect that matches -> is no trouble" {
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref v1.0.0 \
        --expect "${FIRST}"
    assert_success
}

@test "stealth::sys::net::git::clone: --expect that does not -> exits 1" {
    # A branch moves. A caller that says which commit it believes the branch
    # is at finds out here rather than three steps later.
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref v1.10.0 \
        --expect "${FIRST}"

    assert_failure 1
    assert_called_with stealth::util::log::error '*was expected to be at*'
}

@test "stealth::sys::net::git::clone: --expect that is not a full commit -> exits 1" {
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --expect abc123
    assert_refused '--expect takes a commit written out in full, not abc123'
}

@test "stealth::sys::net::git::clone: --full -> the whole history" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --full
    local count

    stealth::sys::net::git::_read count -C "${WORK}/c" rev-list --count HEAD

    assert_equal "${count}" '3'
}

@test "stealth::sys::net::git::clone: nothing said -> one commit of history" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c"
    local count

    stealth::sys::net::git::_read count -C "${WORK}/c" rev-list --count HEAD

    assert_equal "${count}" '1'
}

@test "stealth::sys::net::git::clone: --depth -> that much history" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --depth 2
    local count

    stealth::sys::net::git::_read count -C "${WORK}/c" rev-list --count HEAD

    assert_equal "${count}" '2'
}

@test "stealth::sys::net::git::clone: --submodules -> what is inside comes too" {
    # git refuses a submodule over file:// unless told otherwise, for a
    # vulnerability that does not apply to a repository this test just made.
    stealth::sys::net::git::_run config --file "${GIT_CONFIG_GLOBAL}" \
        protocol.file.allow always

    stealth::sys::net::git::_run init --quiet --initial-branch=main "${WORK}/inner"
    printf 'inside\n' > "${WORK}/inner/b"
    stealth::sys::net::git::_run -C "${WORK}/inner" add b
    stealth::sys::net::git::_run -C "${WORK}/inner" commit --quiet -m inner

    stealth::sys::net::git::_run -C "${ORIGIN}" submodule --quiet add \
        "file://${WORK}/inner" sub
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -m sub

    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --submodules

    assert_file_contains "${WORK}/c/sub/b" 'inside'
}

@test "stealth::sys::net::git::clone: no --submodules -> what is inside stays behind" {
    stealth::sys::net::git::_run config --file "${GIT_CONFIG_GLOBAL}" \
        protocol.file.allow always
    stealth::sys::net::git::_run init --quiet --initial-branch=main "${WORK}/inner"
    printf 'inside\n' > "${WORK}/inner/b"
    stealth::sys::net::git::_run -C "${WORK}/inner" add b
    stealth::sys::net::git::_run -C "${WORK}/inner" commit --quiet -m inner
    stealth::sys::net::git::_run -C "${ORIGIN}" submodule --quiet add \
        "file://${WORK}/inner" sub
    stealth::sys::net::git::_run -C "${ORIGIN}" commit --quiet -m sub

    stealth::sys::net::git::clone "${URL}" "${WORK}/c"

    assert_file_not_exists "${WORK}/c/sub/b"
}

@test "stealth::sys::net::git::clone: a server that will not hand over one commit -> the history is taken" {
    # Plenty of servers refuse to serve a commit nobody asked for by branch.
    # Slower, and it always works.
    mock stealth::sys::net::git::_try '*' 'return 1'

    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref "${FIRST}"
    local at

    stealth::sys::net::git::head at "${WORK}/c"

    assert_equal "${at}" "${FIRST}"
}

@test "stealth::sys::net::git::clone: a server that will not hand over one commit -> says so" {
    mock stealth::sys::net::git::_try '*' 'return 1'

    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref "${FIRST}"

    assert_called_with stealth::util::log::debug '*will not hand over*'
}

@test "stealth::sys::net::git::clone: a ref that is not there -> exits 1" {
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref v9.9.9
    assert_failure 1
}

@test "stealth::sys::net::git::clone: --depth that is not a number -> exits 1" {
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --depth all
    assert_refused '--depth takes a whole number, not all'
}

@test "stealth::sys::net::git::clone: an option it does not take -> exits 1" {
    run stealth::sys::net::git::clone "${URL}" "${WORK}/c" --bare
    assert_refused 'git does not take --bare'
}

@test "stealth::sys::net::git::clone: no address -> exits 1" {
    run stealth::sys::net::git::clone '' "${WORK}/c"
    assert_refused 'an address is required'
}

@test "stealth::sys::net::git::clone: nowhere to put it -> exits 1" {
    run stealth::sys::net::git::clone "${URL}" ''
    assert_refused 'somewhere to put it is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::fetch
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::fetch: a ref made since the clone -> arrives" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref v1.0.0
    stealth::sys::net::git::_run -C "${ORIGIN}" tag v2.0.0

    stealth::sys::net::git::fetch "${WORK}/c" --ref v2.0.0

    run stealth::sys::net::git::checkout "${WORK}/c" FETCH_HEAD
    assert_success
}

@test "stealth::sys::net::git::fetch: no repository -> exits 1" {
    run stealth::sys::net::git::fetch "${WORK}/nowhere"
    assert_refused "no repository at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::checkout
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::checkout: a ref the repository has -> moves to it" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --full

    stealth::sys::net::git::checkout "${WORK}/c" v1.0.0

    assert_file_contains "${WORK}/c/a" 'one'
}

@test "stealth::sys::net::git::checkout: a ref it does not have -> exits 1" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c"

    run stealth::sys::net::git::checkout "${WORK}/c" v9.9.9
    assert_failure 1
}

@test "stealth::sys::net::git::checkout: no ref -> exits 1" {
    run stealth::sys::net::git::checkout "${ORIGIN}"
    assert_refused 'a ref is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::head
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::head: a repository -> the commit it is at" {
    local at

    stealth::sys::net::git::head at "${ORIGIN}"

    assert_regex "${at}" '^[0-9a-f]{40}$'
}

@test "stealth::sys::net::git::head: a ref -> the commit that ref names" {
    local at

    stealth::sys::net::git::head at "${ORIGIN}" v1.0.0

    assert_equal "${at}" "${FIRST}"
}

@test "stealth::sys::net::git::head: a ref that is not there -> returns 1" {
    run stealth::sys::net::git::head at "${ORIGIN}" v9.9.9
    assert_failure 1
}

@test "stealth::sys::net::git::head: no output variable -> exits 1" {
    run stealth::sys::net::git::head '' "${ORIGIN}"
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::is_clean
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::is_clean: nothing touched -> returns 0" {
    run stealth::sys::net::git::is_clean "${ORIGIN}"
    assert_success
}

@test "stealth::sys::net::git::is_clean: a file changed -> returns 1" {
    printf 'changed\n' > "${ORIGIN}/a"

    run stealth::sys::net::git::is_clean "${ORIGIN}"
    assert_failure 1
}

@test "stealth::sys::net::git::is_clean: a file that is not tracked -> returns 1" {
    printf 'new\n' > "${ORIGIN}/b"

    run stealth::sys::net::git::is_clean "${ORIGIN}"
    assert_failure 1
}

@test "stealth::sys::net::git::is_clean: not a repository -> returns 1" {
    run stealth::sys::net::git::is_clean "${WORK}"
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::tags
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::tags: a repository -> its tags, newest first" {
    local names

    stealth::sys::net::git::tags names "${URL}"

    assert_array_equal names v1.10.0 v1.2.0 v1.0.0 nightly
}

@test "stealth::sys::net::git::tags: nothing is cloned to ask" {
    local names

    stealth::sys::net::git::tags names "${URL}"

    assert_dir_not_exists "${WORK}/c"
}

@test "stealth::sys::net::git::tags: a repository with none -> returns 1" {
    stealth::sys::net::git::_run init --quiet --initial-branch=main "${WORK}/bare"

    run stealth::sys::net::git::tags names "file://${WORK}/bare"
    assert_failure 1
}

@test "stealth::sys::net::git::tags: an address that is not a repository -> returns 1" {
    run stealth::sys::net::git::tags names "file://${WORK}/nowhere"
    assert_failure 1
}

@test "stealth::sys::net::git::tags: no output array -> exits 1" {
    run stealth::sys::net::git::tags '' "${URL}"
    assert_refused 'an output array is required'
}

@test "stealth::sys::net::git::tags: no address -> exits 1" {
    run stealth::sys::net::git::tags names
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::latest
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::latest: a repository -> its newest tag" {
    # sort -V would answer v1.2.0 for a list that holds v1.10.0.
    local tag

    stealth::sys::net::git::latest tag "${URL}"

    assert_equal "${tag}" 'v1.10.0'
}

@test "stealth::sys::net::git::latest: a repository with no tags -> returns 1" {
    stealth::sys::net::git::_run init --quiet --initial-branch=main "${WORK}/bare"

    run stealth::sys::net::git::latest tag "file://${WORK}/bare"
    assert_failure 1
}

@test "stealth::sys::net::git::latest: no output variable -> exits 1" {
    run stealth::sys::net::git::latest '' "${URL}"
    assert_refused 'an output variable is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::resolve
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::resolve: a tag -> the commit it names" {
    local at

    stealth::sys::net::git::resolve at "${URL}" v1.0.0

    assert_equal "${at}" "${FIRST}"
}

@test "stealth::sys::net::git::resolve: nothing said -> where the default branch is" {
    local at

    stealth::sys::net::git::resolve at "${URL}"

    assert_equal "${at}" "${TIP}"
}

@test "stealth::sys::net::git::resolve: what it says -> is something clone can pin to" {
    local at

    stealth::sys::net::git::resolve at "${URL}" v1.0.0
    stealth::sys::net::git::clone "${URL}" "${WORK}/c" --ref "${at}" --expect "${at}"

    assert_file_contains "${WORK}/c/a" 'one'
}

@test "stealth::sys::net::git::resolve: a ref that is not there -> returns 1" {
    run stealth::sys::net::git::resolve at "${URL}" v9.9.9
    assert_failure 1
}

@test "stealth::sys::net::git::resolve: an address that is not a repository -> returns 1" {
    run stealth::sys::net::git::resolve at "file://${WORK}/nowhere" HEAD
    assert_failure 1
}

@test "stealth::sys::net::git::resolve: no address -> exits 1" {
    run stealth::sys::net::git::resolve at
    assert_refused 'an address is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::config
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::config: a setting that is there -> its value" {
    stealth::sys::net::git::clone "${URL}" "${WORK}/c"
    local where

    stealth::sys::net::git::config where "${WORK}/c" remote.origin.url

    assert_equal "${where}" "${URL}"
}

@test "stealth::sys::net::git::config: a setting that is not -> returns 1" {
    run stealth::sys::net::git::config value "${ORIGIN}" nothing.here
    assert_failure 1
}

@test "stealth::sys::net::git::config: a setting that is not, with a default -> the default" {
    local value

    stealth::sys::net::git::config value "${ORIGIN}" nothing.here fallback

    assert_equal "${value}" 'fallback'
}

@test "stealth::sys::net::git::config: a setting that is not -> says nothing loud about it" {
    # Asking for something that is not set is an answer, not a fault.
    stealth::sys::net::git::config value "${ORIGIN}" nothing.here fallback

    refute_called stealth::util::log::warn
}

@test "stealth::sys::net::git::config: no setting -> exits 1" {
    run stealth::sys::net::git::config value "${ORIGIN}"
    assert_refused 'a setting is required'
}

@test "stealth::sys::net::git::config: no repository -> exits 1" {
    run stealth::sys::net::git::config value "${WORK}/nowhere" a.b
    assert_refused "no repository at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::net::git::set_config
# ------------------------------------------------------------------------------

@test "stealth::sys::net::git::set_config: a setting -> is readable afterwards" {
    stealth::sys::net::git::set_config "${ORIGIN}" stealth.built yes
    local value

    stealth::sys::net::git::config value "${ORIGIN}" stealth.built

    assert_equal "${value}" 'yes'
}

@test "stealth::sys::net::git::set_config: a setting -> stays in that repository" {
    stealth::sys::net::git::set_config "${ORIGIN}" stealth.built yes

    assert_file_contains "${ORIGIN}/.git/config" 'built = yes'
}

@test "stealth::sys::net::git::set_config: no value -> exits 1" {
    run stealth::sys::net::git::set_config "${ORIGIN}" a.b
    assert_refused 'a value is required'
}

@test "stealth::sys::net::git::set_config: no repository -> exits 1" {
    run stealth::sys::net::git::set_config "${WORK}/nowhere" a.b c
    assert_refused "no repository at ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# sys/net/git, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/git: an ssh key -> is offered and nothing else is" {
    STEALTH_GIT_SSH_KEY="${WORK}/id"
    local vars

    stealth::sys::net::git::_environment vars

    assert_contains "${vars[*]}" "-i ${WORK}/id"
    assert_contains "${vars[*]}" 'IdentitiesOnly=yes'
}

@test "sys/net/git: git -> is never left waiting for somebody to type something" {
    local vars

    stealth::sys::net::git::_environment vars

    assert_contains "${vars[*]}" 'GIT_TERMINAL_PROMPT=0'
    assert_contains "${vars[*]}" 'BatchMode=yes'
}

@test "sys/net/git: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/git
    assert_success
}
