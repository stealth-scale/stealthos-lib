# stealthos-lib

The bash library and command of StealthOS. `stealth` loads modules and runs them through a
lifecycle on a Fedora-based system. The library under it gives a module what it needs, from
logging and assertions to disks, packages, users, services, networks and virtual machines,
as namespaced functions with a contract each.

## Layout

| Path | Contents |
| --- | --- |
| `src/bin/stealth` | The command: options, configuration from `/etc/stealth`, module loading, the lifecycle |
| `src/lib/util` | Logging, assertions, text, lists, math, retries, versions, the importer |
| `src/lib/core` | The engine, the loader, state and traps: the lifecycle |
| `src/lib/sys` | Commands, environment, data formats, files, networks, the runtime |
| `src/lib/api` | Disks, packages, users, services, networks, security, virtual machines: the operations a module composes |
| `tests` | One directory per layer under `tests/<suite>/`, and the harness under `tests/helpers` |

Every function is namespaced by its path, `stealth::sys::cmd::exists`, and a module states
what it needs through the importer. The files under `src/lib` are sourced, not executed.
`stealth` is the entry point. Each module arrives with its tests and its docblocks, and the
suites stay at full line coverage.

## Requirements

Bash 4.4 or later, coreutils, findutils, grep, sed and gawk. Linux is the platform. The
suites run on bash 4.4 to 5.3 and on Fedora.

## Install

```sh
make install                 # bin/ and lib/ under /opt/stealth
make install PREFIX=/usr/local/stealth
```

`bin/stealth` finds `lib/` next to its `bin/`. The system layout, `/usr/bin/stealth` with
`/usr/lib/stealth`, is the package's.

## Working here

```sh
make test                                   # the suites in the bats-test image: bash 5.2, bats 1.14.0
make test DISTRO=fedora                     # on the Fedora image, the platform stealth runs on
make test TARGET=tests/unit                 # one suite
make test BASH_VERSION=4.4 BATS_VERSION=1.7.0
make test-host                              # with the bash and bats of this machine
make coverage                               # the suites under kcov: a table per file, report in coverage/; fails under 100%
make lint                                   # shellcheck over the sources, the helper and the tests
make check                                  # what CI runs: lint, then test
```

`RUNTIME=docker` selects Docker. The default is Podman.

[CONTRIBUTING.md](CONTRIBUTING.md) has the steps for a new module and the conventions.

## License

[MIT](LICENSE). Copyright Stealth Scale B.V.
