# Release Notes

Released changes through Locus 2.6.0. Older entries describe their historical editions. Standard Locus is wallet-free from 2.5 onward; wallet-era release notes are not current standard-app instructions.

## 2.6.0 — 2026-09-07

### Added

- Structured answers can present verified file collections, reusable writing,
  deliverables, and source references while preserving a complete Markdown fallback.
- Writing drafts support editing, original recovery, copying, and export.
  Tables copy all rows and can export CSV even when the display is collapsed.
- The Files panel browses all file types and generated folders with incremental
  expansion, path search, explicit hidden-file visibility, and existing previews.

### Changed

- Agents now have a searchable collection with clear instructions, triggers,
  access, environment, and recent activity. Shared Connections and Runtime
  controls are separate from Agent configuration.
- Creation starts with a schedule, incoming event, or price condition and uses
  a short form with progressively disclosed advanced settings.
- The sidebar, Agent selector, and right inspector clarify Agent ownership,
  live status, connection problems, and the difference between Agent and chat activity.
- Answer and progress presentation is clearer, and behavior previews show the
  effective instructions for the selected provider and mode.
- Goal, plan, and permission controls explain their scope and keep actions
  accessible in compact panels. Reusable profiles are labeled Specialists & teams.

- Task Capsules now guide model setup, keep the next action visible, and make
  saved plans, edits, and past runs easier to find and review at compact sizes.

### Fixed

- Mobile chat refresh preserves partial answers when loading fails and ignores
  stale responses after switching conversations.

- Removing every connected-service action permission now persists the empty
  selection, including restrictions in workflow steps.
- Agent creation from the sidebar waits for its parent sheet to mount.
- Activity uses consistent receipt and execution states; failed or cancelled
  deliveries cannot appear successful because of an older linked run.
- Schedule loading preserves saved data on failure and ignores cancelled requests.

- Browser resizing avoids redundant native layout and repeated file lookups;
  panel expansion and restoration keep their smooth transition.

## 2.5.0 — 2026-09-06

### Added

- **Wallet-free Locus.** The public Mac download now contains the standard
  edition. Existing chats, accounts, settings, and browser data stay in place;
  the optional wallet remains in the separate LocusX edition.
- **Persistent goals.** Give an ordinary chat an objective and optional usage
  allowances. Solo agents and teams continue across turns, retain progress on
  reopening, and report verified completion. Pause, Resume, Edit, and End keep
  control beside the composer; queued instructions take priority.
- **Solo collaboration.** The conversation agent can delegate bounded work to
  helpers while keeping results and verification with the coordinating agent.
- **Private Identity tasks.** Keep reusable personal and business details in
  an encrypted vault, with explicit review before sharing details or documents.
- **Task Capsules.** Save a detailed plan with separate planning,
  implementation, and optional review models. ChatGPT and Kimi Code membership
  routes keep their exact accounts, alongside API and local model support.
  Saved revisions, source-change checks, bounded repairs, and explicit planner
  help keep the handoff reviewable without repeatedly calling the plan author.
- **Workspace Library.** Documents and Outputs share one home without replacing
  the open chat or its draft. Opt-in document knowledge supports PDF, Word,
  spreadsheets, and delimited tables, including local PDF text recognition.
- **Saved output versions.** Deliverables have immutable snapshots, source-chat
  links, export, comparisons, and revision drafts. Existing available outputs
  are imported as their current version; unavailable originals remain visible.
- **Resumable Getting Started.** Document/research and coding examples reuse
  existing model connections and workspaces. A first task succeeds only when
  its response finishes and its output has been saved.
- **Contextual Agent inspector.** Agent, chat, event, scheduled occurrence, and
  run selections retain their exact identity, with scoped history, execution
  attempts, useful results, and recovery actions.

### Changed

- Locus 2.5 uses manual app updates. The previous signed app feed is preserved
  for older installations; upgrading to the wallet-free edition is an explicit
  download. ChatGPT-plan component downloads remain available.
- Generated reports inside build folders can be captured in Outputs. Saved
  history remains available when original workspace files disappear.
- Agent progress and outcomes appear before configuration. Automation state,
  delivery state, and execution outcomes have distinct labels.


## 2.4.0 — 2026-09-04

### Added

- **Automation Studio turns schedules and events into workflows.** Scheduled,
  Gmail, Telegram, webhook, and price-triggered agents can use a forward-only
  sequence of Agent, Condition, and Approval steps. A safe simulator previews
  templates, branches, outputs, and approval cards without calling a model or
  creating chat history.
- **Attention shows only work that needs a decision.** Questions, permissions,
  workflow approvals, recoverable runs, retryable failures, and configuration
  warnings share one deduplicated inbox with inline actions. Ordinary successful
  and informational activity remains in Activity.

### Changed

- **Window resizing and long responses stay responsive.** Shared workspace
  geometry, bounded text-measurement caches, append-only streaming, incremental
  Markdown rendering, focused state models, and asynchronous image thumbnails
  keep expensive work off the hottest interface paths.
- **Workflow occurrences are durable.** Each occurrence snapshots its workflow,
  keeps exclusive use of its dedicated chat between steps, records attempts and
  approvals, and resumes explicitly after a failure or restart without silently
  repeating external actions.

### Fixed

- **Workspace chats open reliably under macOS privacy controls.** Locus now
  keeps the already validated workspace path when the system blocks a child
  process from rediscovering its current folder.
- **Attention recoveries can be cleared when work is no longer wanted.** This
  applies whether the original chat still exists or has already been deleted.
- **The composer stays against the bottom edge.** Workspace layout no longer
  reserves the toolbar height twice, so the composer remains visible at normal
  and compact window sizes.
- **Generated project and design-system checks are current.** The checked-in
  Xcode project and workflow editor typography now match the deterministic CI
  generators and source audit.

## 2.3.0 — 2026-09-03

### Added

- **Agents can pause for a structured decision.** A live task may present one
  or more bounded choices in the composer and continue in the same turn after
  the answer; disconnecting or stopping cancels the wait cleanly.
- **Agents are now a first-class destination.** Scheduled and event-driven work
  is presented as a durable agent with a clear identity, status, source,
  controls, history, and one dedicated primary chat. Each agent can also open
  side chats for investigation without mixing that discussion into its
  automation record.
- **Event-driven agents can react to real inputs.** Locus can connect Gmail,
  Telegram, signed webhooks, and price sources to bounded agent tasks. Delivery
  state is durable and visible, with replay protection, retries, idempotency,
  re-arming for price alerts, and native credential storage outside prompts.
- **Overview follows the current request.** A pinned request summary tracks plan
  steps, files, commands, sources, outputs, subagents, timing, and completion
  state instead of blending activity from the full conversation.
- **Optional voice controls.** Dictate requests, answer attention prompts, and
  listen to responses with explicit microphone, speech-recognition, network,
  and provider controls.
- **Multichain Locus Vault testnet paths.** The direct-download build adds
  reviewed Ethereum, Solana, and Sui asset discovery, activity, and narrowly
  defined native, token, and collectible transfer paths. Unknown assets remain
  quarantined and all mainnet capabilities remain default-denied behind signed
  release and evidence gates.

### Changed

- **Schedules now behave like agents.** A schedule keeps one stable conversation
  across runs, opens directly from the Agents destination, and separates manual
  side chats from its canonical automation transcript.
- **Agent surfaces explain the system in plain language.** Agent setup,
  automation configuration, Overview, navigation, status, and empty states now
  share one vocabulary and visual hierarchy.
- **Session and transcript state has narrower ownership.** Catalog, selection,
  and publication boundaries were extracted from the app composition root so
  unrelated views no longer refresh for every change.
- **Local compatible endpoints stay local.** Keyless LAN endpoints are accepted
  when configured, and Locus no longer guesses HTTPS for explicitly local
  addresses.

### Fixed

- **Incoming events no longer hold the agent queue indefinitely.** Each worker
  now acknowledges an accepted dispatch. If that acknowledgement never
  arrives, Locus safely interrupts only the not-yet-started run, releases its
  execution slot, and leaves the event available to retry without pausing the
  agent.
- **Vault activation completes after a correct recovery confirmation.** The
  signer account payload now decodes its cross-language network identifiers
  explicitly, and vault credentials use the provisioned Keychain access group
  with a clear registration path for existing Macs. Post-confirmation failures
  are reported as activation errors rather than incorrect recovery words.
- **Wallet creation and restore now open reliably.** The unsupported recovery
  window formerly hosted inside an XPC service has moved to a signed, sandboxed
  accessory application with explicit presentation acknowledgement, Bring to
  Front, launch timeout, crash handling, and bounded cancellation.
- **Six-word backup confirmation can be corrected.** A mismatch identifies the
  numbered positions that need attention and preserves the entered values for
  retry. Confirmation and restore fields now include a Show/Hide typed words
  control while remaining secure by default.
- **Recovery exits cleanly.** Cancelling or closing the recovery application no
  longer causes it to reopen, and completion, timeout, signer invalidation, and
  helper termination all converge on one teardown path.
- **Transcript navigation is steadier.** Streaming follow behavior, jump-to-
  latest completion, coordinate clicks, file cards, workspace links, shell
  blocks, and file viewing no longer compete for focus or scrolling.

### Security

- **Recovery secrets stay outside Locus.** The recovery application embeds its
  own authenticated signer service and communicates with the main app through a
  bounded status-only protocol. Recovery phrases, entropy, and private keys are
  excluded from main-process payloads, logs, screenshots, and diagnostics.
- **Signer trust boundaries are caller-specific.** Host and recovery bootstrap
  endpoints enforce separate code-signing requirements, and lock or invalidation
  clears pending recovery material and listeners.
- **Packaging verifies the complete nested chain.** Release audits check both
  signer copies, the recovery helper, sandbox and network entitlements, exact
  executable identity, nested signing order, and direct-versus-App-Store
  distribution boundaries.



## Locus 2.1.0

### Added

* **Notebook** gathers every workspace, chat, shared, and unlinked legacy note into one searchable page. Open it from the sidebar gear, Locus menu, command palette, or ⇧⌘9, and edit any note in the full editor.
* **Locus Vault private alpha** adds an in-app Sepolia Wallet Hub to signed direct-download builds: isolated vault creation and unlock, local ERC-681 receive QR, balance and Etherscan activity, exact agent spending rules, a separate browser opt-in, and native confirmation for every website transaction. The Mac App Store build keeps wallet gates off.
* **ChatGPT conversation controls** add per-account Codex-native mode, model-supported reasoning effort, and optional OpenAI web search. Locus still owns execution and permissions in either contract.

### Changed

* **Grill replaces GSD.** Use ⌥G or /grill for a one-question-at-a-time interview that does not modify the project. Approved Plans now implement in Work; older stored mode values remain compatible.
* **New ChatGPT accounts start with Locus's tools.** Existing accounts keep their previous contract choice. Codex-native mode remains one toggle away and deliberately omits approved memory, cross-chat context, and the skill index.
* **Transcript activity stays chronological.** Collapsed reasoning and tools use quiet inline disclosures at the real activity boundary; detailed modes retain their cards.
* **The app core is decomposed into feature-owned models.** Provider accounts, teams, run history, live run cards, extensions, knowledge, evaluations, schedules, activity, search, background services, AGENTS.md, landing, and toasts now have tested observable owners, reducing the risk of future changes.

### Fixed

* Run Overview and Activity now use only the selected run's events; created-then-deleted files and stale expansion state no longer leak across runs.
* Notes recover from their formatting archive when the plain-text mirror is missing, and UI tests use separate note storage.
* Hosted ChatGPT and Kimi model switches no longer fail against the local Ollama model list.
* Transcript selection spans the conversation, survives scrolling, supports Shift-click, and keeps links clickable; the floating Copy/Quote buttons are gone.
* Produced files open in the correct Mac app and appear in Outputs even when written by scripts, gitignored, or created outside a Git repository.
* Browser layout follows the panel size, keeps native horizontal scrolling, and uses a quieter responsive toolbar.
* The Add Account menu is readable again, and /compact resets the ChatGPT helper's server-side thread.
  {% endupdate %}

{% update date="2026-08-26" tags="v2,updates" %}

## Late 2.0 updates

### Added

* Model Router and Usage & Costs made route scorecards, tokens, estimated spend, provider, model, agent, and workspace attribution inspectable.
* Proxy profiles and failover added workspace/provider assignments, strict tunnel, health checks, external exit address, and fastest-healthy standby selection.
* A calmer workspace added the pinned Overview summary, Notes formatting, chat folders, Side Chat, richer exports, and automatic bounded Solo delegation.

### Fixed

* Failed account switches restore the previous route instead of leaving mismatched provider/model state.
  {% endupdate %}

{% update date="2026-08-22" tags="v2,browser" %}

## Locus 2.0.0

### Added

* ChatGPT-plan helpers moved to a separately downloaded, checksum- and signature-verified component, shrinking the direct app from about 180 MB to about 62 MB.
* Browser input uses real AppKit clicks, keys, scrolling, and dragging when possible.
* Coordinate targeting, region screenshots, per-tab tool targeting, phone user-agent/touch emulation, find in page, page zoom, and visible device controls.
* Named development servers in .locus/launch.json, including URL-only attachment and filtered output.

### Changed

* Browser typing now sends real keystrokes; set\_value remains the one-step replacement action.
* Web Inspector became an opt-in Browser setting.
* Codex helpers are stripped before signing and packaging.

### Fixed

* Streaming continues when a display sleeps or no display is connected.
* Browser scrolling works on headless Macs.
* Codex build caches require an exact architecture match.
  {% endupdate %}

{% update date="2026-08-17" tags="v1.16,ui" %}

## Locus 1.16

* Overview became the pinned Plan, Outputs, Subagents, Background Processes, Sources, and Context Window summary.
* Failed provider switches now roll back cleanly.
  {% endupdate %}

{% update date="2026-08-16" tags="v1.15,workflows" %}

## Locus 1.15

* Bundled Task Observer, Superpowers, workflow routers, Grill Me, and Grilling methods.
* Encrypted workspace continuity, per-chat Notes, model removal/deletion, GitHub MCP device-flow support, and calmer workspace navigation.
  {% endupdate %}

{% update date="2026-08-13" tags="v1.14,updates" %}

## Locus 1.14

* Signed automatic updates for direct downloads; App Store installs continue through Apple.
  {% endupdate %}

{% update date="2026-08-09" tags="v1.13,accounts" %}

## Locus 1.13

* Managed ChatGPT-plan sign-in and the pinned Codex App Server bridge.
* Faster Browser caching and network capture, real tabs, screenshot annotation, attachments in every mode, transcript search, usage/cost reporting, and Git branch/sync/hunk controls.
* Stop and steering controls, provider/model self-identification, and improved navigation and composer preferences.
  {% endupdate %}

{% update date="2026-08-09" tags="v1.12,browser" %}

## Locus 1.12

* The agent-drivable Browser replaced Preview with addressable elements, screenshots, console/network inspection, managed tabs, safe dialogs, quarantined downloads, persistent-profile control, and dev-server supervision.
  {% endupdate %}
  {% endupdates %}

{% hint style="info" %}
The detailed guides describe Locus 2.1.0. Older chats and saved mode values remain compatible, and disabled capabilities leave their stored configuration intact.
{% endhint %}
