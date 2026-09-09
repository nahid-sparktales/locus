> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/release-notes.md).

# Release Notes

Product changes across Locus 2.1, 2.0, and the V2 update line.

{% updates format="full" %}
{% update date="2026-08-30" tags="v2.1,current" %}

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
