# Changelog

## Unreleased

### Added

- **Permission approval moved into the composer**, the way Claude Code and
  Codex ask. While a tool waits, the input is replaced by a prompt with the
  tool, a preview of what will run, and a keyboard-first option list —
  **1** Yes, allow once · **2** Yes, and don't ask again for that tool this
  session · **3** No, and tell Locus what to do differently. `↑`/`↓` move,
  `↵` confirms, `Esc` denies, digits answer directly, and focus returns to
  the editor after any decision. The transcript's tool card keeps the status
  but no longer carries buttons.
- **Git quick actions in Changes**: stage, unstage, and discard per file
  (discard always confirms; untracked files move to the Trash instead of
  `git clean`), plus a commit area with **Draft with AI** — the staged diff
  goes to the local Ollama model, reasoning tags and fences are stripped,
  and the subject is capped at 72 characters; with no local model it falls
  back to a deterministic summary. Git runs directly in the workspace with
  literal pathspecs and a watchdog timeout; stderr surfaces in the toast.
- **Find in conversation** (`⌘F`): a search bar over the transcript with a
  live `n of m` count, `↵`/`⇧↵` navigation with wrap-around, `Esc` to close,
  and scroll-to-match with the current match outlined.
- **A thinking view mode** for the transcript — `/thinking
  hidden|collapsed|expanded`, also in the workspace `…` menu. Hidden shows
  answers only (with a minimal "Thinking…" line while a reply is still all
  reasoning), Collapsed keeps the expandable cards, Expanded pins every card
  open. Persisted with the other settings.
- **Show/Hide Sidebar** (`⌘0`), and the sidebar's state now persists across
  launches like the inspector's. Defaults follow Claude's layout: the session
  sidebar starts open, and the right-hand inspector starts collapsed — the
  conversation gets the room, and `⌘1`–`⌘5` or `⌘⌥I` bring the panel back.
- **Model recommendations now consider this Mac's memory.** The Hugging Face
  library used to pre-select Q4_K_M no matter what — which put a 22 GB model
  on a 32 GB machine, where it starved the context window until tool calls
  were cut off mid-generation. The pre-selected quantization is now the best
  one that comfortably fits the machine's unified memory, every variant card
  carries an honest badge (RECOMMENDED / TIGHT FIT / TOO LARGE), the header
  states the Mac's memory, and the download panel warns — without blocking —
  before a tight or oversized download. The post-install toast repeats the
  warning, and Settings → Status now shows Ollama's own error text (a model
  too large to load, a dead server), which was captured and displayed
  nowhere. The `ollama-code` backend gained the matching resilience: old
  tool outputs are evicted in place when a single turn outgrows the window,
  and a tool call cut off mid-generation is retried once after making room
  instead of failing the turn.

### Changed

- **The app is now fully self-contained — no Python install required.** The
  build embeds a relocatable CPython from python-build-standalone (3.14.6)
  together with the agent's dependencies, replacing the old copy of the
  build machine's Homebrew Python, which kept resolving its dylib and
  standard library from `/opt/homebrew` and made the shipped app require
  `python@3.14`. The first build downloads and checksum-verifies the
  interpreter (~26 MB) into a reusable `.agent-runtime/` cache;
  `LOCUS_BUNDLE_MODE=venv` restores the old behavior, `skip` bundles
  nothing. The bundled runtime is pruned (tests, tkinter, pip, headers) and
  pre-compiled so first launch doesn't byte-compile from the read-only
  bundle.
- **App and agent now live in one repository.** The `ollama-code` service
  moved from the separate `ollama-code-cli` checkout into `agent/`, the
  bundling scripts default to it, and the default fallback backend folder is
  now `~/Documents/locus/agent`. The product site is no longer nested in the
  checkout.

- **The context meter tells the truth.** It measures against the same
  `context_limit` the agent budgets compaction with (falling back to the
  model list), estimates growth while a reply streams instead of freezing
  mid-turn, and no longer double-counts the context pack — included files
  are already inside the session count after each send. With no known
  window — remote endpoints do not advertise one — the chip shows the token
  count plainly instead of a percentage of an invented 32k window; the
  popover's pack row now reads "Context pack (next send)".
- **Test Connection is side-effect free.** It probes the endpoint directly
  with the values as typed. It used to save the settings draft, write the
  API key to the keychain, and switch the live agent's provider — all of
  which survived Cancel and made the following Save skip its reconnect.
- **The agent now budgets against the window Ollama actually serves**
  (fixed in the `ollama-code` backend): it reads the loaded window back
  from `/api/ps`, an optional `context_window` setting pins `num_ctx`
  explicitly, and `/api/models` reports the window in use separately from
  the trained maximum. The model picker's "ctx" figure now shows the
  trained window — the number to compare models by — while the meter keeps
  measuring against the window in use.

### Fixed

- **`/compact` crashed the app** — it re-entered the slash-command matcher
  and recursed until the stack overflowed. Forwarded commands now bypass
  local matching.
- **A permission request without a request id locked the app** — send,
  Clear Chat, and New Session all disable while a request waits, and one
  that cannot be answered kept them disabled forever. Such requests now
  surface as errors instead of arming that state; `turn_done` sweeps any
  card still waiting; requests attach to the newest matching card; the
  in-place upgrade now triggers the auto-scroll that used to leave the
  prompt off-screen; and clearing the chat re-checks for a request that
  arrived while the confirmation alert was open.
- **The console could be bricked by a disconnect** — only a backend event
  cleared its running state, and after a drop none was coming. The command
  field now recovers, and cancelling against a dead socket says so.
- **A transient git error emptied the Changes list** and rendered "Nothing
  changed" over edits that still existed. The last known list is kept, with
  a stale-warning triangle in the header; a superseded refresh no longer
  clears the newer request's spinner.
- **Diff requests broke on legal filenames** — `&`, `+`, `=`, or `?` in a
  path truncated or corrupted the query. Requests now build through
  URLComponents, and the two force-unwraps in the URL builder are gone.
- **Draining the queue destroyed the draft**: a queued message that failed
  to send was written into the composer over whatever had been typed since.
  It returns to the head of the queue instead.
- **The slash popup could run a command you never saw** — arrow keys walked
  the selection past the eight rendered rows. The list is now capped where
  the selection walks it.
- **Stop reported success even when the interrupt never left the app**; it
  now says the agent is unreachable and leaves cleanup to the reconnect
  path. Orphan tool results synthesize a card instead of vanishing.
- **Quitting or changing the backend URL froze the app for up to four
  seconds** waiting for the old backend child to exit. The restart path
  waits off the main thread; quitting waits half a second, then SIGKILLs.
- One missing field in `session_info` silently disabled workspace tracking,
  the file index, and permissions display at once — session, model, and
  history decoding is now tolerant, so a single absent field can no longer
  nil the whole struct (or fail an entire resume on one null tool message).
- The home directory can no longer be recorded as a recent workspace by
  typing before the agent connects.
- The preview's WKWebView no longer uses the private `drawsBackground` KVC
  key, which would crash uncatchably if WebKit renamed it.
- Dead code removed (`changeBlocks`, the unused provider verifier); the
  context-pack folder expansion reuses the shared file-type lists, fixing a
  drifted skip list that missed `.venv`.

### Product site

- **A site for Locus**, in `website/`: one server-rendered page covering the
  workspace, the three work modes, the principles behind the app, the
  inspector, and model selection. Next 16 on vinext, served as a Cloudflare
  Worker. Its test renders the compiled worker in-process and checks the
  finished page — including that the starter template's placeholder copy is
  gone — rather than trusting the build to have succeeded.
- The site is a separate git repository nested inside this checkout, so none of
  it ships with the app and the release build never sees it.
  `website/README.md` covers running, testing, and deploying it; this
  repository's README gained a section pointing at it, and at the copy there
  that has to be re-checked against each release.

## 1.5.1 — 2026-07-27

### Fixed

- **The Changes panel could hang the app.** Opening a real, file-sized diff —
  around 250 lines was enough — pegged the main thread at 100% and stopped the
  window responding at all. The diff's lazy stack sat directly inside the file
  list's lazy stack, so the two re-estimated each other's height forever. The
  diff now scrolls inside its own bounded height, which the list can rely on.
  A second layout trap in the same view is gone too: diff rows no longer sit
  inside a horizontal scroll view, which proposed an unbounded width to rows
  that asked to fill it.
- **The Files browser could come up empty** and stay that way until you pressed
  refresh. Two scans starting close together — the tab appearing and the agent
  reporting a session — cancelled each other, and a cancelled scan threw its
  result away with nothing scheduled to try again.
- Locus no longer indexes your home directory at launch. Before the agent
  reports a workspace there is nothing meaningful to scan, and that walk was
  discarded moments later anyway.
- The Changes tab badge now dims once you have looked at it, instead of staying
  coral forever. The unseen-changes state existed but no view ever read it.

### Documentation

- The README's claims were checked against the source and corrected. The
  notable ones: the packaged app needs the exact Python installation it was
  built against (Homebrew's `python@3.14`), not merely "Python 3.10+"; the
  `Origin` check is a speed bump rather than a wall, since browsers omit the
  header on simple GETs and the service does not validate `Host`; **Always
  Allow** grants a tool everywhere on disk, not only inside the workspace; and
  automatic compaction applies to local Ollama models, which are the ones that
  advertise a context window.
- New screenshots of the workspace, the Changes tab, the Files browser, and the
  console.

## 1.5.0 — 2026-07-27

The right-hand inspector was the one column that could not be hidden, resized,
or trusted. This release rebuilds it.

### Added

- **Console tab.** Run shell commands in the workspace and watch the output
  stream in. Cancel a running command, and answer a `y/n` prompt with a line of
  input. Commands run alongside a conversation rather than blocking it, and
  survive a brief disconnect. It is deliberately not a full terminal:
  interactive programs like `vim` and `top` will not work, and the empty state
  says so.
- **Files tab.** Search the workspace, peek at a file inline, and add it to the
  context pack, mention it in the composer, reveal it in Finder, or copy its
  relative path.
- **Resize and remembered state.** Drag the inspector's left edge to any width
  between 280 and 520 points, or double-click it to reset. The width, the
  collapsed state, and the last open tab persist across launches.
- **Collapse.** `⌘⌥I` or the button in the tab strip hides the inspector
  entirely; a restore control appears in the workspace header, mirroring the
  left sidebar.
- `⌘1`–`⌘5` select Plan, Changes, Files, Console, and Preview.

### Changed

- **Changes now shows what actually changed on disk.** It read the current
  chat's tool calls before, so clearing the chat emptied it, resuming an older
  session lost its edits, and anything you edited outside Locus never appeared.
  It now reads the workspace's git status: real staged and unstaged files with
  per-file diffs, refreshed when the agent edits something, when a console
  command finishes, and on demand.
- **A run no longer yanks you between tabs.** Tool calls and plan updates used
  to switch the inspector under you mid-run; they now raise a badge on the tab
  and leave you where you were.
- The tab strip is 44pt instead of 72pt and is icon-first, showing labels only
  when the panel is wide enough to fit them. The footer, which duplicated the
  model name and token count already in the workspace header, is gone — the
  Ollama status dot it carried moved into the header's context meter.
- The minimum window width is 1120pt so a widened inspector and an open sidebar
  both fit.
- Settings written from a view (including the Preview URL) now actually
  persist; previously only settings changed by the agent were saved.

### Agent backend (ollama-code 0.3.0)

- `GET /api/git/status` and `GET /api/git/diff` report the working tree and
  per-file diffs. Both work while a turn is running, and a non-repository
  answers 200 with `is_repo: false` rather than an error.
- Console runs stream over the existing socket (`terminal_run`,
  `terminal_input`, `terminal_cancel`) on their own threads, so they never
  occupy the conversation's turn slot. The deny list applies to typed commands;
  output is throttled at the source and recorded to the session, and console
  input is never written to disk.
- Session appends are now lock-protected, since the console added a second
  writer thread.

## 1.4.0 — 2026-07-27

### Added

- **Remote models.** Settings can now point Locus at any OpenAI-compatible
  endpoint instead of local Ollama: a Hugging Face Inference Endpoint, or
  vLLM/TGI on a rented GPU. Enter the URL, the model name, and an API key,
  then use **Test Connection** to confirm the endpoint answers before sending
  a message. Endpoint URLs are accepted in any shape (with or without `/v1`,
  or the full `/chat/completions` path).
- The API key is stored in your login keychain and handed to the local agent
  in memory. It is never written to a config file, never returned by any
  endpoint, and only ever sent to the endpoint you configured. The agent can
  also pick it up from `LOCUS_REMOTE_API_KEY`, `HF_TOKEN`, or `OPENAI_API_KEY`
  when run from the command line.
- Endpoints that do not support tool calling get one automatic retry without
  tools, and the reply says so rather than failing.
- **Create a workspace** from the workspace menu, the command palette, or
  `/newworkspace`: name a folder and Locus creates it and opens it. The
  existing workspace chooser also gained macOS's New Folder button.
- The sidebar status pill reads "Endpoint ready" when a remote model is in
  use, so it is always clear where answers are coming from.

## 1.3.0 — 2026-07-27

### Changed

- The black icon rail is gone. Locus now has a single Claude-style left
  sidebar: brand and collapse control, a prominent New chat button, search,
  the conversation list, and a quiet footer with the workspace selector,
  connection status, and an overflow menu (Settings, Checkpoints, archived
  sessions, Clear saved sessions, Reconnect).
- Collapsing the sidebar leaves a restore control at the left of the workspace
  header.

### Agent backend (ollama-code 0.2.0)

- Session organizer metadata (title, pin, archive) is stored in a sidecar
  manifest, so renaming a conversation never rewrites its transcript.
- New endpoints the app already expected: start a fresh session, clear saved
  sessions into a recoverable trash folder (with an undo endpoint), patch
  session metadata, and read a session's workspace, model, and start time.
- Regenerate branches onto a new saved session, leaving the original intact.
- Permission modes — ask, accept edits, bypass — plus a deny list that hard
  blocks destructive shell commands in every mode.
- New tools: `multi_edit` (all-or-nothing multi-change edits), `git_status`,
  and `git_diff`. `read_file` now refuses binary files; `grep` and `glob` skip
  vendor directories and resolve against the workspace.
- Reasoning-model output arrives as its own `thinking` event instead of being
  mixed into the answer.
- Session ids can no longer collide when two sessions start in the same
  millisecond (this previously made a fast New chat or regenerate reuse the
  previous session's file).
- The runtime bundler and app no longer pin Python 3.12; they discover the
  interpreter, so newer Pythons bundle correctly.

## 1.2.0 — 2026-07-26

### Added

- Slash commands: type `/` in the composer for an autocomplete popup
  (`/clear`, `/model`, `/plan`, `/checkpoint`, `/export`, `/help`, and more);
  unknown `/commands` pass through to the local agent.
- `@` file mentions: type `@` to fuzzy-search workspace files, insert the
  path, and attach the file to the context pack in one step.
- Thinking blocks: `<think>`/`<thinking>` output from reasoning models renders
  as a collapsible "Thought process" card, live while streaming.
- Rich message rendering: fenced code blocks become copyable, language-tagged
  cards; headings and inline markdown render in finished responses.
- Diff-aware tool output: unified diffs in tool calls and the Changes
  inspector render with per-line add/remove coloring.
- Context-window meter: a usage ring in the header (with a token-detail
  popover) and a usage bar in the inspector footer.
- Message queueing: sending while a run is active queues the message and
  drains it when the turn finishes; queued chips can be removed.
- Rewind: right-click (or hover) a user message to rewind the conversation to
  that point and edit the message before resending.
- Esc stops the current run; ⌘/ opens a keyboard-shortcut reference;
  ⌥A switches to Ask mode; the rail's Sessions button collapses the sidebar.
- Command palette now supports ↑↓ navigation, ↵ to run, Esc and ⌘K to close.
- System notifications when a run finishes or a permission request arrives
  while Locus is in the background (toggle in Settings).
- The workspace header shows the current git branch; pinned sessions sort to
  the top of the sidebar.

### Fixed

- Streaming assistant bubbles are always finalized — a backend `error`, a
  missed `message_end`, or a dropped connection no longer leaves a forever-
  blinking cursor, a stuck busy state, or an unanswerable permission card.
- Arrow keys move the caret normally inside a multi-line draft; history
  recall only triggers on an empty composer, preserves the unsent draft, and
  resets cleanly when the recalled text is edited.
- Restoring a checkpoint from a different workspace no longer wipes the
  restored conversation; resuming a session clears the previous session's
  plan and transcript context.
- Session previews no longer show the internal mode/context prompt wrapper.
- The bundled agent's output pipe is drained (a chatty backend could
  previously deadlock), backend shutdown no longer depends on a window
  existing at quit, and all WebSocket client state is main-actor confined.
- Model library: cancelling a download is immediate and no longer shows a
  spurious error; overlapping searches and rapid model switches can no longer
  clobber each other's results; sharded GGUF sizes sum all shards; stalled
  downloads fail within minutes instead of hanging for a day; Ollama's own
  error message is surfaced when a pull cannot start.
- Create/refresh plan respects busy state and no longer overwrites the draft
  when disconnected; Clear Chat can no longer latch shut if the backend's
  acknowledgement is lost; an empty preview URL no longer opens a blank
  browser tab.
- UI tests are isolated from any live agent (seeded fixtures can no longer be
  replaced by real session data mid-test), launch with state restoration
  disabled, and match controls the way current macOS actually exposes them
  (MenuButton menus, sheet-style alerts, standalone switches).

## 1.1.2 — 2026-07-25

### Added

- Clear Saved Sessions in the sidebar, workspace menu, Locus menu, and command
  palette.
- Recoverable session storage under `~/.ollama-code/session-trash/`, including
  a manifest with the original organizer metadata.

### Reliability

- Clearing saved history explicitly preserves the active session, current
  conversation, backend connection, and any in-progress model job.
- The clear action refreshes only the organizer list and never restarts or
  reconnects the app.

## 1.1.1 — 2026-07-25

### Added

- Native Local Model Library for searching Hugging Face GGUF repositories,
  scanning quantizations and sizes, and downloading models through Ollama.
- Download progress, cancellation, automatic installed-model refresh, and
  one-step model selection.
- Model-library access from the workspace model picker, Locus menu, and command
  palette.

### Fixed

- Clear Chat now uses a direct request/response acknowledgement in addition to
  the existing WebSocket event, preventing missed events or reconnect timing
  from leaving the visible conversation unchanged.

## 1.1.0 — 2026-07-25

### Added

- Non-destructive Clear Chat with `⌘⇧K` and backend acknowledgement.
- Copy, Use as Draft, and Regenerate actions for conversation messages.
- Session titles, pins, soft archives, archived filtering, and Markdown export.
- Per-workspace profiles for model, mode, preview, draft, and context references.
- Persistent drafts and prompt-history navigation.
- Separate local-agent and Ollama availability indicators.

### Improved

- Assistant streaming is buffered to at most one UI update every 33 ms and
  renders lightweight text until completion.
- Conversation scrolling follows only when the reader remains near the bottom.
- Context packs load off the main thread, support up to 50 text files, expose
  skipped-file warnings, and refresh changed files before every send.
- Context budgets reserve 40% of the selected model window for conversation,
  tools, and output.
- Connections validate on the first backend event, use heartbeat checks, and
  reconnect after 1, 2, 4, 8, then 15 seconds.

### Fixed

- New Session now creates a different saved-session file instead of only
  clearing in-memory conversation state.
- Commands are no longer silently queued while the backend is disconnected.
- Existing checkpoints migrate from stored source contents to file references.
