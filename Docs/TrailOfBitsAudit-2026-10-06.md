# Locus audit using Trail of Bits skills — 2026-10-06

**Remediation update:** the four reproduced findings have now been fixed and regression-tested; see [fixes and validation](TrailOfBitsFixes-2026-10-06.md). The findings below describe the original audited revision and preserve its evidence.

## Executive summary

**Recommendation: fix the plugin cancellation defect before releasing the Social Studio extraction.** Three additional P2 findings affect companion routing and memory recovery. No critical issue, unauthenticated code execution, or confirmed wallet capability leak was found in the reviewed scope. This is an AI-assisted audit using Trail of Bits' methodology, not an audit performed or certified by Trail of Bits.

| Priority | Count | Findings |
| --- | ---: | --- |
| P1 / High | 1 | A plugin can perform a delayed write after its window/request closes |
| P2 / Medium | 3 | Companion subfolder chats disappear; valid conversation model overrides are blocked; stale ownership metadata permits divergent memory writes |

The audit did not change application code. Reproductions use disposable profiles, synthetic tokens and fixture files. No live account, publishing service, personal memory or login Keychain was exercised.

## Installation and method

Registered the [Trail of Bits marketplace](https://github.com/trailofbits/skills) with Codex and installed these six skills under `~/.codex/skills`: `differential-review`, `audit-context-building`, `fp-check`, `variant-analysis`, `sharp-edges`, and `post-patch-validation`. Installation used the Codex skill-installer helper; installed SKILL.md files match upstream revision `82fe8226252622fa807643bdca1710901198553a`. They are available for subsequent turns. No always-on observer or review hook was added.

Applied differential review and false-positive verification: read baseline implementations and invariants; traced changed code through callers and trust boundaries; checked history, permissions and tests; reproduced candidate failures with negative controls. Native, plugin and memory paths were reviewed in parallel, and the principal findings were independently checked. Functional regressions are distinguished from security exploits.

## Scope and changes

Audited checkout: `5529004a47235943991f192464001dbc92685c9f`, initially clean.
Primary comparison: `b332e455..5529004a` (after 3.3.0), eight commits, **218 files, +20,248 / −4,298 lines**. The strategy was a focused review of high-risk paths within this large change set, not a line-by-line audit of all files.

| Change | Commit | Main review focus |
| --- | --- | --- |
| Companion and protected memory integration | `a55169ca` | Storage ownership, agent grants, recovery, provider-bound requests |
| Released memory package and release checks | `d6e629da`, `abd20676` | Package version/hash, offline runtime and migration boundaries |
| Companion sidebar, inspector and menu bar | `4cce6ebf` | Session/project ownership, chat overrides, queue/draft preservation, file links |
| Social Studio extraction | `a27f91c3` / merge `5529004a` | Removed native references, plugin context, authorization, revocation and cancellation |

Supplementary checks covered current wallet-free target separation, the earlier capability fix `9241ca95`, packaging, transport, protocol consistency and the Agent World bundle. Full LocusX signer/cryptography review, downloaded OpenPost service implementation, all vendored code, and every historical removal were outside scope.

The baseline has two main trust boundaries: native user control over an authenticated local Python service, and host-granted agent capabilities over tools/providers. Installed command plugins already execute with local process privileges; project metadata must not be described as an OS sandbox. Memory USER APIs may approve records, whereas model AGENT calls are limited to their host-provided identity/scopes and proposals.

## Findings

### F1 — [P1] Closing a plugin window does not cancel the pending MCP operation in the production HTTP stack

**Location:** [`agent/ollama_code/api/extensions.py:663`](../agent/ollama_code/api/extensions.py#L663). Introduced in `a27f91c3`.

The endpoint polls `request.is_disconnected()` to set the worker's stop event. The production `create_app()` wraps it with HTTP middleware at `server.py:3023–3024`. With the pinned Starlette/AnyIO stack, the middleware's receive wrapper checkpoints before it can supply the disconnect event, while `is_disconnected()` uses an immediately cancelled scope. The polling fails to observe socket closure. The stop event is eventually set in `finally`, after the MCP tool has finished.

**Reproduction:** start the real `create_app` with its middleware and a temporary cooperative MCP plugin. Send an authenticated request through a real TCP socket. Wait for the tool to begin a two-second validation delay, then close the socket. The tool subsequently writes its synthetic publication marker. The same endpoint/tool served without middleware cancels and never writes the marker.

| Exact locked runtime | Production app | Bare-endpoint negative control |
| --- | --- | --- |
| FastAPI 0.141.1, Starlette 1.3.1, AnyIO 4.14.2, Uvicorn 0.52.0, MCP 2.0.0 | `published_after_disconnect=true`, `cancelled=false` | `published_after_disconnect=false`, `cancelled=true` |

This reproduces a future side effect after cancellation, not an already committed remote operation that cannot be reversed. Native panel teardown does cancel its pending URLSession tasks (`PluginPanel.swift:237–240`), so HTTP disconnect is a relevant production path. An authorized plugin operation is required; this is not an unauthenticated execution flaw.

**Impact:** closing a publishing/plugin window may still allow delayed remote writes or other side effects that the user expects cancellation to stop. **Fix direction:** observe disconnect through an ASGI-compatible mechanism, or remove the incompatible HTTP middleware wrapper while preserving all Origin, token, body-size and maintenance checks. Keep the cooperative MCP stop propagation and no-write-retry behavior.

**Coverage gap:** the new disconnect test constructs bare `FastAPI`, omitting production middleware. It passes despite the production failure. Add the same socket-disconnect case against `create_app`, plus normal completion and no-double-write cases. The HTTP handler has one route registration; the underlying dispatcher is also directly exercised by tests. All plugin panel MCP tools share this route.

Evidence: [portable reproducer](evidence/trailofbits-audit-2026-10-06/plugin-disconnect-repro.py), [production result](evidence/trailofbits-audit-2026-10-06/plugin-disconnect-result.json), [negative control](evidence/trailofbits-audit-2026-10-06/plugin-disconnect-control.json), [independent verification](evidence/trailofbits-audit-2026-10-06/plugin-disconnect-verification.md), and [plugin review](evidence/trailofbits-audit-2026-10-06/plugin-review.md). The root review and a separate reviewer confirmed the path; exact-lock execution was repeated.

### F2 — [P2] Companion chats created for Git subfolders disappear from companion selection

**Locations:** [`Locus/AppModel+CompanionNavigation.swift:48–50`](../Locus/AppModel+CompanionNavigation.swift#L48) and [`Locus/CompanionPanelModel.swift:264–265`](../Locus/CompanionPanelModel.swift#L264). Introduced in `4cce6ebf`.

When a user selects a Git subfolder, automatic worktree creation preserves that choice as `environment.source_workspace`, while `workspace_root` becomes the repository root. This is an established supported representation. The new companion filter compares `session.workspacePath == selectedFolder` instead of `belongsToWorkspace`, rejecting the newly created chat. The catalog-refresh validator repeats the same comparison.

**Trigger:** choose `/repo/subproject` as the companion folder and create a conversation. The resulting `/repo`-rooted worktree chat is omitted from the companion list; panel `select` returns without selecting it, and the main shortcut's post-create guard also returns. Repeated attempts can create additional durable chats/worktrees. Existing data remains accessible elsewhere.

**Fix direction:** use the existing validated root/source-alias predicate in both locations without changing execution paths or dropping owner/archive checks. Test create, selection, catalog refresh and main shortcut with a repository subfolder, plus a sibling-folder negative control.

**Verification:** the real backend Git-subfolder fixture passed; existing native identity tests establish the source-alias contract. A compiled probe linked against the actual Debug Locus module returned `belongsToWorkspace=true companionChats=0 selected=nil`. Three direct `companionChats` call sites feed the panel and main navigation; activity uses the correct predicate and can show work whose chat is omitted. See [native review](evidence/trailofbits-audit-2026-10-06/native-review.md) and [probe output](evidence/trailofbits-audit-2026-10-06/native-findings-result.txt).

### F3 — [P2] Companion panel validates the default account instead of the conversation's selected account

**Location:** [`Locus/CompanionPanelModel.swift:81`](../Locus/CompanionPanelModel.swift#L81). Introduced in `4cce6ebf`.

The Send availability gate calls `agentProfileProvider(profile)` on the companion's default profile. Actual dispatch correctly uses `agentChatProfile(profile, sessionID:)`, which applies that conversation's saved model/account override.

**Trigger:** select a healthy local model or account B for the chat, then disconnect/remove the owner's default account A. The normal chat can use B, but the inspector/menu-bar panel validates A and disables Send before the correct dispatch path can execute. This is an availability regression; the inverse case is safely rejected by dispatch and does not execute against the wrong account.

**Fix direction:** use the effective selected-session route for send availability. Retain the owner's default for new conversations. Add healthy-override/unavailable-default and unavailable-override/healthy-default tests.

**Verification:** a compiled probe using `@testable import Locus` against the actual app module resolved `route=ollama/healthy-local`, selected the conversation, and observed `canSend=false` with the unavailable-default-account error. Its synthetic URLProtocol supplied the session response without a live provider. The availability value is read by the Send gate and visible composer notice. See [native review](evidence/trailofbits-audit-2026-10-06/native-review.md), [probe source](evidence/trailofbits-audit-2026-10-06/native-findings-repro.swift), and [output](evidence/trailofbits-audit-2026-10-06/native-findings-result.txt).

### F4 — [P2] Restoring stale ownership metadata silently permits divergent legacy memory writes

**Host locations:** [`agent/ollama_code/memory_ownership.py:11`](../agent/ollama_code/memory_ownership.py#L11), [`agent/ollama_code/memory.py:147–162`](../agent/ollama_code/memory.py#L147). Root cause: pinned `locus-memory 0.3.0`, `migrations/ownership.py:36`.

The package rejects a missing control database when partition data exists, but returns `legacy_authoritative` when a valid control database has no matching ownership row. A genuine pre-cutover shadow database has that shape.

**Reproduction:** back up that real shadow control file; perform snapshot/validate/cutover; save a package-era record; restore only the old control file beside the newer encrypted partition. Ordinary memory APIs hide the package-era record and accept new legacy writes. Restoring the current control file makes the package record visible again. Removing the control file entirely correctly fails closed, providing a negative control.

**Impact and conditions:** this requires a partial local restore or equivalent control-metadata damage. No normal-cutover failure, remote exploit, physical data deletion, forgotten-record resurrection or signed-Keychain bypass was demonstrated. The documentation discourages replacing SQLite files as rollback, but also promises missing/corrupt ownership will not silently select legacy authority. The defect is the silent fallback and split write history under that recovery condition.

**Fix direction:** preserve trustworthy evidence of canonical ownership and refuse ambiguous ownership rollback before legacy reads/writes. Do not reject every empty control table with a partition: legitimate pre-cutover shadow operation uses that state. Repair the package, update the pinned version/hash, and add stale-control plus legitimate-shadow tests.

**Verification:** reproduced independently using the exact runtime lock, real migrations and temporary files. Four direct host ownership-wrapper callers plus bootstrap feed owner selection; the memory facade reaches 21 route call sites and both memory model tools. Existing missing-file tests omit the valid stale-file case. See [memory review](evidence/trailofbits-audit-2026-10-06/memory-review.md), [reproducer](evidence/trailofbits-audit-2026-10-06/memory-ownership-repro.py), and [observed output](evidence/trailofbits-audit-2026-10-06/memory-ownership-result.txt).

## Checked candidates and qualifications

- **Plugin startup workspace versus request metadata:** reproduced a panel captured in A whose service cwd, `${LOCUS_WORKSPACE}` and MCP roots use selected workspace B, although B does not enable the plugin. Request metadata correctly retains A. This is a compatibility/privacy concern for consumers of those ambient values, but `Docs/AppsAndPlugins.md:130` explicitly requires project-aware backends to use per-request metadata. It is recorded as a design limitation, not counted as a confirmed sandbox escape or guaranteed wrong-project write in the downloaded publishing plugin. [Probe](evidence/trailofbits-audit-2026-10-06/plugin-workspace-repro.py).
- **Plugin handoff consent:** rejected the claim of a step-level privilege bypass. The documented consent is for a run and selected agents, and profile ceilings/MCP policies/tool permissions still apply. Storing an explicit editing limit could make the UI promise clearer, but step-specific authority is not the current contract.
- **Memory deletion resurrection:** a canonical-forget probe did not resurrect the deleted record through the stale-control path. No such claim is included in F4.
- **Wallet test-host scan:** scanning the Debug app while it contains the XCTest bundle finds wallet test strings. This is not evidence that the production executable includes wallet features; the production artifact is checked separately.

## Validation

| Check | Result |
| --- | --- |
| Whole Python suite, documented editable development install | **3,095 passed; 31 subtests passed**, 603.13 seconds |
| Native `LocusTests`, Xcode 26.6 / macOS | **1,954 passed**, zero failures |
| Agent World TypeScript and JavaScript | Type check passed; **144 tests passed** |
| Exact hash-locked plugin/product subset | **23 tests passed** |
| Release compile and wallet-free artifact audit | **Passed**; 10 Mach-O files and 9 source/resource files checked; backend bundling skipped |

Already completed: transport-security audit, current protocol manifest, Agent World package verification, Python Ruff checks, Agent World TypeScript check and 144 JavaScript tests. The recent-history gitleaks scan found no leaks across six non-merge commits. The runtime dependency audit checked 51 named dependencies with no known advisories; `locus-memory` was skipped by pip-audit because it is a direct URL requirement, and its relevant ownership/authorization source was inspected manually. This does not certify all external package code.

Targeted checks: 116 memory tests passed; 79 plugin/MCP-focused development-environment tests passed; 23 plugin/product tests passed again against the exact runtime lock; the real Git-subfolder fixture passed. These overlap the broader suites and should not be added together as unique tests. The cancellation regression reproducer intentionally demonstrates behavior the existing tests miss.

## Coverage and remaining risk

Selected high-risk paths and their immediate dependencies were inspected deeply; low-risk artwork, layout and documentation changes were triaged. No line-coverage percentage or claim of complete repository coverage is made. The audit includes negative evidence and reproducers, but passing suites are not proof that no other bugs remain.

The native build uses `LOCUS_BUNDLE_MODE=skip`; it validates native compilation/tests and target separation, not the complete signed/notarized distribution with bundled Python and helper downloads. No UI automation of the menu bar, live provider billing, real publishing, or full signed-helper Keychain recovery was performed. JavaScript checks used local Node 25.5.0, while CI pins 24.20.0. Python whole-suite tests used the documented editable development install; critical reproductions and the focused release-runtime tests additionally used the exact hash-locked dependencies.

Prioritize F1, then the companion regressions. Address F4 with the memory package's ownership model and recovery tests. Keep the production-middleware cancellation probe in regression coverage, and verify fixes through the actual application composition rather than endpoint-only fixtures.
