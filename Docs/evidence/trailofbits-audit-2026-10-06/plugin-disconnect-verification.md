# Independent fp-check: plugin panel disconnect cancellation

## Claim and verdict

**TRUE POSITIVE as a production cancellation/control-lifetime defect.** The new handler's disconnect polling works in its bare FastAPI tests but fails under the real `create_app` middleware stack. A cooperative MCP tool continues past a cancellation point and performs a later synthetic publication after its HTTP connection is closed.

Security characterization is deliberately limited: this demonstrates continuing future side effects after close, not authentication bypass, arbitrary privilege escalation, or rollback of an already committed remote operation. A P1 rating is supportable for a broken stop boundary around publication tools; avoid wording implying unauthenticated access or proof of a real external publication.

## Evidence and verification phases

1. **Data flow complete:** native panel dismantle calls Coordinator.revoke, which cancels each pending Swift Task (`PluginPanel.swift:219,237-240`). Its `callTool` closure awaits `backend.post` (`:416-421`); BackendService.post awaits URLSession.data(for:request) (`BackendService.swift:140-159`). The new HTTP route (`api/extensions.py:651-671`) runs the synchronous MCP call in a worker thread and polls the request to set a threading.Event. The MCP worker checks that event through `revoked`, then `MCPManager.call_tool` cancels the future on `should_stop` (`mcp_runtime.py:823-825`).
2. **API/environment complete:** production `server.create_app` wraps routes in two function middleware layers (`server.py:3023-3024`), implemented with Starlette BaseHTTPMiddleware. Inspected exact-lock installed `Request.is_disconnected`: its already-cancelled AnyIO CancelScope awaits `_receive`. Inspected BaseHTTPMiddleware.receive_or_disconnect: receiving is nested in AnyIO task-group setup/checkpoints before reading the wrapped receive. The immediate cancellation prevents the downstream poll from observing disconnect. The HTTP handler is not automatically cancelled by Uvicorn solely because the client closes while computation continues.
3. **Reachability/concurrency complete:** test uses a real loopback TCP POST, production route, correct synthetic auth token, real MCP subprocess/tool, and production `create_app`. The client waits for the tool's `validation-started` marker, then calls SHUT_RDWR and closes its socket. Tool has a two-second await between start and synthetic publication. This is a concrete wide scheduling interval; no nanosecond race is required. No arbitrary unauthenticated caller is claimed.
4. **PoC and negative control complete:** inspected `/tmp/locus-panel-tcp-disconnect-probe.py` and the fixture it imports. The probe does not stub request.is_disconnected, thread stop logic, or MCP cancellation. Only the tool's side effect is synthetic (temporary marker). Exact runtime-lock results below reproduce the same difference. Negative control runs the same route/fixture under bare FastAPI; cancellation fires and publication is prevented. This refutes the explanation that MCP tools are inherently uncancellable or that publication occurred before disconnect.
5. **Devil's advocate complete:** authorization and plugin enablement are still checked, but those do not indicate the window remains open. Closing the panel does not disable the plugin, so that separate revocation mechanism does not catch the event. "An operation already sent may still finish" is a valid caveat for irreversible or uncooperative work; the same cooperative deferred operation demonstrably stops in the negative control, so it does not explain production's failure to signal cancellation. Tests omit middleware (`test_plugin_panel_disconnect.py:19-23`) and therefore do not establish production cancellation. No native NSWindow-close end-to-end run occurred; native cancellation linkage is source-backed and real HTTP disconnection is directly exercised.

## Exact-lock results

Files supplied by plugin_audit and independently read:

- `/tmp/locus-panel-tcp-disconnect-exact-lock.json`: bare=false, fastapi=0.141.1, starlette=1.3.1, anyio=4.14.2, uvicorn=0.52.0, mcp=2.0.0; validation_started=true, published_after_disconnect=true, cancelled=false.
- `/tmp/locus-panel-tcp-disconnect-exact-lock-negative.json`: same versions, bare=true; validation_started=true, published_after_disconnect=false, cancelled=true.

The earlier overlay-version results match. This independent reviewer read both probes/results and traced the code; plugin_audit executed them.

## Gate review

| Gate | Assessment |
|---|---|
| Process | Completed cross-component data/control trace, environment inspection, executable/negative evidence review, and counterarguments |
| Reachability | Real production authenticated HTTP route reached the real MCP future; client can cause disconnect |
| Impact | Confirmed synthetic write after close; possible deferred external publication uses same flow. Conventional RCE/privilege escalation not claimed |
| PoC | Production and negative control distinguish middleware failure from tool refusal to cancel |
| Bounds | No memory/integer arithmetic claim. Two-second cooperative await allows cancellation; negative control cancels within it |
| Environment | Exact pinned framework versions reproduce the failure; normal permission and plugin-scope checks do not detect panel close |

Recommendation: keep the finding with the narrowed impact above, cite the polling loop `api/extensions.py:663-666`, and add a regression using `server.create_app` with real ASGI/TCP disconnect semantics. Fix by ensuring the disconnect observer consumes a receive channel with reliable cancellation semantics (e.g. an ASGI-level tracker or bounded receive handling), without weakening authentication/body limits or retrying possibly executed writes.
