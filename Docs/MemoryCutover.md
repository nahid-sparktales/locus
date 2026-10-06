# Locus Memory integration and cutover

The runtime bundles `locus-memory==0.2.1` as a pure Python wheel downloaded from
its versioned GitHub release. Both runtime builders install the exact URL and
SHA-256 in `agent/requirements-runtime.lock`; development and CI installations
use the same URL and hash from `agent/pyproject.toml`. Downloads happen during
the build, before signing or packaging. Installing Locus needs no separate
memory setup, and memory works offline after installation. Earlier wheel
provenance is retained in
[`agent/vendor/wheels/README.md`](../agent/vendor/wheels/README.md).

The two handoff patches were applied in order to Locus `b332e455`. The host
integration additionally routes the existing memory UI, REST endpoints and model
tools according to durable ownership. Model calls only propose candidates; user
review remains necessary for approval. Scope grants are built by the host.

`LOCUS_MEMORY_ENGINE_MODE=shadow` preserves the legacy prompt and records counts
and timing. `enabled` serves the engine context. After cutover, package ownership
forces enabled recall even if that environment variable is absent or disabled.
Changing a rollout flag never rolls back storage ownership.

## Offline operator commands

Stop Locus and its independent runtime first. Backends hold a shared profile
lease; the migration process needs the exclusive lease. It also refuses running
Locus processes and other open legacy vault handles. Install the updated app
before cutover: older binaries do not implement writer fencing. Do not launch an
older build against a migrated profile.

Run from the repository root, using the default Locus profile shown below. For
an independent profile, substitute its actual app directory. LocusX must use its
edition-staged backend so it selects the correct security partition.

```sh
export PYTHONPATH="$PWD/agent"
PYTHON=agent/.venv/bin/python
PROFILE="$HOME/.ollama-code"

"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" inventory
LOCUS_MEMORY_ENGINE_MODE=shadow "$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" compare
LOCUS_MEMORY_ENGINE_MODE=enabled "$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" compare
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" snapshot
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" validate
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" cutover --yes
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" state
```

`snapshot` calls `Migrator.prepare_shadow`: consistent encrypted SQLite snapshot,
manifest and import, then `shadow_prepared`. `validate` checks mapped content,
scope, lifecycle and revision metadata, then `validated`. `cutover` drains through
the exclusive host lease, fences legacy writers, applies the last delta, verifies
again, and moves to `package_authoritative`. A failed validation cannot advance
ownership. The host uses its existing key provider and `locus/default` partition;
the standalone `locus-memory` CLI's separate file keys are not used.

Queries can be supplied with repeated `--query`; reports show only their hashes,
counts and timings. Use `--workspace` and `--agent-id` on `compare` to inspect that
scope. Failure counters make a fail-closed empty response fail the rollout check.

## Rollback and recovery

Stop the app again. Preview the representability check, then reverse-sync:

```sh
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" rollback
"$PYTHON" -m ollama_code.memory_migration --app-dir "$PROFILE" rollback --yes
```

The preview exits 2 without changing ownership. Rollback preserves package-era
corrections and deletions and returns to `legacy_authoritative`. This host tool
refuses unreadable records and partial rollback. Keep transcript archival off
unless a package-only recovery store is an acceptable future rollback outcome.
Never restore the old SQLite file over newer data as a substitute for rollback.

Re-running `cutover --yes` or `rollback --yes` resumes the corresponding interrupted
state. `abort --yes` returns an interrupted preparation/cutover to legacy ownership
using the package recovery protocol. Missing or corrupt ownership control fails
closed when partition data exists; restore/recover the ownership file instead of
deleting the engine store. A missing host key is never replaced when legacy or
package data exists.

A valid control database with a missing ownership row also fails closed when its
ownership log or the surviving partition's cutover marker proves a previous
transition. This covers restoring an empty pre-cutover control file beside newer
package data. Legitimate shadow profiles may still have no ownership row, and an
explicit completed rollback remains usable. This check does not authenticate the
age of a nonempty ownership row or detect every combination of files restored
from different migration cycles; keep the current control file with the profile
and use the offline rollback protocol to change owners.

The Migrator removes its temporary encrypted snapshots at cutover and after
rollback. The legacy vault remains for reverse-sync and for the separate
`context_snapshots` and `skill_observations` families, which remain legacy-owned.
This integration does not mark those families or the legacy database retired.

## Compatibility boundaries

Existing memory list, search, approval, correction, deletion, import/export,
feedback and plaintext-note migration use the selected owner. Legacy diagnostics
are not replayed as engine workspace history. Changing an existing memory's kind
or scope and creating a new governed procedure through the ordinary memory form
return an explicit error; the package's procedure workflow requires its own API.
Existing imported procedure text remains editable. Native provider paths that
previously omitted automatic memory retain that behavior; no decrypted memory is
added to persisted provider homes by this change.

Regression coverage includes actual shadow and enabled adapters, candidate
exclusion, scoped USER/AGENT operations, legacy-writer fencing, profile leases,
missing-key and missing-control refusal, restart, rollback with later corrections
and deletions, helper/evaluation recall, and team recall after scheduler admission.

The local validation on 2026-10-04 passed 189 focused host tests and 33 package
migration tests. The vendored package patch also preserves session/run source
bindings for new memories during rollback, including explicit removal of a binding.
The wheel was installed and exercised outside its source checkout and rebuilt
byte-for-byte from the recorded source and patch.

The local Locus profile was then inventoried, snapshotted, validated and cut over
using the installed app's signed runtime. One personal candidate was preserved;
there were no approved memories to inject. The state is `package_authoritative`,
and a fresh process selects enabled package recall even with the rollout variable
set to disabled. Rollback preview reports the one record representable and safe.
The 37 context snapshots and 6 skill observations remain in their separate legacy
families. The local, content-free execution report is at
`~/.ollama-code/memory-engine/migration-report.json`.

## Remaining architecture extraction (0.2.0)

The follow-on extraction moves the canonical compatibility API, ownership lookup
and leases, recall/archive lifecycle, migration session, memory policy, selected
chat candidate review, continuity payload composition and saved-chat FTS search
into `locus_memory`. Locus modules bind app paths, key custody, trusted identities,
HTTP/tool routes, session data, model calls and git inventory to those APIs.

The source of these implementations is the public
[Locus Memory repository](https://github.com/nahid-sparktales/locus-memory); its
`docs/host-extraction.md` records the exact ownership boundary. This extraction
initially used a vendored 0.2.0 wheel; current builds use the pinned release below.

This is a code extraction with unchanged data formats. The completed cutover is
not rerun. Continuity records retain their existing encrypted legacy envelopes
under package implementation, and the saved-chat search cache retains its existing
derived FTS format. Rollback and current approval state remain intact.

The 0.2.0 extraction validation passed 1,545 package tests (one skip), 213 focused
host tests and two additional backend route tests. All 71 installed package
modules import without host or network dependencies; the standalone quickstart
and CLI lifecycle pass. A clean rebuild produces the identical wheel hash.

The signed Release app was rebuilt, audited and installed on 2026-10-04. All
1,245 staged host source files and 73 package files match the build inputs.
A fresh process in the installed bundle reports package version 0.2.0,
`package_authoritative` ownership, one candidate and zero approved memories;
the key, 37 continuity snapshots and six observations are preserved. Rollback
preview remains safe. The content-free report and prior-app backup location are
in `~/.ollama-code/memory-engine/extraction-report.json`.

## Automatic installation (0.2.1)

Locus's local and remote runtime builders now download the public
[0.2.1 release wheel](https://github.com/nahid-sparktales/locus-memory/releases/tag/v0.2.1).
The runtime input, lock and development dependency all pin the same versioned URL
and SHA-256: `66bf34c70ba9a6f213cd18cc3b2a14117fd97b26ebeda3102d3f9df7edb7e948`.
The wheel is installed during packaging and included in the signed application;
users need no Python, package installation, checkout or rollout flag. There is no
first-launch code download for memory.

Fresh profiles automatically initialize an empty package-owned encrypted store
with the host key provider. Initialization serializes concurrent starts, takes an
exclusive profile lease, and atomically publishes the closed, prepared store.
User approval, scope grants and recall settings still govern what is remembered
and used. Existing legacy profiles retain the migration procedure above; existing
package-owned profiles reopen without another cutover. Native Codex parity mode
continues to omit automatic memory context and ordinary memory tools.

Validation on 2026-10-04 passed 1,556 package tests (one optional skip) and 610 host
tests. An anonymous clean pip download verified the release hash. The signed
Release app passed its distribution audit and signature verification; all 1,245
staged host source files and 74 package files matched their build inputs. Its
bundled Python, running outside the source checkout with an isolated fresh
profile and no mode flag, created canonical memory, enforced candidate approval,
recalled approved scoped memory, honored disabled recall, and reopened the same
store in another process.

The updated signed app was installed locally with a verified prior-app backup.
The content-free installation and profile verification report is at
`~/.ollama-code/memory-engine/automatic-install-report.json`. The public package
release is available; distributing this integration to other users still requires
the normal Locus application release process.
