# StealthOS library analysis

Date: 2026-09-19. Reviewer: Claude, at the request of Roy Klopper.

## Scope and method

- Read: all 82 files under `src/lib`, `src/bin/stealth`, `Makefile`, `nfpm.yaml`, `tests/helpers/load.bash`, the two Containerfiles and the e2e suites `01_lifecycle` and `02_bootstrap`.
- Ran: targeted probes of the library on bash 5.3.9 on Fedora 44, `shellcheck`, and a partial run of the unit and integration suites with the host `bats` 1.14.0.
- Defects marked **confirmed** were reproduced by running the code. Defects under "Found by reading" were not run.

## What it is

`stealthos-lib` is a Bash framework for provisioning and building Fedora-family and bootc systems. It is 82 files, 26,852 lines and 750 functions, 141 of them private. Functions are namespaced `stealth::<layer>::<module>::<name>`. The one exception found is a nested helper `_ping_check` in `sys/net/conn.sh:46`. The `stealth` CLI loads user modules from a search path and runs them through a lifecycle. The repository has no commits: `main` is empty and every file is untracked.

## Layers

| Layer | Modules | Role |
|---|---|---|
| `util` (9) | import, log, assert, text, list, math, retry, semver, ui | Pure bash. No system tools except `awk` and `numfmt` in math and `tput` in ui. |
| `core` (4) | state, loader, engine, trap | Lifecycle: module registry, config, I/O redirection, traps. |
| `sys` (26) | cmd, check, env, crypto, system, plus the groups `data/{ini,json,kv,toml,yaml}`, `io/{fs,tmp,archive,block,conf,content}`, `net/{conn,fetch,git,github,gitlab,iface}` and `runtime/{arch,hash,host,lock,proc,user}` | Wrappers over binaries. Atomic file edits. Config-format backends. |
| `api` (41) | `disk/{part,fmt,luks}`, `os/{user,service,kernel,kmod,boot,bootc,locale,time}`, `pkg/{manager,dnf,ostree,rpm,flatpak,appimage}`, `net/{conn,dns,fw}`, `sec/{auth,policy,audit,secret,crypto}`, `virt/{container,qemu}`, `make/{core,pkg,cc,go,rust,zig,rpm,oci}`, `lfs/{env,host,sources,pkg,toolchain}` | The product surface. |

Dependencies point downward: `api` depends on `sys`, and `sys` depends on `util`. `sys/cmd` depends on `util` only, by design (`sys/cmd.sh:5`), so `sys/io` can depend on it without a cycle.

## Run sequence

1. `bin/stealth` picks `/usr/lib/stealth` if it exists, else `../lib` relative to itself, and sources `util/import.sh`.
2. It parses options and exports `STEALTH_LOG_LEVEL`, `STEALTH_LOG_FILE`, `STEALTH_STAGE`, `STEALTH_DRY_RUN`, `STEALTH_CONF_FILE` and `STEALTH_CONF_DIR`.
3. Importing `core/engine` records every `STEALTH_*` variable already set in `_STEALTH_USER_OVERRIDES` (`core/engine.sh:15`). Config files cannot override those later.
4. `-d` paths go into the module search path and the import path. `-m` and `-M` load modules.
5. `engine::run` loads `stealth.conf` and `conf.d/*.conf` as `KEY=VAL` exports, bootstraps, detects the stage, runs the start hooks in load order, runs the payload, then runs the end hooks in reverse order.
6. Bootstrap saves copies of FDs 1 and 2, opens the log file, initialises the logger and the traps, then applies the "Grand Silence": stdout goes to the log file or `/dev/null`, and stderr goes to a temp file that is printed only on a non-zero exit (`core/engine.sh:268`). After that it calls `::init` on every imported library and on every module.

The module contract, from `core/loader.sh:172` and `core/engine.sh:74`:

- A module is a directory `<search-path>/<logical/path>/` with an optional `common.sh` and an optional `<stage>.sh`. The stage is `STEALTH_STAGE`, else `root` or `user` by EUID.
- Hooks are `mod::<path>::init`, `mod::<path>::<stage>::start` and `mod::<path>::<stage>::end`. In the path, `/` becomes `::` and `-` becomes `_`.
- The payload is the first positional argument. It must be a function or executable name. It runs under `sys::cmd::run`, so its stdout is captured and shown only on failure or at `-vv`.

## Conventions the code relies on

- Every file starts with `set -Eeuo pipefail` and a guard variable `_STEALTH_LIB_<PATH>`, then imports its dependencies. The importer honours the guard variable, so a concatenated bundle loads.
- Output goes through namerefs (`local -n`) in the first argument. Locals are given a function-specific prefix such as `_luks_fmt_`. Bash resolves a nameref by name at each use, so the prefix is the only thing that keeps a callee's local from capturing the caller's variable.
- Errors abort. `util/assert` calls `log::error`, and `log::error` calls `exit` (`util/log.sh:569`). `sys::cmd::run` calls `log::error` on any non-zero exit (`sys/cmd.sh:243`). 70 sites write `return 1` directly after `log::error`. None of them are reachable.
- Binaries run only through `sys::cmd::{run,try,capture,silent,stream}`. Output is buffered in a temp file made without forking and logged on failure. `STEALTH_DRY_RUN=1` turns every call into a log line.
- Every config edit goes through `sys::io::fs::atomic` (`sys/io/fs.sh:247`). It creates a temp file beside the target, lets a callback edit it, applies chmod and chown, compares it with `cmp` to skip a no-op, and renames it with `mv -Z`. Temp files are registered and removed at exit.
- `sys/io/conf` picks a backend by file extension: `.json` uses jq, `.yaml` uses yq, `.toml` and `.ini` use Python, and anything else is `KEY=VALUE`.
- `api/make` keeps build state on disk. A context is a `mktemp -d` directory with `.state/{env,opt,hooks}`, `stage/` and `.artifacts/registry`. Options drive the orchestrator. Env is re-exported inside a subshell around each builder (`api/make/core.sh:814`). Hooks are function names stored per event. The registry is append-only `TYPE|PATH|TS|SHA256|META_B64`.

## What it is for

- Provisioning a Fedora or RHEL host, or a bootc image at container-build time:
  - packages through dnf5, dnf or microdnf, rpm-ostree layering, Flatpak with a build-time queue, and AppImage
  - users, sudo rules validated by `visudo`, SSH keys, PAM limits and password quality
  - systemd units, drop-ins, presets and a unit builder
  - sysctl, module load and blacklist, and dracut
  - GRUB and bootc kernel arguments
  - locale, keymap and timezone
  - chrony with NTS, NetworkManager keyfiles, systemd-resolved with DoT and DNSSEC, and firewalld online and offline
  - SELinux, auditd and polkit
  - secrets on disk or in the kernel keyring
  - MOK enrolment, Secure Boot signing, kernel module signing and akmods
- Disk provisioning: sgdisk partitions, mkfs, fstab by UUID, LUKS2 with argon2id and TPM2 or FIDO2 enrolment, header backup.
- Building software: fetch from git, GitHub, GitLab or a tarball with a cache and checksum, patch, build with go, cargo, zig, cmake, meson or autotools with cross triplets and ccache, test, then package as an RPM from a generated spec or as an OCI image, with multi-arch manifests.
- Running containers and QEMU VMs and persisting them as systemd services.
- An LFS toolchain bootstrap, which is a scaffold that does not run.

## Confirmed defects

Ranked by how much stops working.

1. **The logger aborts the process on any enabled log line from a `::`-named function.** `_extract_module` declares `local _mod` (`util/log.sh:166`), which shadows the caller's `_mod`, the nameref target passed at `util/log.sh:419`. The caller then reads an unbound variable at `util/log.sh:443`. `bash src/bin/stealth -- true` exits 1 at the default level. A module written to the loader contract ran `init` and then stopped before `start`. Any error message from library code is replaced by `_mod: unbound variable`. With `-q` the same module ran `INIT START END`. One rename fixes it.
2. **`fs::line` argument order.** The signature is `(target, mode, owner, lines...)` (`sys/io/fs.sh:344`). 9 of 26 callers pass `(mode, owner, target, lines...)`: `api/os/kernel.sh:220`, `:250`, `:287` and `:344`, `api/sec/auth.sh:86`, `:161` and `:375`, `api/sec/policy.sh:214`, and `api/os/service.sh:465`. An empty first argument trips the assertion. `"0600"` first creates a temp file in the current directory and then aborts in `chown`. Broken: `module_enable`, `module_blacklist`, `module_options`, `dracut_module`, `ssh_add_key`, `ssh_import_id`, `ssh_config`, `pam_limit`, `policy::audit_rule`, and `service::builder_set` for any section other than `[Unit]`. The cause is that `touch` and `mkdirs` take mode first while `line` takes target first. `tests/integration/api/sec/auth.bats:64` and `policy.bats:99` mock `fs::line` and assert the wrong order, so the tests pin the bug.
3. **Referenced functions that do not exist** (checked with `declare -F` after import):
   - `stealth::util::assert::file_exists`, called at `api/os/kmod.sh:175`, `api/os/user.sh:178`, `api/sec/crypto.sh:182`, `:210` and `:312`.
   - `stealth::api::make::pkg::pipeline`, called at `api/lfs/toolchain.sh:150`.
   - `stealth::api::make::pkg::_package_none`, selected by `toolchain.sh:147`.
   - `stealth::api::make::_build_rpm`, because `api/make/rpm.sh:800` passes `"_build_rpm"` and `core.sh:849` prefixes `stealth::api::make::`. The other builders pass `"go::_build_go"`.
   RPM packaging, LFS bootstrap, kmod signing, `set_shell` and Secure Boot signing all abort with command-not-found.
4. **`sys::io::conf::set` has no delimiter parameter** (`sys/io/conf.sh:150`). `api/sec/audit.sh:108` passes `" = "`, `api/sec/auth.sh:402` passes `"="`, and `:424` passes `" "`. `auditd.conf` received `log_format=ENRICHED` beside `log_format = RAW`. `login.defs` received `PASS_MAX_DAYS=60` beside `PASS_MAX_DAYS 99999`. The auditd parser is believed to require `key = value` with spaces. That was not verified.
5. **`kv::set` strips the file's final newline when it replaces an existing key** (`sys/data/kv.sh:42`). The next new key is then appended to the last line: `B=2C=3`. Reproduced with `A=9` then `C=3`. All writers through `sys/io/conf` on KV files are exposed: `sysctl.d`, `locale.conf` and `vconsole.conf` among them.
6. **`dns::set_static` writes a literal `\n`** (`api/net/dns.sh:140`, `:144`). `resolv.conf` becomes one line.
7. **`bootc::kargs` writes invalid TOML.** `api/os/bootc.sh:186` passes the array as a string. Without `tomli_w` the fallback writer at `sys/data/toml.sh:64` does not escape quotes. Output: `kargs = "["quiet", "splash"]"`.
8. **`cmd::run` exits, so nothing can wrap it.** `retry::run 2 0 cmd::run <failing>` made one attempt and exited. `api/make/pkg.sh:203`, `:289` and `sys/net/fetch.sh:182` depend on that retry. `cmd::timeout` exits 124 instead of returning it (`sys/cmd.sh:475`). Its docblock says it returns. `sys/net/conn.sh:124` so aborts when a port is closed and `nc` is absent.
9. **`cmd::silent | grep` never matches** because `silent` sends stdout to `/dev/null`. `part::exists` (`api/disk/part.sh:200`) is always false. `fw::new_zone` (`api/net/fw.sh:108`) always tries to create the zone.
10. **`shift N` with fewer arguments aborts under `set -e`.** `fmt::format` without a label (`api/disk/fmt.sh:51`), `qemu::run` and `qemu::systemd` with default memory and CPUs (`api/virt/qemu.sh:271`, `:309`), `lfs::env::enter` with the default command (`api/lfs/env.sh:137`), `bootc::install_to_disk` with one argument (`api/os/bootc.sh:209`).
11. **`zig::_find_binary` reads `$2` for both context and name** (`api/make/zig.sh:40`) and is called with two arguments (`:159`). It never finds the binary.
12. **`make/oci::build` double-encodes secrets.** `api/make/oci.sh:192` formats `id=X,src=Y`, then `api/virt/container.sh:244` formats it again. The integration test produced `--secret id=id,src=npmrc,src=/home/user/.npmrc`.
13. **`hash::string` hashes the input plus a newline** (`sys/runtime/hash.sh:162`). `sha256("abc")` did not match.
14. **`text::trim_all` expands globs** (`util/text.sh:65`). `"a * b"` became a file listing.
15. **The e2e suite encodes an earlier contract.** It writes `entrypoint.sh` (0 references in `src/lib`), hooks named `mod::x::start` without a stage, and `STEALTH_SYS_CMD_DRY_RUN` (0 references in `src`). An e2e-style module ran nothing under `-q`.
16. **`make lint` fails.** shellcheck returned 1 with 112 findings. 81 are SC2148 because library files have no shebang and the Makefile passes no `-s bash`.
17. **Packaging references files that do not exist.** `nfpm.yaml` lists `src/etc/stealth.conf`, `src/etc/conf.d/*` and `LICENSE`. `src/bin/stealth` is mode 644 in the checkout.

The partial test runs had failures in `lfs/host`, `lfs/pkg` and `make/oci` in the integration suite and a non-zero exit from the unit suite. Totals were not collected.

## Found by reading

- `toml::_cb_modify` returns 0 on failure (`sys/data/toml.sh:229`). A failed TOML edit is committed as if it succeeded.
- `secret::keyring_add` captures the stdout of `cmd::run`, which is always empty (`api/sec/secret.sh:217`). `keyctl timeout` then gets an empty key id.
- `hash::_get_cmd` stores `"shasum -a 256"` as one string and callers expand it as an array (`sys/runtime/hash.sh:53`, `:118`). The fallbacks only matter where `sha256sum` is absent.
- `rpm::_build_rpm` runs hooks `pre_rpm_build` and `post_rpm_build` (`api/make/rpm.sh:264`, `:285`) that `register_hook` refuses (`api/make/core.sh:431`).
- `pkg::_stage_package` defaults the format to empty, not `rpm`, because `read_opt` always returns 0 (`api/make/pkg.sh:483`). A pipeline that never calls `pkg::format` aborts at packaging.
- `state::detect_stage` accepts any `[a-z0-9]+` (`core/state.sh:61`), but the hooks assert `build|setup|user|root` (`core/engine.sh:62`). `STEALTH_STAGE=production` aborts at the first phase.
- `engine::run` never runs the end hooks when the payload fails, because the failure path is `exit`.
- `_fast_mktemp` (`sys/cmd.sh:44`) builds predictable names without `O_EXCL`. As root in a shared `/tmp`, another user could pre-create a symlink at that name. Low likelihood.
- `lfs/sources::cache_pkg` creates a symlink where the comment says hardlink and sets `PKG_SOURCE_URL=file://…`, which nothing parses (`api/lfs/sources.sh:116`).

## Design risks

- **Abort-only errors.** The primitives exit, but their callers are written as if they return: `try`, `retry`, `if ! …`, and 70 dead `return 1` lines. Decide once whether `log::error` returns or exits. Everything else follows from that.
- **Namerefs resolve at each use.** The prefix discipline is the only guard, and one unprefixed local took the logger down. A grep for `local [a-z_]*=` without a module prefix would catch the next one.
- **Positional conventions differ.** `touch` and `mkdirs` take mode first, `line` takes target first, `write` takes content second. Callers guessed, and the tests agreed with the guess.
- **Mocks replace contracts.** The test loader mocks `stealth::util::import` for every test, so no test exercises the real dependency graph. `lfs/pkg` fails today because `assert::is_dir` was never loaded. kcov reports lines executed while their dependencies were `true`.
- **Distro coupling.** Paths and tools are Fedora and RHEL: dnf, rpm-ostree, `grub2-*`, `/boot/efi/EFI/fedora`, chrony, firewalld, SELinux. `nfpm.yaml` also declares deb, apk and Arch packages, on which `api/*` would not run.

## What works today

- The `util` and `sys` layers do what they say, with the exceptions listed.
- The core lifecycle works under `-q`: search path, module loading, `init`, forward `start`, reverse `end`, config precedence, log file, temp cleanup.
- The `api` layer is not usable unpatched. Items 1 to 3 are small fixes. Item 1 is one rename. Item 2 is nine call sites. Item 3 is four names. After those, most of the remaining items are one-line changes.
