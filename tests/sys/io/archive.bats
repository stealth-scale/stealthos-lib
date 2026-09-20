#!/usr/bin/env bats

# shellcheck disable=SC2034,SC2030,SC2031
# Variables here are read by name through the library's namerefs, and every
# @test is its own process, not a subshell of the file.

# ==============================================================================
# sys/io/archive - Test Suite
# ==============================================================================
# The claim this module makes is that the same files give the same archive,
# whoever builds it and whenever. Two trees are built with the same contents
# and different modification times, and the two archives are compared byte for
# byte. That comparison is what the tests are here for. Everything else is
# around it.
#
# SOURCE_DATE_EPOCH is cleared in setup, because a machine that has it set
# would otherwise decide what the default time is.
#
# The tests are grouped by subject: the public functions in the order the
# module declares them, then the internals, then the module itself.
# ==============================================================================

bats_load_library stealth

setup() {
    common_setup

    load_lib util/import sys/io/archive
    load_mock util
    mock::stealth::util::log

    unset SOURCE_DATE_EPOCH

    TREE=''
    WORK="${BATS_TEST_TMPDIR}/work"
    mkdir -p "${WORK}"
}

teardown() {
    common_teardown
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Builds a small tree of the same contents every time, under a name of the
# caller's choosing, with every file given the date the caller asks for, and
# leaves the path of it in TREE.
make_tree() {
    local -r root="${WORK}/${1}"
    local -r when="${2:-2020-01-01}"

    mkdir -p "${root}/usr/bin" "${root}/etc"
    printf 'tool\n' > "${root}/usr/bin/tool"
    printf 'setting = 1\n' > "${root}/etc/app.conf"
    chmod 0755 "${root}/usr/bin/tool"
    touch -d "${when}" "${root}/usr/bin/tool" "${root}/etc/app.conf"

    TREE="${root}"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::kind
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::kind: a gzip file -> says gzip" {
    printf 'body\n' | gzip -n -c > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'gzip'
}

@test "stealth::sys::io::archive::kind: a bzip2 file -> says bzip2" {
    printf 'body\n' | bzip2 -c > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'bzip2'
}

@test "stealth::sys::io::archive::kind: an xz file -> says xz" {
    printf 'body\n' | xz -c > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'xz'
}

@test "stealth::sys::io::archive::kind: a zstd file -> says zstd" {
    printf 'body\n' | zstd -q -c > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'zstd'
}

@test "stealth::sys::io::archive::kind: a file that is not compressed -> says none" {
    printf 'plain text\n' > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'none'
}

@test "stealth::sys::io::archive::kind: an empty file -> says none" {
    : > "${WORK}/blob"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob"

    assert_equal "${how}" 'none'
}

@test "stealth::sys::io::archive::kind: the name says otherwise -> the bytes decide" {
    printf 'body\n' | zstd -q -c > "${WORK}/blob.tar.gz"
    local how

    stealth::sys::io::archive::kind how "${WORK}/blob.tar.gz"

    assert_equal "${how}" 'zstd'
}

@test "stealth::sys::io::archive::kind: no output variable -> exits 1" {
    run stealth::sys::io::archive::kind '' "${WORK}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::io::archive::kind: no such file -> exits 1" {
    run stealth::sys::io::archive::kind how "${WORK}/nowhere"
    assert_refused "no file to look at in ${WORK}/nowhere"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::create
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::create: a directory -> the tar is written" {
    make_tree one
    local -r root="${TREE}"

    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    assert_file_exists "${WORK}/one.tar"
}

@test "stealth::sys::io::archive::create: the same files, different times -> the same bytes" {
    make_tree a 2020-01-01
    local -r a="${TREE}"
    make_tree b 2026-09-20
    local -r b="${TREE}"

    stealth::sys::io::archive::create "${WORK}/a.tar" "${a}"
    stealth::sys::io::archive::create "${WORK}/b.tar" "${b}"

    run cmp "${WORK}/a.tar" "${WORK}/b.tar"
    assert_success
}

@test "stealth::sys::io::archive::create: the same directory twice -> the same bytes" {
    make_tree one
    local -r root="${TREE}"

    stealth::sys::io::archive::create "${WORK}/first.tar" "${root}"
    stealth::sys::io::archive::create "${WORK}/second.tar" "${root}"

    run cmp "${WORK}/first.tar" "${WORK}/second.tar"
    assert_success
}

@test "stealth::sys::io::archive::create: a file that differs -> the bytes differ" {
    make_tree a
    local -r a="${TREE}"
    make_tree b
    local -r b="${TREE}"
    printf 'setting = 2\n' > "${b}/etc/app.conf"

    stealth::sys::io::archive::create "${WORK}/a.tar" "${a}"
    stealth::sys::io::archive::create "${WORK}/b.tar" "${b}"

    run cmp "${WORK}/a.tar" "${WORK}/b.tar"
    assert_failure
}

@test "stealth::sys::io::archive::create: a directory -> everything in it is there" {
    make_tree one
    local -r root="${TREE}"
    local members

    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    stealth::sys::io::archive::list members "${WORK}/one.tar"

    assert_array_contains members './usr/bin/tool'
    assert_array_contains members './etc/app.conf'
}

@test "stealth::sys::io::archive::create: an --epoch -> is the time in the tar" {
    make_tree one
    local -r root="${TREE}"

    stealth::sys::io::archive::create "${WORK}/zero.tar" "${root}" --epoch 0
    stealth::sys::io::archive::create "${WORK}/later.tar" "${root}" --epoch 86400
    stealth::sys::io::archive::create "${WORK}/again.tar" "${root}" --epoch 86400

    run cmp "${WORK}/zero.tar" "${WORK}/later.tar"
    assert_failure
    run cmp "${WORK}/later.tar" "${WORK}/again.tar"
    assert_success
}

@test "stealth::sys::io::archive::create: SOURCE_DATE_EPOCH -> is the time when none is given" {
    make_tree one
    local -r root="${TREE}"

    stealth::sys::io::archive::create "${WORK}/asked.tar" "${root}" --epoch 86400
    export SOURCE_DATE_EPOCH=86400
    stealth::sys::io::archive::create "${WORK}/env.tar" "${root}"

    run cmp "${WORK}/asked.tar" "${WORK}/env.tar"
    assert_success
}

@test "stealth::sys::io::archive::create: an --epoch that is not a number -> exits 1" {
    make_tree one
    local -r root="${TREE}"

    run stealth::sys::io::archive::create "${WORK}/one.tar" "${root}" --epoch soon
    assert_refused '--epoch takes a whole number of seconds, not soon'
}

@test "stealth::sys::io::archive::create: an --exclude -> leaves that out" {
    make_tree one
    local -r root="${TREE}"
    mkdir -p "${root}/var/cache"
    printf 'junk\n' > "${root}/var/cache/leftover"
    local members

    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}" --exclude './var/cache'
    stealth::sys::io::archive::list members "${WORK}/one.tar"

    refute_array_contains members './var/cache/leftover'
    assert_array_contains members './etc/app.conf'
}

@test "stealth::sys::io::archive::create: an --exclude with no pattern -> exits 1" {
    make_tree one
    local -r root="${TREE}"

    run stealth::sys::io::archive::create "${WORK}/one.tar" "${root}" --exclude
    assert_refused '--exclude takes a pattern'
}

@test "stealth::sys::io::archive::create: no --xattrs -> tar is told to leave them out" {
    make_tree one
    local -r root="${TREE}"
    mock tar '*' 'return 0'

    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    assert_called_with tar '*--no-xattrs*'
}

@test "stealth::sys::io::archive::create: --xattrs -> tar is told to keep them" {
    make_tree one
    local -r root="${TREE}"
    mock tar '*' 'return 0'

    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}" --xattrs

    assert_called_with tar '*--xattrs*'
    refute_called_with tar '*--no-xattrs*'
}

@test "stealth::sys::io::archive::create: the directory above is not there -> it is made" {
    make_tree one
    local -r root="${TREE}"

    stealth::sys::io::archive::create "${WORK}/blobs/deep/one.tar" "${root}"

    assert_file_exists "${WORK}/blobs/deep/one.tar"
}

@test "stealth::sys::io::archive::create: an option it does not take -> exits 1" {
    make_tree one
    local -r root="${TREE}"

    run stealth::sys::io::archive::create "${WORK}/one.tar" "${root}" --gzip
    assert_refused 'create does not take --gzip'
}

@test "stealth::sys::io::archive::create: no archive to write -> exits 1" {
    run stealth::sys::io::archive::create '' "${WORK}"
    assert_refused 'an archive to write is required'
}

@test "stealth::sys::io::archive::create: no such directory -> exits 1" {
    run stealth::sys::io::archive::create "${WORK}/one.tar" "${WORK}/nowhere"
    assert_refused "no directory to archive at ${WORK}/nowhere"
}

@test "stealth::sys::io::archive::create: tar fails -> ends the run" {
    make_tree one
    local -r root="${TREE}"
    mock tar '*' 'return 2'

    run stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::extract
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::extract: an archive -> the files come back" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out"

    assert_file_exists "${WORK}/out/etc/app.conf"
    assert_file_contains "${WORK}/out/etc/app.conf" 'setting = 1'
}

@test "stealth::sys::io::archive::extract: an archive -> the modes come back" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out"

    assert_file_permission 0755 "${WORK}/out/usr/bin/tool"
}

@test "stealth::sys::io::archive::extract: the directory is not there -> it is made" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/deep/out"

    assert_dir_exists "${WORK}/deep/out"
}

@test "stealth::sys::io::archive::extract: --strip -> drops the leading components" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    # The members are ./etc/app.conf and ./usr/bin/tool, so two components
    # off the front leaves app.conf beside bin/tool.
    stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out" --strip 2

    assert_file_exists "${WORK}/out/app.conf"
    assert_file_exists "${WORK}/out/bin/tool"
}

@test "stealth::sys::io::archive::extract: --strip that is not a number -> exits 1" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    run stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out" --strip top
    assert_refused '--strip takes a whole number, not top'
}

@test "stealth::sys::io::archive::extract: --xattrs -> tar is told to keep them" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    mock tar '*' 'return 0'

    stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out" --xattrs

    assert_called_with tar '*--xattrs*'
}

@test "stealth::sys::io::archive::extract: an option it does not take -> exits 1" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    run stealth::sys::io::archive::extract "${WORK}/one.tar" "${WORK}/out" --overwrite
    assert_refused 'extract does not take --overwrite'
}

@test "stealth::sys::io::archive::extract: no such archive -> exits 1" {
    run stealth::sys::io::archive::extract "${WORK}/nowhere.tar" "${WORK}/out"
    assert_refused "no archive to unpack at ${WORK}/nowhere.tar"
}

@test "stealth::sys::io::archive::extract: no directory to unpack into -> exits 1" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    run stealth::sys::io::archive::extract "${WORK}/one.tar" ''
    assert_refused 'a directory to unpack into is required'
}

@test "stealth::sys::io::archive::extract: a member that climbs out -> is refused" {
    mkdir -p "${WORK}/evil"
    printf 'owned\n' > "${WORK}/evil/passwd"
    tar --create --file "${WORK}/evil.tar" --directory "${WORK}/evil" \
        --transform 's|^passwd|../../escaped|' passwd

    run stealth::sys::io::archive::extract "${WORK}/evil.tar" "${WORK}/out"

    assert_file_not_exists "${WORK}/escaped"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::list
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::list: an archive -> the names come back in order" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    local members

    stealth::sys::io::archive::list members "${WORK}/one.tar"

    assert_equal "${members[0]}" './'
    assert_array_contains members './usr/bin/tool'
}

@test "stealth::sys::io::archive::list: an archive that holds nothing -> an empty array" {
    tar --create --file "${WORK}/empty.tar" --files-from /dev/null
    local members

    stealth::sys::io::archive::list members "${WORK}/empty.tar"

    assert_array_empty members
}

@test "stealth::sys::io::archive::list: no output variable -> exits 1" {
    run stealth::sys::io::archive::list '' "${WORK}"
    assert_refused 'an output variable is required'
}

@test "stealth::sys::io::archive::list: no such archive -> exits 1" {
    run stealth::sys::io::archive::list members "${WORK}/nowhere.tar"
    assert_refused "no archive to read at ${WORK}/nowhere.tar"
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::is_whole
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::is_whole: an archive that reads through -> returns 0" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"

    run stealth::sys::io::archive::is_whole "${WORK}/one.tar"
    assert_success
}

@test "stealth::sys::io::archive::is_whole: a file that is not an archive -> returns 1" {
    printf 'not a tar at all\n' > "${WORK}/one.tar"

    run stealth::sys::io::archive::is_whole "${WORK}/one.tar"
    assert_failure 1
}

@test "stealth::sys::io::archive::is_whole: an archive cut in half -> returns 1" {
    make_tree one
    local -r root="${TREE}"
    # Large enough that the archive runs past its first record of 10240
    # bytes, which is as far as tar can tell that anything is missing.
    head -c 100000 /dev/urandom > "${root}/etc/big"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    truncate --size 40000 "${WORK}/one.tar"

    run stealth::sys::io::archive::is_whole "${WORK}/one.tar"
    assert_failure 1
}

@test "stealth::sys::io::archive::is_whole: a member with contents missing -> returns 1" {
    make_tree one
    local -r root="${TREE}"
    head -c 100000 /dev/urandom > "${root}/etc/big"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    # Listing an archive seeks past the contents of a member. is_whole
    # unpacks to nowhere instead, so it reads every byte.
    truncate --size 60000 "${WORK}/one.tar"

    run stealth::sys::io::archive::is_whole "${WORK}/one.tar"
    assert_failure 1
}

@test "stealth::sys::io::archive::is_whole: no such file -> returns 1" {
    run stealth::sys::io::archive::is_whole "${WORK}/nowhere.tar"
    assert_failure 1
}

@test "stealth::sys::io::archive::is_whole: nothing -> returns 1" {
    run stealth::sys::io::archive::is_whole
    assert_failure 1
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::compress
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::compress: a file -> zstd unless told otherwise" {
    printf 'body\n' > "${WORK}/plain"
    local how

    stealth::sys::io::archive::compress "${WORK}/plain" "${WORK}/packed"
    stealth::sys::io::archive::kind how "${WORK}/packed"

    assert_equal "${how}" 'zstd'
}

@test "stealth::sys::io::archive::compress: gzip -> the same bytes every time" {
    make_tree a 2020-01-01
    local -r a="${TREE}"
    make_tree b 2026-09-20
    local -r b="${TREE}"
    stealth::sys::io::archive::create "${WORK}/a.tar" "${a}"
    stealth::sys::io::archive::create "${WORK}/b.tar" "${b}"

    stealth::sys::io::archive::compress "${WORK}/a.tar" "${WORK}/a.tar.gz" gzip
    stealth::sys::io::archive::compress "${WORK}/b.tar" "${WORK}/b.tar.gz" gzip

    run cmp "${WORK}/a.tar.gz" "${WORK}/b.tar.gz"
    assert_success
}

@test "stealth::sys::io::archive::compress: bzip2 -> is recognised afterwards" {
    printf 'body\n' > "${WORK}/plain"
    local how

    stealth::sys::io::archive::compress "${WORK}/plain" "${WORK}/packed" bzip2
    stealth::sys::io::archive::kind how "${WORK}/packed"

    assert_equal "${how}" 'bzip2'
}

@test "stealth::sys::io::archive::compress: xz -> is recognised afterwards" {
    printf 'body\n' > "${WORK}/plain"
    local how

    stealth::sys::io::archive::compress "${WORK}/plain" "${WORK}/packed" xz
    stealth::sys::io::archive::kind how "${WORK}/packed"

    assert_equal "${how}" 'xz'
}

@test "stealth::sys::io::archive::compress: a kind it does not know -> exits 1" {
    printf 'body\n' > "${WORK}/plain"

    run stealth::sys::io::archive::compress "${WORK}/plain" "${WORK}/packed" lzma
    assert_refused 'nothing here compresses with lzma'
}

@test "stealth::sys::io::archive::compress: no such file -> exits 1" {
    run stealth::sys::io::archive::compress "${WORK}/nowhere" "${WORK}/packed"
    assert_refused "no file to compress at ${WORK}/nowhere"
}

@test "stealth::sys::io::archive::compress: nowhere to write it -> exits 1" {
    printf 'body\n' > "${WORK}/plain"

    run stealth::sys::io::archive::compress "${WORK}/plain" ''
    assert_refused 'somewhere to write it is required'
}

@test "stealth::sys::io::archive::compress: the tool fails -> the target is left alone" {
    printf 'body\n' > "${WORK}/plain"
    printf 'the old one\n' > "${WORK}/packed"
    mock zstd '*' 'return 1'

    run stealth::sys::io::archive::compress "${WORK}/plain" "${WORK}/packed"

    assert_failure 1
    assert_file_contains "${WORK}/packed" 'the old one'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::decompress
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::decompress: what compress wrote -> comes back the same" {
    make_tree one
    local -r root="${TREE}"
    stealth::sys::io::archive::create "${WORK}/one.tar" "${root}"
    stealth::sys::io::archive::compress "${WORK}/one.tar" "${WORK}/one.tar.zst"

    stealth::sys::io::archive::decompress "${WORK}/one.tar.zst" "${WORK}/back.tar"

    run cmp "${WORK}/one.tar" "${WORK}/back.tar"
    assert_success
}

@test "stealth::sys::io::archive::decompress: a gzip file -> comes back the same" {
    printf 'body of the file\n' > "${WORK}/plain"
    gzip -n -c < "${WORK}/plain" > "${WORK}/packed"

    stealth::sys::io::archive::decompress "${WORK}/packed" "${WORK}/back"

    run cmp "${WORK}/plain" "${WORK}/back"
    assert_success
}

@test "stealth::sys::io::archive::decompress: a file that is not compressed -> is copied" {
    printf 'body of the file\n' > "${WORK}/plain"

    stealth::sys::io::archive::decompress "${WORK}/plain" "${WORK}/back"

    run cmp "${WORK}/plain" "${WORK}/back"
    assert_success
}

@test "stealth::sys::io::archive::decompress: no such file -> exits 1" {
    run stealth::sys::io::archive::decompress "${WORK}/nowhere" "${WORK}/back"
    assert_refused "no file to decompress at ${WORK}/nowhere"
}

@test "stealth::sys::io::archive::decompress: nowhere to write it -> exits 1" {
    printf 'body\n' > "${WORK}/plain"

    run stealth::sys::io::archive::decompress "${WORK}/plain" ''
    assert_refused 'somewhere to write it is required'
}

@test "stealth::sys::io::archive::decompress: a file that is cut short -> the target is left alone" {
    printf 'body of the file\n' | zstd -q -c > "${WORK}/packed"
    truncate --size 8 "${WORK}/packed"
    printf 'the old one\n' > "${WORK}/back"

    run stealth::sys::io::archive::decompress "${WORK}/packed" "${WORK}/back"

    assert_failure 1
    assert_file_contains "${WORK}/back" 'the old one'
}

# ------------------------------------------------------------------------------
# stealth::sys::io::archive::_head
# ------------------------------------------------------------------------------

@test "stealth::sys::io::archive::_head: a file that cannot be read -> an empty string" {
    local start='left over'

    stealth::sys::io::archive::_head start "${WORK}/nowhere" 4

    assert_equal "${start}" ''
}

@test "stealth::sys::io::archive::_head: a file -> the bytes it begins with" {
    printf 'abcdefgh' > "${WORK}/plain"
    local start

    stealth::sys::io::archive::_head start "${WORK}/plain" 4

    assert_equal "${start}" 'abcd'
}

# ------------------------------------------------------------------------------
# sys/io/archive, the module itself
# ------------------------------------------------------------------------------

@test "sys/io/archive: sourced twice -> returns before it declares anything" {
    run load_lib sys/io/archive
    assert_success
}
