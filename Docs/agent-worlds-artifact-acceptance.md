# Agent Worlds artifact acceptance

Verified October 5, 2026 from independent repository commit `ec9416679a5f4929d78ae2f19acb6e4d572eb234`. The clean clone was created with `git clone --no-local` into a new temporary directory whose only child was `agent-worlds`. No Locus sibling, generated build output, local node_modules, private asset-generation records or credentials were copied. The build used macOS arm64, Node v25.5.0 and npm 11.8.0.

`npm ci --ignore-scripts --no-audit --no-fund` succeeded. `npm run check` passed typechecking, 222 tests (zero failures/skips), the source asset hash/allowlist checks, actual esbuild dependency-graph checks, and packaging. The inspected production graph contained 1,170 inputs, no developer mock, tests, Outpost renderer components or external Locus sources. The source manifest verified 114 immutable authored files.

This final candidate supersedes source `68a60d4` and ZIP `090c697ed4c4c16f7bb0a4c284fe1cfead62cb7e7b335862c6e5da483c5c3421`. It moves world catalog and welcome labels into the plugin's bounded presentation metadata. Existing canonical Crew Chat terminology and compatibility identifiers remain in the native host. The earlier lifecycle fixes and browser/native captures remain applicable; native acceptance runs again against this exact final artifact. A fresh clone independently repeated every build/package/install check. The prior record remains in Git history; the result JSON explicitly records its supersession. The final clean clone remained unmodified after build/test/package.

The package contains 113 files and 221,540,432 installed bytes. The ZIP is 221,559,432 bytes. A second `npm run package` rebuilt source and produced byte-for-byte identical output; Python's standard ZIP CRC check passed.

```text
agent-worlds-0.2.0.zip
SHA-256 4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8
installed tree digest 71588bfd345d2ed1090385b393111f54cf6bf355d9ff00f7f0c494714c183c81
```

The exact clean-clone outputs were copied to the independent checkout's ignored `release/` directory: ZIP, `.sha256` and the full per-file `asset-manifest.json`. The completed repository was subsequently moved intact to `/Users/nahid/Documents/agent-worlds` so it survives managed-worktree archival. Its source commit and ZIP hash were rechecked at that location. The delivered ZIP is `/Users/nahid/Documents/agent-worlds/release/agent-worlds-0.2.0.zip`. Historical clean-clone evidence retains its original temporary paths. No source or generated artifacts are fetched from Locus during this process.

`Tools/VerifyAgentWorldsArtifact.py` accepted this pinned ZIP through the normal parser and ExtensionManager using isolated temporary application state. It preserved identity `locus/agent-world` and passed v1-to-v2 upgrade, rejection of the stale reviewed digest, workspace enablement preservation, rollback, reinstall, disable and uninstall. The original v1 plugin was read only from the verified external recovery-archive restoration after its old Locus source directory had been removed. Malformed archive bounds/path/symlink/duplicate/manifest checks have focused automated tests. The native application installation and visual acceptance result are recorded separately; this installer rehearsal alone does not prove native UI compatibility.

Detailed results are in `agent-worlds-verification/clean-clone-result.json` and `clean-clone-check.txt`. Browser baseline/candidate evidence is in `agent-worlds-browser-verification.md`. Outpost recovery remains in the verified external archive described in `agent-worlds-recovery.md`.

This is a local candidate, not a published release. `NOTICE` preserves the unresolved derivative/reference-art redistribution status; it does not invent rights or a blanket asset license.
