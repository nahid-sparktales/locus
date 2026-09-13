# Agent World

Agent World is an optional Locus plugin. It opens a separate window containing
Orbital Outpost, a 3D overview populated by the user's saved agent
profiles. Conversations and work run through Locus's existing providers and
permissions. Exploring the world makes no model calls.

## Install and enter

Build the Locus version containing plugin screen support. In Settings →
Extensions, add this repository directory as a local marketplace if it has not
already been discovered from the current workspace. Install **Agent World**,
review its screen capabilities, and choose **Open**. Installed screens also
appear in the Work menu.

The repository's `.agents/plugins/marketplace.json` points to the distributable
package at `plugins/agent-world`. The web runtime and prepared assets are
included in that package. Users do not need Node, a Meshy account, or a Meshy
API key. Installing this plugin in a Locus version without screen support does
not provide a launchable world. This is a Locus screen extension, not a Codex
screen extension.

## Meet your agents

- In Locus’s **Agent** page, choose **New Agent** to use the same setup form as
  Agent World. Saving creates a named sidebar group and its first chat. Saved
  agents also appear as residents in the world.
- **Manage Agent → Add…** offers **New chat**, **On a schedule**, **When an event
  arrives**, and **When a price changes**. Each conversation and automation
  stays with that agent and uses its saved model, instructions, and access.
- Drag to orbit the overview camera; scroll to zoom.
- Click an agent or its label to interact. The searchable resident list also
  provides direct access to every agent.
- Available agents explore the commons and pause at landmarks. Agents with
  active work return to their assigned workstation. Selecting or hovering over
  a wandering agent pauses it so it is easy to interact with.
- Use **Chat** for a conversation or **Assign work** to start agentic work.
  The native conversation panel shows replies, progress, and any attention
  required. Existing Locus permission controls continue to apply.
- Each saved profile has a separate persistent conversation for each project.
  **Open in Locus** opens that same saved conversation in the main workspace.
  The world stays with the project it opened in; changing the main workspace
  does not redirect queued work. Use **Start a new conversation** in the
  resident's menu to deliberately replace that resident's saved binding.
- Closing the world releases its rendering resources. It does not stop work.
  Use the conversation's Stop action to interrupt a task.

The outpost combines planted commons, lounge areas, and workstations with
different resident designs. Each agent keeps a stable appearance. Additional
residents appear in sectors of up to twelve. A missing profile, unavailable
account, disconnected worker, or failed 3D renderer is
shown explicitly; the world never substitutes a different model account.

## Develop and verify

The frontend source lives in `AgentWorldWeb`. From that directory, run
`npm ci` and `npm run check`. The build writes the bundled runtime into
`plugins/agent-world/ui` and preserves the theme assets.

From the repository root, run `agent/.venv/bin/python
Tools/VerifyAgentWorldPackage.py` to validate the plugin, embedded GLB resources,
animation clips, asset hashes, and generation credit ledger. Use the repository's
normal Python and native test commands for the host and execution contracts.

For a standalone visual preview, serve `plugins/agent-world/ui` with a local
HTTP server. It displays a clearly marked demonstration roster when the native
Locus bridge is absent. Demonstration residents cannot start real agent tasks.

## Add a theme

A theme directory contains `theme.json` and self-contained GLB files. The
version-1 manifest describes the theme ID, name, description, palette, asset
paths, target model heights, orientation corrections, and optional map layout.
The layout can set the map radius, resident workstation positions, navigation
landmarks, and decorative props. All asset paths stay within the installed
plugin. Use embedded textures and geometry without external
Draco, Basis, or meshopt decoders.

Characters carry idle and walking animation clips, selected by their clip names.
Missing artwork uses simple geometry so agents remain reachable.
Changing artwork or a map does not change profile IDs, conversations, provider
routes, or permissions. The initial release includes only the outpost theme.

## Asset provenance and regeneration

The prepared assets were generated using Meshy for this project. Their prompts,
task IDs, hashes, and credit totals are recorded in the theme's
`provenance.json`. Babylon.js retains its Apache-2.0 license; packaged notices
are included with the plugin.

The original generation campaign consumed **112 Meshy credits**. The commons
campaign consumed **97 additional credits**, for **209 credits total**, and adds
two animated resident designs and three scenery models. Both campaigns are
recorded in `provenance.json`.
Eleven models are included: four animated resident designs and seven scenery
models. The original explorer is reused as an autonomous resident. The packaged
hashes identify the shipped files; submitting the same prompts again is not
guaranteed to reproduce identical models.

`Tools/GenerateAgentWorldAssets.py` is a developer-only generation utility. It
reads the Meshy key from a hidden prompt or `MESHY_API_KEY`, keeps the key in
memory, and reserves the documented credit cost before every submission. It
flushes reservations to disk before making paid requests and refuses a ceiling
of 1,000 or more. API redirects are rejected so authorization cannot be
forwarded to another host. A private state directory outside the
repository stores expiring provider responses and the durable ledger; resume
with that same directory and generation script to avoid submitting duplicate
tasks or relabeling older outputs with changed prompts. The utility rejects a
state directory inside this repository. Missing completed output files are
downloaded again from the existing tasks without new generation. Uncertain
submissions require reconciliation rather than an automatic retry. Failed
tasks remain recorded and are not automatically regenerated.

The ceiling bounds the recorded reservations using the prices in this script;
check those prices against Meshy's current pricing before starting a new asset
campaign. Keep the existing state directory when resuming a campaign. The
`commons` campaign requires the completed original ledger through
`--prior-ledger`; both ledgers count toward `--total-credit-ceiling`. Its
additional campaign ceiling cannot exceed 200 credits. Resume configuration is
bound to the original prompts, animation IDs, and prior ledger hash.

Asset generation is never part of plugin installation, startup, or normal use.
