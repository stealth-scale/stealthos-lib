# Contributing

## Getting set up

You need GNU make, [ShellCheck](https://www.shellcheck.net) and Podman or Docker.
`make test` pulls `ghcr.io/stealth-scale/bats-test`, the image of the
[bats-test](https://github.com/stealth-scale/bats-test) repository, at the bash and bats-core
versions it is given, or the Fedora image with `DISTRO=fedora`. For `make test-host`,
install Bash 4.4 or later and [bats-core](https://github.com/bats-core/bats-core) 1.7.0 or
later.

```sh
git clone --recurse-submodules git@github.com:stealth-scale/stealthos-lib.git
cd stealthos-lib
make check
```

bats-expect, bats-mock and bats-matrix are submodules under `tests/helpers`. After a pull,
`git submodule update --init` brings them to the recorded commits.

## Before you open a pull request

```sh
make lint       # shellcheck over the sources, the helper and the tests
make docs       # every function carries a full docblock
make test       # the suites in the bats-test image; DISTRO, BASH_VERSION and BATS_VERSION pick the cell
make test-host  # the suites with the bash and bats of this machine
make coverage   # the suites under kcov: a table per file, report in coverage/; every line must be covered
make check      # what CI runs: lint, then test
```

`RUNTIME=docker` selects Docker. The default is Podman. `TARGET` selects a suite or a file.

CI runs `make lint`, `make docs`, `make test` for bash 4.4, 5.1, 5.2 and 5.3 against bats-core 1.7.0 and
1.14.0, `make test` on the Fedora image, and `make coverage` on the Fedora image at the
100% floor.

## Adding a module

One module per pull request, with its tests.

1. Write it as `src/lib/<layer>/<module>.sh`: the module header, the sourcing guard, and
   functions named `stealth::<layer>::<module>::<name>`. Internal functions carry a
   leading underscore. `tests/fixtures/lib/probe.sh` shows the shape.
2. State what it needs through the importer, and check for the tools a function needs
   before use. Take input as arguments and pass it to commands as arguments.
3. Write the docblock every function has, internal functions too: a summary, then
   `Usage:` with one line a caller can copy, `Arguments:` with every parameter or `None`,
   and `Returns:` with every status and what ends the process. Add `Globals:` when the
   body reads or writes a variable of the library, and `Outputs:` when it writes to a
   descriptor of its own. `make docs` checks all of this and CI runs it.
4. Test it in `tests/<layer>/<module>.bats`. The tests mirror `src/lib`, so
   `src/lib/sys/io/fs.sh` is tested by `tests/sys/io/fs.bats`. The file starts with the
   harness:

   ```bash
   bats_load_library stealth
   setup() { common_setup; load_lib util/log; }
   teardown() { common_teardown; }
   ```

   `load_lib` sources a module by its path, `load_mock` a shared mock from `tests/mocks`,
   and bats-expect, bats-mock and bats-matrix are loaded. Mock the commands a module calls
   rather than run them. The image has no network and no capabilities.
5. Write one case per test, named `<subject>: <case> -> <expectation>`. The subject is the
   full function name, so a reader knows what failed without opening the file:

   ```bash
   @test "stealth::sys::io::fs::atomic: the callback fails -> leaves the target alone" {
   @test "stealth::sys::io::fs::_temp_beside: a path in /etc -> returns a sibling" {
   ```

   For a test of the file itself rather than one of its functions, such as the sourcing
   guard, the subject is the module path: `@test "sys/io/fs: sourced twice -> ..."`.
   Group the tests by subject under a banner comment, in the order the functions appear
   in the module.
6. `make coverage` must stay at 100%. A line that cannot run under the Linux coverage run
   carries `# LCOV_EXCL_LINE` with the reason.
7. Add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

## Releasing

A release is a tag on `main`.

1. Move the `Unreleased` entries in `CHANGELOG.md` under a new `## [X.Y.Z] - YYYY-MM-DD`
   heading and add the compare link at the foot of the file.
2. Commit as `chore: release vX.Y.Z`.
3. `git tag -s vX.Y.Z -m vX.Y.Z && git push --follow-tags`.

The release workflow runs the ci workflow on the tag and publishes a GitHub release with
the changelog entry as its notes. A tag without a matching changelog entry fails the
workflow.

## Conventions

Commit messages take the form `type(scope): summary`, as the standards for every stealth
repository set out at https://docs.stealthscale.io. The scope is the layer or the module a
change stays in: `feat(util/log): ...`, `fix(sys/cmd): ...`.

## Review

A pull request is reviewed by a maintainer of the stealth-scale organisation.
