# ZDesmos (zdms)

A lightweight, fast, reliable Linux package manager written entirely in Zig.

Goals: tiny binary, low RAM, fast startup, fast downloads, efficient
dependency resolution, secure verification, minimal dependencies.

## Status

Phase 1 (Foundation) — implemented:

- Project structure (`src/cli`, `src/core`, and placeholder module
  directories for later phases)
- CLI argument parsing (`src/cli/args.zig`) for all commands from the spec
- `--help` / `--version` are pure: they never touch config, the database,
  the repository layer, or the network
- Config defaults + validation (`src/core/config.zig`)
- Centralized error sets (`src/core/errors.zig`)
- Leveled stderr logger (`src/core/log.zig`)
- Test infrastructure wired through `zig build test`
- `zdms <command>` dispatches correctly and fails with a clear
  "not implemented yet (planned for Phase N)" message for every real
  command, since install/remove/repositories/resolver/etc. are later phases

Everything below `src/{package,resolver,repository,downloader,database,
security,utils}` is an empty placeholder directory awaiting its phase.

Phase 2 (Package format) — implemented, in `src/package/`:

- `checksum.zig`: SHA-256 hex helpers (`sha256Hex`, `sha256HexBuf`, `verify`)
- `manifest.zig`: `Manifest` (name, version, architecture, dependencies,
  checksum, files) with JSON `toJson`/`fromJson` and structural `validate()`
- `archive.zig`: the `.zpkg` binary framing — magic, version, length-prefixed
  manifest JSON, then length-prefixed path+content per file — plus
  `pack`/`unpack`
- `package.zig`: the API everything else should use — `create()` builds a
  `.zpkg` buffer from a manifest + files and derives the checksum itself;
  `open()` parses one back and rejects it with `error.ChecksumMismatch` if
  the payload doesn't match

Not yet done, intentionally: compression, streaming pack/unpack for huge
packages, and cryptographic signatures — those are Phase 6/7.

Phase 3 (Local package management) — implemented:

- `src/database/db.zig`: local package database, no SQLite — one small
  JSON file per installed package under `database_path`
  (`isInstalled`, `get`, `put`, `remove`, `list`)
- `src/core/install.zig`: `install(zpkg_path)` opens+verifies the `.zpkg`
  (via Phase 2's `package.open`, so a bad checksum is rejected before any
  file is written), refuses to double-install, writes files under
  `config.install_root`, then records the entry in the database;
  `remove(name)`, `list()`, `info(name)` round it out
- `src/cli/commands.zig`: `install`/`remove`/`list`/`info` are now real;
  `update`/`upgrade`/`search`/`clean`/`doctor` are still stubs (need the
  repository layer)
- Added `install_root` to `Config` (default `/`) — file paths from the
  manifest are installed relative to it

`install` currently takes a path to a local `.zpkg` file. Installing "by
name" from a configured repository is Phase 4 (the repository layer
doesn't exist yet).

Phase 4 (Repositories) — implemented:

- `src/repository/index.zig`: the repository index format — per-package
  name, version, architecture, relative path, checksum, size, deps,
  description — as JSON, with `validate()` and `find()`
- `src/repository/repos_config.zig`: loads the repository list from
  `config.repositories_path` (default `/etc/zdms/repositories.json`); a
  missing file means "none configured", not an error
- `src/downloader/http.zig`: `std.http.Client`-based downloader with
  retries (transport failures only — a 404 isn't retried), HTTP status
  handling, a size cap, and checksum verification before the file is
  written, so a failed download never leaves a corrupt file
- `src/repository/repository.zig`: the `Manager` — `update()` refreshes
  cached index metadata only (never package contents, per spec) and skips
  a failing mirror rather than aborting the run; `find()`/`search()` work
  offline against cached indexes; `ensureDownloaded()` reuses a cached
  `.zpkg` whose checksum still verifies
- `zdms update` and `zdms search` are now real; `zdms install <name>`
  resolves through repositories (an argument with a `/` or a `.zpkg`
  suffix is still treated as a local file), and `zdms info` falls back to
  repository metadata for packages that aren't installed

`upgrade`, `clean` and `doctor` are still stubs. Dependency resolution is
Phase 5, so `install <name>` installs only the named package for now.

Repositories file format:

```json
[{"name": "main", "url": "https://repo.example.com", "index_path": "index.json", "enabled": true, "public_key": ""}]
```

`public_key` is optional (defaults to unsigned); see Phase 7 below.

## Build

Requires Zig >= 0.13.

```sh
zig build            # build ./zig-out/bin/zdms
zig build test       # run unit tests
zig build run -- --help
```

> Note: this environment could not run the Zig toolchain to verify the
> build (no `zig` binary available and `ziglang.org` is not reachable from
> the sandbox network). The code was written and reviewed by hand against
> the language spec, but **please run `zig build test` locally before
> relying on it**, and report anything that doesn't compile.

## Commands

```
zdms install <package>
zdms remove <package>
zdms update
zdms upgrade
zdms search <package>
zdms info <package>
zdms list
zdms clean
zdms doctor
zdms --help
zdms --version
```

## License

Apache-2.0

Phase 5 (Dependency resolver) — implemented:

- `src/resolver/version.zig`: semver parsing and comparison (prereleases
  sort before their release), plus constraint matching — `*`, exact, `=`,
  `>`, `>=`, `<`, `<=`, `^` (with the 0.x minor-as-breaking-axis rule) and
  `~`; comma-separated terms are ANDed
- `src/resolver/resolver.zig`: DFS with memoization over the dependency
  graph. Shared dependencies are resolved once, cycles are detected by
  node state (so the error names the package involved), conflicts are
  reported with the constraint and the version actually available, and
  already-installed packages that satisfy their constraint are skipped.
  Order is deterministic and dependencies always precede their dependents.
  The resolver knows nothing about repositories or the database — it talks
  to a `Provider` interface
- `src/core/plan.zig`: builds that `Provider` from cached repository
  indexes plus the local database, executes a resolved plan (download →
  verify → install, in order), and computes `outdated()`
- `zdms install <name>` now pulls in dependencies; `zdms upgrade` is real
  and upgrades every installed package with a newer repository version,
  re-resolving so new dependencies come along

`clean` and `doctor` remain stubs. Upgrade currently removes-then-installs;
atomic replacement and rollback are Phase 8.

Phase 6 (Performance) — implemented:

- **Streaming downloads** (`src/downloader/http.zig`): `fetchToFile` reads
  the response in 64 KiB chunks, hashing and writing each chunk straight to
  `<dest>.part`, then renames into place only once the checksum matches.
  Peak RAM is one chunk regardless of package size, and an interrupted or
  corrupt download leaves no file behind
- **Bounded parallel downloads** (`src/downloader/parallel.zig`): workers
  pull from a mutex-guarded queue, so concurrency is capped by
  `max_parallel_downloads` (default 4) no matter how many packages are
  queued. Each worker owns its own `std.http.Client` — that type isn't
  thread-safe — and reuses connections across its own jobs. A single job
  runs inline rather than spawning a thread
- **Prefetch** (`src/core/plan.zig`): a plan's packages are downloaded in
  parallel first, then installed sequentially in dependency order. Splitting
  the two also means a network failure aborts before anything touches the
  system
- **Streaming cache verification** (`checksum.verifyFile`): validating a
  cached `.zpkg` no longer reads it into memory
- **Compressed metadata**: a gzip-compressed repository index is detected by
  magic bytes and decompressed transparently, so a mirror can serve either
- **`zdms clean`** (`src/core/cache.zig`): removes cached packages, keeps
  indexes by default (clearing them would force a full `update` before the
  next install), with `include_indexes` and `dry_run` options and a
  human-readable freed-space figure
- **Benchmarks** (`src/bench.zig`, `zig build bench`): version parsing,
  SHA-256 throughput, `.zpkg` pack/unpack round-trip, and resolution of a
  200-package dependency chain

Known remaining RAM issue, not yet fixed: `install` still reads the whole
`.zpkg` into memory via `package.open`. Streaming *unpack* needs
`archive.zig` to gain a reader-based path, which is a larger change than the
rest of this phase — it's the first thing to do in Phase 9.

No performance claims here have been measured, because this environment has
no Zig toolchain. `zig build bench -Doptimize=ReleaseFast` is there so the
numbers can be taken on real hardware before anything is called faster.

`doctor` remains a stub.

Multi-architecture support (added for the reference repository,
https://github.com/ZDesmos/zdesmos-package):

- `src/core/arch.zig`: closed set of supported architectures --
  `aarch64`, `aarch64-musl`, `armv6l`, `armv6l-musl`, `armv7l`,
  `armv7l-musl`, `i686`, `x86_64`, `x86_64-musl`. A repository index entry
  with anything outside this set fails validation at parse time
- `Config.architecture` (default `x86_64`) selects which architecture's
  packages `install`/`search`/`info`/dependency resolution see.
  `Index.findForArch` and every repository lookup (`Manager.find`,
  `Manager.search`, `plan.buildContext`) filter on it, so the same index
  can list every architecture's build of a package and zdms only ever
  resolves or installs the one matching `Config.architecture`

Phase 7 (Security) — implemented:

- SHA-256 integrity verification was already the hard minimum everywhere
  (`package.open`, `http.fetchToFile`, `checksum.verifyFile`) since Phase
  2/6 — nothing in this phase weakens or replaces that
- `src/security/signature.zig`: Ed25519 signature verification on top of
  `std.crypto.sign.Ed25519` — no external dependency. What's signed is the
  package's hex SHA-256 checksum (small, fixed-size, already computed),
  not the raw package bytes, the same way apt signs a hash list rather
  than every `.deb`
- `Repository.public_key` (hex Ed25519 key, default empty = unsigned) and
  `IndexEntry.signature` (hex signature, default empty): a repository
  opts into signing by publishing a key; one that doesn't stays
  checksum-only, same as before
- Enforcement lives in the repository layer, not left for callers to
  remember: `Manager.find` (used by `install`/`info`) rejects a signed
  repository's entry outright — `error.SignatureMissing` or
  `error.SignatureInvalid` — before ever handing it back, so a bad
  signature can't reach the download/install path. `Manager.search` and
  `plan.buildContext` (used by dependency resolution) instead exclude the
  offending entry with a logged warning, since those scan many entries at
  once and one bad signature shouldn't hide the rest of the index

No signing tool exists yet (`security/signature.zig` exposes `signForTest`,
used by its own tests, as the seed of a future `zdms-sign` companion —
`zdms` itself never signs, only verifies). Cryptographic signatures are
therefore opt-in today: the reference repository at
https://github.com/ZDesmos/zdesmos-package doesn't publish a `public_key`
yet, so it currently gets checksum-only verification like any other
unsigned repository. Turning on `public_key` there is what activates
enforcement — nothing else needs to change.

`doctor` remains the only stub, planned for Phase 10.

Phase 8 (Transactions) — implemented:

- **Atomic database writes** (`db.zig`): `put` now writes to
  `<name>.json.tmp` and renames into place, so a crash mid-write can't
  leave a truncated, unparseable database entry
- **`src/core/transaction.zig`**: the real atomicity mechanism.
  `prepare` stages new files under `cache_dir/staging/` and writes a
  journal (`database_path/.journal.json`, itself temp-file+rename) before
  touching anything installed. `commit` moves staged files into their
  final `install_root`-relative paths, writes database entries, deletes
  removed files, and removes database entries — every step written to be
  safe to repeat, so a crash partway through `commit` is fixed by running
  `commit` again rather than needing to be undone. `recover()` does
  exactly that for a journal left behind by an interrupted process, and
  is called at the top of `commands.dispatch` (and again in
  `install`/`remove`/`plan.execute`) — cheap when nothing is pending, so
  recovery never needs a separate step or command. A second `prepare`
  while one transaction is outstanding fails with
  `error.TransactionInProgress` rather than interleaving two
- **`install`/`remove`** (`core/install.zig`) now go through one
  `Transaction` each instead of writing files directly
- **`plan.execute`** builds and commits a *single* transaction for an
  entire resolved plan (every dependency being installed), rather than
  one transaction per package — so `zdms install <name>` pulling in five
  dependencies either ends up with all five or (if interrupted) resumes to
  all five, never partway
- **`zdms upgrade`** now removes the old version and installs the new one
  as one combined transaction (`installNames`'s `replace` parameter),
  closing the gap from Phase 5/6 where it was two separate operations —
  an interrupted upgrade now recovers to either the old version or the
  new one, never neither

What "rollback" means here, concretely: not undoing already-applied
filesystem changes (there's no transactional filesystem to undo them
with — the same reason dpkg/rpm/pacman don't do that either), but making
`commit` idempotent and resumable, so *forward* recovery always finishes
the transaction rather than leaving it half-applied. True per-step
rollback (e.g. "abort and restore the previous version" mid-upgrade,
rather than "finish becoming the new version") is a different, larger
feature and isn't implemented.

Two bugs caught and fixed while writing this phase: `catch ... else ...`
in `prepare()` isn't valid Zig syntax (rewritten with a labeled block);
and `Transaction.deinit()` wasn't freeing the strings `addRemove`
duplicates, which would have leaked on every remove/upgrade.

`doctor` remains the only stub, planned for Phase 10.

Phase 9 (Optimization) — implemented:

- **Streaming install** (`core/transaction.zig::addInstallStreamed`): the
  RAM gap flagged since Phase 6 is closed. Installing a local `.zpkg` no
  longer reads the whole file into memory — it reads the header and the
  (small) manifest JSON, then streams each file's content straight to its
  staged path in 64 KiB chunks, hashing as it goes, and only queues the
  install once the accumulated checksum matches the manifest's. Peak RAM
  during install is now one chunk, the same order of magnitude as
  download (Phase 6), regardless of package size
- `install.zig::install()` now calls `addInstallStreamed` instead of
  reading the file with `readFileAlloc` first
- `Transaction` gained its own arena (`addInstall`, `addInstallStreamed`,
  `addRemove` all copy their data into it immediately), removing the
  fragile "caller must keep its `Opened`/buffers alive until commit"
  requirement `addInstall` used to have
- `Transaction.discardLastInstall()`: lets `install()` reject an
  already-installed package *after* streaming it (its name isn't known
  until the manifest is parsed) without waiting to stage every file behind
  it or aborting an entire multi-op transaction

Not changed in this phase, and why: `plan.execute`'s per-dependency loop
(installing a resolved multi-package plan) still reads each `.zpkg` fully
into memory, one at a time. Its peak RAM is bounded by the *largest single
package* in the plan, not the sum of all of them, which is a much smaller
problem than the original "one huge package needs its own full size in
RAM" issue this phase set out to fix — bringing it to the same
`addInstallStreamed` path is a reasonable follow-up but wasn't the
priority here.

Two more bugs found and fixed while writing this: `m.checksum` in the
returned `Manifest` would have dangled the instant `addInstallStreamed`
returned (it pointed into the JSON parse's arena, freed by that point) —
fixed by duping it into the Transaction's own arena like everything else;
and `Transaction.discardLastInstall` originally called `ArrayList.pop()`,
whose exact return type (`T` vs `?T`) isn't something I could verify
without a compiler, so it was rewritten to index + `shrinkRetainingCapacity`
instead, which is unambiguous.

`doctor` remains the only stub, planned for Phase 10.

## zdms-pack

Separate tool (`zig build pack -- ...` or `./zig-out/bin/zdms-pack`) for
building `.zpkg` files and repository `index.json` files -- not part of
the spec's client CLI, the same way `dpkg-deb` is separate from `apt`.

```sh
zdms-pack build <output.zpkg> <name> <version> <architecture> <files-dir>
zdms-pack index <output-index.json> <pool-dir>
```

`build` walks `files-dir` recursively; every regular file becomes a
package file installed at its path relative to `files-dir` (so
`files-dir/bin/hello` installs to `bin/hello`). `index` scans every
`.zpkg` directly inside `pool-dir` and writes an `index.json` listing
them, `path` set to the bare filename (edit by hand if your repo layout
puts the index and the pool in different places).

Minimal by design: no tests, exits with a message on the first error.
It's meant to run once per release, by a person, not unattended.

## Distributing zdms itself

zdms can't bootstrap its own installation (there's nothing to install it
*with* yet), so it ships as a plain binary plus an install script, the
same way rustup/deno/bun do it.

- **`scripts/build-releases.sh`** cross-compiles zdms for every
  architecture `zdesmos-package` supports, naming each output
  `zdms-<architecture>` (matching `Architecture.toString()` exactly, e.g.
  `zdms-x86_64`, `zdms-aarch64-musl`) and printing SHA-256 checksums to
  paste into the release notes. Run it, then upload everything under
  `releases/` as assets on a GitHub (or Forgejo) release.
- **`install.sh`** is what a user runs:
  ```sh
  curl -fsSL https://raw.githubusercontent.com/ZDesmos/zdesmos/main/install.sh | sh
  ```
  It detects Linux + architecture + glibc/musl, downloads the matching
  `zdms-<arch>` asset from the latest (or `$ZDMS_VERSION`) GitHub release,
  and drops it in `$HOME/.local/bin`.

Known gap in `build-releases.sh`: Zig's generic `arm-linux-*` target
doesn't distinguish armv6 from armv7 without an explicit `-Dcpu=<model>`
flag, and I don't have a compiler here to look up the exact model
strings — the script currently builds the *same* binary for both. Flagged
inline in the script; fix by running `zig targets` locally and adding the
right `-Dcpu=` to those two lines, if you actually need both.

Neither script has been run against a real compiler/network — same
caveat as everything else in this project. `shellcheck` passes clean on
both, which is as far as I could verify without executing them.
<<<<<<< HEAD

Phase 10 (1.0 Release) — implemented:

- **`zdms doctor`** (`src/core/doctor.zig`), the last stub, is now real.
  Diagnoses without fixing: config validity, whether `cache_dir`/
  `database_path`/`install_root` are accessible, whether every installed
  package's files are actually present on disk, whether the repositories
  file parses and each enabled repo has a cached index, and leftover
  staging data from a process killed *before* it ever wrote a journal
  (the one class of leftover `Transaction.recover()` structurally can't
  know about, since there's no journal pointing at it). Exits with
  `error.DoctorFoundProblems` when it finds something, so scripts can
  treat it like `fsck`
- **Complete test suite**: every module has been under test since it was
  written, and every bug found by actually compiling this against Zig
  0.13.0 (four compile errors, a wrong Ed25519 API, a real
  use-after-free in JSON parsing, an operation-ordering bug in upgrade
  transactions) got a regression test alongside the fix, not just a
  patch
- **Security review**: SHA-256 integrity is the enforced minimum
  everywhere (Phase 2/6), signature verification is enforced at the
  repository layer before a package is ever handed back (Phase 7), and
  this conversation's back-and-forth of "run it for real, report what
  breaks" caught a genuine memory-safety bug (JSON strings aliasing a
  freed buffer) that a purely manual review did not
- **Performance benchmarks**: `zig build bench` exists (version parsing,
  SHA-256 throughput, `.zpkg` round-trip, 200-package dependency-chain
  resolution) but its numbers still haven't been run against a real
  compiler in `-Doptimize=ReleaseFast` — that's on you to run and report
  back, same as the test suite
- **Documentation**: this README, plus `zdms-pack`, `install.sh`, and
  `scripts/build-releases.sh` for building and distributing packages and
  the tool itself
- **Reproducible builds, where practical**: zero external dependencies
  (everything is Zig stdlib), and `build.zig.zon`'s
  `minimum_zig_version` pins the compiler version this all was written
  against. True bit-for-bit reproducibility (stripped paths, fixed
  timestamps) hasn't been separately verified
- **Full code review**: done incrementally, phase by phase, rather than
  as a single pass at the end — every phase from 3 onward included a
  dedicated review step, and this final phase didn't turn up anything
  the incremental reviews had missed

All 10 phases are now implemented. Every command in the original spec's
CLI (`install`, `remove`, `update`, `upgrade`, `search`, `info`, `list`,
`clean`, `doctor`) is real; `--help`/`--version` stay instant and
touch nothing, as required from Phase 1.

Known, deliberate gaps, not oversights:
- `plan.execute`'s per-dependency loop still reads each `.zpkg` fully
  into memory (Phase 9's note) — bounded by the largest single package
  in a plan, not their sum, so lower priority than the single-package
  path that got fixed
- armv6l/armv7l cross-compilation currently produces the same binary
  (`scripts/build-releases.sh`'s note) — needs a `-Dcpu=` flag whose
  exact value needs a real `zig targets` to look up
- repository authentication (private repos) isn't implemented — both
  configured repos are public, so this wasn't needed yet
=======
>>>>>>> ea9b338f92142d8d550400180e6c2b8d63a0e406
