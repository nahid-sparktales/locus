# Optional local Agent Worlds installation

`Tools/InstallAgentWorldsArtifact.py` is an explicit local installation entrypoint for a built Agent Worlds 0.2.x plugin ZIP. Locus's existing extension APIs accept catalog directories and Git sources; they do not provide a native ZIP import operation. This CLI uses `ExtensionManager.inspect_catalog_plugin`, `install_plugin` and `rollback_plugin` for trust, immutable version caching, scope preservation and atomic state replacement. A small source adapter supplies one reviewed local directory. It does not create, rename or replace a marketplace. The installation identity remains **`locus/agent-world`**, including an explicit upgrade from the legacy version.

The CLI requires Python 3.10+ in an environment with Locus's Python dependencies installed. Run it from the Locus source checkout. It does not download packages or contact a network service. The user must choose the extension state root; there is no default destination. Obtain the actual root from the running Locus backend configuration before stopping it. For a non-containerized backend this is normally `$OLLAMA_CODE_HOME/extensions`, or `~/.ollama-code/extensions` if no override is set. Sandboxed/app-managed installations may use a different directory.

## Review, then install

The ZIP checksum must come from the artifact producer through a trusted channel. The checksum pins bytes; it is not a code signature or a claim about third-party artwork rights. Keep the artifact's notices and the review report.

```sh
python Tools/InstallAgentWorldsArtifact.py review \
  --artifact /absolute/path/agent-worlds-0.2.0.zip \
  --sha256 ARTIFACT_SHA256 \
  --extract-to /absolute/path/new-review-folder \
  > /absolute/path/review.json
```

Review prints the plugin identity, version, wire protocol, requested capabilities, manifest, world metadata, full file inventory with byte sizes and individual SHA-256 hashes, and `plugin_digest`. `--extract-to` is optional and must name a new directory; it exposes the exact reviewed file contents for inspection without overwriting anything. Review never opens the extension state store. Unexpected identity, capabilities, executable extension features, path traversal, symlinks, forbidden archive contents and oversized packages fail before installation.

Quit Locus **and its backend** before mutating the extension store. The manager has an in-process lock; the CLI's filesystem lock prevents concurrent CLI installs, but it cannot coordinate with a running backend. Supplying a path to a live store is not safe. With the reviewed `plugin_digest`:

```sh
python Tools/InstallAgentWorldsArtifact.py install \
  --artifact /absolute/path/agent-worlds-0.2.0.zip \
  --sha256 ARTIFACT_SHA256 \
  --review-digest PLUGIN_DIGEST_FROM_REVIEW \
  --state-root /absolute/path/locus-state/extensions \
  --workspace /absolute/path/workspace
```

The default is workspace-only installation. `--scope global` is an explicit choice for a new installation. Upgrades preserve existing enabled/disabled workspace and global settings regardless of the supplied scope. Add `--upgrade-legacy-v1` to intentionally replace an installed protocol-1 Agent World. That upgrade reports the existing manager's renewed-trust capability diff and retains the old cached version. The candidate requires a host supporting protocol 2; merely having an old Locus app installed is insufficient.

Restart the compatible Locus app after installation. Its existing plugin discovery/window route finds the installed screen. This is an offline CLI entrypoint; a native drag-and-drop or ZIP-import button has not been added. Existing native enable/disable/uninstall controls continue using the same identity. A pre-existing `locus` catalog is left untouched; until a real published source is configured, use this reviewed CLI for artifact upgrades rather than the old catalog's update action.

The installed source is retained as a content-addressed directory under `extensions/plugins/artifacts/`. The active version is copied into the manager's normal `extensions/plugins/cache/locus/agent-world/` directory. No installed path points into a temporary directory or a sibling repository. The manager commits a prepared version directory before replacing its state file; interruption or an injected state-write failure leaves the old active record intact, possibly with an inactive cached directory. This is filesystem transaction behavior, not a claim of immunity to power loss or independent writers.

## Rollback

Review `state.json` read-only to obtain the current plugin digest and the first `previous` version's digest. Keep Locus and its backend stopped. Rollback checks both pinned records and rehashes both cached trees before calling the existing manager:

```sh
python Tools/InstallAgentWorldsArtifact.py rollback \
  --state-root /absolute/path/locus-state/extensions \
  --current-digest CURRENT_PLUGIN_DIGEST \
  --target-digest PREVIOUS_PLUGIN_DIGEST
```

A changed current version, missing previous version or tampered cache is rejected. Rollback preserves activation scopes and canonical Locus data. Returning to a protocol-1 plugin also requires its previously verified compatible host; a protocol-2-only host must safely reject the old plugin. The CLI changes neither the application binary nor native preferences. World preference migration retains legacy visual keys separately; canonical profiles, conversations, runs, provider settings and permissions are outside this tool's state root and are never migrated or reset.

## Explicit development directory

Development uses the same immutable installation path and permissions. Build Agent Worlds, then explicitly select its `dist/plugin` directory:

```sh
python Tools/InstallAgentWorldsArtifact.py review \
  --development-directory /absolute/path/agent-worlds/dist/plugin \
  --extract-to /absolute/path/new-development-review-folder \
  > /absolute/path/development-review.json

python Tools/InstallAgentWorldsArtifact.py install \
  --development-directory /absolute/path/agent-worlds/dist/plugin \
  --review-digest DEVELOPMENT_PLUGIN_DIGEST_FROM_REVIEW \
  --state-root /absolute/path/locus-state/extensions \
  --workspace /absolute/path/workspace
```

This opt-in configuration copies the directory, rejects symlinks, applies the visible native name and screen title **“Agent Worlds (development)” before calculating the review digest**, and validates the same identity, protocol and capabilities. It does not alter the selected build directory. A changed build requires another review and installation. There is no hot reload, directory link, implicit search for a checkout, mock-host enablement or production fallback. The native screen still connects to the real authorized host. To leave development mode, install a reviewed production ZIP under the same identity.

## Recorded verification

`python -m pytest -q agent/tests/test_agent_worlds_artifact_install.py` passed **13 tests** on 2026-10-05 with Python 3.14.6. Tests cover read-only content review, safe extraction, identity/scope/catalog preservation, explicit legacy upgrade, stale pins, corrupt state, injected failed state commit, tampered rollback caches and development snapshot isolation/re-review.

A separate real-artifact rehearsal installed the existing legacy **0.1.1** plugin into disposable state, upgraded it to **0.2.0**, then rolled back to **0.1.1** with scopes preserved. The reviewed ZIP contained **113 files**:

- Artifact SHA-256: `08185931c0170330997b120f2149fccf9ac767c1cdd3b184dfb21a6d36b689e7`
- Locus content digest: `517ac68cc830ec1fc40c1ee238ab7c86594330bb9e634b6fcac521cfa8d90bb4`

These identify the earlier rehearsed build. The final source `ec94166` was independently rehearsed after cutover with ZIP SHA-256 `4a4ca458bd1e0391e2ead1b52a58977329e85c30280218e605e992808f99eff8` and content digest `71588bfd345d2ed1090385b393111f54cf6bf355d9ff00f7f0c494714c183c81`; its verified legacy upgrade/rollback, reinstall, disable and uninstall results are in [artifact acceptance](agent-worlds-artifact-acceptance.md). No real user installation was changed. The CLI tests do not establish native rendering/UI parity, publication, signature validity or artwork redistribution rights; those have separate acceptance evidence.
