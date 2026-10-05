# Agent Worlds artifact acceptance

Verified October 5, 2026 from independent repository commit `3e6afd4e5708ed25d63ad50408a164a046c05308`. The clean clone was created with `git clone --no-local` into a new temporary directory whose only child was `agent-worlds`. No Locus sibling, generated build output, local node_modules, private asset-generation records or credentials were copied. The build used macOS arm64, Node v25.5.0 and npm 11.8.0.

`npm ci --ignore-scripts --no-audit --no-fund` succeeded. `npm run check` passed typechecking, 220 tests (zero failures/skips), the source asset hash/allowlist checks, actual esbuild dependency-graph checks, and packaging. The inspected production graph contained 1,170 inputs, no developer mock, tests, Outpost renderer components or external Locus sources. The source manifest verified 114 immutable authored files.

An initial npm-ci attempt was accidentally dispatched before clone checkout had finished and correctly reported a missing lockfile; it was rerun after clone completion. This was test orchestration timing, not a repository failure. The completed clean clone remained unmodified after build/test/package.

The package contains 113 files and 221,540,093 installed bytes. The ZIP is 221,559,093 bytes. A second `npm run package` rebuilt source and produced byte-for-byte identical output; Python's standard ZIP CRC check passed.

```text
agent-worlds-0.2.0.zip
SHA-256 08185931c0170330997b120f2149fccf9ac767c1cdd3b184dfb21a6d36b689e7
installed tree digest 517ac68cc830ec1fc40c1ee238ab7c86594330bb9e634b6fcac521cfa8d90bb4
```

The exact clean-clone outputs were copied to the independent checkout's ignored `release/` directory: ZIP, `.sha256` and the full per-file `asset-manifest.json`. No source or generated artifacts are fetched from Locus during this process.

`Tools/VerifyAgentWorldsArtifact.py` accepted this pinned ZIP through the normal parser and ExtensionManager using isolated temporary application state. It preserved identity `locus/agent-world` and passed v1-to-v2 upgrade, rejection of the stale reviewed digest, workspace enablement preservation, rollback, reinstall, disable and uninstall. The original v1 plugin was read only. Malformed archive bounds/path/symlink/duplicate/manifest checks have focused automated tests. The native application installation and visual acceptance result are recorded separately; this installer rehearsal alone does not prove native UI compatibility.

Detailed results are in `agent-worlds-verification/clean-clone-result.json` and `clean-clone-check.txt`. Browser baseline/candidate evidence is in `agent-worlds-browser-verification.md`. Outpost recovery remains in the verified external archive described in `agent-worlds-recovery.md`.

This is a local candidate, not a published release. `NOTICE` preserves the unresolved derivative/reference-art redistribution status; it does not invent rights or a blanket asset license.
