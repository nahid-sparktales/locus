# Troubleshooting

Resolve model, Agent, goal, capsule, document, output, browser, mobile, and update problems in Locus 2.6.

Start with the visible status in the sidebar, Overview, transcript, run board, Activity and Attention, or Runs. Locus reports the failing layer rather than silently changing routes.

## Local services or Ollama are unavailable

Wait for Starting or Recovering to finish. Confirm Ollama is installed and reachable at the configured host. A local model loads on the first prompt and may reload after a context-window change.

## ChatGPT sign-in or component fails

Open Settings → Updates and confirm the Codex component is installed. Retry the component download on a stable connection. A checksum or code-signature failure installs nothing; remove and reinstall the component if the verified archive is incomplete. ChatGPT-plan routing never falls back to an API key.

If /compact appears ineffective, update to 2.6; compaction resets the helper's server-side thread too.

## ChatGPT behavior changed after the update

Open the account editor and check **Codex-native mode**. New accounts begin with Locus's prompt and tools; accounts added before 2.1 keep their previous choice. Turning the toggle on or off restarts the conversation's server-side context, and the first message in an existing chat may replay history once.

Reasoning effort applies on the next turn without a reset. Web search is a separate, off-by-default toggle.

## A hosted account will not switch

Test the account, URL, key, and selected model. Kimi and Kimi Code use different hosts and credentials. Authenticated custom endpoints require HTTPS and cannot redirect. A rejected switch should restore the previous active route. Update to 2.6 if a ChatGPT or Kimi model is incorrectly reported as not installed.

## A model answers but cannot edit or see images

The route may lack tool calling or image input. Locus retries once without the rejected capability and records a note. Choose a tool-capable or vision-capable model for that request.

## A note opens empty

Update to 2.6 before typing into it. Locus now falls back to the formatting archive when the plain-text mirror is missing. Open Notebook with ⇧⌘9; older notes that cannot be matched to an existing owner appear under Unlinked.

## Browser input, layout, or Autofill fails

Refresh the page snapshot before reusing element identifiers. For a canvas or map, capture the region and target page coordinates. Confirm real input is enabled under Settings → Browser. Reload after changing the mobile-device presentation because sites choose their layout at navigation time.

Resize the inspector after updating to 2.6; the live page should follow the panel and wide pages should keep native horizontal scrolling.

For Autofill, confirm the vault is loaded and the required category is enabled for agent access. Passwords are origin-scoped. Browser JavaScript and dev-server startup require approval even in Bypass.

## Wallet controls are missing

This is expected in standard Locus 2.6.0: the app is wallet-free. Cryptocurrency wallet functionality belongs to the separate LocusX edition. Old wallet files and Keychain entries are not deleted or automatically migrated. [Identity Vault](safety-and-privacy/identity-vault.md) is a separate private profile-and-document feature.

## A named dev server will not start

Validate .locus/launch.json, executable, arguments, and port. Use a URL-only configuration to attach to an existing server. Read the bounded server output with a level or search filter.

## Mobile will not pair

Enable Mobile Access on the Mac, keep Locus or its menu-bar process running, and use a fresh five-minute code. Confirm both devices can reach each other over the LAN or Tailscale. A changed Mac certificate requires a new pairing.

## A command needs a full terminal

Use Terminal for interactive programs. Managed background services are better for watchers and servers that should survive an agent turn.

## A run shows the wrong files, steps, or usage

Update to 2.6. Overview and Activity are scoped to the selected run even when another run is live. Switch away and back if you were viewing data loaded by an older build.

## A team plan is repaired or a run reaches a limit

Open the board or Runs for the exact validation or budget boundary. Writer-step and model-call limits pause at a durable checkpoint; they are not success conditions. Repair the missing profile, credential, checkout, or budget and resume.

## Proxy traffic fails

Run a profile health check. In strict tunnel mode, external traffic remains blocked until a healthy route exists. PAC-based system proxy settings may not reach agent libraries; use a manual profile. A child process can report 407 because Locus withholds proxy passwords from it.

## Still blocked?

Record the Locus version, build channel, provider and model, visible error, and relevant Runs timeline. Do not include credentials. Report security issues privately to <security@sparktales.io>.

## An Agent is active but no chat is running

Active means the Agent is enabled for its trigger. Inspect the next occurrence or incoming-event record, connection health, and the exact execution status. A received, waiting, or skipped record is not a completed run. Locus must remain running for local work to execute.

## A goal has paused

Check whether the mode, account, team, allowance, or connection changed. Review any interrupted action with an unknown outcome before Resume. Required questions need a real answer; elapsed time is not approval.

## A Task Capsule will not run

Check the selected profiles, account availability, and implementation access ceiling. If a named file changed after planning, use **Update the plan or ask for help** to save a revision. Review partial file changes before starting another run.

## A document or output is missing

Enable Document knowledge for persistent document search and check the extraction status. Older DOC/XLS files need conversion; formulas without saved values and hidden spreadsheet sheets are omitted with warnings. Retry an extraction after correcting the source.

In Outputs, inspect the workspace storage budget and per-file limit. Missing originals cannot be reconstructed from older entries unless a version was already saved. Existing history remains available when limits are reached.

## The app does not update automatically

Locus 2.6.0 uses manual app updates. Install the desired version from its release page. A ChatGPT component update does not update the application. The old wallet-era feed does not migrate an installation to wallet-free Locus.
