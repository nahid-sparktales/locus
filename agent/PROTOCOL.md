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
  "error": null
}
```

`ollama` is false (and `error` a string) when the Ollama daemon is unreachable.

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
unarchived defaults automatically.

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
  "reason": "clear_chat"
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

`reason` may be `clear_chat` or `new_session`. The previous session remains
available. Memory, todos, session permissions, interrupts, and token counters
are reset. A matching `session_started` WebSocket event is also emitted when a
client is connected.

### `POST /api/sessions/restore`

Body: `{ "batch": "<timestamped batch name>" }`; omitting `batch` restores the
newest recovery batch. Returns `{ "ok": true, "restored": <count> }`.
Traversal-like batch names are refused and existing session files are never
overwritten. Returns 409 while a turn is active.

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

Body: `{ "model": "<name>", "cwd": "<path>", "context_window": <int> }` — every
field optional. Response: same shape as `GET /api/config`. 422 for a bad `cwd`,
or for a `context_window` between 1 and 1023 (almost always a window written in
thousands); 409 for any state-changing config request while a turn is running.
The busy check is atomic and happens before any field is applied. Emits
`session_info` on the WS when anything changed.
`model` and `context_window` are persisted to `~/.ollama-code/config.json`.

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
  heartbeat traffic, and independent console operations remain accepted.

---

## 3. Client → server messages

| `type` | Extra fields | Effect |
|---|---|---|
| `user_message` | `text: string` | Runs one agent turn. If `text` starts with `/` it is executed as a slash command and ends with a `slash_result` event instead of `turn_done`. |
| `permission_decision` | `request_id: string`, `decision: "once" \| "always" \| "deny"` | Answers a `permission_request`. Unknown/invalid values are treated as `deny`. Late answers are ignored. |
| `interrupt` | — | Soft-interrupts the current turn: streaming stops after the current chunk, pending permission waits are denied, turn ends with `turn_done {reason: "interrupted"}`. Safe to send when idle. |
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
  "permissions": { "skip_all": false, "allowed": ["bash", "write_file"] }
}
```

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

### `message_start` / `token` / `message_end`
Assistant streaming. `token` carries `{ "type": "token", "text": "<piece>" }`;
concatenate `text` in order. `<think>...</think>` blocks are already stripped.
`message_start` and `message_end` have no extra fields. One
`message_start … message_end` pair wraps each model call, so a multi-tool turn
contains several pairs.

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

### `thinking`

`{ "type": "thinking", "text": "..." }` — native reasoning output, separate
from visible answer tokens. Provider-required continuation state (including
OpenAI-compatible `reasoning_content` and Anthropic thinking signatures) is
retained in the private session transcript but omitted from sanitized
REST/resume payloads shown to the UI.

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
`reason` is `complete` | `interrupted` | `max_iterations` | `error`.
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

Notes:

- Denied permission: `tool_result {ok: false, denied: true}` replaces execution;
  the model usually replies with text afterwards and the turn completes.
- `interrupt` mid-stream: current `message_start…message_end` pair closes, then
  `turn_done {reason: "interrupted"}` + `session_info`. Interrupt during a
  permission wait auto-denies it first.
- Tool-call arguments are **not** streamed; while the model generates long
  arguments no `token` events arrive.
- Slash commands: no `message_start`/`turn_done` (except `/init`, which runs a
  full agent turn internally); the turn ends with `slash_result`.
- History messages (from resume / `GET /api/sessions/{id}`) are sanitized:
  `{role, content, name?, tool_calls?}` where `content` is capped at 4000 chars,
  `name` is the tool name for `role: "tool"`, and `tool_calls` on assistant
  messages is a list of tool-name strings (not full call objects).

---

## 6. Tools the model can call

`read_file`, `write_file`, `edit_file`, `multi_edit`, `bash`, `glob`, `grep`,
`list_dir`, `todo_write`, `web_fetch`, `git_status`, and `git_diff`.
Workspace-contained `read_file`, `glob`, `grep`, `list_dir`, and `todo_write`
are permission-free. Everything else follows the selected permission mode.
Writes through a symlinked workspace component are refused; permission previews
show the resolved target when it differs. The shell deny list is a final
catastrophic-command guardrail, not a process sandbox.
Recursive reads never follow workspace symlinks. Individual text reads are
limited to 8 MB, directory scans and result lists are bounded, and fetched web
responses are limited to 2 MB after decompression. `web_fetch` never follows
redirects: the final URL must be approved explicitly. Stop requests interrupt
provider streams and long-running shell, git, search, directory, and web-fetch
operations cooperatively; spawned shell and git process groups are terminated.
