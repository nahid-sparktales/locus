# Account controls and navigation verification

Base: `ce5c9ead67342c9a9689a5d2fe5bc80dc05d2c13` (v2.8.0).
Implementation branch: `codex/account-navigation-fixes`.

## Changes

- Read the managed helper's current `reasoningEffort` field as well as the older `effort` field. Preserve advertised choices, including `ultra`, and update the toolbar after asynchronous catalog arrival. Keep each effort choice separately accessible.
- Move speech engine, audio account, transcription model, speech model, and voice identifier into Manage Accounts. Keep microphone and playback behavior in Chat settings, with a link to the audio section. Settings search and section links scroll after the destination has mounted.
- Add the permission-gated ChatGPT GPT Image 2 route through an ephemeral native image thread. Keep native image tools disabled in ordinary chat threads. The selected account owns authentication; no API fallback is provided. Preserve existing cancellation, validated image bytes, task file history, atomic output writes, and artifact cards.
- Remember the last nonarchived chat independently for Work and Agent. Restore through the existing session lifecycle without starting a run. An empty destination hides the other tab's conversation while preserving its draft; the sidebar can still be reopened.
- Route configuration warning actions independently of their associated run. Clear Warning acknowledges the automation warning and refreshes Attention; Open Configuration focuses the saved automation, including when its list arrives later.
- Show Notebook in the Work sidebar and open the existing Notebook sheet. Agent retains Manage Agents, and the right rail still opens the Notes tab.

## Model availability finding

The inspected account-scoped helper catalog, fetched on 2026-09-10 at 02:38 UTC using the pinned 0.147.0 helper, did not contain `gpt-6-astra`, including among hidden entries. This is evidence about the catalog returned to Locus, not proof of the account's eligibility through every OpenAI application. The model endpoint has no Astra-specific exclusion. An HTTP route regression verifies that Astra and its advertised effort choices pass through when present.

## Deterministic validation

- Full backend suite: **2,332 passed**. Final focused image, catalog, and broker checks: **74 passed** after the last parser adjustment.
- Full macOS unit suite: **1,451 passed**. All **26 EventAutomationTests** passed after the final configuration-focus adjustment.
- **14 focused UI scenarios passed** across the final runs: late-arriving effort choices and selecting High; audio settings navigation; an empty Agent tab with sidebar collapse/reopen; restoring the last Agent chat; ChatGPT GPT Image 2 account settings; Notebook sheet versus Notes tab; sidebar layout; Activity Center; and Agent configuration, creation, draft preservation, saved settings, event queues, and schedule editing.
- Python lint, protocol manifest (revision 2), generated Xcode project, design-system audit, and whitespace checks passed.

Native tests ran on macOS 26.4.1 with Xcode 26.6 and use an isolated bundle identifier to avoid interfering with an already running production Locus. No production account, conversation, notebook, or settings store is used by UI fixtures. Earlier UI failures exposed inherited accessibility identifiers in the effort popover and an offscreen settings link; both were corrected before the passing rerun. Subsequent test assertions were aligned with the restored chat inspector and the full image-account menu label. Those scenarios passed on rerun.

Raw reports are retained locally in `/Users/nahid/Documents/locus-account-navigation-validation`. UI results are retained with their Xcode result bundles.

## Deferred validation and compatibility

Live ChatGPT image generation, live-provider recovery campaigns, and comparative benchmarks were not run. Stubbed helper results establish deterministic routing and failure handling, not subscription eligibility or live image availability. No metered provider requests were made.

The image-provider discriminator is additive and defaults to the legacy API route. Existing image settings and model names remain valid. Sidebar memory is an additive preference; no database migration is needed. Mobile wire behavior remains compatible. This change does not implement evaluation or cost accounting and does not publish a release.
