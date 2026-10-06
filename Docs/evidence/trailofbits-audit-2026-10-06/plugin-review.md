# Locus plugin and MCP differential security audit

Audit date: 2026-10-06. Worktree HEAD: `5529004a`. Differential focus: `4cce6ebf..a27f91c3` (Social Studio extraction); current-state review of adjacent panel/MCP trust boundaries. No production files edited. Task Observer was not used.

## Executive summary

| Classification | Confirmed findings |
| --- | ---: |
| P1 / high correctness and external-side-effect risk | 1 |
| P2 / nonblocking project-context correctness and privacy observation | 1 |
| Critical / demonstrated remote code execution or sandbox escape | 0 |

Recommendation: fix and integration-test panel disconnect cancellation before relying on window closure to cancel plugin publication work. The captured-workspace mismatch is a nonblocking compatibility/privacy observation with explicit documented limits; it is not a filesystem sandbox or access-control bypass. Resolve or explicitly restrict workspace-bound MCP connection features for retained panels as hardening.

One candidate about native run-step read/write consent was independently challenged and excluded from confirmed findings: documented authority is per-run/per-agent under the saved-agent ceiling, not per-step.

## Scope, changes, and baseline

The repository contains approximately 2,910 tracked/nonignored files (`rg --files`), so this review applied the skill's surgical strategy to the plugin execution boundary, not a claim of full-repository coverage. Read the Trail of Bits differential-review skill, methodology, adversarial modeling, and reporting instructions.

| Changed file | Additions | Deletions | Risk / coverage |
| --- | ---: | ---: | --- |
| `agent/ollama_code/api/extensions.py` | 99 | 6 | High: full changed call path, authorization, disconnect/revocation |
| `agent/ollama_code/mcp_runtime.py` | 68 | 15 | High: full changed paths, startup, retry, task handling, catalog publication |
| `agent/ollama_code/extensions.py` | 1 | 3 | High validation removal; reviewed replacement capability allowlist and one-hop plugin parsing/scope |
| `Locus/PluginPanel.swift` | 30 | 5 | High: request binding, cancellation, native bridge and handoff authority |
| `Locus/Models/ExtensionModels.swift` | 1 | 6 | Medium: supported capabilities and removed native social screen handling |

Also inspected `MCPAppHost.swift`, `mcp_apps.py`, `tool_registry.py`, server HTTP/auth middleware, request-body limits, plugin panel tests, changed marketplace source, and removed Social Studio store/window entry points. The extraction replaces native Social Studio dispatch with ordinary plugin panels. The removed `social.workspace` special-case validator is accompanied by removal from both backend and Swift capability allowlists, so it does not broaden accepted screen capabilities.

Baseline invariants and call chain:

* A WebKit panel cannot supply its own top-level plugin/project authority; native `PluginPanelBridge.toolRequest` captures plugin ID, panel ID, reviewed digest, and canonical opening workspace. JavaScript arguments remain separate.
* The backend rejects malformed/stale panel context, checks current plugin enablement and per-panel hidden-tool ownership, and rechecks before dispatch/retry. Direct HTTP requests require native token authentication in production (`server.py:250-268`); no external unauthenticated caller was demonstrated.
* `PluginPanelHost.Coordinator.revoke` cancels native tasks. HTTP disconnection is intended to set a worker stop flag; `MCPManager.call_tool` polls that flag and cancels the MCP future.
* Request metadata provides the original project while selected-chat state can change. Process launch and MCP roots existed before this new retained-panel cross-project path.
* Installed stdio plugins already execute as the user's unsandboxed processes. Their scope is exposure/activation, not OS-enforced filesystem confinement.

Call chain: panel JavaScript -> capability/shape decoder -> native bridge -> authenticated `POST /api/extensions/plugins/panel-tool` -> async HTTP wrapper -> synchronous context/scope checker -> `MCPManager.call_tool` -> `_call_tool` -> connection owner -> MCP server. Three `_connect(server)` call sites serve refresh, initial panel dispatch, and retry; one `_session_owner` creation site handles every transport. Four production `mcp.call_tool` call sites exist (panel endpoint, tool registry, MCP Apps, Jira); only the panel endpoint currently supplies the new resolver/metadata pair.

## Confirmed finding 1: P1 — production middleware prevents closed panels from cancelling pending MCP publication

**Primary code:** `agent/ollama_code/api/extensions.py:662-666` (especially `await request.is_disconnected()`).

**Related code:** `agent/ollama_code/server.py:3017-3024`; `agent/ollama_code/mcp_runtime.py:826-829`; `agent/tests/test_plugin_panel_disconnect.py:19-23`.

**Introduced:** `a27f91c3` adds the async HTTP wrapper and cancellation promise. Native cancellation reaches a real socket disconnection, but the new HTTP wrapper does not observe it under the production middleware stack.

**Concrete result:** With an installed synthetic plugin using a cooperative async MCP tool, the tool starts validation, waits two seconds, then writes a harmless `published` marker. The client closes its TCP socket immediately after validation starts. Under the actual `create_app` application, `published_after_disconnect` is **true**, while the server's `CancelledError` marker is **false**. The same tool and TCP request under the bare FastAPI application used by the tests produces **false/true** respectively.

The actual production application was used, including both HTTP middlewares and request-size middleware, at the real `/api/extensions/plugins/panel-tool` route. The request supplied a synthetic valid `X-Locus-Token`. Uvicorn listened only on an ephemeral loopback port. No external service, actual user account, or publication was used.

**Reproduction artifacts:**

* `/tmp/locus-panel-tcp-disconnect-probe.py`
* `/tmp/locus-panel-tcp-disconnect-exact-lock.json` — actual production `create_app`: publication true, cancellation false.
* `/tmp/locus-panel-tcp-disconnect-exact-lock-negative.json` — `--bare`: publication false, cancellation true.
* `/tmp/locus-panel-middleware-probe.py` — additionally reuses the committed ASGI disconnect regression test unchanged, adding only production `block_browser_origins`; this also fails.

Commands:

```sh
/tmp/locus-audit-pinned-20261006/bin/python /tmp/locus-panel-tcp-disconnect-probe.py
/tmp/locus-audit-pinned-20261006/bin/python /tmp/locus-panel-tcp-disconnect-probe.py --bare
```

The full runtime-lock environment reproduced the issue with FastAPI **0.141.1**, Starlette **1.3.1**, AnyIO **4.14.2**, Uvicorn **0.52.0**, and MCP **2.0.0**. Reproduction also succeeds with the newer dev environment, so this is not based only on dependency drift.

**Root cause:** Starlette's `Request.is_disconnected` performs its receive inside an already-cancelled AnyIO cancel scope, intended as a nonblocking check. The `BaseHTTPMiddleware` receive wrapper used by `.middleware("http")` performs async task-group work before returning the disconnect. The poll never sees the event in this stack. Uvicorn does not automatically cancel a normal application handler just because its peer closes. Therefore the worker's stop flag is set only when the tool finishes or the handler is otherwise cancelled—too late for the pending write.

**Accessibility / exploitability:** An installed plugin with `plugin.tools`, an open native panel, and an in-flight async operation. A malicious external attacker is not required; an ordinary user closing a Social Studio publication panel during validation triggers the failure. The tested server explicitly honors cancellation, so the result does not depend on a server refusing to cancel.

**Impact:** Plugin work continues after the user closes the panel, and external publication/writes can begin afterward. This is failure to send the cancellation signal, not a claim that Locus can undo an external operation already accepted or force noncooperative servers to stop.

**Blast radius:** One native panel-tool HTTP endpoint and one native `callTool` bridge dispatch path; every plugin panel using the endpoint is exposed, not just Social Studio. Other MCP callers do not use this HTTP-disconnect wrapper.

**Test gap:** Existing 16 context/disconnect tests pass even under the exact lock. Their `_app` fixture constructs bare `FastAPI()` and omits both production HTTP middlewares, which is why the new cancellation regression is invisible. The negative control proves this omission materially changes behavior.

**Suggested correction:** Monitor ASGI disconnect with a receive path that works through the production middleware stack, or convert these middleware functions to pure ASGI middleware so their receive wrappers do not defeat the poll. Add an integration test through `create_app` and preferably a real disconnected socket. Preserve prompt cancellation without retrying write operations.

## Nonblocking observation: P2 — retained panel connections still use the selected project's MCP roots/startup context

**Primary changed call:** `agent/ollama_code/mcp_runtime.py:982-986` connects the captured-project server without a captured workspace in the connection identity/configuration.

**Actual incorrect context:** `mcp_runtime.py:306-310` returns `extensions.cwd` for `roots/list`; lines 322, 329-332 resolve stdio environment/command/arguments/cwd from the same selected workspace, and line 340 resolves HTTP headers there as well.

**Concrete scenario:** Enable a panel plugin only in project A; select a chat in project B; call the still-open A panel. The endpoint correctly verifies A enablement and sends A in `com.locus/panel` metadata, but a newly launched MCP server receives B for `${LOCUS_WORKSPACE}`, process cwd, and `roots/list`. B is explicitly inactive for that plugin.

**Reproduction artifacts:**

* `/tmp/locus-panel-context-probe.py`
* `/tmp/locus-panel-context-probe.json`: A metadata, B process cwd/env/roots, `active_in_selected:false`, harmless relative fixture read returns `SELECTED PROJECT PRIVATE DATA`.
* `/tmp/locus-panel-context-negative-control.json`: using `--selected-original`, all context and fixture data are A.
* `/tmp/locus-panel-http-context-probe.json`: using `--http`, a real loopback streamable-HTTP MCP server receives B's `file://` root while activated only for A. Only the `roots` field is evidence of host-to-remote disclosure here; the HTTP fixture's own cwd/data fields are fixture process setup and are not evidence of Locus remote file access.

The runtime's roots callback is shared across stdio, streamable HTTP, and SSE. The stdio and HTTP paths were executed; SSE is source-inspected only.

**History:** Selected-workspace startup substitution predates the change (`82620182` / `8d1b18062`); roots callback added by `ab1b1cca` (Improve MCP diagnostics and broaden server compatibility). The new route can now connect an A-only server while B is selected, violating the old assumption that connected workspace context equals the selected project.

**Threat-model limits and counterevidence:** `Docs/AppsAndPlugins.md:130-135` expressly tells new project-aware backends to use request metadata rather than cwd/startup environment. A backend following that guidance for every operation can avoid wrong-project data access. Stdio plugins have full user filesystem privileges already; this is not an OS sandbox escape or elevation. The demonstrated remote disclosure is B's workspace root URI/name, not B's file contents. No in-repository surviving bundled panel was found depending on `${LOCUS_WORKSPACE}` or roots for its data selection. These facts justify P2 correctness/privacy classification instead of a broader security claim.

**Impact:** Existing plugins that use normal MCP roots or workspace substitutions can act on B while the native window identifies A. Even a metadata-aware remote server requesting roots learns an unrelated project's path when it is disabled there. Running an A panel should not expose contradictory project roots.

**Blast radius:** One new captured-project route, three connect call sites, one session owner; all plugin panel server transports using workspace-dependent startup settings or opt-in `share_workspace_root`. Actual installed-user prevalence was not measured.

**Suggested correction:** Bind roots/startup context to a captured workspace and make that workspace part of connection identity when workspace-bound features are used. Avoid mutating global cwd for a panel request. Alternatively reject incompatible retained cross-project panel connections with a clear error while keeping request-metadata-only backends usable. Test A/B mismatch for roots, env/cwd and HTTP substitutions.

## Verification and excluded candidates

* Dev environment: `test_plugin_panel_context.py`, `test_plugin_panel_disconnect.py`, `test_extensions.py`: **79 passed in 13.15s**.
* Exact runtime-lock environment: context and disconnect test modules: **16 passed in 13.15s**; log `/tmp/locus-plugin-targeted-exact-lock-tests.log`.
* Root independently repeated the exact-lock TCP positive/negative controls (`/tmp/locus-panel-tcp-disconnect-root.json`, `/tmp/locus-panel-tcp-disconnect-root-negative.json`). Native auditor independently challenged the finding and confirmed its narrow cancellation scope in `/tmp/locus-plugin-disconnect-fp-check.md`.
* Real TCP production and bare negative controls both exited successfully with the divergent markers stated above. The earlier ASGI middleware test fails with publication committed and no cancellation marker, consistent with real TCP.
* Context spoofing through ordinary panel arguments, stale digest, undeclared panel ID, other panel hidden-tool access, oversized inputs/outputs, plugin disable, read-only retries, and task-required metadata forwarding have existing tests; no high-confidence bypass found in those paths.
* MCP Apps have their own view context fingerprint, tool/agent policy rechecks, native per-action confirmation, HTML sandbox and schema restrictions. No new MCPAppHost regression was found in this extraction; this was one-hop source review, not an exhaustive WebKit exploit audit.
* Native handoff `edits` preview is not retained as an authorization ceiling, but `agent/PROTOCOL.md:1744-1757` and `PluginPanelHandoffs` explicitly define authority as run-to-agent; existing saved-agent ceiling still applies. Independent native audit challenged the privilege-escalation interpretation. Excluded from confirmed findings; optional hardening is to retain max read/write scope so previews are less ambiguous.
* Resource-link/task provenance from a retained panel can inherit selected-chat runtime context. No concrete confidentiality breach beyond allowed server resources was demonstrated, so excluded rather than inflating findings.

## Coverage limits

No real OpenPost account or extracted external `locus-openpost` repository was exercised. No UI clicks or new Swift test run were performed by this subaudit; native verification is handled separately. No network fuzzing, OS sandbox testing, or complete installed-plugin inventory. The disconnect probe disables Uvicorn lifespan to avoid unrelated service startup/shutdown, while using the actual application, route/auth/middleware stack, TCP transport, and MCP runtime. All test fixtures use isolated temporary state and synthetic publications. Git status remained clean.
