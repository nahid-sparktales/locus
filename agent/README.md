# ollama-code

A local coding agent powered by [Ollama](https://ollama.com). It ships as two
front ends over one agent core:

- **`ollama-code`** — an interactive terminal REPL.
- **`ollama-code-server`** — the REST + WebSocket service that Locus for
  macOS (the app in the repository root above this folder) drives.

Everything runs on your machine by default. No prompt, file, or model response
leaves it unless you deliberately point the agent at a remote endpoint — see
*Model providers*.

## Install

```bash
cd ~/Documents/locus/agent
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
```

This is only for working on the agent or using the REPL — the Locus app
bundles its own copy of the service with a self-contained Python, so app
users install nothing. The app's *fallback backend folder* setting expects
exactly this layout (`.venv/bin/python` plus the `ollama_code` package).

## Use it from the terminal

```bash
.venv/bin/ollama-code                    # interactive REPL
.venv/bin/ollama-code -p "explain app.py"  # one-shot, prints and exits
.venv/bin/ollama-code -c                 # resume the most recent session
.venv/bin/ollama-code --serve --port 8791  # run the GUI backend
```

## Tools the agent can call

| Tool | Permission | What it does |
| --- | --- | --- |
| `read_file` | automatic | Read a text file with line numbers, offset/limit paging |
| `glob` | automatic | Find files by pattern, newest first |
| `grep` | automatic | Regex search across the tree, vendor dirs skipped |
| `list_dir` | automatic | Directory tree to a chosen depth |
| `todo_write` | automatic | Maintain the visible task plan |
| `write_file` | asks | Create or overwrite a file |
| `edit_file` | asks | Replace one exact unique string |
| `multi_edit` | asks | Several edits to one file, all-or-nothing |
| `bash` | asks | Run a shell command in the workspace |
| `web_fetch` | asks | Fetch a URL as text |
| `git_status` / `git_diff` | asks | Inspect the working tree |

## Model providers

By default the agent talks to a local Ollama. It can also talk to Anthropic's
native API or any OpenAI-compatible endpoint — a Hugging Face Inference
Endpoint, the HF Inference Providers router, or vLLM/TGI on a rented GPU:

```bash
.venv/bin/ollama-code-server \
  --remote-url https://xxxx.us-east-1.aws.endpoints.huggingface.cloud \
  --remote-model meta-llama/Llama-3.1-8B-Instruct
```

The URL may be given with or without `/v1`. The API key is read from
`LOCUS_REMOTE_API_KEY`, `OLLAMA_CODE_API_KEY`, `HF_TOKEN`,
`HUGGING_FACE_HUB_TOKEN`, or `OPENAI_API_KEY`, or supplied by the app from its
credential file via `POST /api/provider`. **It is never written to
`config.json`** — `save_config` strips it — and no endpoint ever returns it;
`/api/provider` reports only `has_api_key`.

An API key may be sent over HTTP only to loopback (`localhost`, `127.0.0.0/8`,
or `::1`); every other authenticated endpoint must use HTTPS. Redirects are
refused rather than followed with credentials.

Endpoints that reject tool calling get one automatic retry without tools, and
the reply says so instead of failing.

`POST /api/provider` takes two optional fields alongside the endpoint. Both
follow the same rule as `api_key`: omitting one keeps the current value.

- `auth_style` — `bearer` (the default) or `anthropic`. The latter uses
  Anthropic's native Models and Messages APIs with `x-api-key` and
  `anthropic-version`. Left unset, it is inferred from the host. Anything
  unrecognized falls back to `bearer`.
- `account_label` — the app's name for the account in use, such as
  `Claude — Work`. Two accounts can share a host, so this is what tells them
  apart: it comes back in `provider_state` and `session_info`, and it is
  written into each session's `meta` record next to the provider. It is a
  display label, not a credential, and it is persisted; `use_ollama` clears it.

## Permission modes

| Mode | Behavior |
| --- | --- |
| `ask` (default) | Every write, command, and fetch asks first |
| `accept_edits` | File edits run automatically; commands still ask |
| `bypass` | Everything runs automatically (`--dangerously-skip-permissions`) |

Change it with `/permissions mode accept_edits`, or `POST /api/permissions`.
A deny list in `~/.ollama-code/config.json` hard-blocks destructive commands
(`rm -rf /`, `mkfs`, `dd if=`, fork bombs) in every mode — no answer overrides it.

## Slash commands

`/help` `/model` `/clear` `/compact` `/init` `/todos` `/tools` `/status`
`/sessions` `/resume` `/diff` `/retry` `/permissions` `/exit`

## Sessions

Transcripts are append-only JSONL under `~/.ollama-code/sessions`. Titles, pins
and archive flags live in `~/.ollama-code/session-meta.json`, so renaming a
session never rewrites its transcript. Clearing saved sessions **moves** them to
`~/.ollama-code/session-trash/<timestamp>/` with a manifest of their metadata;
`POST /api/sessions/restore` (or `SessionStore.restore_from_trash()`) puts them
back.

## HTTP API

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/health` | Service + model-backend reachability |
| GET | `/api/models` | Installed models, each with the window it will really run in |
| GET | `/api/sessions?include_archived=` | Session list with organizer metadata |
| POST | `/api/sessions/new` | Start a fresh session (`{"reason": "clear_chat"}`) |
| DELETE | `/api/sessions` | Move all but the active session to the trash |
| POST | `/api/sessions/restore` | Undo the most recent clear |
| GET | `/api/sessions/{id}` | Transcript, title, workspace, model, start time |
| PATCH | `/api/sessions/{id}` | Set `title`, `pinned`, `archived` |
| POST | `/api/sessions/{id}/resume` | Load a session into the agent |
| GET | `/api/tools` | Tool schemas |
| GET/POST | `/api/permissions` | Read or change the permission mode |
| GET/POST | `/api/provider` | Switch between local Ollama and a remote endpoint |
| GET/POST | `/api/config` | Model, host, working directory, context window |

### Context window

Ollama does not give a model the window it was trained for. Unless a request
sets `num_ctx`, Ollama sizes the window itself — 32k on current builds, or
whatever `OLLAMA_CONTEXT_LENGTH` says — however large a window the model
advertises. Budgeting a conversation against the trained window therefore
overflows the real one long before the agent thinks it is close: the prompt
crowds out the reply, a long tool call is cut off partway through its JSON
arguments, and Ollama rejects it with *unexpected end of JSON input*.

So the agent budgets against the window actually in use, which it reads back
from `/api/ps` once the model is resident rather than assuming a default. By
default it asks for nothing and lets Ollama size the window as it always has —
no forced KV-cache growth, and no evicting a runner that is already loaded.

Set `context_window` in `~/.ollama-code/config.json` (or `POST /api/config`) to
request a specific window instead; it is then sent as `num_ctx` on every request
and clamped to what the model was trained for. Raising it costs memory for the
KV cache. It is in tokens, not thousands — anything between 1 and 1023 is
refused, since a window that small cannot hold the system prompt. On an
OpenAI-compatible endpoint there is no equivalent knob, so `context_window`
there only gives automatic compaction a number to work against.

Within a turn, the window is guarded too: a turn that reads more than the
window holds gets its oldest tool outputs stubbed out in place (the session
file keeps the originals), and a tool call that is cut off by the window
mid-generation is retried once after making room instead of failing the turn.

`/api/models` reports both windows: `context_length` is the one in use and the
one to meter a session against — `0` when the model is not loaded and the answer
is genuinely not known — and `trained_context_length` is the model's maximum,
which is the number worth comparing models by.

## WebSocket protocol (`/ws/chat`)

Client → server: `user_message`, `retry_last`, `interrupt`,
`permission_decision`, `set_model`, `set_cwd`, `set_permission_mode`,
`new_session`, `clear`, `compact`, `resume`, `ping`.

Server → client: `session_info`, `session_started`, `message_start`, `token`,
`thinking`, `message_end`, `tool_call_proposed`, `permission_request`,
`tool_result`, `todo_update`, `turn_done`, `slash_result`, `error`, `pong`.

A turn runs in a worker thread; permission requests block that thread on a
future until the client answers, so the UI stays responsive and no tool runs
before the user allows it.

## Tests

```bash
.venv/bin/python -m pytest -q
```

202 tests cover the tools (including atomic `multi_edit` and the binary-file
guard), permission modes and the deny list, streaming and `<think>` filtering,
session metadata and trash recovery, the context window (that the number sent as
`num_ctx` is the same one compaction budgets against, and that it never reaches
the remote provider), the remote provider (URL normalization, bearer auth,
streamed tool-call assembly, the no-tools retry, and that the API key reaches
neither disk nor any response), the session, config, git, permissions and
provider HTTP endpoints, the WebSocket handshake, and the agent loop end to end
against a scripted model. The extensions surface — plugins, skills, MCP servers
and marketplaces — is covered at the unit level in `test_extensions.py`, but
most of its routes have no HTTP-level test yet.
