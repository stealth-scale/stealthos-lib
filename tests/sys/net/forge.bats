#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/net/forge - Test Suite
# ==============================================================================
# A stand-in forge answers on the loopback address, serving the two shapes
# GitHub and GitLab answer with. Both are pointed at it, so the same tests
# run against both and a difference between them shows up as a failure
# rather than as a second test file nobody kept in step.
#
# tests/fixtures/forge-server.py is that server. A static directory will not
# do, because GitLab writes the project into the path with its slash as %2F
# and http.server decodes that before looking for a file.
#
# Anything backgrounded here closes descriptor 3. bats waits for that
# descriptor to close.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/net/forge
    load_mock util
    mock::stealth::util::log

    export TMPDIR="${BATS_TEST_TMPDIR}/tmp"
    mkdir -p "${TMPDIR}"

    PORT=$(( 19600 + ($$ % 300) ))
    SERVER=''
    ROUTES=''
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
    BASE="http://127.0.0.1:${PORT}"

    STEALTH_FORGE_API['github']="${BASE}"
    STEALTH_FORGE_RAW['github']="${BASE}"
}

teardown() {
    if [[ -n "${SERVER}" ]]; then
        kill -9 "${SERVER}" 2>/dev/null || true
        wait "${SERVER}" 2>/dev/null || true
    fi
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Starts the stand-in forge with the paths it is to answer, and waits until
# it answers them.
serve() {
    printf '%s' "${1}" > "${WORK}/routes.json"

    python3 "${BATS_TEST_DIRNAME}/../../fixtures/forge-server.py" \
        "${PORT}" "${WORK}/routes.json" > /dev/null 2>&1 3>&- &
    SERVER=$!

    local -i waited=0
    while (( waited < 100 )); do
        if bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ 127.0.0.1 "${PORT}" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
        waited=$(( waited + 1 ))
    done
    return 1
}

# The paths a GitHub-shaped forge answers, left in ROUTES.
github_routes() {
    ROUTES='{
      "/repos/org/repo/releases/latest": "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"tool-1.2.3-linux-amd64.tar.gz\",\"browser_download_url\":\"https://e/amd64\"},{\"name\":\"tool-1.2.3-linux-arm64.tar.gz\",\"browser_download_url\":\"https://e/arm64\"},{\"name\":\"toolX1X2X3-linux-amd64XtarXgz\",\"browser_download_url\":\"https://e/regex-would-match-this\"}]}",
      "/repos/org/repo/tags": "[{\"name\":\"v1.0.0\"},{\"name\":\"v1.10.0\"},{\"name\":\"v1.2.0\"},{\"name\":\"v1.10.0-rc1\"},{\"name\":\"nightly\"}]",
      "/repos/org/tagsonly/tags": "[{\"name\":\"v2.0.0\"},{\"name\":\"v2.1.0\"}]",
      "/repos/org/notags/tags": "[]",
      "/repos/org/noassets/releases/latest": "{\"tag_name\":\"v1.0.0\"}",
      "/repos/org/nameless/releases/latest": "{\"tag_name\":\"v1.0.0\",\"assets\":[{\"browser_download_url\":\"https://e/nameless\"}]}",
      "/repos/org/repo/releases/tags/v0.9.0": "{\"tag_name\":\"v0.9.0\",\"assets\":[{\"name\":\"tool-0.9.0-linux-amd64.tar.gz\",\"browser_download_url\":\"https://e/old-amd64\"}]}",
      "/org/repo/main/README.md": "the readme"
    }'
}

# The paths a GitLab-shaped forge answers, left in ROUTES.
gitlab_routes() {
    ROUTES='{
      "/api/v4/projects/g%2Fp/releases": "[{\"tag_name\":\"v9.9.9\",\"assets\":{\"links\":[{\"name\":\"pkg-amd64.deb\",\"url\":\"https://e/deb\"}]}}]",
      "/api/v4/projects/g%2Fp/repository/tags": "[{\"name\":\"v9.0.0\"},{\"name\":\"v9.9.9\"}]",
      "/api/v4/projects/g%2Fp/releases/v9.0.0": "{\"tag_name\":\"v9.0.0\",\"assets\":{\"links\":[{\"name\":\"pkg-old-amd64.deb\",\"url\":\"https://e/old-deb\"}]}}",
      "/g/p/-/raw/main/README.md": "the readme"
    }'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::which
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::which: a github address -> github" {
    local where

    stealth::sys::net::forge::which where 'github.com/org/repo'

    assert_equal "${where}" 'github'
}

@test "stealth::sys::net::forge::which: a gitlab address -> gitlab" {
    local where

    stealth::sys::net::forge::which where 'gitlab.com/group/project'

    assert_equal "${where}" 'gitlab'
}

@test "stealth::sys::net::forge::which: a full URL -> the forge its host names" {
    local where

    stealth::sys::net::forge::which where 'https://gitlab.com/group/project.git'

    assert_equal "${where}" 'gitlab'
}

@test "stealth::sys::net::forge::which: no host at all -> github" {
    local where

    stealth::sys::net::forge::which where 'org/repo'

    assert_equal "${where}" 'github'
}

@test "stealth::sys::net::forge::which: a host nothing knows -> github" {
    local where

    stealth::sys::net::forge::which where 'forge.example.com/org/repo'

    assert_equal "${where}" 'github'
}

@test "stealth::sys::net::forge::which: a host and nothing else -> exits 1" {
    run stealth::sys::net::forge::which where 'github.com/'
    assert_refused 'github.com/ names no project'
}

@test "stealth::sys::net::forge::which: no output variable -> exits 1" {
    run stealth::sys::net::forge::which '' 'org/repo'
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::forge::which: no project -> exits 1" {
    run stealth::sys::net::forge::which where
    assert_refused 'a project is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::version
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::version: a github release -> its tag" {
    github_routes
    serve "${ROUTES}"
    local tag

    stealth::sys::net::forge::version tag 'org/repo'

    assert_equal "${tag}" 'v1.2.3'
}

@test "stealth::sys::net::forge::version: a gitlab release -> its tag" {
    gitlab_routes
    serve "${ROUTES}"
    local tag

    stealth::sys::net::forge::version tag 'g/p' --forge gitlab --instance "${BASE}"

    assert_equal "${tag}" 'v9.9.9'
}

@test "stealth::sys::net::forge::version: a project with tags and no release -> the newest tag" {
    # Plenty of projects tag and never cut a release. The release endpoint
    # answers with nothing for those, which is not a failure.
    github_routes
    serve "${ROUTES}"
    local tag

    stealth::sys::net::forge::version tag 'org/tagsonly'

    assert_equal "${tag}" 'v2.1.0'
}

@test "stealth::sys::net::forge::version: a project with neither -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::version tag 'org/nothing'
    assert_failure 1
}

@test "stealth::sys::net::forge::version: nothing answering -> returns 1" {
    # --retries 0 because nothing is coming. With the default budget this
    # waits out two retry sequences before it says so.
    run stealth::sys::net::forge::version tag 'org/repo' --retries 0
    assert_failure 1
}

@test "stealth::sys::net::forge::version: no output variable -> exits 1" {
    run stealth::sys::net::forge::version '' 'org/repo'
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::forge::version: no project -> exits 1" {
    run stealth::sys::net::forge::version tag
    assert_refused 'a project is required'
}

@test "stealth::sys::net::forge::version: a forge nothing knows -> exits 1" {
    run stealth::sys::net::forge::version tag 'org/repo' --forge codeberg
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::tags
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::tags: a project -> its tags, newest first" {
    github_routes
    serve "${ROUTES}"
    local names

    stealth::sys::net::forge::tags names 'org/repo'

    assert_equal "${names[0]}" 'v1.10.0'
}

@test "stealth::sys::net::forge::tags: a release before a prerelease -> comes first" {
    # sort -V does not know this. util/semver does.
    github_routes
    serve "${ROUTES}"
    local names

    stealth::sys::net::forge::tags names 'org/repo'

    assert_array_equal names v1.10.0 v1.10.0-rc1 v1.2.0 v1.0.0 nightly
}

@test "stealth::sys::net::forge::tags: a tag that is not a version -> goes last" {
    github_routes
    serve "${ROUTES}"
    local names

    stealth::sys::net::forge::tags names 'org/repo'

    assert_equal "${names[-1]}" 'nightly'
}

@test "stealth::sys::net::forge::tags: a gitlab project -> its tags" {
    gitlab_routes
    serve "${ROUTES}"
    local names

    stealth::sys::net::forge::tags names 'g/p' --forge gitlab --instance "${BASE}"

    assert_array_equal names v9.9.9 v9.0.0
}

@test "stealth::sys::net::forge::tags: a project with none -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::tags names 'org/nothing'
    assert_failure 1
}

@test "stealth::sys::net::forge::tags: a project whose list is empty -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::tags names 'org/notags'
    assert_failure 1
}

@test "stealth::sys::net::forge::tags: a project whose list is empty -> says so" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::tags names 'org/notags'

    assert_called_with stealth::util::log::debug '*has no tags*'
}

@test "stealth::sys::net::forge::tags: no output array -> exits 1" {
    run stealth::sys::net::forge::tags '' 'org/repo'
    assert_refused 'an output array is required'
}

@test "stealth::sys::net::forge::tags: no project -> exits 1" {
    run stealth::sys::net::forge::tags names
    assert_refused 'a project is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::asset
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::asset: a pattern that matches -> its address" {
    github_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'org/repo' '*linux-amd64.tar.gz'

    assert_equal "${url}" 'https://e/amd64'
}

@test "stealth::sys::net::forge::asset: another pattern -> the other one" {
    github_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'org/repo' '*linux-arm64.tar.gz'

    assert_equal "${url}" 'https://e/arm64'
}

@test "stealth::sys::net::forge::asset: a pattern is a shell pattern, not a regex" {
    # The release holds a second file named the same but with the dots
    # replaced. jq's test() would read every dot as any character and match
    # that one too, and which of the two it returned would be luck. A glob
    # reads a dot as a dot.
    github_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'org/repo' 'tool-1.2.3-linux-amd64.tar.gz'

    assert_equal "${url}" 'https://e/amd64'
}

@test "stealth::sys::net::forge::asset: a question mark -> matches one character, as a glob does" {
    github_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'org/repo' 'toolX1X2X3-linux-amd64?tar?gz'

    assert_equal "${url}" 'https://e/regex-would-match-this'
}

@test "stealth::sys::net::forge::asset: a pattern with a quote in it -> matches nothing" {
    # Handed to jq inside a test() this would end the string and rewrite the
    # program. Here it is a pattern that happens to match no file.
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/repo' '*" or true or "*'
    assert_failure 1
}

@test "stealth::sys::net::forge::asset: a gitlab release -> the link" {
    gitlab_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'g/p' '*amd64.deb' --forge gitlab \
        --instance "${BASE}"

    assert_equal "${url}" 'https://e/deb'
}

@test "stealth::sys::net::forge::asset: nothing matching -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/repo' '*windows*'
    assert_failure 1
}

@test "stealth::sys::net::forge::asset: nothing matching -> says so" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/repo' '*windows*'

    assert_called_with stealth::util::log::debug '*is named like*'
}

@test "stealth::sys::net::forge::asset: a project with no release -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/nothing' '*'
    assert_failure 1
}

@test "stealth::sys::net::forge::asset: --tag -> that release rather than the latest" {
    github_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'org/repo' '*linux-amd64.tar.gz' \
        --tag v0.9.0

    assert_equal "${url}" 'https://e/old-amd64'
}

@test "stealth::sys::net::forge::asset: --tag on gitlab -> that release" {
    gitlab_routes
    serve "${ROUTES}"
    local url

    stealth::sys::net::forge::asset url 'g/p' '*amd64.deb' --tag v9.0.0 \
        --forge gitlab --instance "${BASE}"

    assert_equal "${url}" 'https://e/old-deb'
}

@test "stealth::sys::net::forge::asset: a release with no files at all -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/noassets' '*'
    assert_failure 1
}

@test "stealth::sys::net::forge::asset: a file with no name -> is passed over" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::asset url 'org/nameless' '*'
    assert_failure 1
}

@test "stealth::sys::net::forge::asset: no output variable -> exits 1" {
    run stealth::sys::net::forge::asset '' 'org/repo' '*'
    assert_refused 'an output variable is required'
}

@test "stealth::sys::net::forge::asset: no pattern -> exits 1" {
    run stealth::sys::net::forge::asset url 'org/repo'
    assert_refused 'a pattern is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::raw
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::raw: a file -> arrives" {
    github_routes
    serve "${ROUTES}"

    stealth::sys::net::forge::raw 'org/repo' 'README.md' "${WORK}/out" --ref main

    assert_file_contains "${WORK}/out" 'the readme'
}

@test "stealth::sys::net::forge::raw: a gitlab file -> arrives" {
    gitlab_routes
    serve "${ROUTES}"

    stealth::sys::net::forge::raw 'g/p' 'README.md' "${WORK}/out" --ref main \
        --forge gitlab --instance "${BASE}"

    assert_file_contains "${WORK}/out" 'the readme'
}

@test "stealth::sys::net::forge::raw: a file that is not there -> returns 1" {
    github_routes
    serve "${ROUTES}"

    run stealth::sys::net::forge::raw 'org/repo' 'nowhere.md' "${WORK}/out" \
        --ref main --retries 0
    assert_failure 1
}

@test "stealth::sys::net::forge::raw: no project -> exits 1" {
    run stealth::sys::net::forge::raw '' 'a' "${WORK}/out"
    assert_refused 'a project is required'
}

@test "stealth::sys::net::forge::raw: no file -> exits 1" {
    run stealth::sys::net::forge::raw 'org/repo' '' "${WORK}/out"
    assert_refused 'a file is required'
}

@test "stealth::sys::net::forge::raw: nowhere to put it -> exits 1" {
    run stealth::sys::net::forge::raw 'org/repo' 'a' ''
    assert_refused 'somewhere to put it is required'
}

# ------------------------------------------------------------------------------
# stealth::sys::net::forge::_take_options
# ------------------------------------------------------------------------------

@test "stealth::sys::net::forge::_take_options: --instance with nothing after it -> exits 1" {
    run stealth::sys::net::forge::version tag 'org/repo' --instance
    assert_refused '--instance takes an address'
}

@test "stealth::sys::net::forge::_take_options: --ref with nothing after it -> exits 1" {
    run stealth::sys::net::forge::raw 'org/repo' 'a' "${WORK}/out" --ref
    assert_refused '--ref takes a branch, a tag or a commit'
}

@test "stealth::sys::net::forge::_take_options: --tag with nothing after it -> exits 1" {
    run stealth::sys::net::forge::version tag 'org/repo' --tag
    assert_refused '--tag takes a tag'
}

# ------------------------------------------------------------------------------
# sys/net/forge, the module itself
# ------------------------------------------------------------------------------

@test "sys/net/forge: nothing is left behind after asking" {
    github_routes
    serve "${ROUTES}"
    local tag

    stealth::sys::net::forge::version tag 'org/repo'

    # shellcheck disable=SC2312  # the count is the answer, not the status
    run bash -c 'ls "${1}"/forge.* "${1}"/answer.* 2>/dev/null | wc -l' _ "${TMPDIR}"
    assert_output '0'
}

@test "sys/net/forge: sourced twice -> returns before it declares anything" {
    run load_lib sys/net/forge
    assert_success
}
