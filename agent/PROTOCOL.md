# ollama-code Server Protocol

Definitive reference for the FastAPI + WebSocket backend (`ollama_code/server.py`).
The server exposes the agent core (`ollama_code/core.py`) over:

- REST: `http://127.0.0.1:8791/api/...`
- WebSocket: `ws://127.0.0.1:8791/ws/chat`

Start it with:

```bash
.venv/bin/python -m ollama_code.server --port 8791 --model huihui_ai/qwen3-abliterated:latest
# flags: --host 127.0.0.1  --cwd <dir>  --dangerously-skip-permissions
```

All WS messages in both directions are single JSON text frames. All REST bodies
are JSON. Browser origins are denied by default. When the app launches the
bundled service it also sets a random per-launch capability; every REST request
and WebSocket handshake must then carry it as `X-Locus-Token`. Command-line
launches without `LOCUS_AGENT_TOKEN` retain origin protection but do not require
the header and are restricted to a loopback `--host`; a non-loopback bind is
refused unless the capability is configured.

---

## 1. REST API

### `GET /api/health`

```json
{
  "ok": true,
  "version": "0.2.2",
  "ollama": true,
  "host": "http://localhost:11434",
  "model": "huihui_ai/qwen3-abliterated:latest",
  "error": null,
  "capabilities": {
    "durable_runs": true, "recovery_controls": true, "evaluations": true,
    "adaptive_routing": true, "workspace_knowledge": true, "modern_mcp": true
  }
}
```

`ollama` is false (and `error` a string) when the Ollama daemon is unreachable.
Each additive orchestration stage has an independent
`LOCUS_CAPABILITY_<NAME>` rollout gate. Disabled REST collections return 404
and disabled model tools are omitted from their schemas; stored data is not
removed.

### Durable orchestrations

`GET /api/orchestrations` lists authoritative SQLite run records. `GET
/api/orchestrations/{run_id}` adds attempts and the latest stable checkpoint;
`GET /events?after_seq=N` returns the ordered suffix for reconnect backfill.
Every persisted event has immutable `event_id`, per-run monotonic `seq`,
`occurred_at`, `schema_version`, and optional job/attempt identity. Clients
deduplicate by `event_id`. The database uses WAL, foreign keys, transactional
additive migrations, and reopens read-only if a migration cannot complete.
Persisted user messages may carry an optional bounded `team_run_id`, allowing
clients to restore the durable run surface beside the request that originated
it. Older clients ignore the field.
`dispatcher_plan_rejected` is an additive diagnostic event with `stage`
(`initial` or `repair`), a bounded validation `reason`, `response_source`, and
`will_retry`. It never contains the raw model response or provider credentials.

`GET /api/orchestrations/{run_id}/export?include_content=false` produces the
redacted `locusrun` version-1 document. Conversation, goal, output, reasoning,
tool arguments/results, and previews are omitted unless content is explicitly
requested; credentials and provider signatures are always redacted.
`POST /api/orchestrations/{run_id}/otlp` accepts `{endpoint, authorization?,
include_content?}` and sends an OTLP/HTTP JSON trace without following
redirects. Remote endpoints require HTTPS. Authorization is transient and is
never written by the backend.

Recovery controls are `POST /pause`, `/resume`, `/cancel`, `/discard`,
`/jobs/{job_id}/retry`, `/jobs/{job_id}/reassign`, `/replay`, and `/duplicate`.
`POST /recovery-assessment` returns the current repair checklist without
starting work. `DELETE /api/tasks/{task_id}` is the separate, explicit managed
checkout cleanup action; discarding a run does not delete its checkout.
Resume/retry/reassign reuse a stable checkpoint only when the team/profile
fingerprint and managed baseline still match. Active jobs become new attempts;
completed independent specialist results may be reused. Writer mutations and
tool calls are never replayed. Replay creates a new checkout at the original
immutable baseline. Duplicate creates a new checkout from current source
workspace state. Startup only advertises abandoned runs and never calls a
model. Pending permission, computer, dispatch, and MCP-input waits are
cancelled and must be requested again.

### Evaluation Lab

`/api/evaluations` supports suite CRUD, result history, deterministic grading,
execution and cancellation. `GET /api/evaluations/{suite_id}/comparison`
groups Solo/team metrics and `/export` returns a portable versioned JSON suite
plus results. A case describes prompt/tags, Solo or team target,
mode, timeout, assertions, optional rubric and reviewer judge, and passing
score. A case may pin its own bounded orchestration budget; its timeout
cooperatively interrupts provider streams and cancellable tools. Solo cases
also acquire the shared cross-chat model lease. Assertions cover commands, required/forbidden paths, exact/contains/
regex text, allowed/forbidden changed paths, JSON pointer/schema checks, and
expected output. Required deterministic failures always fail before subjective
grading. A judge sees only the case, rubric, output, baseline-relative diff,
tests, and evidence—not provider/model identities—and its score is labelled
subjective.

Every Git-backed case captures an immutable private fixture when the suite is
saved, then replays each execution into a fresh disposable checkout. Evaluation changes are
never offered to Apply. Computer Control and mutating MCP are absent; read-only
MCP remains off unless the suite opts in, and annotations plus the agent policy
still gate it. Results report pass rate, rubric score, median/p95 latency,
calls, tokens, estimated cost, and retry/failure evidence through the existing
global scheduler.

### Workspace knowledge

`/api/knowledge` exposes status/settings, bounded search, reindex/full or
changed-path updates, and approved-memory CRUD. Each canonical workspace owns
a separate SQLite FTS5 database. Indexing follows Git ignores, refuses
symlinks, hidden/build/vendor paths, binary or over-2-MB files, and common
credential/key/certificate/environment-secret names. Content hashes make
workspace-open, native watcher, and Locus-mutation refreshes incremental.

Selecting a local Ollama embedding model creates a new vector generation and
uses only a loopback Ollama `/api/embed`; text search remains available if
embedding fails. Settings may add exclusion globs without weakening the hard
secret and symlink exclusions. `search_workspace_knowledge` returns bounded snippets with canonical
relative path, line range, freshness, and text/vector/approved-memory source.
Every result is labelled untrusted and cannot alter instructions, permissions,
or team membership. Memory is written only by explicit Remember, `/remember`,
or the memory editor. `DELETE /api/knowledge` removes index and memories only.

### Modern MCP catalogs, tasks, and input

MCP capability negotiation preserves legacy servers and conditionally adds
bounded deferred resources/prompts. The permission-free discovery tools are
`search_extension_resources`, `read_extension_resource`,
`search_extension_prompts`, and `load_extension_prompt`. Resources are
untrusted evidence. Prompts are untrusted instructions and require both server
and profile allowlisting. Lists are bounded and cached by server TTL.

Task-required tools persist remote task ID, run/job/tool-call origin, progress,
state, cancellation and terminal payload in the run database. `mcp_task_*`
events are ordered with their run. `GET /api/mcp/tasks` lists persisted tasks;
explicit `/lookup` and `/cancel` actions reconnect or terminate a selected
remote task and never run automatically at startup. Form elicitation admits only bounded,
schema-valid non-sensitive fields; password, token, API-key, payment and
credential-shaped fields are refused and must use a credential-free HTTPS URL
flow. The client replies with `mcp_input_response {request_id, action,
content?}`. Decline, timeout, cancellation, or disconnect produces a normal
terminal tool result. OAuth uses PKCE, exact callback scheme/host/port/path,
issuer metadata discovery and exact issuer validation, and never forwards
tokens to another origin.

An agent profile's `mcp_policy` has explicit `server_ids`, `tools`, `resources`
and `prompts` allowlists. Empty is no access. Read-only specialists,
dispatchers and reviewers can invoke only allowlisted tools annotated
read-only and non-destructive. Mutation remains writer-only and still follows
permissions and hard guardrails.

### `GET /api/models`

```json
{
  "models": [
    {
      "name": "qwen3.6:27b",
      "size": 17420432739,
      "parameter_size": "27.8B",
      "context_length": 32768,
      "trained_context_length": 262144
    }
  ],
  "current": "huihui_ai/qwen3-abliterated:latest"
}
```

`size` is bytes. `context_length` is the window the model is **actually running
in** — read back from Ollama once it is resident — and is what a session should
be metered against; it is 0 when that is not known, which includes any model
that is not currently loaded and any OpenAI-compatible endpoint.
`trained_context_length` is the window the model was built for, which is what to
compare models by; it is 0 when it cannot be determined. 502 if Ollama is down.

### `GET/POST /api/provider`

`GET` returns the current routing without credentials:

```json
{ "provider": "remote", "host": "https://api.anthropic.com/v1",
  "model": "claude-sonnet-5", "remote_base_url": "https://api.anthropic.com/v1",
  "remote_model": "claude-sonnet-5", "has_api_key": true,
  "account_label": "Claude — Work" }
```

`POST` accepts `provider: "ollama" | "remote"`. Ollama accepts optional `host`
and `context_window`. Remote requires `base_url` and accepts `api_key`, `model`,
`auth_style`, `account_label`, `lists_models`, `context_window`, and `verify`.
Omitting a credential or account field keeps its in-memory value; an explicit
empty key clears it. Keys are never returned or persisted. Anthropic uses its
native Messages API; other remote providers use OpenAI chat completions.
Authenticated non-loopback HTTP and every redirect are rejected. Errors: 409
busy, 422 invalid configuration, 502 verification failure.

### `GET /api/sessions`

```json
{
  "sessions": [
    { "id": "20260723-010948-123456-users-nahid", "name": "20260723-010948-123456-users-nahid.jsonl",
      "preview": "create a file …", "mtime": 1784783548.44, "size": 126216,
      "cwd": "/Users/me/project",
      "title": "Shipping checklist", "pinned": true, "archived": false }
  ],
  "current": "20260723-011732-users-nahid"
}
```

Query parameters:

- `limit` — 1–500, default 100.
- `query` — case-insensitive title, preview, or filename search.
- `include_archived` — include soft-archived sessions when true.

Pinned sessions sort first, then all remaining sessions by modification date.
`id` is the filename stem. Existing sessions receive empty-title, unpinned,
unarchived defaults automatically. `cwd` is optional for compatibility with
older sessions; clients may group missing values under an unassigned section.

### `DELETE /api/sessions`

Moves every saved session except the active session to a timestamped recovery
folder under `~/.ollama-code/session-trash/`.

```json
{
  "ok": true,
  "count": 12,
  "preserved_session_id": "20260725-212500-123456-users-me",
  "recovery_path": "/Users/me/.ollama-code/session-trash/20260725-220000-123456",
  "job_active": false
}
```

This endpoint returns 409 while the agent is busy, so a clear cannot race with
records being appended to the active turn. A `manifest.json` beside the
recovered JSONL files preserves identifiers and organizer metadata.

### `DELETE /api/sessions/{session_id}`

Moves one session and its organizer metadata into a uniquely named recovery
batch. If it is the active session, a blank replacement is created in the same
workspace before the old file is moved.

```json
{
  "ok": true,
  "id": "20260723-010948-123456-users-nahid",
  "trash_batch": "20260725-220000-123456",
  "deleted_active": true,
  "replacement_session_info": { "session_id": "20260725-220001-123456-users-nahid" }
}
```

Unknown IDs return 404, traversal-like IDs return 422, and deletion returns
409 while a turn or permission decision is active. Workspace files are never
part of the recovery batch.

### `GET /api/sessions/{session_id}`

```json
{ "id": "...", "messages": [ { "role": "user", "content": "..." } ],
  "preview": "...", "cwd": "/Users/me/project", "model": "qwen3:8b",
  "started": "2026-07-25T19:00:00", "title": "", "pinned": false,
  "archived": false }
```

`messages` are sanitized (see §4). 404 when the id is unknown; 413 when the
transcript exceeds the bounded file, record, or message-count limits.

### `PATCH /api/sessions/{session_id}`

Updates any supplied combination of `title` (string, max 120 normalized
characters), `pinned` (boolean), and `archived` (boolean).

```json
{ "title": "Release review", "pinned": true }
```

Returns the normalized metadata. The active session cannot be archived (409).
Invalid or unknown fields return 422. The atomic metadata sidecar is stored at
`~/.ollama-code/session-metadata.json`; conversation JSONL remains append-only.

### `POST /api/sessions/{session_id}/resume`

Loads the session into the live conversation. Body: empty (`{}`).

```json
{ "ok": true, "text": "Resumed ....jsonl (12 messages).",
  "messages": [ { "role": "user", "content": "..." } ],
  "session_info": { "...": "..." } }
```

Errors: 404 unknown id · 409 agent busy · 413 session safety limit exceeded ·
422 session file has no messages.
Also emits a `session_info` WS event to the connected client.

### `POST /api/sessions/new`

Creates a genuinely separate saved session and returns a direct acknowledgement:

```json
{
  "reason": "clear_chat",
  "cwd": "/Users/me/project"
}
```

```json
{
  "ok": true,
  "reason": "clear_chat",
  "session_info": {
    "session_id": "20260725-212500-123456-users-me"
  }
}
```

`reason` may be `clear_chat`, `new_session`, or a client-specific session reason.
The optional `cwd` must be an existing directory and makes the new session's
workspace explicit. The previous session remains available. Memory, todos,
session permissions, interrupts, and token counters are reset. A matching
`session_started` WebSocket event is also emitted when a client is connected.

### `POST /api/sessions/restore`

Body: `{ "batch": "<timestamped batch name>" }`; omitting `batch` restores the
newest recovery batch. Returns
`{ "ok": true, "restored": <count>, "session_ids": ["<restored-id>"] }`.
Traversal-like batch names are refused and existing session files are never
overwritten. Returns 409 while a turn is active.

### Managed team tasks

`GET /api/tasks/{task_id}` returns the task record, current tree, and complete
baseline-relative binary patch. `POST /api/tasks/{task_id}/apply` first runs a
complete `git apply --check`; only a clean check is applied to the source
workspace, unstaged and uncommitted. A conflict leaves the source untouched.
Successful application records the applied tree, so later rounds expose only
their new delta. Task IDs are bounded identifiers and traversal is refused.

Session summaries and details may include `task`, `team`, `workspace_root`,
`execution_path`, and `environment`. Details and resume responses additionally
include `agent_activities`, `orchestration_state`, `orchestration_run_id`, and
`worker_id`. Agent activity comes from separate append-only JSONL records and
never contains provider credentials or reasoning signatures.

### `GET /api/git/status` and `GET /api/git/diff`

`status` accepts `untracked=normal|all|no` and returns branch, repository state,
and changed files. `diff` requires a percent-encoded `path` and accepts
`staged`, `context`, and bounded `max_bytes`. Paths outside the workspace are
refused. Both are read-only and remain available during a turn.

### `GET /api/tools`

Returns the live tool names, descriptions, and JSON parameter schemas used for
model calls.

### `GET/POST /api/permissions`

`GET` returns mode, session/permanent allowances, safe tools, and the shell
deny list. `POST` accepts `mode: "ask" | "accept_edits" | "bypass"` and/or
`reset: true`; returns 409 while a turn is active.

### `GET /api/config`

```json
{ "model": "...", "host": "...", "cwd": "...", "max_iterations": 40,
  "context_window": 0, "session_info": { "...": "..." } }
```

`context_window` is the window to request as `num_ctx`; `0` means let Ollama
size it and read the result back. `session_info.context_limit` is what that
setting resolved to — the number compaction budgets against.

### `POST /api/config`

Body:
`{ "model": "<name>", "cwd": "<path>", "context_window": <int>, "max_iterations": <int> }`
— every field optional. Response: same shape as `GET /api/config`. 422 for a bad
`cwd`, for a `context_window` between 1 and 1023 (almost always a window written
in thousands), or for a `max_iterations` outside 1–1000; 409 for any
state-changing config request while a turn is running. The busy check is atomic
and happens before any field is applied. Emits `session_info` on the WS when
anything changed. `model`, `context_window` and `max_iterations` are persisted to
`~/.ollama-code/config.json`.

`max_iterations` caps the tool iterations in a single turn; reaching it ends the
turn with `turn_done` `reason: "max_iterations"`. A value that cannot be used
(absent, zero, negative, non-numeric) falls back to the default of 40 rather than
producing a turn that can take no action at all.

### `POST /api/context/reload`

Re-reads the workspace context files (`AGENTS.md` and friends) without
restarting the session. Response reports what was reloaded.

### Extensions: plugins, skills, MCP servers and marketplaces

The extension surface shares one error and concurrency contract:

- A rejected request raises `ExtensionError`, which becomes **HTTP 422** with
  the message in `detail` (`{"detail": "remote MCP URLs must use HTTPS"}`).
  Clients should render `detail`, not the raw body.
- The plugin, skill and MCP mutation routes run under `state_mutation()`, which
  returns **409** while a turn is in flight, the same rule `POST /api/config`
  uses. The three marketplace routes, `POST /api/extensions/mcp/test` and
  `POST /api/extensions/mcp/credentials` are **not** gated and are accepted
  mid-turn.
- Those gated changes refresh the tool registry and emit `extensions_changed`
  on the WebSocket, so clients re-read state rather than tracking it locally.
  The exception is `POST /api/extensions/mcp/credentials`, which emits
  `mcp_credential_refresh` with a `server_id` instead.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/extensions` | Full snapshot: plugins, skills, MCP servers, marketplaces, and any load `errors`. A non-empty `errors` means the lists may be partial. |
| GET | `/api/extensions/catalog` | Catalog entries; optional `query` and `marketplace_id` filters. |
| GET | `/api/extensions/catalog/trust` | Trust review of one catalog plugin before installing it. Requires both `marketplace_id` and `plugin` query parameters. |
| POST | `/api/extensions/marketplaces` | Add a marketplace source. |
| POST | `/api/extensions/marketplaces/{marketplace_id}/refresh` | Re-fetch one marketplace. |
| DELETE | `/api/extensions/marketplaces/{marketplace_id}` | Remove a marketplace. |
| POST | `/api/extensions/plugins/install` | Install a plugin from a catalog entry or source. |
| POST | `/api/extensions/plugins/enable` | Enable or disable an installed plugin. |
| POST | `/api/extensions/plugins/update` | Update a plugin to its newest version. |
| POST | `/api/extensions/plugins/rollback` | Restore the previously installed version. |
| DELETE | `/api/extensions/plugins/{plugin_id:path}` | Uninstall a plugin. |
| POST | `/api/extensions/skills/import` | Import a skill. |
| POST | `/api/extensions/skills/enable` | Enable or disable a skill. |
| DELETE | `/api/extensions/skills/{skill_id:path}` | Remove a skill. |
| POST | `/api/extensions/mcp` | Create or update an MCP server. `transport` is `"streamable_http"` or `"stdio"` — note the underscore. |
| POST | `/api/extensions/mcp/enable` | Enable or disable a server. |
| POST | `/api/extensions/mcp/test` | Probe a server's connectivity. |
| POST | `/api/extensions/mcp/reconnect` | Drop and re-establish a server's session. |
| POST | `/api/extensions/mcp/policy` | Set a server's default tool-approval mode. |
| POST | `/api/extensions/mcp/credentials` | Hand transient credentials to the agent. Secrets are held in memory only — the app stores them in its own credential file (`~/.locus/auth.json`, mode 0600, or the equivalent inside the app container in the sandboxed build) and replays them here. |
| DELETE | `/api/extensions/mcp/{server_id:path}` | Remove a server. Clients must also delete the matching credential-file entry. |

`stdio` transport is refused when the agent is sandboxed, so App Store builds
can only use remote servers.

---

## 2. WebSocket lifecycle

Endpoint: `/ws/chat`.

- **Single client.** A new connection closes and replaces the previous one.
- Replacing an old socket does not interrupt the turn owned by the new socket.
- On connect the server immediately sends one `session_info` event, then
  replays events queued while no socket was attached.
- On disconnect the server soft-interrupts any running turn and denies all
  pending permission requests (the turn then ends with
  `turn_done {reason: "interrupted"}` or a denied `tool_result`).
- **Busy rule:** while a turn (or slash command) is running, every command that
  would replace or mutate turn state is rejected with `command_error`
  ("Agent is busy — press Stop first."). This includes `user_message`,
  `new_session`, `retry_last`, `compact`, `resume`, `set_model`, `set_cwd`,
  `set_permission_mode`, and `clear`. Only `interrupt`, permission decisions,
  `steer`, native computer-action results, heartbeat traffic, and independent
  console operations remain accepted.

---

## 3. Client → server messages

| `type` | Extra fields | Effect |
|---|---|---|
| `user_message` | `text: string`, optional `mode: "ask" \| "work" \| "plan" \| "build"`, optional `attachments`, optional `team` manifest | Runs one solo or dispatcher-led team turn. Existing modes remain compatible. A team manifest contains one explicit team, its enabled profiles and ephemeral routes, optional forced member, and bounded budgets. Credentials are accepted only in memory and are never echoed or persisted. Slash commands and Chat mode reject team routing. |
| `permission_decision` | `request_id: string`, `decision: "once" \| "always" \| "deny"` | Answers a `permission_request`. Unknown/invalid values are treated as `deny`. Late answers are ignored. |
| `interrupt` | — | Soft-interrupts the current turn: streaming stops after the current chunk, pending permission waits are denied, turn ends with `turn_done {reason: "interrupted"}`. Safe to send when idle. |
| `steer` | `text: string` | Adds direction to the active turn. It interrupts only the current provider generation, waits for an already-running tool/native action to reach a safe boundary, and continues the same turn without an intermediate `turn_done`. |
| `set_computer_control` | `enabled: boolean`, `native_available: boolean` | Advertises the direct-build native broker. Computer tools enter model schemas only when both values are true. Rejected while a turn is busy. |
| `computer_action_result` | `request_id: string`, `result: object` | Completes one pending native broker request. `result` may contain `text`, `error`, and optional `screenshot` metadata/data. Late, duplicate, and unknown IDs are ignored after cancellation or timeout. |
| `set_browser_control` | `enabled: boolean` | Advertises the native browser broker. Browser tools enter model schemas only while true. Rejected while a turn is busy, so the client re-sends after `turn_done`. Unlike computer control there is no `native_available`: a web view needs no special access and is present in every build. |
| `browser_action_result` | `request_id: string`, `result: object` | Completes one pending browser request. `result` may contain `text`, `error`, and optional `screenshot` metadata/data. Late, duplicate, and unknown IDs are ignored after cancellation or timeout. |
| `set_model` | `model: string` | Switches model (substring match allowed). Emits `session_info` on success, `command_error` if rejected. Persisted to config. |
| `set_cwd` | `path: string` | Changes the agent working directory. Emits `session_info` on success, `command_error` otherwise. |
| `set_permission_mode` | `mode: "ask" \| "accept_edits" \| "bypass"` | Changes the permission mode while idle and emits `session_info`. |
| `clear` | — | Resets the conversation and todos. Emits `todo_update`, `session_info`, then `slash_result {command: "clear"}`. |
| `new_session` | — | Creates a different saved-session file and resets memory, todos, session permissions, interrupts, and token counters. Emits `session_started {reason: "clear_chat"}` followed by `session_info`. |
| `retry_last` | — | Creates a new branch through the latest user message, preserving the original session, then regenerates the response. Emits `session_started {reason: "retry"}` before streaming. |
| `compact` | — | Summarizes history to free context (runs as a background slash command). Ends with `slash_result {command: "compact"}`. Rejected when busy. |
| `resume` | `session_id: string` | Resumes a saved session. Ends with `slash_result {command: "resume", data: {messages: [...]}}`. Rejected when busy. |
| `terminal_run` | `command`, optional `cwd`, `run_id`, `timeout` | Starts one independent console command. It does not occupy the chat turn slot. |
| `terminal_input` | `run_id`, `text`, optional `newline` | Sends stdin to the active console command. |
| `terminal_close_stdin` | `run_id` | Closes that command's stdin. |
| `terminal_cancel` | `run_id`, optional `force` | Sends a graceful cancel, or a force kill when requested. |
| `ping` | — | Emits `pong`; used as an ordering sentinel. |

A team budget may include `call_budget_mode: "automatic" | "fixed"`.
`automatic` resolves to the bounded 100-call adaptive pool; `fixed` preserves
the supplied `max_model_calls`. Missing mode remains fixed for compatibility
with older clients.

Any other `type` produces
`command_error {operation: "<type>", message: "unknown message type: ..."}`.

---

## 4. Server → client events

Every event has a `type` field. Emitted types and exact fields:

### `session_info`
Sent on connect, after `set_model`/`set_cwd`/`clear`/`compact`/`resume`, and after
every `turn_done`.

```json
{
  "type": "session_info",
  "model": "...", "host": "...", "cwd": "...",
  "session": "/Users/me/.ollama-code/sessions/<file>.jsonl",
  "session_id": "<filename stem>",
  "messages": 7,
  "approx_tokens": 1234,
  "prompt_tokens": 0, "completion_tokens": 0,
  "max_iterations": 40,
  "has_project_context": false,
  "permissions": { "skip_all": false, "allowed": ["bash", "write_file"] },
  "worker_id": "per-process identity", "process_id": 1234
}
```

The macOS app keeps one control service and launches one additional local
service/WebSocket per running team chat. Worker identity is repeated on every
orchestration, job, and scheduler-lease event so background updates remain
scoped to the correct chat.

### `session_started`

Acknowledges that a genuinely different saved session is active. Clients should
only clear or branch their visible transcript after this event.

```json
{
  "type": "session_started",
  "reason": "clear_chat",
  "session_info": { "session_id": "20260725-190000-123456-users-me", "...": "..." }
}
```

`reason` is `clear_chat`, `retry`, or another server-defined session-start
reason. A retry copies history only through the latest user message; the source
session is never modified.

### `message_start` / `token` / `thinking` / `message_end`
Assistant streaming. `token` carries `{ "type": "token", "text": "<piece>" }`;
concatenate `text` in order. `<think>...</think>` blocks are already stripped.
`thinking` carries `{ "type": "thinking", "text": "<piece>" }`; concatenate
only explicit provider-supplied native reasoning or text from inline
`<think>`/`<thinking>` blocks, and apply one visibility setting to both.
Provider signatures and redacted reasoning are never sent.
`message_start` and `message_end` have no extra fields. One
`message_start … message_end` pair wraps each model call, so a multi-tool turn
contains several pairs.

### `plan_ready`

Emitted after the permission-free `submit_plan` tool succeeds. It is a final
plan-decision boundary, not a general progress event.

```json
{ "type": "plan_ready", "plan": {
  "id": "8f38c1d2d9a04bc1", "title": "Implementation plan",
  "summary": "...", "steps": ["..."], "tests": ["..."]
} }
```

The client presents Proceed, Revise, and Cancel only after the surrounding Plan
turn completes successfully. Reconnection replay preserves this event's order.

### `steer_ack` / `steer_applied`

`steer_ack {text, state}` accepts a steering message. `state` is
`interrupting_generation` or `after_current_action`. Later,
`steer_applied {text}` marks the safe boundary where the text was appended to
the same turn's user history. Multiple steers preserve receive order.

### `computer_control_status` / `computer_action_request`

`computer_control_status {enabled}` acknowledges the native capability
handshake. When enabled, a native tool call emits:

```json
{ "type": "computer_action_request", "request_id": "...",
  "tool": "computer_get_state", "arguments": {"app": "Safari"},
  "timeout_ms": 60000 }
```

The agent worker blocks for the matching `computer_action_result`. Exactly one
result is accepted per ID. The request fails after 60 seconds; `interrupt` and
socket teardown cancel all pending native requests immediately. Element IDs are
valid only for the latest Accessibility snapshot and must be refreshed after a
mutation. A screenshot result is an ephemeral newest-only observation; routes
that reject images are retried once without it and remain Accessibility-only
for the session.

### `browser_control_status` / `browser_action_request`

`browser_control_status {enabled}` acknowledges the browser capability
handshake. When enabled, a browser tool call emits:

```json
{ "type": "browser_action_request", "request_id": "...",
  "tool": "browser_read_page", "arguments": {"filter": "interactive"},
  "timeout_ms": 60000 }
```

The agent worker blocks for the matching `browser_action_result`. Exactly one
result is accepted per ID. `timeout_ms` is the client's budget — 60 seconds for
most tools, 120 for `browser_navigate` — and the worker waits eight seconds
longer than it, so a result delivered right at the client's deadline is still
collected rather than being dropped as a timeout after the action already
happened. `interrupt` and socket teardown cancel all pending browser requests
immediately, and cancellation also stops the load rather than only unblocking
the worker.

Element IDs are valid only for the latest `browser_read_page` snapshot and are
retired by navigation, by same-document routing, and by any in-place removal of
an element that snapshot named; acting on an older one returns
`Error: page changed; call browser_read_page again.` A screenshot result is an
ephemeral newest-only observation sharing one slot with computer control, and
routes that reject images fall back to text for the session.

Unlike computer control, a browser request from a background team worker is
served immediately and answered on that worker's own socket rather than being
held until the user opens its conversation: driving a web view takes nothing
away from the person at the keyboard.

### Team orchestration and scheduler events

- `orchestration_started` identifies `run_id`, `team_id`, `team_name`,
  `worker_id`, state, and the accepted hard budget.
- `dispatch_plan` carries the validated, acyclic job graph. It is emitted only
  after a required `submit_dispatch_plan` tool call, a normalized JSON candidate,
  one schema-aware repair, or the deterministic default-writer recovery.
- `dispatcher_plan_rejected` records the bounded validation reason and whether
  repair will be attempted. It deliberately omits the rejected model output and
  credentials. A second rejection explains the one-writer safe fallback.
- `orchestration_state` reports `dispatching`, `running`, `reviewing`, or a
  permission/computer wait. Steering cancels unstarted jobs and returns to
  dispatching without an intermediate `turn_done`.
- `agent_job_started`, `agent_job_stream`, and `agent_job_completed` identify
  the agent, exact provider/model, bounded goal, elapsed time, evidence, and
  usage. Only explicitly supplied `reasoning_text` is retained; signatures and
  redacted reasoning are never exposed. Stream chunks are not persisted.
- Ordered writer attempts add `writer_job_id`, `writer_position`, and
  `writer_total`. `agent_job_continuing` reports another bounded slice of the
  same coding job. `agent_job_incomplete` reports a checkpointed, paused job
  with its bounded reason, calls used, and applicable limit; it never counts as
  completion.
- `scheduler_lease_waiting`, `scheduler_lease_acquired`, and
  `scheduler_lease_released` expose the authenticated local model-call lease.
  Leases are shared across worker processes, round-robin by run, heartbeat
  while held, and reclaimed after expiry or process failure.
- `task_ready`, `task_changes`, `task_state`, and `task_applied` carry the
  managed checkout record and baseline-relative change state.
- `orchestration_completed` is terminal for the orchestration but not the chat;
  exactly one `turn_done` follows it. A recoverable budget boundary emits
  `orchestration_paused` instead, followed by `turn_done` with the exact limit
  reason. `interrupt` cancels every job in the run.

Persisted variants add `event_id`, `seq`, `occurred_at`, `schema_version`, and
when applicable `attempt_id`. `orchestration_checkpoint`,
`orchestration_recovery_available`, `dispatch_plan_ready`, `routing_decision`,
`evaluation_*`, `knowledge_indexing`, `mcp_task_*`, and `mcp_input_required`
are additive. Older clients may ignore all unknown events and fields.

Dispatchers and read-only specialists receive no mutation, MCP, extension, or
computer schemas. Specialists cannot recursively delegate. Only a write-capable
member assigned to the current ordered coding job enters the existing
permission-controlled agent loop. Coding jobs share a checkout but never
overlap. Computer Control remains foreground-only and globally exclusive in the
native broker.

### `tool_call_proposed`
The model asked to run a tool. Always emitted before any `permission_request`
or `tool_result` for the same call.

```json
{ "type": "tool_call_proposed", "id": "a1b2c3d4e5", "tool": "bash",
  "summary": "$ python3 hello.py", "detail": "python3 hello.py", "auto": false }
```

`id` (10 hex chars) correlates this call across all later events. `auto` is true
when the tool runs without asking (safe tools `read_file`/`glob`/`grep`/`list_dir`,
tools previously allowed with `always`, or `--dangerously-skip-permissions`).

### `permission_request`
Only when `auto` is false. The turn blocks until a `permission_decision` arrives.

```json
{ "type": "permission_request", "request_id": "ab12cd34ef56", "id": "a1b2c3d4e5",
  "tool": "write_file",
  "preview": { "summary": "write /tmp/x.py (3 lines)", "detail": "print('hi')" } }
```

`request_id` (12 hex chars) is what `permission_decision` must echo back;
`id` matches the `tool_call_proposed`.

### `tool_result`
Exactly one per `tool_call_proposed` (after permission, if any).

```json
{ "type": "tool_result", "id": "a1b2c3d4e5", "tool": "bash",
  "summary": "$ python3 hello.py", "result": "hello from gui",
  "ok": true, "denied": false }
```

`ok` is false when the tool returned an error string; `denied` is true (with
`ok: false`) when the user refused permission.

### `todo_update`
`{ "type": "todo_update", "todos": [ { "content": "...", "status": "pending" } ] }`
— `status` is `pending` | `in_progress` | `completed`. Emitted after every
`todo_write` tool call and on `clear`.

### `workspace_changed`

`{ "type": "workspace_changed", "reason": "tool", "tool": "edit_file" }` —
follows a successful mutating tool result so clients can refresh file and git
views without changing the active inspector tab.

### `note`
`{ "type": "note", "text": "...", "error": false }` — advisory commentary on
the turn in progress: automatic compaction, mid-turn eviction of old tool
output, the model hitting its output limit, or a retry after a tool call was
cut off by the context window. `error` is optional and defaults to false.
Clients render notes as inline system lines; they never change turn state.

### `turn_done`
Ends a turn started by `user_message` (non-slash input).
`reason` is `complete` | `interrupted` | `max_iterations` |
`model_call_budget` | `error`. Limit outcomes add `iteration_limit` and/or
`model_call_limit`, plus the model calls used, so clients name the boundary that
actually ended the turn.
A `session_info` event follows immediately.

### `command_error`
`{ "type": "command_error", "operation": "set_model", "message": "..." }` —
rejects a client command without changing the active turn's lifecycle. Clients
must not clear their busy state when this event arrives.

### `error`
`{ "type": "error", "message": "..." }` — a failure inside the active agent
turn. It is followed by `turn_done {reason: "error"}`.

### `slash_result`
Ends a slash command (`/help`, `/model`, `/clear`, `/compact`, `/init`,
`/todos`, `/status`, `/sessions`, `/resume`, `/permissions`, `/exit`) sent via
`user_message`, and the WS `clear`/`compact`/`resume` messages.

```json
{ "type": "slash_result", "command": "resume",
  "text": "Resumed ....jsonl (12 messages).",
  "data": { "messages": [ { "role": "user", "content": "..." } ] },
  "error": false }
```

`text` may be absent; `data` is command-specific (`messages` for resume,
`todos` for todos, `sessions` for sessions, `summary` for compact, full
session-info fields for status). `error: true` marks failures.

### Console and heartbeat events

- `terminal_state {runs: [...]}` is sent on every WebSocket connection.
- `terminal_started` carries `run_id`, command, cwd, pid, shell, timeout,
  `started_at`, and `resumed`.
- `terminal_output` carries `run_id`, monotonically increasing `seq`, `text`,
  and optionally `gap` on reconnect replay.
- `terminal_exit` carries `run_id`, nullable `exit_code`, signal, reason,
  duration, truncation, and byte counts.
- `terminal_error` carries `run_id`, stable `code`, and `message`.
- `pong` has no additional fields.

---

## 5. Event ordering

Typical agentic turn with one guarded tool call:

```
session_info                       (on WS connect only)
message_start
token × N
message_end
tool_call_proposed    {id: X, auto: false}
permission_request    {id: X, request_id: R}     ← client replies permission_decision {request_id: R}
tool_result           {id: X, ok: true, denied: false}
[todo_update]                      (only after todo_write)
message_start                      (model continues after tool result)
token × N
message_end
turn_done             {reason: "complete"}
session_info
```

Typical team turn:

```
orchestration_started
scheduler_lease_waiting/acquired/released       (dispatcher)
dispatch_plan
agent_job_started/completed × N                 (read-only waves may overlap)
agent_job_started {writer_job_id, writer_position, writer_total}
message/tool/permission events × N              (ordinary permission loop)
agent_job_completed {writer_job_id, writer_position, writer_total}
… repeated sequentially for each coding job; writers never overlap
orchestration_state {state: "reviewing"}
agent_job_started/completed × N                 (baseline-relative review)
[writer revision round]
agent_job_started/completed                     (dispatcher synthesis)
task_changes
orchestration_completed
task_state
turn_done
session_info
```

With dispatch preview, `dispatch_plan_ready` is persisted before the server
enters `waiting_dispatch_approval`; no jobs start until `dispatch_decision`
chooses Run Plan. That single decision releases the complete validated graph;
there is no dispatch decision per model, agent, job, or step. The native Locus
client always requests preview, including for teams previously stored as
automatic, while the protocol retains automatic mode for other clients. Tool
permission requests remain independent. Every edit or re-dispatch is fully
revalidated. With recovery,
an `orchestration_checkpoint` follows validated dispatch and each terminal
specialist wave, coding job, review, Lead Writer revision, and synthesis
boundary. Coding checkpoints add `completed_writer_job_ids` and bounded
`writer_results`; older clients may ignore both. Pause waits
for a safe boundary: streams and cancellable tools stop cooperatively, while a
non-cancellable action finishes before its checkpoint is marked.

Notes:

- Denied permission: `tool_result {ok: false, denied: true}` replaces execution;
  the model usually replies with text afterwards and the turn completes.
- `interrupt` mid-stream: current `message_start…message_end` pair closes, then
  `turn_done {reason: "interrupted"}` + `session_info`. Interrupt during a
  permission wait auto-denies it first and cancels a pending native request.
- `steer` mid-stream: `steer_ack` is sent first, the current
  `message_start…message_end` pair closes, then `steer_applied` precedes the next
  `message_start`. There is no intermediate `turn_done`. During tool execution,
  the tool's terminal `tool_result` comes before `steer_applied`.
- Stop & Send is a client ordering rule: send `interrupt`, wait for the old
  turn's terminal `turn_done`, then send a fresh `user_message`.
- Tool-call arguments are **not** streamed; while the model generates long
  arguments no `token` events arrive.
- Slash commands: no `message_start`/`turn_done` (except `/init`, which runs a
  full agent turn internally); the turn ends with `slash_result`.
- History messages (from resume / `GET /api/sessions/{id}`) are sanitized:
  `{role, content, reasoning?, name?, tool_calls?}` where `content` is capped at
  4000 chars, visible provider-supplied `reasoning` at 20000 chars, `name` is
  the tool name for `role: "tool"`, and `tool_calls` on assistant messages is a
  list of tool-name strings (not full call objects). Signatures and redacted
  provider blocks are omitted.

---

## 6. Tools the model can call

`read_file`, `write_file`, `edit_file`, `multi_edit`, `bash`, `glob`, `grep`,
`list_dir`, `todo_write`, `submit_plan`, `web_fetch`, `git_status`, and
`git_diff`. Workspace-contained `read_file`, `glob`, `grep`, `list_dir`,
`todo_write`, and `submit_plan` are permission-free. Everything else follows
the selected permission mode.

When native computer control is enabled and available, the schema additionally
contains `computer_list_apps`, `computer_get_state`, `computer_activate_app`,
`computer_click`, `computer_set_value`, `computer_type_text`,
`computer_press_key`, `computer_scroll`, and `computer_drag`. Listing and state
inspection are automatic. Mutations follow the global permission mode, except
high-consequence actions always ask and credential entry, password changes,
security interstitials, contracts, and final financial transactions are hard
blocked for user takeover even in Bypass.
When the browser broker is enabled the schema also contains `browser_read_page`,
`browser_get_text`, `browser_find`, `browser_screenshot`, `browser_wait_for`,
`browser_console`, `browser_network`, `browser_tabs`, `browser_navigate`,
`browser_input`, `browser_resize`, `browser_javascript`, and
`browser_dev_server`. The reading half is
permission-free and stays available to read-only agents, which is a deliberate
departure from computer control — a reviewer should be able to look at the page
it is reviewing. Everything else follows the permission mode, and
`browser_javascript` and `browser_dev_server` ask every time, Bypass included.
`browser_dev_server` is the one browser tool that never crosses the socket: the
agent process spawns and owns the server itself, applies the shell deny list to
its command, keeps a bounded output ring readable through `status`, and kills
every server at backend shutdown — a server otherwise outlives the conversation
that started it. Navigation is restricted
to `http`, `https` and `about`: a `file:` URL would otherwise read any file
without passing through `read_file`'s workspace scoping or its prompt. Typing a
credential is hard blocked on both sides — by content in the agent, and by the
field's own type, its autocomplete hint, and whether its form holds a password
in the app.

JavaScript dialogs never block the page: alerts are acknowledged, and an
unarmed `confirm`/`prompt` takes the safe branch — dismissed — with the outcome
folded into the triggering action's result. `browser_input` with action
`dialog` arms a one-shot answer for the next dialog on the tab; answering an
*open* dialog is structurally impossible, since it blocks the click that still
holds the broker's single execution slot. `window.open` and `target="_blank"`
become managed tabs owned by the opener's session. Files a page cannot render
download into the app's own container — size-capped, quarantined per file,
never executed, never the user's Downloads folder — and a page's file-upload
picker is always refused. Cookies are forgotten at quit unless the user opts
into the per-workspace persistent profile.

Page text, console output and network payloads are labelled untrusted external
data. Capture is JavaScript-level: `fetch` and `XMLHttpRequest` are recorded in
full, sub-resources appear as timing only, main-document status codes come from
the navigation delegate, and anything logged before the page's own scripts ran
is not recorded. Results are truncated to the same 30 000-character bound the
built-in tools use, because a session record over 2 MB is written and then
skipped on read.

Writes through a symlinked workspace component are refused; permission previews
show the resolved target when it differs. The shell deny list is a final
catastrophic-command guardrail, not a process sandbox.
Recursive reads never follow workspace symlinks. Individual text reads are
limited to 8 MB, directory scans and result lists are bounded, and fetched web
responses are limited to 2 MB after decompression. `web_fetch` never follows
redirects: the final URL must be approved explicitly. Stop requests interrupt
provider streams and long-running shell, git, search, directory, and web-fetch
operations cooperatively; spawned shell and git process groups are terminated.
