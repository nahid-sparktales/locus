# Runtime extraction: companion ownership and consumers

Audit date: 2026-10-05. Locus implementation baseline:
`4319810bfb13d42be47d0e5278c3f55135a357c2` (the checkout started detached).
The brief's `b332e4554e72956f949506207ffa034749360d79` is a historical reference,
not the implementation base. This audit inspected source and release metadata;
it did not launch companion applications or change companion repositories.

## Revisions inspected

| Repository | Local checkout and revision | Remote main observed | Release / artifact actually relevant |
| --- | --- | --- | --- |
| `locus-platform` | `/Users/nahid/Documents/locus-platform`, branch `sync/locus-3.1.0`, `1ff6bb6b0559e15f7ddd34e3c13b7bec0a836051`, clean | `10174f9675e46dc98eafb29ec765be185496a769` | Browser published artifact uses platform `v0.1.0-canary.5`, `49ad2a3cf8c9a9009e291dd32ed0e23c5435345c`; current browser CI selects `.7`, `b7a39f31566a190342db735485c0f566fbce7e27`. Platform has tags but no GitHub Release objects at audit time. |
| `locus-browser` | `/Users/nahid/Documents/locus-browser`, branch `main`, `bf8d58037cf50c5d2430e10c293cf009f1eb037f`; one unrelated modified file left untouched | Same revision | Latest published release `v0.1.0-canary.6`; release manifest records browser commit `a37a8f6d5afff3f77c1b357382b67677085dd9bc`. |
| `locus-memory` | `/Users/nahid/locus-memory`, branch `main`, `ec7e87d821af064c5cd7fc680357f58b3ecc9a22`, clean | Same revision | Locus pins released `locus_memory-0.3.0-py3-none-any.whl`, SHA-256 `aafdbdf72b04aa2e83589cf0b88f1f9c8493b6ab9e97b65b6deac6dd5802d4b6`. Release provenance identifies this source revision. |
| `langgraph-workflow` | `/Users/nahid/Documents/langgraph-workflow`, branch `raise-max-jobs-ceiling`, `52799242a53d80ed067797d0cbb6e1c83363214e`; untracked `.DS_Store` left untouched | `e13ee9fa90203232af8128bfb809e260d95ccf5b` | Package/plugin version `0.4.1`; vendored wheel SHA-256 `f90963f21d8c378ead956b2a9fd5924e7c546ad8f23ff5ec46f58573a754d492` in both inspected plugin manifests. No GitHub Release objects observed. |
| `locus-mobile` | No dedicated local checkout used; inspected through GitHub contents/tree APIs | `5f38ad95cc3934bb5d2d098697795ec5b5a426f0` | Flutter manifest version `1.0.0+1`; no GitHub Release objects observed. It selects a paired Mac endpoint, not a Python package release. |

Remote observations used authenticated, read-only `gh api` calls, including
commit/tree/contents, tags, release asset contents, and the single nonsecret
browser `canary` environment variable `LOCUS_PLATFORM_REF`. No credentials,
production profiles, installed plugin folders, or active runtime packages were
read or modified. The absence of a GitHub Release does not imply the absence of
private deployments, package-index releases, or installed consumers.

## Ownership and active dependency paths

Here, “consumer” means a dependency or execution path demonstrated by the
inspected source or artifact, not a claim about which applications a user has
installed.

| Consumer | Demonstrated source / package supplier | Ownership and extraction implication | Evidence |
| --- | --- | --- | --- |
| Native Locus foreground and optional independent/remote worker | This Locus repository's `agent/ollama_code`; baseline distribution is `ollama-code==0.3.0`. No platform dependency was found in its Python manifests, XcodeGen file, Swift package resolution, or assembly scripts. | Keep product worker, routes, account/policy, native broker and Swift UI here. Extract execution mechanics through explicit adapters. The same `ollama-code` distribution name/version in platform is not evidence of interchangeable builds. | `agent/pyproject.toml`, `Tools/PrepareAgentRuntime.sh` (`backend_root` defaults to this repo's `agent`), `Tools/BundleBackend.sh`, `Tools/PackageRemoteRuntime.py`, `project.yml`. |
| Locus Browser local Python backend | Platform's `agent/ollama_code`, copied as product source into the Electron artifact, with dependencies from platform's hashed runtime lock. | Platform remains the browser product backend supplier. Its shared schema, TS/Swift protocol clients and browser bridge remain there. This task does not migrate Browser or extract its full backend. | [Browser manifest](https://github.com/nahid-sparktales/locus-browser/blob/bf8d58037cf50c5d2430e10c293cf009f1eb037f/apps/desktop/package.json), [assembly script](https://github.com/nahid-sparktales/locus-browser/blob/bf8d58037cf50c5d2430e10c293cf009f1eb037f/scripts/prepare-agent-runtime.sh), [launcher](https://github.com/nahid-sparktales/locus-browser/blob/bf8d58037cf50c5d2430e10c293cf009f1eb037f/apps/desktop/src/main/AgentRuntime.ts). |
| Locus Browser shared TS contracts and isolated-world bridge | `@locus/protocol` and `@locus/browser-bridge`, both version `0.1.0`, via `link:../../../locus-platform/packages/...`; CI checks out the selected platform ref beside Browser. | These are existing product/wire contract owners, not runtime-internal schemas. Do not move or replicate them in `locus_runtime`. | Browser `apps/desktop/package.json` and `pnpm-lock.yaml`; platform `packages/protocol/package.json`, `packages/browser-bridge/package.json`, and `Package.swift`. |
| Locus memory operations | Hash-pinned `locus-memory==0.3.0` release wheel. Concrete imports appear in `memory_adapter.py`, `memory_guard.py`, `memory.py`, `continuity.py`, `transcript_search.py`, and product API modules. | Memory storage/crypto/history stay in `locus_memory`; product admission and account integration stay in Locus. No memory engine belongs in `locus_runtime`. Platform's inspected Python manifests do not consume this package. | Locus `agent/pyproject.toml`, `agent/requirements-runtime.in`, `agent/requirements-runtime.lock`; [memory provenance](https://github.com/nahid-sparktales/locus-memory/releases/download/v0.3.0/release-provenance.json). |
| Optional LangGraph workflow plugin | Marketplace plugin launches `/bin/sh ${PLUGIN_ROOT}/bin/launch`; the launcher installs hashed dependencies and its vendored `langgraph_workflow-0.4.1` wheel into plugin data, then runs `-m langgraph_workflow.mcp_server`. | Keep graph/checkpoint/job semantics in the existing workflow package. Locus baseline has no `langgraph_workflow` imports or Python dependency. A user-installed MCP plugin is a separate execution path; no installed-plugin state was inspected. | [Plugin MCP manifest](https://github.com/nahid-sparktales/langgraph-workflow/blob/e13ee9fa90203232af8128bfb809e260d95ccf5b/plugin/.mcp.json), [launcher](https://github.com/nahid-sparktales/langgraph-workflow/blob/e13ee9fa90203232af8128bfb809e260d95ccf5b/plugin/bin/launch), [wheel hashes](https://github.com/nahid-sparktales/langgraph-workflow/blob/e13ee9fa90203232af8128bfb809e260d95ccf5b/plugin/wheels/SHA256SUMS). |
| Mobile iOS/Android companion | Dart client speaks versioned companion WebSocket envelopes to a certificate-pinned paired Mac; Mac owns dispatch through `CompanionGateway` and `AppModel+MobileCompanion`. No platform/Python dependency in mobile `pubspec.yaml`. | Preserve Locus-owned paired-device authority, gateway sanitization and companion protocol fixtures. Mobile does not directly select or install an execution runtime wheel. | [Dart manifest](https://github.com/nahid-sparktales/locus-mobile/blob/5f38ad95cc3934bb5d2d098697795ec5b5a426f0/pubspec.yaml), [client](https://github.com/nahid-sparktales/locus-mobile/blob/5f38ad95cc3934bb5d2d098697795ec5b5a426f0/lib/src/companion_client.dart), Locus `Locus/CompanionGateway.swift`, `Locus/AppModel+MobileCompanion.swift`, `ProtocolFixtures/companion-v1.json`. |

### Platform reconciliation

Platform's [ownership statement](https://github.com/nahid-sparktales/locus-platform/blob/10174f9675e46dc98eafb29ec765be185496a769/README.md)
calls its whole Python agent backend a runtime and says both native Locus and
Browser consume tagged platform releases. Actual native Locus build inputs at
this baseline do not support the latter claim. Browser does consume platform,
but the two source trees are already separate product-backend implementations.

The inspected platform main, local branch, and canary `.6` source tree do not
contain the independent-service extraction candidates `runtime.py`,
`runtime_store.py`, `runtime_remote.py`, `runtime_install.py`, or
`runtime_snapshots.py`. They contain other product modules such as
`mcp_runtime.py` and `runtime_components/`; those names do not establish
ownership of the independent execution supervisor. Platform's console script
is only `ollama-code-server = ollama_code.server:main`; native Locus additionally
owns the pre-extraction `locus-runtime` script.

The narrow reconciliation is therefore:

```text
Native Locus product/adapter ──────────────> locus_runtime mechanics
Browser Electron adapter ──> platform product backend (existing path)
Browser contracts ─────────> platform shared schemas/clients/bridge
Locus memory adapter ──────> locus_memory
Optional workflow plugin ──> langgraph_workflow + Locus MCP boundary
Mobile ────────────────────> Locus companion gateway
```

Do not copy the platform backend into `locus-runtime`, require platform's
`ollama_code` from the new package, or move shared product contracts into a
second schema owner. A future platform adapter may depend on the same immutable
runtime wheel; that direction does not require a reverse dependency. The
existing native/platform product-backend duplication remains an explicit
separate issue, not something this extraction silently resolves.

### Published Browser provenance outranks README pins

The [Browser canary `.6` release manifest](https://github.com/nahid-sparktales/locus-browser/releases/download/v0.1.0-canary.6/release-manifest.json)
records browser commit `a37a8f6d5afff3f77c1b357382b67677085dd9bc`.
Its [published SBOM](https://github.com/nahid-sparktales/locus-browser/releases/download/v0.1.0-canary.6/sbom.cdx.json)
records `locus:platform-revision=49ad2a3cf8c9a9009e291dd32ed0e23c5435345c`,
which is platform tag `v0.1.0-canary.5`. The SBOM's expected SHA-256 in the
release manifest is `4be13ef91bd2496db06b0a987a21091d107c114c936312ee553d8f0b3d88d588`.
This audit read those JSON assets; it did not download, authenticate the
publisher signature of, install, or execute the DMG/ZIP.

Current Browser CI selects platform `.7`; current `canary` environment
`LOCUS_PLATFORM_REF` is `.5`; platform's README says `.6`. These are three
different facts, not interchangeable compatibility claims. Release workflow
rejects an empty ref or `main`, but that check alone does not prove any other
branch name immutable. Any integration release must resolve and record the
exact tested commit and wheel hashes.

## Tracked integration requirements (not completed migrations)

No companion repository patch was applied. These identifiers track the exact
remaining work here; they are not GitHub issues or claims of test completion.

| ID | Owner / trigger | Concrete integration and acceptance requirement |
| --- | --- | --- |
| CR-1 | Platform, when opting its product backend into extracted mechanics | Add a concrete platform worker/storage/authority adapter, depend on the identical tested immutable `locus-runtime` wheel, regenerate `agent/requirements-runtime.lock` with hashes, and remove only replaced mechanics. Keep platform schemas and `ollama_code.server` product ownership. Do not install native Locus and platform `ollama-code` distributions together. Run platform Python, schema/fixture, TS and Swift gates before tagging. There is no platform independent-service implementation to delete at the audited revisions. |
| CR-2 | Browser, after CR-1 | Select the tested platform commit in `.github/workflows/ci.yml` and release environment; keep `scripts/prepare-agent-runtime.sh` consuming the platform lock so it installs the runtime wheel into packaged `site-packages`. Extend its packaged import smoke and `AgentRuntime` process tests to assert the intended runtime version and adapter path. Verify source/wheel provenance, launch readiness, controller reconnect, cancellation, preserved token/data-root scopes, and an offline packaged application. Existing native Electron process ownership must be reconciled explicitly before adding another supervisor. Do not claim migration based only on changing the checkout ref. |
| CR-3 | Platform/Browser documentation and release provenance | Correct the platform README claim that current native Locus consumes platform and reconcile `.5`/`.6`/`.7` statements against release evidence. Record both platform product commit and runtime wheel version/hash in packaged `PROVENANCE`, SBOM and release validation. Current Browser SBOM supplies platform revision but no runtime wheel identity because it has no such dependency. |
| CR-4 | Locus workflow integration, only if in-process workflow admission is later added | Preserve the optional MCP plugin boundary now. Reassess `integrations/locus/compatibility.json` and its patches against the actual Locus revision before enabling its reference in-process adapter. That compatibility record tests workflow `0.1.0` against Locus `5ac5b5b1c450eff0013ed6caae8c696dfc6fb0eb`, not current `0.4.1` against this extraction. Future continuation callbacks must keep canonical budgets, permissions and verification in Locus. No workflow implementation is added to `locus_runtime`. |
| CR-5 | Mobile affected-neighbor gate | Keep companion v1 envelopes, token authority and brokered one-time decisions unchanged. Run Locus companion fixture/dispatch tests and mobile `flutter analyze` / `flutter test`; perform paired-device reconnect/approval tests only with an authorized test Mac/device. An unchanged Dart manifest alone is not a compatibility test. |
| CR-6 | Memory affected-neighbor gate | Keep `locus-memory` `0.3.0` hash pin, product adapters and shared canonical memory ownership. Run existing memory boundary/isolation and packaged import tests alongside runtime extraction tests. Do not move memory databases, usage ledgers or workflow checkpoints into runtime storage. |

## Audit reproduction

Read-only checks used local `git status --short`, `git rev-parse HEAD`, manifests,
assembly scripts and imports, plus GitHub API snapshots. Useful commands:

```sh
gh api repos/nahid-sparktales/locus-platform/commits/main --jq .sha
gh api 'repos/nahid-sparktales/locus-platform/git/trees/10174f9675e46dc98eafb29ec765be185496a769?recursive=1' --jq '.tree[].path'
gh api repos/nahid-sparktales/locus-platform/tags --jq '.[] | {name,sha:.commit.sha}'
gh api repos/nahid-sparktales/locus-browser/releases/assets/528453933 -H 'Accept: application/octet-stream'
gh api repos/nahid-sparktales/locus-browser/releases/assets/528453934 -H 'Accept: application/octet-stream' --jq '.metadata.properties'
gh api repos/nahid-sparktales/locus-browser/environments/canary/variables --jq '.variables[] | select(.name == "LOCUS_PLATFORM_REF") | {name,value}'
gh api repos/nahid-sparktales/locus-memory/releases/assets/611616475 -H 'Accept: application/octet-stream'
rg -n 'locus_memory|langgraph_workflow|locus-platform|LocusProtocol' agent/ollama_code agent/pyproject.toml Tools project.yml --glob '!**/builtin_skills/**'
```

These findings establish ownership and source/artifact identity. They do not
establish live Browser, mobile, SSH, Tailscale, service, signing, provider or
production compatibility. Those remain separate implementation/release gates.
