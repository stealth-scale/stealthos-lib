# RFC: stealthos-lib, the library behind the engine

**Status:** Draft
**Date:** 2026-09-19
**Scope:** the library. The product, StealthOS, is a list of modules in its own repository. The engine under `.scratch/src/lib/core` runs that list. This document keeps the engine and every module group of the library, and adds what a container-native, signed, CI-driven build needs.

## 1. Summary

One invocation builds the whole system:

```sh
stealth -s build -d /srv/stealthos/modules -M /srv/stealthos/modules.list
```

The engine loads the modules in list order and runs every `build::start` hook forward and every `build::end` hook in reverse. The list is the build order. Each module builds one thing inside a container and the result is an OCI image: a toolchain image, a package image, a kernel image, a UKI image, a bootc image, a media image. A package image is one layer, and a layer is a tarball that the library writes itself. Later modules compose the images of earlier modules. Verification, signing, receipts and the boot test are modules in the same list. The same list runs on a laptop with a coloured status line per module and in a CI job on a private runner with plain log groups.

The engine is unchanged. The library keeps its four layers and every module group it had, because the `root` and `user` stages configure a live node after an image is deployed, and the package, disk, security and network groups are what those stages call. The library adds one group for containers and layers, one for image composition, one for signing and receipts, and one for CI. The tools behind the additions were checked on this host on 2026-09-19: podman 5.8.4, buildah 1.43.2, skopeo 1.22.2, crane 0.21.3, cosign 3.0.5, bootc 1.16.10, rpm-ostree 2026.2 and zig 0.16.0.

## 2. The engine as it is

These facts come from `.scratch/src/lib/core/{engine,loader,state,trap}.sh`, read in full on 2026-09-19.

- A module is a directory on a search path. `loader::module` imports `common.sh` when it exists and `<stage>.sh` when it exists, then registers the module in load order (`loader.sh` lines 154 to 200).
- The stage is `STEALTH_STAGE`, else `root` or `user` by EUID (`state.sh` lines 60 to 66). The engine accepts `build`, `setup`, `user` and `root` (`engine.sh` line 67).
- A logical path becomes a namespace under the prefix `mod`, with `/` as `::` and `-` as `_` (`loader.sh` lines 50 to 55). `pkg/zlib` gives `mod::pkg::zlib`.
- The hooks are `mod::<path>::init`, `mod::<path>::<stage>::start` and `mod::<path>::<stage>::end`. `init` runs at bootstrap for every imported library and every module. `start` runs forward over the module order and `end` runs in reverse (`engine.sh` lines 96 to 137 and 408 to 441).
- `engine::run` loads `stealth.conf` and the `conf.d` fragments as `KEY=VALUE` exports. A variable that is already in the environment keeps its value (`engine.sh` lines 15 to 20 and 190 to 226). The engine then bootstraps, detects the stage, runs the start hooks and an optional payload through `sys::cmd::run`, and runs the end hooks (`engine.sh` lines 457 to 496).
- Bootstrap saves the original stdout and stderr, opens the log file, initialises the logger and the traps, syncs `dry_run`, `log_level`, `conf_file` and `stage` into the state registry, and redirects stdout to the log file and stderr to a flight recorder that is printed only on failure (`engine.sh` lines 239 to 326).
- `state::get` reads the registry first and then `STEALTH_<KEY>` from the environment (`state.sh` lines 116 to 144).
- The trap module keeps a LIFO stack of cleanup handlers, prints a stack trace on `ERR`, and dumps the flight recorder on a non-zero exit (`trap.sh`).

The defects inside the engine are small and known.

| Defect | Where | Fix |
| --- | --- | --- |
| The logger aborts on any enabled line from a `::`-named function | `util/log.sh` line 166, defect 1 in `library-analysis.md` | Rename one local |
| The stage set differs between the engine and the state module | `engine.sh` line 67 accepts four names, `state.sh` line 68 accepts any `[a-z0-9]+` | One table, read by both |
| The binary prefers `/usr/lib/stealth` over its own checkout | `.scratch/src/bin/stealth` lines 17 to 23 | Resolve the library relative to the binary |
| The fragment directory defaults differ | `bin/stealth` line 48 says `/etc/stealth/conf.d`, `engine.sh` line 38 says `/etc/stealth/stealth.conf.d` | One default |
| `trap::defer` evaluates a string with `eval` when the entry is not a function name | `trap.sh` line 152 | Accept a function name with arguments, which is what every caller passes |

## 3. The module groups and the stages that call them

The first draft of this document dropped most of the api layer. That was wrong, and the reason is the stage model. A module of the product has hooks for more than one stage. `pkg/zlib` has a `build.sh`. `profiles/workstation` has a `root.sh` that runs on the node after the image is deployed. It also has a `user.sh` that runs in the session. The same library serves all three stages. Every group in the table has a stage that calls it.

| Layer | Group | Called from | Consequence of removing it |
| --- | --- | --- | --- |
| `util` | `log`, `assert`, `text`, `list`, `math`, `retry`, `semver`, `import` | Everywhere | None of the layers work |
| `util` | `ui` | Every run on a terminal | Runs show log lines only. A person watching a four-hour build sees no status per module and no summary |
| `core` | `engine`, `loader`, `state`, `trap` | The binary | The product has no order and no lifecycle |
| `sys` | `cmd`, `check`, `env`, `system` | Everywhere | Nothing runs a command |
| `sys` | `data/{ini,json,kv,toml,yaml}`, `io/{conf,content,fs,tmp,archive,block}` | The `root` and `user` stages, and image assembly | No module can edit a configuration file on a node, render a template, unpack a source or format a disk |
| `sys` | `net/{conn,fetch,git,github,gitlab,iface}` | Ingestion on the low side and the `root` stage | Sources cannot be fetched and a node cannot be told its interfaces |
| `sys` | `runtime/{arch,hash,host,lock,proc,user}` | Everywhere | No target triples, no digests, no locks, no facts about the node a `root` hook is configuring |
| `api` | `disk/{part,fmt,luks}` | The installer and the `root` stage | No partitioning, no LUKS with TPM2 or FIDO2 enrolment, which spec 4.3 requires |
| `api` | `os/{user,service,locale,time,kernel,kmod,boot,bootc}` | The `root` stage and image assembly | No users, units, presets, sysctl, kargs, dracut or `bootc switch` on a node |
| `api` | `pkg/{manager,dnf,rpm,ostree,flatpak,appimage}` | Package builds inside a toolchain container and the `root` and `user` stages | No RPM as the intermediate representation, no packages inside a build container, no Flatpak on Flavor W |
| `api` | `net/{conn,dns,fw}` | The `root` stage | No default-deny firewall, no DoT resolver, no NTS chrony on a node |
| `api` | `sec/{auth,policy,audit,secret,crypto}` | The `root` stage and signing | No PAM, polkit, auditd, SELinux or secret handling on a node, and no signature verification |
| `api` | `virt/{container,qemu}` | Every build step, the boot test, and Quadlet units on a node | No sandbox, no boot test, no container services |
| `api` | `make/{core,pkg,cc,go,rust,zig,rpm,oci}` | Package builds | No cross builds. `zig cc -target x86_64-linux-musl -static` built and ran a static binary on this host today, which is the shortest path to a static musl toolchain before the bootstrapped GCC exists |
| `api` | `lfs/{env,host,sources,pkg,toolchain}` | The toolchain modules | The scaffold that becomes the bootstrap driver |

The groups keep their names and their functions. The confirmed defects in `library-analysis.md` are fixed in place. Section 4 changes the `make` context into the store. It gives the container wrapper the flag set and a second engine. It gives `crypto` the signing backends.

One packaging change follows from the stage model. The Validation Gate scans build scripts for network calls (arch 2.2 §3.2). The library keeps its network modules for the low side and the `root` stage, and the package for a build node omits them. `nfpm.yaml` produces `stealth` with every module and `stealth-build` without `sys/net` and `api/net`. The exclusion list is the only difference between the two packages.

## 4. The additions

### 4.1 Podman and docker

`api/virt/container` already detects podman before docker (`container.sh` lines 42 to 62). The rewrite keeps that order and adds the flag set below. Every flag exists in podman 5.8.4 on this host and in the docker run reference read today, except where the table says so.

| Concern | Flags | Note |
| --- | --- | --- |
| No network | `--network none` | Both engines |
| No capabilities | `--cap-drop ALL` | Both engines |
| No SELinux relabel of the mounts | `--security-opt label=disable` | Both engines |
| Read-only root, writable work dir | `--read-only --tmpfs /build:rw,exec` | Both engines |
| Read-only inputs | `--volume VAULT:/vault:ro --volume LIB:/stealth:ro` | Both engines |
| Identity | `--user UID:GID` | Both engines. `--userns=keep-id` is podman only. Rootless docker maps the container root to the calling user by itself |
| Limits | `--pids-limit N --memory M --cpus C` | Both engines |
| No pulls | `--pull never` | Both engines |
| Ephemeral | `--rm` | Both engines |

`api::virt::container::run` takes the image, the command and the mounts, and applies the set. A module never writes an engine flag. The build image for a step is a toolchain image from the store, so the tools inside the sandbox are pinned by that image's digest.

### 4.2 Layers from tarballs

A layer is a tar file. The library writes it with one function, `api::oci::layer::pack DIR OUT`, and the tar is deterministic:

```sh
tar --sort=name --mtime=@"$EPOCH" --owner=0 --group=0 --numeric-owner \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -cf "$OUT" -C "$DIR" .
```

The SHA-256 of that tar is the layer's diff ID. `tar` writes it on the host or in the toolchain container, without a container engine. A package image is the layer plus a config and a manifest, and each of the following tools writes those from the tar.

- `crane append --oci-empty-base -f layer.tar -t NAME -o image.tar` writes the image as a tarball. Run twice on this host, one second apart, it produced byte-identical output. The config it writes has `created` at the zero time and no history entry with a date. `crane append -b BASE` stacks a layer on an existing image, `crane mutate` sets labels, annotations, entrypoint and user, `crane flatten` squashes, and `crane export - fs.tar < image.tar` extracts a filesystem tar without a runtime.
- `regctl image mod --layer-add tar=layer.tar --reproducible --time T --label K=V --annotation K=V --to-oci` does the same with explicit control over every timestamp, and regclient supports an OCI layout directory as a local repository. Recalled for the layout scheme, verified for the flags.
- `umoci raw add-layer --image DIR:TAG layer.tar --history-created DATE` appends an uncompressed tar to an image in an OCI layout directory and works without root through `--rootless`.

The library uses crane as the default because it is installed, deterministic, daemon-free, and writes the tarball format that skopeo and podman load. regctl is the alternative when a timestamp inside a layer has to be rewritten after the fact.

### 4.3 The store

The store of a run is an OCI layout directory, `$STEALTH_STORE`. It replaces the `.artifacts/registry` file of the old `make` context, which recorded a timestamp per entry. Images are named `<kind>/<name>:<key>` where the kinds are `toolchain`, `pkg`, `kernel`, `uki`, `image`, `media` and `rpm`, and the key is the digest of the inputs. The functions are `has`, `digest`, `tag`, `put`, `get`, `export` and `import`.

- `crane pull --format oci NAME DIR` and `crane push DIR NAME` move images between the layout and a registry.
- `skopeo copy` moves images between `oci:`, `oci-archive:`, `dir:`, `docker-archive:`, `containers-storage:` and `docker:`, with `--preserve-digests`. The `oci-archive` form is what crosses the diode.
- An SBOM, a receipt or an RPM is stored next to its image as an OCI artifact with a subject, through `regctl artifact put --subject NAME --artifact-type TYPE --file PATH`, or through `podman artifact add --type TYPE NAME PATH` when podman is the engine.

A module checks the store for its output image before it builds. When the image exists and the cache is on, the hook returns at once. A consensus run turns the cache off.

### 4.4 A package build

`api::make::pkg::build NAME --version V --from toolchain/NAME --dep pkg/DEP... --source FILE --system autotools|cmake|meson|make|spec|zig --configure '...' --build '...' --install '...'` does the following, and a module calls it once.

1. Resolves each source through the lock file and the vault and checks the digests and the gate signatures.
2. Extracts every dependency image into a build root with `crane export`.
3. Runs the steps inside the toolchain image with `api::virt::container::run`: unpack, patch, configure, build, check, install into `/build/out`. The build system supplies the defaults and the module overrides a step with a string. The steps see `SOURCE_DATE_EPOCH`, `LC_ALL=C`, `TZ=UTC` and the jobs count and nothing else from the host.
4. Runs `rpmbuild` in the same container when the toolchain image has it, with the fixed build host and build time macros, and keeps the RPM and the debuginfo RPM as artifacts.
5. Packs `/build/out` into a layer, appends it to an empty base, and puts the result in the store under `pkg/NAME:KEY`.
6. Runs the elf checks over the layer in the toolchain image. The binaries must be static, without an interpreter or a `DT_NEEDED` entry. The recorded flags from `-frecord-gcc-switches` must match the flag matrix, the CET markers must be present, and `-march` must be the baseline of the profile.
7. Writes the SBOM through a scanner image and attaches it.

Before `rpm` exists, in the first toolchain modules, step 4 is skipped. `zig` is one of the build systems because `zig cc -target x86_64-linux-musl -static` produces a static musl binary from the host's own zig, which gives a working static toolchain image on day one, before the bootstrapped GCC exists.

### 4.5 Composition

`api::make::oci::compose` assembles a rootfs from package images and turns it into a bootc image in five steps. `podman build` is not one of the tools it calls.

1. Extracts the package layers of the profile into a rootfs directory with `crane export`, or installs the RPM artifacts into it with `rpm --root` inside the toolchain container when the profile selects the RPM path. The RPM path gives the ghost-file check between `find` and `rpm -qal --root`, the IMA signatures, and an SBOM of the assembled root while the rpmdb exists. The rpmdb and the rpm binaries are removed afterwards, as ADR 0026 requires.
2. Applies the bootc layout checks that bootc.dev states: the kernel at `/usr/lib/modules/$kver/vmlinuz` with `initramfs.img` beside it, an empty `/boot`, `/sysroot`, `/usr/lib/ostree/prepare-root.conf` with `[composefs] enabled = true`, the `/ostree -> /sysroot/ostree` link that `bootc container lint` wants, kargs under `/usr/lib/bootc/kargs.d`, and the label `containers.bootc=1`.
3. Runs `bootc container lint --fatal-warnings --rootfs DIR` inside the toolchain container.
4. Writes the image with `rpm-ostree compose build-chunked-oci --rootfs DIR --bootc --output oci:$STEALTH_STORE:image/NAME --max-layers N --previous-build REF`. This is the tool the bootc ecosystem uses to split a rootfs into content-addressed layers by package. `--previous-build` keeps the layer plan of the last release so that an update changes few layers. `--sign-commit ed25519=KEY` or `spki=KEY` signs the embedded ostree commit, which is what the initramfs verifies when `prepare-root.conf` says `enabled = signed`.
5. For a sealed image, runs `bootc container split-kernel-and-rootfs --rootfs DIR --output OUT` and then `bootc container ukify --rootfs DIR -- --output uki.efi` with the signing arguments of section 4.6. bootc computes the composefs digest of the rootfs, reads the kargs, and calls ukify. The sealed UKI goes to `/boot/EFI/Linux/$kver.efi` and the digest is on its command line as `composefs=<sha512>`.

A flavor image is a second call with the core image as the base. The order of the modules in the list is `kernel`, then `uki`, then the sidecars with `uki_hash` in their metadata, then `image/core` with the sidecar digests in its annotation. The media modules produce the seed ISO with `xorriso` inside a container from the media image. `bootc-image-builder` produces `qcow2`, `raw`, `anaconda-iso`, `bootc-installer` and `pxe-tar-xz` from a bootc image, runs privileged with the containers storage mounted, and is oriented at Fedora and CentOS images. It is the tool to test first for disk images and the tool to avoid for the ISO of a musl image, because its installer types need Anaconda.

### 4.6 Signing

The library signs each artifact kind in the table with the tool and the key location shown, and a build node or a runner never has a private key in clear text. The table lists the tool, the key location and the verifier for each artifact. Every flag in it is in the help output read on this host today, unless the row says recalled.

| Artifact | Tool | Key | Verified by |
| --- | --- | --- | --- |
| Package, kernel, UKI, bootc and media images | `cosign sign --key URI` or keyless with `--fulcio-url --rekor-url --oidc-issuer --identity-token` and a `--signing-config` for a private Sigstore, `--record-creation-timestamp=false` so the signature has no clock in it | `hashivault://`, `awskms://`, `azurekms://`, `gcpkms://`, `k8s://`, `env://`, or a hardware token with `--sk --slot signature`. The release binary of cosign has no PKCS#11 support, verified | `cosign verify`, and `policy.json` on the node with `sigstoreSigned` |
| Provenance and SBOM | `cosign attest --type slsaprovenance1 --predicate FILE` and `--type cyclonedx`, `--type openvex` | As above | `cosign verify-attestation`, and the Validation Gate |
| RPMs | `rpmsign` with a GPG or Sequoia key on the signing station | HSM through the GPG agent | `rpmkeys --checksig` before composition |
| The ostree commit inside a bootc image | `rpm-ostree compose build-chunked-oci --sign-commit ed25519=KEY` | Ed25519, which is what ostree verifies at boot | The initramfs, with `enabled = signed` and `composefs.keyfile` in `prepare-root.conf` |
| The UKI | `bootc container ukify -- --signtool systemd-sbsign --secureboot-private-key URI --secureboot-certificate CERT` | A PKCS#11 URI through `systemd-sbsign --private-key-source provider:pkcs11`, which caches the token PIN in the kernel keyring. Recalled from the systemd 257 manual | UEFI with the customer's db key, and PCR 4 |
| Kernel modules | The kernel's `sign-file` with a `pkcs11:` URI in `CONFIG_MODULE_SIG_KEY` | The same token | The kernel at load |
| ISO and other files | `cosign sign-blob --bundle FILE` | As for images. The algorithms are ECDSA P-256 to P-521 and RSA PKCS#1, verified. ML-DSA is absent | `cosign verify-blob` |
| Git commits and tags | The maintainer's hardware key, as today | A FIDO2 or PIV token | The merge rule in guidelines 01 |

The Builder and Auditor signatures of arch 2.5 §4 are enforced by `policy.json` as it is. The manual states that when a requirement is a list, all its entries must be satisfied, so two `sigstoreSigned` entries with two keys or two Fulcio identities require two signatures on every pull.

The following caveats change what the signing module writes. Each comes from the reading today.

- bootc enforces `policy.json` on `install` and `switch`, and issue 528 states there is no option to enforce it on `upgrade`. The node's update path needs a test before the policy is trusted.
- cosign 3 writes signatures as Sigstore bundles through OCI referrers by default. podman and bootc cannot see that format, as projectbluefin issue 977 reports for June 2026. The signing module passes `--new-bundle-format=false` for every image a node pulls, and keeps the bundle format for artifacts only cosign reads.
- cosign has no ML-DSA. Images and blobs get an ECDSA or RSA signature today, and the post-quantum signature of ADR 0004 waits for the tool.

The private Sigstore that arch 2.5 describes is Fulcio, Rekor and a TSA from `sigstore/scaffolding`. Rekor v2 is the tile-based log, backed by Trillian Tessera, with a POSIX filesystem backend among its storage options, only `hashedrekord` and `dsse` entry types, and support in cosign from 2.6.0. That is the log ADR 0041 asks for, and a POSIX backend is a directory that `rsync` can carry across a diode.

### 4.7 Receipts and consensus

`api::sec::receipt::write` reads every image and artifact digest in the store, the digests of the host tools, the lock file digest, the module files' digests and the state keys the run read, and writes an in-toto statement with a SLSA provenance predicate. The statement has no timestamp. It is attached to the release image with `cosign attest --type slsaprovenance1`.

Consensus compares unsigned digests. A signature changes the bytes of an image manifest, an RPM and a UKI, and three nodes without keys cannot produce three identical signed artifacts. `api::sec::consensus::compare` reads the receipts and lists the subjects that differ. Signing is applied once, after the compare, by the signing module of the release list.

### 4.8 CI on private infrastructure

The build runs on a self-hosted GitHub Actions runner in the private data centre, with the same command as on a laptop. The library adds one group for it, `api/ci`, with four functions.

- `api::ci::detect` reads `CI` and `GITHUB_ACTIONS` and switches the UI to plain log groups, `::group::` and `::endgroup::`, one per module.
- `api::ci::identity` requests the OIDC token from `ACTIONS_ID_TOKEN_REQUEST_URL` when the job has `id-token: write`, and hands it to cosign as `--identity-token`. The token's claims include the repository, the ref, the workflow and the runner environment, so a private Fulcio can bind a certificate to the job. `actions/attest` uses the GitHub private Sigstore instance for private repositories and needs `id-token: write`, `attestations: write` and `artifact-metadata: write`. It is the alternative when GitHub's instance is acceptable as the log.
- `api::ci::cache` pushes the store to the private registry after a run and pulls it before the next, so a package whose key exists is not rebuilt. zot is the registry: one static binary, OCI referrers and artifacts, cosign and notation verification through its image trust extension, and a sync extension for mirroring into an air-gapped site.
- `api::ci::summary` writes the per-module table to `GITHUB_STEP_SUMMARY`.

A runner has docker, podman or both, and the engine detection in section 4.1 picks what is present. A runner has an OIDC identity and, for the RPM and UKI keys, a network path to the signing station that has the token. The signing keys are not on the runner.

### 4.9 The UI

`util/ui` is kept and extended. On a terminal a run shows one line per module with a spinner while it runs and a tick, a duration and the digest when it ends, and a summary table at the end. `--no-color`, a missing terminal, or CI detection turn that into plain lines. `STEALTH_LOG_JSON=1` adds a JSON line per event for machines. The engine's flight recorder is unchanged: stderr of a failing step is printed once, at the end.

### 4.10 The runtime stages

A node is configured after deployment by the `root` and `user` hooks of the product's profile modules, through the same library. This is the "stage to configure the runtime once an image is live". The library serves it with the groups in section 3, and two rules apply.

- A `root` or `user` hook changes the node and nothing else. It never builds. A `build` hook builds and never touches the host. The stage name in the hook makes the intent visible in the module file.
- Spec 1.3 §3.2 allows audited shell scripts on the host and ADR 0029 bans interpreters from the TCB. The `stealth` package on a node is that audited script set, pinned by digest in the image's SBOM like every other file, and the Python-backed format modules `data/ini` and `data/toml` gain a pure-bash reader so that a node does not need Python for them.

## 5. Conventions

- The engine sets `set -Eeuo pipefail` once. A module starts with the guard `_STEALTH_LIB_<PATH>` and imports what it needs.
- Output returns through a nameref in the first argument, and every local in such a function has a prefix unique to the function.
- A function that takes a path takes it first. Mode and owner follow as `--mode` and `--owner`. Defect 2 was two orders.
- `sys::cmd::run` aborts on failure and `sys::cmd::try` returns the status. A function named `is_*`, `has_*` or `verify_*` returns a status and never exits. A pipeline never contains a function that may exit. `shift N` follows a check of `$#`.
- No `$RANDOM`, `date` or `hostname` value enters an image, an artifact or a receipt.
- The unit tests mock every external command by name, as `CONTRIBUTING.md` asks.

## 6. Tests

- Unit and sys suites per module, with podman, docker, crane, skopeo, cosign and jq mocked, in the bats-test image as today.
- An integration suite on a builder image with the real tools: a fixture module builds a package image twice with the cache off on two hosts with different hostnames, users and locales, and the store digests match. The crane half of that test passed on this host today.
- A hermetic test builds a fixture module whose configure step runs `curl`, and the step must fail inside the container.
- A signing test signs the fixture image with a `dev` key, writes a `policy.json` with two requirements, and pulls it with skopeo. The pull must fail with one signature and pass with two.
- A boot test boots the fixture UKI under QEMU with OVMF and swtpm in the lab and waits for the health marker on the serial console.
- Coverage stays at the 100% floor, with `# LCOV_EXCL_LINE` and a reason on the lines that run only with a real engine.

## 7. The tools, compared

| Tool | What it does for the library | Needs a runtime | Deterministic | Status |
| --- | --- | --- | --- | --- |
| crane 0.21.3 | Image from a layer tar, mutate, flatten, export, pull to and push from an OCI layout | No | Yes, tested twice today | Installed, verified |
| regctl | The same, with explicit timestamps and OCI referrers, on OCI layouts | No | Yes, by its `--reproducible` and `--time` options | Verified from its docs |
| umoci 0.6.0 | Raw layer append and repack on OCI layouts, rootless | No | With `--history-created` | Verified from its manual |
| oras | Artifacts and referrers, `--oci-layout` targets | No | Not relevant | Verified from its docs |
| skopeo 1.22.2 | Transport between every store form, signing with sigstore, Sequoia and GPG | No | Copies preserve digests | Installed, verified |
| podman 5.8.4, docker | Run a build step in a toolchain image | Is the runtime | Not relevant, no image is built with it | Installed, verified |
| rpm-ostree 2026.2 `compose build-chunked-oci` | A chunked bootc image from a rootfs directory, with a signed ostree commit | No | Chunked by RPM data, stable through `--previous-build` | Installed, verified |
| bootc 1.16.10 `container lint`, `split-kernel-and-rootfs`, `ukify` | The layout check, the kernel split and the sealed UKI | No | Not relevant | Installed, verified |
| rpm-ostree `compose image` | A chunked image from a treefile and RPM repositories | No | Reproducible by its own description | Installed, verified |
| bootc-image-builder | Disk images and installer ISOs from a bootc image | Privileged podman | Not stated | Verified from its README |
| hhd-dev rechunk | Re-layering of an existing bootc image by package and changelog history | Rootful podman | Not across builds, by its own description | Verified from its README |
| BuildKit, docker buildx | Containerfile builds with `SOURCE_DATE_EPOCH` and `rewrite-timestamp=true`, `--output type=oci` | The docker daemon | Yes, from BuildKit 0.13 | Verified from its docs. Not used for layers |
| apko | An image from apk packages, reproducible, with an SBOM | No | Yes | Verified from its README. apk, not RPM |
| stacker | An image from YAML with LXC-isolated steps, squashfs and erofs layers | LXC | Not stated | Verified from its README |
| cosign 3.0.5 | Signatures, attestations, blob signatures, private Sigstore configuration | No | `--record-creation-timestamp=false` | Installed, verified |
| zot | The private registry with referrers, verification and sync | No | Not relevant | Verified from its docs |
| zig 0.16.0 | A static musl cross compiler on day one | No | Not tested | Installed, one static build verified |

## 8. Risks and open points

1. `bootc upgrade` does not enforce `policy.json`, per issue 528. A node's update path needs a test before signatures on the update path are trusted.
2. cosign 3 bundle signatures are invisible to podman and bootc, per issue 977. The signing module passes `--new-bundle-format=false` for images a node pulls.
3. cosign has no ML-DSA and the cosign release binary has no PKCS#11. Hardware keys go through `--sk` or through a KMS such as Vault with an HSM behind it.
4. ostree verifies the commit with Ed25519, so the post-quantum mandate of ADR 0004 stops short of the boot chain until ostree gains another algorithm.
5. Whether a layer written by the library and the import into composefs keep the `security.ima` attribute is untested, and fs-verity signatures take its place if they do not.
6. `rpm-ostree compose build-chunked-oci` was verified from its help and not run. Its first run on a musl rootfs is the first task after the store exists.
7. `bootc-image-builder` needs Anaconda for its installer types, so the seed ISO of a musl image is built with `xorriso`.
8. Nested containers on the clean-room node: a runner that runs `stealth` inside a container runs podman or docker inside it. Rootless nesting needs `/dev/fuse`, a user namespace and `label=disable`. Rootful nesting is simpler. Per site, and it needs a test.
9. `_FORTIFY_SOURCE` has no effect on plain musl without `fortify-headers`. Recalled. The elf check reports the header package as required.
10. `ldd` cannot prove static linking on a musl host. The elf check uses `readelf` for `PT_INTERP` and `DT_NEEDED` and accepts the `PT_DYNAMIC` segment of a static PIE.
11. kCFI needs Clang. RANDSTRUCT works with either compiler since 5.19. Recalled. The toolchain modules build LLVM if the kernel uses Clang.
12. A stripped static binary has no symbol table, so `nm` proves nothing about a flavor's absence of a component. The compose function proves it from the package list, the file list and a `strings` scan for a marker.
13. bootc merges `/etc` three ways. A file that `systemd-tmpfiles` copies from `/usr/share/factory` on first boot counts as a local edit afterwards. Defaults belong in `/usr/lib` drop-ins where software reads them, and in `/etc` inside the RPM where it does not.
14. bootc applies SELinux labels from the policy in the image at deploy, and ADR 0010 removes SELinux. An image without a policy needs a lab test.

## 9. Build order

1. `core`, `util` and `sys` as they are, with the fixes in section 2 and the defects of `library-analysis.md`. A module with an `init` and a `build::start` hook runs at the default log level with the UI on.
2. `api/virt/container` with both engines and the flag set, `api/oci/layer` and the store. The reproducibility test with crane passes on two hosts.
3. `api/make/pkg::build` with the `zig` and `autotools` systems. A fixture module builds `zlib` as a package image with an elf report and an SBOM artifact.
4. `api/make/oci::compose` with the bootc checks and `build-chunked-oci`. A fixture profile composes three package images into a bootc image that passes `bootc container lint`.
5. `api/sec/sign` and `api/sec/receipt`. The two-signature test passes.
6. `api/os/kernel`, the UKI through `bootc container ukify`, and the boot test.
7. `api/ci`. The same list runs on a self-hosted runner and pushes the store to zot.
8. The `root` and `user` stages against a booted fixture image in QEMU.

## 10. Claims and their status

Verified means read or run on 2026-09-19. Recalled means from memory.

| Claim | Status |
| --- | --- |
| The engine, loader, state and trap behaviour in section 2 | Verified, read in full |
| podman 5.8.4 flags, `podman artifact`, skopeo 1.22.2 transports and signing flags | Verified, `--help` on this host |
| crane 0.21.3 subcommands, and byte-identical output from two `crane append` runs | Verified, run on this host |
| cosign 3.0.5 flags, the absence of PKCS#11 in the release binary, the sign-blob algorithm list | Verified, `--help` on this host |
| bootc 1.16.10 `container lint`, `split-kernel-and-rootfs` and `ukify` | Verified, `--help` on this host |
| rpm-ostree 2026.2 `compose build-chunked-oci` options | Verified, `--help` on this host |
| zig 0.16.0 static musl build | Verified, run on this host |
| docker run flags in section 4.1 | Verified from the docker reference |
| The bootc layout rules, the sealed UKI path and the `composefs=` karg | Verified on bootc.dev |
| `policy.json` semantics for lists of requirements | Verified from the containers/image manual |
| Rekor v2 backends and entry types, and `sigstore/scaffolding` components | Verified from the Sigstore blog and the repository |
| BuildKit `SOURCE_DATE_EPOCH` and `rewrite-timestamp`, umoci and regctl options, apko, stacker, rechunk, bootc-image-builder, zot | Verified from their documentation |
| `--userns=keep-id` as podman only | Recalled |
| `systemd-sbsign --private-key-source provider:pkcs11` and the kernel `pkcs11:` URI for `CONFIG_MODULE_SIG_KEY` | Recalled from the manuals found in search |
| regclient's OCI layout reference scheme | Recalled. The README states OCI layout support without the scheme |
| Items 9 and 11 of section 8 | Recalled |
| Items 1, 5, 6, 8 and 14 of section 8 | Untested |
