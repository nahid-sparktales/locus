# Changelog

## Unreleased

### Changed

- **GSD mode retired; Grill mode takes its place.** The fourth composer mode is
  now Grill (⌥G, `/grill`): a relentless one-question-at-a-time interview that
  stress-tests a plan or idea using the built-in grilling skill, and never
  modifies anything until you confirm the shared understanding. Approving a
  plan now implements it in Work mode, which already carries GSD's
  end-to-end behavior. Everything saved under the old mode keeps working:
  stored workspaces and older mobile clients that still say "build" land on
  Work, and custom GSD instructions in an agent's per-mode guidance carry over
  to Grill. The Runs panel also gets its own icon — the three-node
  orchestration glyph now belongs to the team dispatcher alone.

### Added

- **Notebook gathers every note you have into one page.** The sidebar gear
  menu, the Locus menu (⇧⌘9), and the command palette open a searchable list of
  every note Locus has kept — one per workspace, one per chat, and the shared
  one — with any of them editable right there in the full notes editor. A note
  and its Notes-panel copy are the same document, so the two can never
  disagree. Notes are stored under a one-way hash of the workspace or chat that
  owns them, so Locus now records what each one is called while that owner
  still exists; notes written before this release are named where they can
  still be matched and grouped under "Unlinked" where they cannot.

- **Locus Vault is now an in-app Sepolia Wallet Hub for the private alpha.**
  Signed direct-download builds can review risks and enable the feature in
  Settings without Terminal setup, create or unlock the isolated vault,
  receive through a locally generated ERC-681 QR, refresh a locked-safe public
  balance, follow activity on Sepolia Etherscan, and copy redacted diagnostics.
  Agent budgets are now presented as spending rules with exact decimal
  ETH-to-wei input. Browser access remains a separate confirmed opt-in: Locus
  revokes pending work and origins before reloading tabs, publishes a frozen
  EIP-6963 provider with a fresh UUID per page, and still requires exact native
  confirmation for every website transaction. The Mac App Store build keeps
  all wallet gates forced off.

- **ChatGPT-plan chats now answer the way Codex does.** A new per-account
  "Codex-native mode" (on by default) runs Work, Plan, and Build turns under
  the model's own Codex prompt and Codex-shaped tools — `shell`,
  `apply_patch`, `update_plan` — instead of the Locus contract. The model
  keeps its trained voice, editing style, and workflow. Execution never
  leaves Locus: every call still runs through the same permission prompts,
  deny lists, and accept-edits behavior as before, and `apply_patch` previews
  render as a diff. In native mode those chats deliberately carry no approved
  memories, cross-chat context, or skill index — that is what "answers like
  Codex" means — and skipping that recall work also shaves time off every
  message. Ask mode, teams, evaluations, and Solo Swarm are unchanged. Turn
  the toggle off in the account editor to get the previous Locus-flavored
  behavior back; flipping it restarts the conversation's server-side context,
  and the first message of each existing ChatGPT chat after this update
  replays its history once.
- **Reasoning effort is now yours to set.** ChatGPT accounts gain a
  reasoning-effort picker fed by the account's own model list, so a chat can
  match the effort you use in Codex. It applies per turn — changing it never
  resets the conversation. Higher efforts consume plan quota faster.
- **Optional web search for ChatGPT chats.** A separate per-account toggle
  (off by default) lets Codex-native chats use OpenAI's web search the way
  Codex can. Turning it on sends search queries to OpenAI.

### Changed

- **New ChatGPT plans now answer with Locus's tools.** Adding a ChatGPT account
  starts it under the Locus contract — Locus's own prompt and tool registry,
  with approved memories, cross-chat context, and the skill index — instead of
  Codex-native parity. ChatGPT accounts you already added are untouched and
  keep answering exactly as they did; flipping that switch restarts a
  conversation's server-side context, so it stays your call. "Codex-native
  mode" is still one toggle away in the account editor, for either direction.

- **Reasoning and tool activity now stay in transcript order.** Collapsed mode
  uses quiet inline summary disclosures at each real activity boundary, while
  Expanded reasoning and Verbose tools retain their detailed cards. Each turn
  shows one Locus marker as soon as its first activity begins, and response
  actions remain with its final answer.

### Fixed

- **Notes whose plain-text mirror went missing are no longer loaded as empty.**
  Each note is kept as a plain `.txt` alongside a formatting archive, and a note
  that had lost the `.txt` opened blank — so the first keystroke saved that
  blank over the archive and took the text with it. The archive is now used
  when the mirror is absent, which restores those notes. Text genuinely cleared
  stays cleared.

- **UI test runs no longer read or write your real notes.** The suite drives
  the actual notes editor and had no separate storage, so a test run left its
  own documents in your notes folder. It now uses a temporary directory.

- **Switching models no longer reports a model you have as "not installed".**
  The agent checked every model switch against the list of *locally installed
  Ollama* models, even for a ChatGPT-plan account whose models do not live
  there — so moving between, say, `gpt-5.6` and `gpt-5.6-sol` failed with
  "model not installed" while the chat itself worked perfectly. Endpoints that
  do not publish a model list, such as Kimi Code, were stuck on whichever
  model they started with for the same reason.
- **Selecting text in the transcript works like text.** Selection was scoped to
  a single assistant answer segment, so a drag could not reach the next
  paragraph, let alone a question and its answer; scrolling threw the selection
  away, because the rows it covered were destroyed as they left the screen; a
  click anywhere cleared it before the transcript could interpret the click, so
  shift-click never extended anything; dragging through the empty margin beside
  a line jumped to whole-block selection; and a one-pixel wobble while clicking
  a link swallowed the click. One selection now spans the whole conversation,
  survives scrolling, extends the way a pointer suggests, keeps up with
  edge-scrolling, and leaves links clickable. Copy and Command-C return exactly
  what is highlighted, including passages that have scrolled out of view.
- **The floating Copy / Quote buttons are gone.** They appeared on every
  selection, fought with scrolling, and duplicated Command-C. Right-click still
  offers Copy and Search in Google.
- **Files the agent produces now open properly, and appear in Outputs.**
  Clicking a produced PDF used to raise an empty or unrelated Quick Look
  panel; it now opens in whatever app you use for that file type, and source
  files still open in the Files inspector. Outputs also stops missing work:
  the agent reports the files each tool created or changed, and Locus watches
  the workspace for anything a shell command wrote — so a PDF built by a
  script now shows up even in a folder that is not a Git repository or where
  the output is gitignored.
- **The Browser now follows the panel instead of acting like a zoomed canvas.**
  Resizing the inspector immediately resizes the live page, wide pages retain
  WebKit's native horizontal scrolling, and the always-visible magnification
  controls have been removed. Tabs and navigation now use a quieter,
  responsive toolbar, with less common page actions collected in one menu.
- `/compact` on a ChatGPT chat now also resets the helper's server-side
  thread. It previously kept the full uncompacted history, silently undoing
  the compaction on the next message.

## 2.0.0 — 2026-08-22

### Added

- **ChatGPT plan support is now a separate download.** The two OpenAI helpers
  behind ChatGPT-plan accounts are about 270 MB installed and do nothing at all
  unless you sign in to a plan, so they no longer ship inside the app. Locus
  offers them at the moment you add a ChatGPT-plan account and installs them
  once; anyone using Ollama, an API key or a custom endpoint never downloads
  them. The direct download drops from about 180 MB to about 62 MB. The
  component is signed by SparkTales and its signature is checked before it is
  put in place or run, so a payload that is not ours installs nowhere, and it
  can be removed again to reclaim the space. App Store builds are unchanged and
  still bundle the helpers, because the App Store does not permit downloading
  executable code.

- **The agent's clicks are now real input.** Actions were dispatched as
  JavaScript events the browser built itself, which carry `isTrusted: false`
  and no user gesture — so pages were free to ignore them, and many did. They
  are now delivered as the same `NSEvent`s AppKit hands the web view for your
  own clicks and keystrokes, hit-tested by WebKit rather than by us. Drag
  surfaces, gesture-gated controls and anything drawn into a `<canvas>` respond
  the way they do for a person. Scrolling arrives as a phased gesture aimed at a
  point, so the container under the pointer moves rather than always the
  document. Where real delivery is impossible the old path still runs, and the
  result says so rather than reporting a click that never landed. Settings ▸
  Browser can switch back to synthetic events, which cannot open a popup or
  start playback either.
- **Anything on the page can be aimed at by coordinate.** `browser_input` takes
  `at: [x, y]` in page pixels wherever it took a ref, and `browser_screenshot`
  takes a `region` to capture one part of the viewport up close. Every capture
  now reports the frame it is in — image pixels, the page pixels they cover, and
  the origin — so a position measured on a picture converts back into an action.
  Together these reach what the element tree cannot name: canvases, maps,
  drawing tools, custom widgets. A coordinate meets the same credential gate a
  ref does; the page is asked what sits under those pixels, and a password field
  is refused either way.
- **Every browser tool takes a `tab_id`.** A tab can be read, screenshotted and
  driven without pulling the view onto it, and a new tab opens in the background
  by default with its id in the reply. Naming a tab reaches only the calling
  session's own, so concurrent workers still cannot steer each other's pages.
- **A mobile viewport now presents a mobile device.** The phone preset — or any
  width under 768 — also serves a mobile user agent, five touch points,
  coarse-pointer and no-hover media queries, and translates mouse input to touch
  where WebKit allows it, so feature detection sees a phone instead of a narrow
  desktop. The reply says to reload, because a site decides what to serve at
  load time. The Browser toolbar shows when a tab is presenting itself this way,
  and Settings ▸ Browser can turn it off.
- **Dev servers can be named in `.locus/launch.json`.** A workspace lists its
  servers once — name, executable, arguments, port — and the agent starts one by
  name instead of rediscovering the command every session; `configurations`
  lists what is on offer. An entry with a `url` and no executable attaches to a
  server you already have running rather than fighting it for the port. Server
  output can be narrowed with `level`, `search` and `lines` instead of reading
  the whole ring.
- **Find in page and page zoom.** ⌘F searches the page WebKit's own way, with
  next and previous and an honest "Not found" rather than an invented match
  count; ⌘+, ⌘− and ⌘0 zoom the page, with the current percentage in the toolbar
  while it is not 100%. The viewport control is now a device menu carrying pixel
  dimensions, the mobile-device toggle and a light/dark switch that was
  previously only reachable by the agent.

### Changed

- **The bundled Codex helpers are stripped.** OpenAI's release profile keeps
  release binaries symbolicateable and defers stripping to whoever packages
  them — which Locus never did, so every download carried about 73 MB of symbol
  table that nothing at runtime reads. They are now stripped before signing,
  which also shrinks the App Store build.

- **`browser_input`'s `type` now types.** It sends real keystrokes into the
  focused element, so search-as-you-type and key handlers see each character
  arrive; `set_value` still replaces a field's value in one step, and still
  matches a `<select>` option by its visible label as well as by its value.
- **Web Inspector is a setting rather than a build flag.** Debug builds are
  unchanged; a release build can now opt in from Settings ▸ Browser, with the
  warning that any local process can then attach and read whatever has been
  browsed. It stays off by default.
- **The browser tool schemas cost about 350 more tokens.** Coordinates, region
  capture, per-tab targeting and device emulation are not free, and every prompt
  pays for them. Descriptions were trimmed to claw back as much as possible; the
  budget guard that keeps this from creeping was raised to match.

### Fixed

- **Streaming no longer stalls when the display sleeps.** Replies were flushed
  to the screen on the display's own refresh, which is the right clock for
  keeping text growth and scroll anchoring on one frame — but a `CADisplayLink`
  simply goes quiet when its display sleeps, is unplugged, or never existed,
  without cancelling itself or reporting anything. A flush waiting on the next
  frame then waited forever, and because a pending flush suppresses further
  requests, streamed text stopped appearing until something flushed directly.
  Every request now also arms a watchdog: whichever arrives first wins, the
  frame on a live display or the watchdog on a dark one. A link that has gone
  quiet is dropped and rebuilt against whatever display exists next, so the app
  recovers on its own when a screen comes back.
- **The browser can scroll on a Mac with no display attached.** Aiming a wheel
  event needed the height of the primary screen, so with the lid shut and
  nothing plugged in there was no screen to ask and the scroll silently fell
  back to the synthetic path. The coordinate flip is now measured out of AppKit
  itself rather than looked up, which is correct for any display arrangement,
  including none.

- **The Codex build cache no longer hands back the wrong architectures.** The
  cache's architecture check matched a substring, so a cache holding a universal
  `arm64 x86_64` build satisfied a request for `arm64` alone. An Apple-silicon
  release could therefore embed a helper twice the size it needed, depending
  only on what the last build had left in the cache. The check now matches the
  whole line.

## 1.16.0 — 2026-08-17

### Fixed

- **A provider account no longer sticks when the agent never took it.**
  Switching accounts committed the route before the agent accepted it, so a
  failed switch left the app pointing at the new account while every turn
  still ran on the old one — visible in the model picker as an account paired
  with another provider's model, such as "Kimi · gpt-5.6-sol". The setting is
  restored when the switch fails, and the picker resolves its model against
  the active account.

### Changed

- **Overview is now a pinned summary.** The Overview tab mirrors Codex's
  pinned summary: collapsible Plan, Outputs, Subagents, Background processes,
  and Sources sections, each present only while it has something to show, with
  the Context window card pinned beneath. Outputs lists files the agent
  created and local previews it started, with a "+" that inserts a
  document/presentation/spreadsheet/site prompt into the composer; Sources
  lists attached files, fetched links, MCP servers, and web search — first
  three plus "View all" — with a "+" for attaching files or opening Skills &
  MCP. The old status pill, activity feed, running-processes card, error
  banner, and quick-access grid are gone, so nothing lingers after a run.

## 1.15.0 — 2026-08-16

### Added

- **A built-in development workflow suite.** Task Observer and Superpowers now
  start automatically in Work, Plan, and Build chats, with global and
  workspace controls in Skills settings. Locus also bundles six lightweight
  GSD workflow routers, Matt Pocock's Grill Me and Grilling methods, pinned
  upstream provenance, and complete third-party notices. Just Chat keeps its
  existing no-tools privacy boundary.
- **Private continuity across development chats.** Encrypted, workspace-local
  rolling snapshots preserve goals, plans, checkpoints, changed files, final
  outcomes, and pending work without another model call. Settings can inspect,
  remove, or disable snapshots, and `$context-handoff` captures one explicitly.
- **Per-chat Notes.** Every chat has its own focused writing space in the right
  rail, directly below Browser, with a quick-tab shortcut and automatic local
  saving.
- **Local-model management.** Models can be removed from Locus without touching
  their files, or deleted from the Mac when their provider supports local
  removal. Browser preferences now live in their own Settings tab.

### Changed

- **GitHub MCP authentication is ready for GitHub App device flow.** Locus no
  longer attempts unsupported dynamic client registration against GitHub's
  remote MCP. Account connection uses GitHub's device flow when the release
  app is configured, validates the signed-in account, stores credentials in
  Keychain, refreshes expiring tokens, and retains personal-token fallback
  with clearer organization and permission errors.
- **Workspace navigation is calmer and more predictable.** Quick-tab hit areas,
  hover treatment, and selection affordances were refined. Settings is back in
  the bottom-left navigation, the duplicate menu beneath Notes is gone, and
  the vertical workspace actions menu sits above Overview.

## 1.14.0 — 2026-08-13

### Added

- **Direct-download builds now update themselves.** Locus checks the stable
  GitHub release feed daily, verifies signed feeds and archives with Sparkle
  plus Apple code signing, downloads updates in the background, and installs
  them when the app quits. Updates settings expose the automatic choices and a
  manual check. The Mac App Store target contains no updater and continues to
  receive releases through Apple. Existing installations need one final manual
  download of 1.14.0; later releases update automatically.

## 1.13.0 — 2026-08-09

### Added

- **Use included ChatGPT-plan access without an API key.** A separate,
  single-identity ChatGPT account opens OpenAI's managed browser sign-in,
  discovers available models, routes solo chats, teams, and evaluations, and
  shows plan rate limits plus token activity separately from API cost
  estimates. The existing stored `codex` account remains backward compatible
  and is now labelled **OpenAI API**. There is no dependency on an installed or
  running ChatGPT/Codex app, and the managed route never falls back to a
  billable API key.
- **A pinned Codex App Server bridge that keeps Locus in control.** Locus builds
  and signs OpenAI Codex `rust-v0.147.0` plus its companion code-mode host from
  checksum-pinned source and V8 inputs, isolates file-backed OAuth state, and
  exposes only Locus's current tools through dynamic tools and its existing
  permission system. A primary-backend broker multiplexes team workers without
  sharing OAuth credentials. Models, usage, interruptions, failures, thread
  resume, and provider-supplied reasoning summaries map into Locus's existing
  UI and transcript model; raw private reasoning is ignored.
- **Account fields and Settings handoff now behave naturally.** Clicking
  anywhere across Name, URL, API-key, or context-window rows focuses the field,
  and typing or pasting starts at the left and advances left-to-right. Browse
  Hugging Face Models dismisses either Settings presentation and opens the
  library immediately. The Browser's compact control bar now sits above its
  tabs, keeping tabs adjacent to the address bar they control.
- **The right rail and session list now say what they mean.** The general panel
  button restores the last workspace tab instead of accidentally reopening
  Plan or Browser, the expand arrow lives at the rail bottom, and the redundant
  Settings item is gone. Context & Plan for solo requests and Team Runs for
  team requests now have separate first-use explanations and independent
  automatic-opening choices; every prompt points back to General settings.
  Foreground browser tool use still opens Browser. Session rows use solo/team
  symbols with fill for the selected chat, and only running work shows an
  elapsed timer; idle chats show no stale activity time.
- **Composer and branding preferences.** First launch asks whether Enter or
  Command–Enter should send, points back to General settings, and remembers the
  answer. Shift–Enter keeps a newline and Command–Enter remains available. The
  in-app green mark now matches the site's side-by-side `//` artwork.

- **The browser got fast.** Three real defects made every page slow. Every
  navigation carried a forced hard-reload cache policy inherited from the old
  dev-server Preview pane — WebKit propagates it to every subresource, so each
  Enter refetched every script, style, and image; ordinary browsing now uses
  the HTTP cache, and the hard reload survives only for loopback hosts, where
  a stale asset would hide the edit you just made. The injected network
  capture used to sit between the network and the page, holding every fetch
  until its whole body downloaded — and deadlocking forever on
  server-sent-event streams; capture now reads bodies after the page already
  has its response, skips streaming bodies entirely, and stays out of
  sub-frames, so `browser_wait_for` settles truthfully on streaming pages.
  And the browser now completes its user-agent with the Safari token the
  WebKit engine actually is, which stops bot-detection vendors from routing
  it into challenge interstitials. Parked background tabs also suspend media
  playback, and the default ephemeral profile stops being rebuilt on every
  session event.
- **Screenshot, annotate, attach.** A camera button in the browser captures
  the visible page into an annotation sheet — crop, pen, box, arrow, text
  labels, five colors, undo — and one click attaches the flattened PNG to
  the composer, named "Browser screenshot …", ready for a vision model in
  any mode. Copy and Save PNG… are there too. The user's own capture asks no
  consent and has no size cap: those guard the agent shipping pixels
  autonomously, not you cropping your own screenshot — and the composer's
  attachment limits still apply.
- **Real tabs.** The tab strip is always visible with a reachable "+" (a new
  tab focuses the address bar), chips carry the page's favicon — fetched once
  per host, through the configured proxy, never retried on failure — or a
  loading spinner, tooltips show the full URL, and a right-click offers Close
  Tab, Close Other Tabs, Copy URL, and Open in Default Browser. ⌘T, ⌘W, and
  ⇧⌘]/⇧⌘[ work while the browser panel is showing — ⌘W is deliberately
  shadowed there to mean "close tab" (and in the main window an un-shadowed
  ⌘W would quit the app); everywhere else it keeps meaning Close Window.
  Dragging chips to reorder is deferred: per-session tab counts are small,
  and a drag inside the scrolling strip needs machinery the release does not
  earn yet.
- **A stop button.** While a solo run is active and the composer is empty,
  the send slot shows a stop control — the space that used to hold a disabled
  arrow — and ⌘↵ or Esc stops the run. Typing switches the slot back to
  steering, which stays the primary busy action on purpose. Team runs keep
  their own Stop on the run board.
- **Models now know what they are.** Every model used to answer "what LLM are
  you" with "I'm ollama-code" or "I'm Locus" — the persona the system prompt
  assigns — because nothing ever told it what it actually was; only strongly
  self-identifying models broke through, which read as smart models "knowing".
  Both prompts now state the underlying model and provider, refreshed on
  every model switch, in Just Chat too.

- **Screenshot-to-fix: attachments in every mode.** Images and files attach to
  Work, Plan, and Build messages — not just Just Chat — so "here's a
  screenshot of the bug, fix it" finally works. Drag files onto the composer
  or the conversation, or paste an image with ⌘V (a clipboard screenshot
  attaches; copied text still pastes as text — file URLs win over both).
  Attachment chips with thumbnails sit under the editor. On a team run the
  images reach the dispatcher and the first coding job, and a note in the
  transcript says exactly that; specialists and reviewers stay text-only
  because their goals are written by the dispatcher, which has seen the
  evidence. Local models report vision support straight from Ollama's own
  capability list — the composer warns before sending images to a model known
  to refuse them, remote listings stay honestly unknown — and a provider that
  rejects image input triggers one automatic retry with the images stripped
  and a note saying so. That retry also fixes a latent bug: a rejected image
  used to stay in history and poison every later turn on the same
  conversation. Attachments are still never persisted; a restored session
  shows their names, not their bytes.
- **Search across all conversations.** The sidebar search now looks inside
  transcripts, not just titles: an "In conversations" section ranks matching
  messages with highlighted snippets, and selecting one opens that session
  scrolled to the exact message. ⇧⌘F focuses it from anywhere. The index is
  one SQLite full-text database built lazily on first search and kept current
  by comparing file stats before each query — nothing changes about how
  sessions are written, so trash, restore, and delete are picked up
  automatically, and clearing all sessions empties the index at the same
  moment. A large history builds in the background while partial results
  flow. Semantic search stayed out deliberately: plain full-text answers
  "where did we discuss X" without new model dependencies.
- **A Usage & Costs dashboard.** Sidebar ▸ ••• ▸ Usage & Costs answers "what
  did I spend, on which provider, in which workspace": totals, by-agent and
  by-model and by-workspace tables, the most expensive runs (each deep-links
  into the Runs inspector), and a 7d/30d/90d/All filter — all computed from
  the run store that already recorded every orchestration. Costs are estimates
  from the per-agent rates you entered; local Ollama rows say so at $0, and
  the sheet says plainly that it is not a bill. Solo chat turns start
  recording token counts from this release — they were never persisted
  before, so there is nothing to backfill, and with no pricing outside agent
  profiles solo rows show tokens, never dollars.
- **Ship a change from the Changes tab.** The header names the current branch
  and switches or creates branches (no auto-stash — git's own refusal is
  surfaced verbatim, because nothing that can lose work belongs behind one
  click). Fetch, fast-forward-only pull, and push — publishing the branch on
  first push — appear in the direct-download build; the App Store sandbox
  cannot reach your keychain or SSH keys, so there the buttons stay away and a
  footnote says why, the same honest carve-out as Computer Control. "Open a
  pull request" opens GitHub's compare page with the branch prefilled — the
  human owns the actual Create button, no embedded GitHub login, no `gh`
  dependency. And review gets hunk-level control: each hunk in a file's diff
  stages, unstages, or discards independently, with a synthesized minimal
  patch applied through git itself. A hunk that changed since the diff was
  read is re-located by content and, failing that, never applied — the diff
  refreshes instead. Renamed files keep whole-file actions only, truncated
  diffs disable hunk controls rather than guess, and discarding a hunk always
  confirms first. Team-run review deliberately stays apply-all/discard-all:
  partial application of a reviewed plan is a different, riskier feature.

## 1.12.0 — 2026-08-09

### Added

- **A browser the agent can drive.** The model gains browser tools over the
  native broker: open a page, read it as a tree of addressable elements, click
  and type with framework-aware input, capture screenshots, wait for a
  single-page app to settle, inspect console output and network requests,
  manage tabs, resize the emulated viewport, and evaluate JavaScript for
  debugging. Reading is permission-free — a reviewer can look at the page it is
  reviewing — while running page JavaScript asks every time, Bypass included.
  Navigation is limited to http and https, typed credentials are refused on
  both sides of the broker, and page content is always labelled untrusted
  external data. The browser is on by default, works in the sandboxed App Store
  build, and can be turned off in Settings ▸ Permissions.
- **The Preview tab is now the Browser tab.** The same live pages the agent
  drives, with an address bar, back/forward, stop/reload, load progress, tab
  chips, a console and network drawer, and an emulated-viewport picker. Pages
  render off-screen while the panel shows another tab, so the agent keeps
  browsing — and screenshots keep working — with the inspector collapsed.
  `/browser` opens it; `/preview` still works. Tabs belong to the conversation
  that opened them: background team workers keep their pages across chat
  switches, and a conversation's tabs close when it ends.
- **A detachable Browser window, safe dialogs, contained downloads.** The
  Browser opens into its own full-size window and hands the page back to the
  inspector when closed. JavaScript dialogs never block or prompt: alerts are
  acknowledged, an unanswered confirm takes the safe branch, and the agent can
  arm a one-shot answer before the click that triggers one — the outcome is
  always reported in the action's own result. Popups become managed tabs, page
  file-upload pickers are refused, and downloads land quarantined in Locus's
  own folder — size-capped, never executed, never the user's Downloads.
  Cookies are forgotten at quit unless the new per-workspace persistent
  profile is switched on; Clear Browsing Data erases it.
- **The agent can run the dev server.** `browser_dev_server` starts the
  project's server in the agent process, waits for its port, keeps a bounded
  output log readable on demand, and stops it on request or at quit. Starting
  one asks every time, Bypass included, and the command passes the same deny
  list the console enforces. The Console tab stays free for the user's own
  commands.

## 1.11.0 — 2026-08-08

### Added

- **Adaptive Work and explicit multi-agent teams.** Locus can dispatch bounded
  work to configured local and hosted specialists, run eligible read-only jobs
  concurrently, reserve mutations for one fixed writer, and reproduce the
  current Git state in an isolated managed worktree. Hosted routing requires
  explicit consent, and team membership, capabilities, cost, calls, tokens, and
  concurrency all remain visible and bounded.
- **Durable run history, recovery, and evaluations.** Team activity is persisted
  before it reaches the interface and is available through a Run Inspector with
  ordered timelines, evidence, routing explanations, checkpoints, pause/resume,
  retry, reassignment, replay, and repair guidance. Evaluation suites compare
  Solo and team configurations in immutable fixtures without applying their
  changes to the source workspace.
- **Workspace chats and recoverable chat deletion.** Conversations are grouped
  under their project folders, each workspace restores its latest chat, and an
  individual deletion moves history into a recoverable batch with Undo.
- **Local workspace knowledge and approved memory.** Eligible agents can search a
  bounded local index and user-approved memories; retrieved content is treated as
  untrusted data and remains unavailable to Just Chat.
- **Modern MCP resources, prompts, tasks, progress, and input flows.** Access is
  deny-by-default per agent, destructive operations remain writer-only and pass
  through normal permissions, and sensitive input is kept on verified HTTPS
  pages rather than returned through a model-visible form.
- **Native Computer Control for signed direct-download builds.** The foreground
  writer can inspect and operate Mac interfaces after Accessibility and Screen
  Recording are enabled. It is off by default, globally exclusive, permission
  gated, unavailable to evaluations, and omitted from the sandboxed App Store
  build.

- **Locus works behind a proxy.** A new **Settings ▸ Network** tab routes
  outbound traffic — the app's own requests, the agent's model and web traffic,
  MCP servers, extension installs, git — through an HTTP/HTTPS or SOCKS5 proxy,
  with optional sign-in and a bypass list. *Use system proxy* mirrors the
  macOS proxy configuration into the agent's environment; *Manual proxy* names
  one explicitly. Loopback, the local agent, and the Ollama host always connect
  directly. A proxy that stops answering is an error, never a silent direct
  connection, and a **Test Proxy** button probes the draft values before
  anything is saved.

  The boundaries, stated plainly: the proxy password lives in
  `~/.locus/auth.json` and is deliberately withheld from anything the model can
  run — shell commands and stdio MCP servers get the proxy address but cannot
  answer its sign-in. A PAC-based system proxy applies to app traffic only,
  because PAC cannot be expressed in the environment variables the agent's
  libraries read. Proxy changes restart the agent, the same way backend
  changes always have.

### Changed

- **The default launch window is now 1250×760.** The extra width keeps the right
  inspector fully visible in the standard three-column workspace. Existing
  installs adopt the new centered size once, then macOS continues remembering
  later user resizing.

- **Accounts and permissions each have their own Settings tab.** Both used to be
  sections buried in General, above the backend and preview fields, which is a
  long way to scroll for the two things people actually open Settings to change.
  They are now **Settings ▸ Accounts** and **Settings ▸ Permissions**, alongside
  General and Extensions. Neither takes part in the Cancel/Save bar, which is
  right: an API key writes `~/.locus/auth.json` the moment it is entered and a
  permission mode applies to a turn that may already be running, so there was
  never anything for Cancel to undo. General keeps everything the draft does
  save. **Manage Accounts…** in the model picker now lands on the Accounts tab
  rather than the top of General.

- **The sidebar's workspace row is a folder, and the icons line up.** The row at
  the bottom carried a shipping-box glyph, and its label was centred rather than
  starting where New chat's plus and the search magnifier start — SwiftUI's
  borderless menu style centres a custom label the way an `NSPopUpButton` centres
  a title. It is a folder now, laid out verbatim, and every leading glyph in the
  sidebar is drawn in a shared fixed-width column at a shared inset, so they sit
  on one rail whatever each symbol's own width happens to be.

- **Manage Accounts and Hugging Face are one click from the sidebar.** They join
  Plugins & MCP under the Chat/Work switch: the first opens Settings on the new
  Accounts tab, the second opens the model library that was previously reachable
  only through the model picker or `/models`.

- **Local models now run in a window Locus asks for, instead of Ollama's
  4,096-token default.** The agent requests the model's own trained ceiling,
  capped at 32,768 tokens, so the context meter and automatic compaction work
  from the first message rather than from the second. At Ollama's default, a turn
  had under a thousand tokens left for the conversation once the tool schemas,
  system prompt and reply room were accounted for — not enough to hold a single
  file read.

  Two consequences worth knowing. The first turn after upgrading reloads each
  model once, because Ollama keys a loaded runner by the options it was given.
  And a larger window costs memory for the KV cache: if a model ends up partly on
  the CPU as a result, Locus notices from `/api/ps`, halves what it asks for,
  remembers the lower ceiling for that model on this Mac, and says so in the
  transcript. Pin an exact window under **Settings ▸ General ▸ Local model** to
  opt out of all of it.

- **Hosted endpoints now report their own context window.** vLLM, TGI and
  llama.cpp deployments — including Hugging Face Inference Endpoints — state
  their window in metadata Locus was already fetching and then discarding. It is
  read from the model listing, or from TGI's `/info` and llama.cpp's `/props`
  when the listing is bare, and cached per endpoint and model. Custom accounts
  that previously had no window therefore get a live meter and automatic
  compaction, where before both were switched off.

- **The context meter says where its number came from.** A window measured from
  the runtime or reported by an endpoint is drawn as before; a vendor's published
  figure for a model — an assumption, since nothing was observed — now shows a
  `≈` prefix and a dashed ring, and the source is named in the popover and the
  inspector. "Window unknown" still means unknown.

### Fixed

- **Switching model within one hosted account kept the previous model's context
  window.** Moving a Claude account from a 1,000,000-token model to a
  200,000-token one left the agent budgeting against 1,000,000: it would not
  compact until roughly five times over the real window, and every request past
  the real one failed.
- **A turn that hits the tool-step limit now names the limit** — "Iteration limit
  reached (40 steps)" — and the limit is editable under **Settings ▸ Agent** and
  over `POST /api/config`. It was previously settable only by hand-editing the
  agent's config file, and invisible from inside the app, so a wrong value looked
  like the model giving up. An unusable value (zero, negative, non-numeric) now
  falls back to 40 instead of producing turns that could take no action at all,
  or preventing the agent from starting.
- **Opening Settings and pressing Save no longer clears a pinned context
  window.** The field was never filled in from the saved value, and an empty
  field means "clear it".
- **A Kimi Code account no longer reports a working key as rejected.** The model
  listing is not requested for a provider that does not serve one, matching what
  the health probe already did.
- **The context meter no longer blanks for a moment on every permission
  decision**, and local models keep their window in the picker while a hosted
  account is active.
- `GET /api/models` asked Ollama to describe every installed model on every call,
  which the app makes every 15 seconds. Those descriptions are now cached until a
  model is pulled or deleted.

### Internal

- The agent's test suite can no longer write to a developer's real
  `~/.ollama-code`. Every data path is redirected per test by
  `agent/tests/conftest.py`, and an audit hook fails the suite if anything tries.
  Two test modules previously had no isolation at all: one wrote real session
  transcripts, and a config clobbered this way is what left `max_iterations: 5`
  in a working install. `Tools/PruneAgentTestLitter.py` repairs an affected
  `~/.ollama-code`.
- Unit tests no longer read the accounts saved by the developer's own copy of
  Locus, which made account tests pass on CI and fail on a real machine.

## 1.10.0 — 2026-08-03

### Changed

- **API keys and MCP tokens now live in `~/.locus/auth.json` instead of the
  login keychain.** The file is mode `0600` inside a `0700` directory, so no
  other account on the Mac can read it; in the sandboxed App Store build it sits
  in the app container. This matches how Codex keeps `~/.codex/auth.json`.

  **You will need to re-enter each account's API key once, and re-supply every
  MCP server credential** — re-authorizing OAuth servers and re-entering any
  bearer token, header value, or environment secret you typed in by hand.
  Existing keychain entries are not migrated and are left where they are;
  nothing reads them any more, and you can delete them from Keychain Access if
  you want them gone.

  This is a real reduction in protection and worth understanding before you
  upgrade. The keychain enforced *per-application* access — a different program
  reading your key triggered an authorization prompt. File permissions do not:
  they keep the keys away from other users of the Mac, but anything running as
  **you** can read that file. What you get in exchange is that Locus stops
  asking for your keychain password when you run a build signed differently from
  the one that stored the key.

## 1.9.0 — 2026-08-03

### Added

- **Extensions — plugins, skills, and MCP servers.** Locus can install plugins
  and skills from a marketplace catalog, and connect to Model Context Protocol
  servers whose tools then appear to the model alongside the built-in ones.
  Remote servers support OAuth, with tokens held in the macOS Keychain and
  handed to the local agent only through a transient credential endpoint; each
  server carries its own default tool-approval policy. The App Store build is
  sandboxed, so it connects to remote servers only — `stdio` servers, which run
  a local command, are refused there. Managed under **Settings ▸ Extensions**.
- **Image attachments in Just Chat.** Paste or attach PNG, JPEG, GIF, or WebP
  images — up to 10 per message, 15 MB each and 25 MB in total — and they are
  sent to any model that accepts them. Attachments count toward the context
  meter and the compaction budget like any other content, because they stay in
  the conversation and are re-sent on every following turn.
- **Local runtimes are supervised instead of assumed.** Locus now starts the
  shared Ollama application when it is installed, falls back when it is not, and
  carries an explicit runtime phase — starting, online, recovering, unavailable —
  through the UI. A local model whose runtime is not actually up now says so,
  and says which state it is in, rather than accepting a prompt and failing at
  the first message.

### Fixed

- **The context meter never worked for a hosted account, and could not have.**
  Nothing in the app could set a context window — `/api/config` accepted one but
  no code called it — and a hosted endpoint advertises none, so every Claude,
  Codex, Kimi and Custom account had a dead meter and no automatic compaction at
  all. Accounts now carry a window, defaulting to the provider's published
  figure for the selected model, and local Ollama has one in Settings for
  pinning a window rather than measuring it.
- **Switching models kept the previous model's window.** A 4K model would read
  about 12% at 96% of its real window and budget compaction against a window
  that does not exist. The rule that keeps a window through eviction is now
  scoped to the model it was measured for.
- **The meter disagreed with compaction.** It divided by the raw window while
  compaction budgets against the window less the tool schemas and the room kept
  for a reply — so compaction fired at a displayed ~55–73%. The agent now
  reports the usable figure and the meter divides by that, reaching 100% exactly
  when compaction acts.
- The meter no longer freezes mid-turn: tool output, which is most of what fills
  a window, was invisible until the turn ended. It also no longer jumps backwards
  when the permission mode is changed during a run.
- Windows measured before they were scoped by host are re-keyed rather than
  discarded, so upgrading does not blank the meter.
- The window opens at 1200×760 rather than 1420×860, so first launch fits a
  smaller display without the user having to resize it. Frames you have already
  moved or resized are left alone.
- The permission panel is drawn on the inspector's own background instead of a
  slightly different one, so it no longer reads as a separate surface.

## 1.8.0 — 2026-07-30

### Added

- **Provider accounts — Claude, Codex, and Kimi models alongside local ones.**
  **Settings ▸ Model providers ▸ Add Account…** signs Locus in to Anthropic,
  OpenAI, or Moonshot with an API key, or to any other OpenAI-compatible
  endpoint. **Several accounts per provider are supported**: two Claude keys
  become "Claude — Work" and "Claude — Personal". Each account gets its own
  section in the model picker, and choosing a model routes the session through
  that account — the checkmark tracks the account as well as the model, so the
  same model name under two accounts is never ambiguous. A switch requested
  mid-turn is applied when the turn finishes, since the agent cannot swap
  providers during a run. Removing an account deletes its key and, if it was
  in use, falls back to local Ollama. The single **Remote endpoint** from
  earlier versions migrates automatically into a Custom account, keeping its
  URL, model, and saved key.
- Every account keeps its key in its own login-keychain entry. Keys still
  reach the agent in memory only, are never written to a config file, and are
  only ever sent to their own provider. Anthropic accounts also send the
  native `x-api-key` header its model listing requires.
- Session transcripts now record the provider and account that produced them,
  so an exported session says which of two same-provider accounts ran it.
- **Kimi Code accounts spend a Kimi membership instead of per-token credit.**
  Moonshot documents this route for third-party tools: keys minted in the Kimi
  Code Console bill against the plan rather than by the token. It is a separate
  provider from pay-per-token **Kimi** — a different host, a different key, and
  a different model line-up — and each editor now says which is which, so a
  membership key is not pasted into an account that cannot use it. Kimi Code
  serves only chat completions, so Locus offers its published models rather
  than probing a model listing that would answer like a rejected key.
- Locus now identifies itself by name and version on every outbound request,
  including the pages the model browses — which previously claimed to be
  "ollama-code/0.2", a product name Locus has not used for two releases.
  Moonshot's terms require third-party tools to identify themselves honestly,
  so the header is a constant no setting can rewrite.
- **The context meter no longer goes blank whenever Ollama unloads a model.**
  The window a model really runs in can only be measured while it is resident,
  and Ollama evicts after about five idle minutes — so the meter was dark on
  every launch and went dark again mid-session. Measured windows are now
  remembered per model and reused when the model is not loaded. Still measured,
  never guessed: a model that has never been resident reports no window rather
  than borrowing the trained one, which reads reassuringly low right up to the
  point where replies start getting truncated.
- Switching to a different endpoint no longer arrives carrying the previous
  one's model name — that is how a Kimi model ended up pointed at Anthropic,
  failing with an error that named neither.
- Claude account setup now states plainly that Anthropic requires a console API
  key and does not permit third-party apps to use Claude.ai subscription
  credentials, with a link to their terms — the absence of a "sign in with
  Claude" button is a rule, not an oversight.

### Fixed

- **The bundled agent would not start in a locally built app.** The runtime was
  signed with the hardened runtime regardless of configuration, which turns on
  library validation — so an ad-hoc-signed build produced an interpreter that
  refused to load its own extension modules, and the app came up with no agent
  and no local models. Release builds were unaffected, because a real
  certificate gives every file the same Team ID.

### Distribution

- The direct download is now **signed with the SparkTales Developer ID,
  notarized, and stapled**, so it runs on a Mac that has never seen it without
  a Gatekeeper prompt. `Release` and `ReleaseMAS` are now separate
  configurations: the direct download is not sandboxed, since a container buys
  nothing outside the App Store and only limits which workspaces the agent can
  reach; the App Store build keeps the sandbox and its entitlements.

## 1.7.0 — 2026-07-29

### Added

- **Plan approval in the composer**, the way Claude Code closes plan mode.
  When a Plan-mode turn finishes with a plan on the board, the input is
  replaced by "Do you want to implement this plan?" with the numbered steps
  and a keyboard-first option list — **1** Yes, and auto-accept edits ·
  **2** Yes, and approve each edit as it happens · **3** No, keep planning.
  Implementing switches to Build mode and starts the run; auto-accepting
  also raises Ask permissions to Accept Edits first. The offer is keyed to
  the mode the turn was *dispatched* in, only fires for turns that actually
  wrote the todo list, and never fires over a queued message, an
  interrupted or exhausted run, or an agent-side slash command.
- **Plan prompt suggestions**: the Plan tab's "Create a plan" button now
  opens five ready-made prompts (current request, latest problem, codebase
  improvements, missing tests, a safe refactor) — pick one and it is sent
  as the plan request.

### Changed

- **Release builds are prepared for Mac App Store distribution** under the
  SparkTales team: the bundle ID is now `io.sparktales.locus`, Release
  builds enable the App Sandbox and hardened runtime, workspaces persist
  through security-scoped bookmarks, the agent keeps its state in the app
  container when sandboxed, the bundled runtime's 24 Python packages are
  pinned by hash in `agent/requirements-runtime.lock`, and third-party
  license notices ship inside the app. The GPLv3 `_dbm` extension (and the
  unused `_tkinter`) are stripped from the runtime before signing, and
  `Tools/AuditDistribution.sh` blocks an archive that still contains
  either. The 1.6.0 (9) build was already uploaded to App Store Connect.

### Removed

- The circular-arrow refresh button in the Plan tab header. Plans are
  created from the suggestions popover and refreshed by the agent's own
  todo updates.

## 1.6.0 — 2026-07-28

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

- **Release packaging could ship a broken code-signature seal.** The bundled
  Python wrote `.pyc` caches into the sealed app the first time it ran,
  after which macOS reports the download as "damaged". The runtime now
  ships fully pre-compiled (stdlib included), the app launches Python with
  byte-code writing disabled, and `Tools/PackageRelease.sh` verifies the
  seal after signing, again after exercising the runtime, and once more
  across the zip round-trip before anything is uploaded.
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
