from pathlib import Path
import json, re, shutil, os, difflib, hashlib

ROOT = Path(__file__).resolve().parent
PAGES = ROOT / 'pages'
BEFORE = ROOT / 'before'
manifest = json.loads((ROOT / 'manifest-before.json').read_text())

def normalize(s):
    return re.sub(r'^> For the complete documentation index,.*?\n\n', '', s, count=1).strip()+'\n'

for p in BEFORE.rglob('*.md'):
    dst=PAGES/p.relative_to(BEFORE)
    dst.parent.mkdir(parents=True,exist_ok=True)
    dst.write_text(normalize(p.read_text()))

def read(path): return (PAGES/path).read_text()
def write(path, text):
    p=PAGES/path; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(text.strip()+'\n')
def replace(path, old, new):
    s=read(path)
    assert old in s, (path,old[:100])
    write(path,s.replace(old,new))
def section(path, heading, body):
    s=read(path)
    pattern=r'^## '+re.escape(heading)+r'\n.*?(?=^## |\Z)'
    s,n=re.subn(pattern,lambda _:body.strip()+'\n\n',s,flags=re.M|re.S)
    assert n==1,(path,heading,n)
    write(path,s)
def append(path, body): write(path,read(path)+'\n'+body)

write('locus.md', '''# Locus

Your models, projects, agents, and tools in one native macOS workspace.

Locus 2.6 brings conversations, files, a terminal, browser tabs, plans, recurring Agents, and saved deliverables together. Use local Ollama, an eligible ChatGPT plan, or a provider API account. Local Ollama is the default; Locus never silently switches to a paid account.

![Locus workspace with the conversation, model selector, and Files panel](assets/locus-workspace-dark.png)

*The wallet-free workspace with demonstration data. The Files panel keeps project material beside the conversation.*

[Download Locus 2.6.0](https://github.com/nahid-sparktales/locus/releases/tag/v2.6.0) · [Product website](https://locushost.co) · [Release notes](release-notes.md)

## Start with the work you want to do

| Your task | Start here |
| --- | --- |
| Connect a model and complete your first request | [Getting Started](getting-started.md) |
| Work with project files, the browser, and a terminal | [Working in Locus](working-in-locus.md) |
| Search documents and keep deliverable versions | [Library, Documents & Outputs](working-in-locus/library-documents-and-outputs.md) |
| Run work on a schedule or incoming event | [Agents & Automation](working-in-locus/agents-and-automation.md) |
| Keep a chat working toward an objective | [Persistent Goals](working-in-locus/persistent-goals.md) |
| Plan with one model and implement with another | [Task Capsules](working-in-locus/task-capsules.md) |
| Delegate to helpers or a configured team | [Agent Teams](agent-teams.md) |
| Reuse private profile details with explicit review | [Identity Vault](safety-and-privacy/identity-vault.md) |

## What is new in 2.6

**Agents have a clearer home.** Search configured Agents, review instructions and triggers, inspect connection health, and follow exact runs. Connections and shared Runtime settings have their own sections. Reusable model profiles are labeled **Specialists & teams**.

**Answers and files are easier to use.** Structured answers can show file collections, writing drafts, deliverables, and source references. Writing drafts support editing, copying, recovery of the original, and export. Tables can copy or export all rows even when their display is collapsed. Files browses generated folders and all file types, with path search and an explicit hidden-file control.

**Longer work keeps its context.** Persistent goals, saved Task Capsules, the workspace Library, and versioned Outputs carry progress between turns. The current release also includes clearer compact controls and more reliable mobile transcript refresh.

## Requirements and editions

Use an Apple Silicon Mac running macOS 14 or later. Packaged apps include the agent runtime. Local Ollama and model weights are separate installations; hosted accounts use their own access and billing.

**Locus is wallet-free.** Wallet functionality belongs to the separate **LocusX** edition. Identity Vault is a private profile-and-document feature and does not provide cryptocurrency wallets. Installing Locus preserves existing Locus chats, accounts, settings, and browser data; it does not import or delete wallet data.

These docs describe the **2.6.0 release**. This release uses **manual app updates**. See [Install Locus](getting-started/install-locus.md) before upgrading an older installation.

Screenshots use demonstration data. Your selected model, files, and activity will differ.
''')

write('getting-started.md', '''# Getting Started

Connect a model, choose a workspace, and complete your first Locus task.

1. [Install Locus](getting-started/install-locus.md) on an Apple Silicon Mac running macOS 14 or later.
2. Open **Help → Getting Started** if setup does not open automatically.
3. Choose a document/research or coding example, connect a model, and choose a workspace.
4. Select **Run first task** when you are ready. Setup reuses your existing connections and workspaces.
5. Review the finished response and its saved file in **Library → Outputs**.

You can go back or skip while keeping setup progress. Connection and task errors can be retried. Setup records success only when the first task finishes and its output has been saved.

Local Ollama is the default. A ChatGPT-plan account and an API-key account are separate routes; selecting one does not silently fall back to the other.

For your own project, follow [Your First Workspace](getting-started/your-first-workspace.md). Start with **Ask every time** permissions while you learn how file and command approvals work.
''')

write('getting-started/install-locus.md', '''# Install Locus

Install the wallet-free Locus 2.6.0 release and choose your model source.

## Requirements

- Apple Silicon Mac running macOS 14 or later.
- One model source: local Ollama with a downloaded model, an eligible ChatGPT plan, or a supported API account.

The packaged app includes its Python agent runtime. You do not need a separate Python installation, Homebrew, Rust, Codex CLI, or a running ChatGPT or Codex app. Ollama and model weights are separate installations.

## Install and open

1. Download **Locus-macOS.zip** from the [2.6.0 release](https://github.com/nahid-sparktales/locus/releases/tag/v2.6.0).
2. Unzip it and move **Locus.app** to Applications.
3. Open Locus and follow Getting Started. Existing users can reopen setup from **Help → Getting Started**.
4. Choose local Ollama or connect your account under **Settings → Models & Providers**.
5. Choose a workspace and review your permission mode before sending a request.

## ChatGPT-plan components

ChatGPT-plan access uses pinned Codex helpers. Direct release builds normally offer them as a separate component download when you add that account. Ollama and API-key accounts do not need the component. Downloaded components must pass checksum and SparkTales code-signature checks before installation or execution. A failed check preserves the previous installation.

Debug and Mac App Store builds bundle the helpers; direct builds can also explicitly bundle them. Use **Settings → Updates** for the component's available controls.

## Updating 2.6.0

**Locus 2.6.0 uses manual app updates.** Download and install the desired release yourself. The old signed app feed remains available to earlier wallet-era installations and does not automatically move them to wallet-free Locus. Component downloads are separate from app updates.

Installing the standard Locus app preserves existing Locus chats, accounts, settings, and browser data. Wallet files and Keychain entries are left untouched and are not automatically imported. Follow the release notes for the version you install.

## Locus and LocusX

| Edition | Wallet functionality | App data |
| --- | --- | --- |
| Locus | Excluded | Keeps the existing Locus profile |
| LocusX | Separate optional wallet implementation | Independent chats, accounts, settings, and browser profile |
| Mac App Store build target | Excluded | Uses the sandboxed app distribution |

The direct-download distribution supports optional Computer Control; the Mac App Store target excludes it. The built-in browser is available in both. The existence of a build target does not imply a currently available App Store listing.
''')

replace('getting-started/your-first-workspace.md','Locus 2.1 request','Locus 2.6 request')
replace('getting-started/your-first-workspace.md','Just Chat','Ask')
replace('getting-started/your-first-workspace.md','delegate bounded read-only research','delegate bounded research or isolated coding work')
append('getting-started/your-first-workspace.md','''## Save and revisit the result

Open **Library** from the sidebar or press **⇧⌘L**. Documents and Outputs open without replacing the current conversation or its draft. Outputs keeps saved versions of deliverables, links back to the source chat, and offers preview, export, compare, and revision actions.

For guided examples, use **Help → Getting Started**. The document example produces `Locus Summary.md`; the coding example produces `Repository Overview.md`.
''')

replace('getting-started/chat-work-plan-and-build.md','Just Chat','Ask')
replace('getting-started/chat-work-plan-and-build.md','bounded read-only delegation','bounded research or isolated coding delegation')
replace('getting-started/chat-work-plan-and-build.md','or ask temporary read-only workers for parallel evidence','or ask helpers for research or isolated coding work')
section('getting-started/chat-work-plan-and-build.md','Grill mode','''## Grill mode

Use **Grill**, ⌥G, or `/grill` to refine a request through one focused question at a time. It develops a shared understanding before project changes. After approval, implementation continues in Work.

Required questions remain pending until answered; they do not gain approval from elapsed time. Optional questions can appear above the composer while independent work continues. Their visible recommendation may be used after Skip or the displayed timeout. A defaulted recommendation is labeled as such and is never permission to perform a protected action.

Older saved mode values remain compatible. Use the current Ask, Work, Plan, and Grill labels when choosing a mode.
''')
append('getting-started/chat-work-plan-and-build.md','''## Continue beyond one turn

Use [Goal](../working-in-locus/persistent-goals.md) for an ordinary Solo or team chat that should continue toward a saved objective. Use [Task Capsules](../working-in-locus/task-capsules.md) for a saved plan with explicit planning, implementation, and optional review models.
''')

write('working-in-locus.md', '''# Working in Locus

Keep the conversation, project tools, and the record of the work together.

- [Conversations & Context](working-in-locus/conversations-and-context.md): organize chats, choose context, and work with answers and files.
- [The Inspector](working-in-locus/the-inspector.md): follow the current request in Overview and inspect files, tools, runs, and the selected Agent.
- [Library, Documents & Outputs](working-in-locus/library-documents-and-outputs.md): search document knowledge and preserve deliverable versions.
- [Agents & Automation](working-in-locus/agents-and-automation.md): configure scheduled and event-driven work, workflows, and connection access.
- [Persistent Goals](working-in-locus/persistent-goals.md): keep an ordinary chat working toward an objective across turns.
- [Task Capsules](working-in-locus/task-capsules.md): save a detailed plan and choose models for each stage.
- [Git Changes & Terminal](working-in-locus/git-changes-and-console.md): review real changes and run interactive commands.
- [Browser & Dev Servers](working-in-locus/browser-and-dev-servers.md): use shared web tabs and named local previews.
- [Mobile, Schedules & Background Work](working-in-locus/mobile-schedules-and-background-work.md): continue through the companion and understand when local work can run.
- [Shortcuts & Slash Commands](working-in-locus/shortcuts-and-slash-commands.md): navigate from the keyboard.

**Manage Agents** opens the persistent Agent collection. **Library** opens Documents and Outputs without replacing the current chat. **Notebook** brings standalone, workspace, chat, and shared notes together. The right inspector keeps the tools relevant to your current selection beside the conversation.
''')

append('working-in-locus/conversations-and-context.md','''## Writing drafts and structured answers

Answers can include verified file collections, reusable writing, deliverables, and source references with a complete Markdown fallback. Editable writing drafts support copying, export, and recovery of the original text. Table copy and CSV export include all rows even when the displayed table is collapsed.

Context controls choose information included in the chat; they do not grant broader file access. File access still follows the workspace and permission boundaries.

## Saved deliverable history

Use [Library → Outputs](library-documents-and-outputs.md) to revisit saved versions, compare changes, export a snapshot, or prepare a revision. Opening Library preserves the current chat and draft. Saved snapshots remain available when the original workspace file is removed, provided the version was captured successfully.
''')
replace('working-in-locus/conversations-and-context.md','Just Chat','Ask')
section('working-in-locus/conversations-and-context.md','Notebook, knowledge, and continuity','''## Notebook, knowledge, and continuity

Open **Notebook…** from the sidebar menu or press **⇧⌘9**. Create a standalone note with **New Note**, search full note text, pin or duplicate a note, and export text or RTF. Workspace, chat, and shared notes keep their existing ownership. Standalone notes are not automatically included in agent context.

Deleted notes remain in **Recently Deleted** until you explicitly remove them. You can preview and restore them. Permanent deletion requires confirmation; no automatic deadline applies.

Eligible agentic modes can query enabled workspace knowledge. [Document knowledge](library-documents-and-outputs.md) is a separate opt-in. Long-term memory is added only after explicit approval, and encrypted continuity preserves development state across chats.

Ask mode does not receive workspace tools, skills, knowledge retrieval, or continuity.
''')

replace('working-in-locus/the-inspector.md','**AGENTS.md**','**Instructions**')
replace('working-in-locus/the-inspector.md','Workspace search, inline previews, context actions, and paths','All file types and generated folders, path search, explicit hidden-file visibility, previews, and context actions')
append('working-in-locus/the-inspector.md','''## Overview, Agent, and Runs

**Overview** follows the current request in the open conversation: the request summary, plan, sources, outputs, tool activity, helpers, and completion state. It does not combine every request into one plan.

The **Agent** panel describes the selected persistent Agent, including instructions, trigger health, environment, access, and recent activity. Selecting an Agent and selecting one of its chats are separate actions. An Agent being active means it is enabled; it does not necessarily mean a chat is currently running.

**Runs** opens the current chat's executions and keeps exact event, occurrence, attempt, and output records. A received event is not proof of a successful execution. Use record details to distinguish waiting, skipped, failed, cancelled, and completed work.

**Instructions** is the workspace `AGENTS.md` panel. Reusable specialist profiles are configured through **Specialists & teams**.
''')

section('working-in-locus/git-changes-and-console.md','Files','''## Files

Files browses all file types and generated folders, with incremental folder expansion, path search, and an explicit control for hidden files. Available previews depend on the file type. Add a file to context, insert an @ mention, reveal it in Finder, or copy its relative path.

Browsing a file does not automatically add it to model context or document knowledge. Use Context for the chat and Library's Document knowledge setting for persistent document indexing.
''')
section('working-in-locus/browser-and-dev-servers.md','Locus Vault browser access','''## Wallet-free Locus

Standard Locus does not include a cryptocurrency wallet, wallet tools, or browser wallet-provider injection. Wallet functionality belongs to the separate LocusX edition. The [Identity Vault](../safety-and-privacy/identity-vault.md) is a separate feature for private profile details and documents.
''')

write('working-in-locus/agents-and-automation.md', '''# Agents & Automation

An Agent saves instructions, a model route, an environment, and one trigger for recurring work. It owns a primary conversation and can have side chats for investigation.

## Create an Agent

1. Open **Manage Agents** and choose **New Agent**.
2. Choose what starts the work: a **schedule**, **incoming event**, or **price condition**.
3. Enter a name and clear instructions, then configure the cadence or matching conditions.
4. Review the model, workspace or environment, and allowed connected-service actions. Advanced settings reveal additional controls.
5. Save the Agent. An incoming-event Agent can be created paused so you can review its configuration before enabling it.

For example: “Review the workspace and summarize what changed since yesterday. Include the relevant files and any items that need my decision.” Choose the schedule and model that fit that request.

![Scheduled Agent with instructions, controls, next occurrence, and run records](../assets/locus-schedules-dark.png)

*Demonstration data: the Agent panel distinguishes an enabled Agent from running chats and shows individual scheduled occurrences.*

## Find configuration and activity

| Section | Use it for |
| --- | --- |
| Agents | Search and filter configured Agents; inspect instructions, triggers, access, and recent activity |
| Activity | Review recent schedule and event records, filter by Agent or status, and inspect supported retry actions |
| Connections | Review shared source connections, their health, last check, and which Agents use them |
| Runtime | Set shared local concurrency and execution context; open specialist and team settings |

The right **Agent** panel follows the selected Agent. **Overview** follows the open conversation. **Runs** shows that chat's executions. Activity's recent list is an entry point; the contextual inspector carries the exact durable record and its available evidence.

## Triggers and service access

Incoming events can use configured Gmail, Telegram, or signed webhook sources. Price conditions use configured price sources and a symbol or threshold. Each Agent currently has one trigger.

A connection used to receive events is separate from permission to perform service actions. Grant only the action connections that the task needs. Clearing every action grant keeps the selection empty. Webhook and price-feed identifiers are not action grants.

Tool approval mode is shared across chats and worker runtimes. The Agent's workspace, environment, and service restrictions still apply. Selecting a hosted model does not turn the Agent into a cloud service.

## Workflows and Attention

Automation workflows can sequence **Agent**, **Condition**, and **Approval** steps. The simulator previews templates, branches, outputs, and approval cards without calling a model or creating chat history.

Each occurrence records its workflow, attempts, and approval state. After interruption or failure, inspect the occurrence before resuming. An uncertain external action is not silently repeated.

**Attention** collects questions, permissions, workflow approvals, recoverable runs, retryable failures, and configuration warnings that need a decision. Routine successful activity belongs in Activity.

## Pause, run, and recover

Use **Pause** to stop automatic triggering and **Run now** for supported manual runs. Read an occurrence's status before retrying: receipt, delivery, and execution outcomes are distinct. A previous successful chat does not make a later failed or cancelled delivery successful.

Locus must be running and the Mac available for work to execute. Quitting does not leave a cloud worker behind. Review connection errors, missing accounts, and interrupted actions before restarting work.

For ongoing work in an ordinary chat, use [Persistent Goals](persistent-goals.md). For a saved model-to-model plan, use [Task Capsules](task-capsules.md). Reusable model profiles are configured under **Specialists & teams**.
''')

write('working-in-locus/persistent-goals.md', '''# Persistent Goals

Give an ordinary Solo or team chat an objective that continues across turns in Work mode.

## Start and supervise a goal

1. Open an idle ordinary chat and choose the account or team that should do the work.
2. Select **Goal** beside the composer. Enter the objective and optional model-call or token allowances, then select **Start goal**.
3. Follow the goal card for progress and cumulative usage. Send a message to refine the request while keeping the objective.
4. Use **Pause** or Stop to stop automatic continuation. **Resume** returns to Work mode. **Edit** saves changes while paused. **End** closes the goal without claiming the objective was achieved.

Only one unfinished goal can belong to a chat. Switching to Ask, Plan, or Grill pauses it. Changing the model or team also pauses it; save the newly selected configuration through Goal before resuming. Editing the objective or allowances preserves accumulated usage.

Queued messages take priority over automatic continuation. Unsent drafts and attachments stay in the composer. A finished turn is an intermediate result: completion requires evidence from the coordinating agent that the objective has been achieved.

## Understand allowances

Usage accumulates across turns, helpers, team stages, retries, and restarts. Goal allowances do not replace profile or team limits. Tokens describe provider-reported input and output, not currency or remaining subscription quota. In-flight responses can exceed an allowance, and provider-internal work can only be counted as exposed by the provider.

If an allowance cannot be enforced from the available measurements, the goal pauses. Exhausted, blocked, and paused goals need attention before continuing.

## Reopen and recover

Locus must be running for work to execute. Quitting saves the goal; reopening restores eligible goals with their original account, team, and workspace. It does not install a service that works after Locus quits.

Review partial work and usage before resuming an interrupted operation with an unknown outcome. Locus does not automatically replay it. Missing accounts or workspaces, incompatible team changes, and repeated missing progress can stop continuation.

Permissions and required questions keep their normal behavior. Losing a connection or waiting longer never grants approval. Scheduled Agents, workflows, Task Capsules, and Identity tasks have separate execution lifecycles.
''')

write('working-in-locus/task-capsules.md', '''# Task Capsules

Save a detailed plan with explicit models for planning, implementation, and optional review. A capsule keeps its plan, revisions, model choices, usage allowances, and run history together.

## Set up and run

1. Connect the accounts you want to use under **Models & Providers**.
2. In **Specialists & teams**, configure reusable profiles with the desired account and model. An implementation profile needs an **Access ceiling** of **Workspace edits**. One profile can serve more than one role.
3. Open **Locus → Task Capsules…** or press **⌥⌘K** in the target workspace.
4. Describe the task or customize an editable example. Choose **Plan with**, **Implement with**, and optionally **Review with**. Set optional allowances under **Advanced · Usage limits**.
5. Select **Generate plan**. Planning is read-only; answer any clarification in its conversation. A successful structured plan saves automatically.
6. Reopen the capsule and review instructions, constraints, checks, and design decisions. **Expand steps** reveals the detail. Choose **Run plan** when ready.
7. Review stage outcomes and available usage in run history. **Review result** runs a separate read-only review; **Run again** starts another execution of an existing plan.

If profiles are missing, **Set up models** opens settings while preserving the task description. **Continue planning** returns to a waiting planner's conversation.

## Accounts remain explicit

Each stage uses the exact account assigned to its profile. An unavailable account stops the stage. ChatGPT-plan and Kimi Code membership routes never silently fall back to metered APIs. Capsule choices do not permanently replace the ordinary chat's model selection.

## Saved plans and changed files

A detailed plan can contain up to 16 ordered steps. Execution follows dependencies sequentially. Before execution, Locus checks fingerprints for files named in those steps, including planned new files. Changed, removed, or unexpectedly created files pause the handoff.

Choose **Update the plan or ask for help** to inspect the current workspace and save a revision. Fingerprints cover named files, not the whole repository. Older plans without named files have no file baseline.

## Limits, review, and recovery

Planning and standalone review have per-turn model-call allowances. Implementation, its automatic reviewer, and repairs share the execution allowance. Profile runtime and response limits still apply. A failed or malformed review does not count as approval.

Optional API cost limits are estimates for configured execution prices, not hard billing ceilings. They exclude planning, standalone review, tool charges, and image generation. Subscription routes record exposed calls and tokens without inventing per-token subscription prices.

Asking the planner for help is explicit. Repair and help allowances accumulate across the capsule, including later runs. Increasing a limit does not erase previous attempts.

Stopped work keeps the files already changed and its run evidence. Inspect them before repeating execution. Partial changes may require a revised plan; recovery returns to Task Capsules instead of silently restarting a team checkpoint.
''')

write('working-in-locus/library-documents-and-outputs.md', '''# Library, Documents & Outputs

Open **Library** from the sidebar or press **⇧⌘L**. Documents and Outputs open without replacing your selected conversation or its draft.

## Add document knowledge

Turn on **Document knowledge** for the workspace to discover supported documents. This is separate from text and code indexing. **Import** copies external files into the visible `Locus Documents` folder and chooses a new name if one already exists.

| Format | What is indexed |
| --- | --- |
| PDF | Page text, with local text recognition for pages without useful text |
| DOCX | Body paragraphs and tables, with source locations |
| XLSX | Visible sheets and cells using cached formula values |
| CSV and TSV | UTF-8 delimited tables |

Convert older DOC and XLS files first. Word headers, footers, footnotes, endnotes, and text in images are not indexed. Hidden spreadsheet sheets and formulas without saved values are omitted with warnings; Locus does not calculate formulas.

For PDFs with an unreliable text layer, use **Recognize all pages**. Recognition runs locally and depends on scan quality; it does not reconstruct the original page layout or tables.

Attaching a document to a chat uses temporary extraction and does not opt the workspace into persistent document knowledge.

## Search and check sources

Search results identify the source and location. PDF results open the cited page; Word and table results open the extracted section. Locus identifies a source that has changed since it was cited. Document previews offer **Open in App** and **Reveal**.

Extraction supports files up to 100 MB, 500 PDF pages, 200,000 spreadsheet cells, and 5 MB of extracted text. Partial results and failures remain visible. Cancel or retry a job as needed. Unchanged files are skipped during refresh; failed files retry after their contents change or you choose Retry. Temporary jobs expire after 24 hours.

## Keep output versions

Outputs saves immutable snapshots of captured deliverables and links them to their source chats. Identical content does not create another version. The default storage budget is **2 GB per workspace**, adjustable in Outputs, with a **100 MB per-file limit**.

If a storage limit is reached, existing history remains available and Locus identifies content it could not save. History is never silently purged. Removing output history does not delete the original workspace file.

Earlier output entries with an available source file receive **Imported current version**. Missing files remain visible as unavailable entries; older versions are not reconstructed. Websites remain live links, while local HTML files can be saved as snapshots.

## Review or revise a deliverable

1. Select an output and version to preview or export it.
2. Compare it with a previous version when available.
3. Choose **Revise** to open a draft in the output's workspace with the selected snapshot attached and the destination stated.
4. Review and send the draft through the normal agent workflow.

The saved reference stays unchanged. A successful edit can produce a new version for later comparison.
''')

section('working-in-locus/mobile-schedules-and-background-work.md','Scheduled tasks','''## Scheduled Agents

Open **Manage Agents** to create a schedule and review its instructions, model, cadence, and workspace. Each scheduled Agent owns a stable primary conversation across runs. Its Agent panel shows controls, the next occurrence, and recorded runs. Use Pause or Run now as needed; the mobile companion also supports schedule controls.

![A scheduled Agent's instructions, next occurrence, and run history](../assets/locus-schedules-dark.png)

*Demonstration data. Enabled status and actual running chats are shown separately.*

Use **Activity** for recent records and **Attention** for decisions or recoveries. See [Agents & Automation](agents-and-automation.md) for event triggers, connected-service access, and workflows.

Locus must be running and the Mac available for scheduled work to execute. Closing a window is different from quitting the app. The schedule is not a hosted cloud worker.
''')
replace('working-in-locus/mobile-schedules-and-background-work.md','Locus V2 can keep useful work available after the main window closes without turning your Mac into a cloud relay.','Locus can continue work through its local runtime while the app remains running. The mobile companion connects directly to that Mac.')

replace('agent-teams.md','Adaptive Work and Plan may create temporary read-only workers when parallel investigation helps; they share the selected model and fixed limits while the primary agent remains responsible for the result.','Solo collaboration can use reusable research helpers and isolated coding helpers. Helpers inherit the active provider, account, model, and reasoning settings; the coordinating agent reviews their evidence and validates combined changes. Non-Git or unsupported coding snapshots fall back to research instead of shared writes.')
append('agent-teams.md','''## Agents, specialists, goals, and capsules

**Manage Agents** configures persistent scheduled or event-driven Agents. **Specialists & teams** configures reusable behavior, models, and access ceilings for delegated work.

An ordinary Solo or team chat can use a [Persistent Goal](working-in-locus/persistent-goals.md) for continued work across turns. [Task Capsules](working-in-locus/task-capsules.md) save a detailed plan with planning, implementation, and optional review profiles. Each keeps its own execution and recovery controls.
''')

section('extensions-and-mcp/workspace-knowledge-and-memory.md','Encryption details','''## Encryption details

Memory content and optional semantic vectors are encrypted with AES-256-GCM. The backend's memory key is stored in its local `memory/master.key` file with user-only access; it is not protected by a separate per-application Keychain prompt. Continuity uses the backend memory encryption key.

Treat the local application profile and backups as private data. Memory export deliberately writes readable JSON. The separate Identity Vault uses its own edition-specific Keychain key.
''')
section('extensions-and-mcp/bundled-workflows-notes-and-continuity.md','Notebook and Notes','''## Notebook and Notes

Open **Notebook…** from the sidebar menu or press **⇧⌘9**. **New Note** creates a standalone note; ⌘N does the same while Notebook is frontmost. Notes autosave, and failed saves offer Retry.

Rename, duplicate, pin, search full note text, or export as text or RTF. Workspace, chat, and shared notes preserve their ownership and existing Notes-panel behavior. Renaming their Notebook title does not change that ownership. Standalone notes are not automatically available through agent Notes tools.

Deleted notes remain in **Recently Deleted** until explicitly removed. Preview and restore them there. **Delete Permanently** and **Empty Recently Deleted** require confirmation; there is no automatic deletion deadline. Deleting an owned note pauses its Notes-panel editing until restoration or an explicit new note.
''')

write('safety-and-privacy/identity-vault.md', '''# Identity Vault

Keep reusable personal, business, and career details, original documents, signatures, and writing drafts in an encrypted vault on your Mac. Open it below Library or choose **Use Identity Vault…** in the composer.

Identity Vault does not sync to a cloud service or automatically import contacts, Library documents, or browser Autofill records. It is separate from LocusX cryptocurrency wallet functionality.

## Create a career profile or draft

1. Import PDF, DOCX, TXT, PNG, or JPEG material up to 100 MB. Text extraction and recognition run locally.
2. Review the extracted text, save the original, and choose **Create career profile from text…**. Correct the proposed fields before using them.
3. Choose **Write with AI** to open a separate Identity task. Review the career details that may be sent to the selected provider.
4. Review generated claims before saving. **Create PDF & Word** produces a single-column PDF and editable DOCX, inserting private contact details locally.
5. Use **Export this version…** only when you want an ordinary decrypted file outside the vault. Previous vault versions remain available.

## Use a profile in a private application

An Identity task can open an HTTPS application in a fresh, nonpersistent browser context. Existing browser logins are not copied.

**Fill from Profile…** and **Attach Document…** work locally without sending the page or private values to an AI provider. Review the exact values, document version, destination, and controls before releasing them. Unclear matches remain blank. Unsupported or embedded forms need manual completion.

**Continue with AI…** asks you to review one exact page-text snapshot. Only approved text reaches the selected account; later snapshots need another review. Agent-driven website actions receive a native confirmation, including actions that may submit. Websites may receive data as soon as it is filled or attached.

Signature images can be previewed and explicitly uploaded. Signing PDFs and filling PDF forms are outside this release.

## Privacy and supported routes

Vault content and metadata use AES-GCM with an edition-specific Keychain key. Search and previews use decrypted memory without a plaintext index or preview cache. Lock, sleep, and quit clear decrypted state, cancel work, and close private browser contexts. Unlocking the Mac makes the vault available without a second prompt.

Sharing is bound to the requesting task and actual provider, account, endpoint, and model. Restoring or changing context requires renewed review. **Sharing History** records completed releases. Revocation blocks future use but cannot recall data already sent. Generated replies follow normal chat retention; exported copies follow their destination's storage rules.

The protected workflow currently supports **Local Ollama and API providers**. Managed ChatGPT-plan Identity tasks are disabled because that retained provider-side context cannot yet enforce this boundary. General shell/filesystem tools, MCP, Computer Control, teams, automatic fallback, and background execution are unavailable in Identity tasks, including under Bypass mode.
''')

write('safety-and-privacy.md', '''# Safety & Privacy

Your Mac stores the workspace and its history. The account and capabilities you select determine what information is sent elsewhere.

- [Permission Modes](safety-and-privacy/permission-modes.md) explains shared approval settings and tool boundaries.
- [Credentials & Local Data](safety-and-privacy/credentials-and-local-data.md) covers credentials, transcripts, memory, documents, output versions, browser data, and mobile pairing.
- [Identity Vault](safety-and-privacy/identity-vault.md) provides private profiles and documents with exact review before release.
- [Native Computer Control](safety-and-privacy/native-computer-control.md) describes optional foreground Mac interaction.
- [Network Proxies](safety-and-privacy/network-proxies.md) covers route profiles, strict tunnel settings, and failover.
- [Agents & Automation](working-in-locus/agents-and-automation.md) explains triggers, connected-service action grants, approvals, and local execution.

Hosted providers receive the prompts and context sent through their selected accounts. Local Ollama is the default. Adding context, selecting an Agent or team, or connecting a source does not grant unlimited file or service access.

**Standard Locus is wallet-free.** Cryptocurrency wallet functionality belongs to the separate LocusX edition. Installing Locus does not import or delete old wallet data. Identity Vault and Browser Autofill are distinct features with their own controls.
''')

replace('safety-and-privacy/credentials-and-local-data.md','Approved memory and continuity snapshots are encrypted with AES-256-GCM; the key is stored in Keychain.','Approved memory and continuity snapshots are encrypted with AES-256-GCM; the backend key is a local `memory/master.key` file with user-only access. Identity Vault uses its own edition-specific Keychain key.')
section('safety-and-privacy/credentials-and-local-data.md','Locus Vault','''## Editions and Identity Vault

Standard Locus excludes cryptocurrency wallets, wallet tools, and browser wallet-provider injection. LocusX is a separate edition with an independent app profile. Existing wallet files and Keychain entries are left untouched, with no automatic import or migration.

[Identity Vault](identity-vault.md) encrypts reusable private details and documents separately. Exporting a version creates a decrypted file at a destination you choose. Approved releases and generated model replies have their own retention; revocation cannot recall already shared data.

Deleting a chat moves it to recoverable local storage and does not delete workspace files.
''')
append('safety-and-privacy/credentials-and-local-data.md','''## Library and saved outputs

Document knowledge is opt-in per workspace. Import copies external documents into the workspace's visible `Locus Documents` folder. Chat attachments do not automatically enable persistent knowledge.

Outputs stores metadata and immutable file snapshots locally under Application Support. These are ordinary local deliverable snapshots, separate from the encrypted Identity Vault. Removing output history does not delete original files; reaching a storage budget does not silently purge saved history.
''')
append('safety-and-privacy/permission-modes.md','''## Shared policy and Agent access

Tool approval mode is shared across chats and worker runtimes. Each Agent still has its own workspace/environment boundaries and explicitly allowed service actions. Receiving events from a connection does not automatically authorize sending or editing through it. Saving an empty action selection keeps all of those actions disabled.

Adding a file to Context controls what is included in the chat; it does not expand filesystem permissions. Persistent goals, teams, and Task Capsules keep the existing approval boundaries. Optional question defaults are not user approval; required decisions remain pending.
''')

section('troubleshooting.md','Locus Vault is unavailable','''## Wallet controls are missing

This is expected in standard Locus 2.6.0: the app is wallet-free. Cryptocurrency wallet functionality belongs to the separate LocusX edition. Old wallet files and Keychain entries are not deleted or automatically migrated. [Identity Vault](safety-and-privacy/identity-vault.md) is a separate private profile-and-document feature.
''')
append('troubleshooting.md','''## An Agent is active but no chat is running

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
''')
replace('troubleshooting.md','Fix common Locus 2.1 runtime, component, model, browser, Notebook, Vault, run, mobile, proxy, and recovery problems.','Resolve model, Agent, goal, capsule, document, output, browser, mobile, and update problems in Locus 2.6.')
replace('troubleshooting.md','Activity Center','Activity and Attention')

write('developer-guide/build-and-test.md', '''# Build & Test

Build wallet-free Locus from the repository's `main` branch with Xcode 26 and XcodeGen. `project.yml` is the source of truth for the generated Xcode project.

## Build for Ollama and API accounts

From the repository root:

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Locus.xcodeproj -scheme Locus -configuration Debug \\
  -destination 'platform=macOS' -derivedDataPath build/locus \\
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \\
  LOCUS_DIRECT_ENTITLEMENTS=Config/LocusDirectAdHoc.entitlements \\
  LOCUS_BUNDLE_CODEX=skip build
open build/locus/Build/Products/Debug/Locus.app
```

The first build downloads the standalone Python runtime. `LOCUS_BUNDLE_CODEX=skip` omits optional ChatGPT helpers and avoids their Rust build. To include them, install Rust through rustup and remove that setting; the pinned Codex source selects its toolchain. LocusX additionally needs the signer toolchain pinned in `WalletSignerCore/rust-toolchain.toml`.

Use separate build directories for Locus and LocusX. Locus and LocusMAS exclude wallet code, SDKs, resources, signer helpers, and wallet browser injection. A backend setting cannot enable wallet tools in the standard staged app.

## Native tests

For common native tests, replace the final `build` above with `test -only-testing:LocusTests`. LocusX uses its own scheme, build directory, and `LocusXTests`. Run relevant UI checks for interface changes. Consult the repository's CI workflow for the exact release checks.

## Backend tests

From the repository root, use Python 3.10 or later:

```sh
python3 -m venv agent/.venv
agent/.venv/bin/pip install -e './agent[dev]'
agent/.venv/bin/python -m pytest -q
```

Tests use disposable application data. CI currently uses Python 3.14.

## Mobile checks

From the mobile checkout with its pinned Flutter SDK:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter build ios --simulator --no-codesign
```

## Packaging

Packaged apps must include the agent runtime. `LOCUS_BUNDLE_MODE=skip` is a compile-only shortcut, not a deliverable app. Direct release builds normally deliver ChatGPT helpers separately; Debug and ReleaseMAS bundle them. Component delivery verifies checksums and signing identity before execution.

Locus 2.6.0 uses manual app updates. Follow the version's release procedures and edition audit; do not publish wallet-free Locus through the preserved legacy app feed. See the repository's [Contributing guide](https://github.com/nahid-sparktales/locus/blob/main/CONTRIBUTING.md) and [Editions guide](https://github.com/nahid-sparktales/locus/blob/main/Docs/Editions.md) for current source build and packaging details, which may advance beyond these release docs.
''')

release=read('release-notes.md')
changelog=(ROOT.parents[1]/'CHANGELOG.md').read_text()
new_notes=changelog.split('## 2.6.0',1)[1].split('## 2.1.0',1)[0] if '## 2.1.0' in changelog else ''
# Preserve the existing 2.1 and earlier historical notes and add the released 2.6–2.2 entries.
release_body=release[release.find('\n## '):] if '\n## ' in release else release
write('release-notes.md','# Release Notes\n\nReleased changes through Locus 2.6.0. Older entries describe their historical editions. Standard Locus is wallet-free from 2.5 onward; wallet-era release notes are not current standard-app instructions.\n\n## 2.6.0'+new_notes+'\n'+release_body)

# Apply screenshot replacements only where the original screenshot served the same purpose.
assetmap={'locus-v2-workspace.png':'locus-workspace-dark.png','locus-v2-plan.png':'locus-plan-dark.png','locus-v2-settings.png':'locus-settings-dark.png','locus-v2-schedules.png':'locus-schedules-dark.png'}
for p in PAGES.rglob('*.md'):
    s=p.read_text()
    for old,new in assetmap.items():
        dest=os.path.relpath(PAGES/'assets'/new,p.parent)
        s=re.sub(r'https://[^\s)]+/'+re.escape(old)+r'\?alt=media',dest,s)
    # Make original site's internal links portable while preserving all page slugs.
    def local_link(m):
        target=m.group(1)
        return ']('+os.path.relpath(PAGES/target,p.parent)+')'
    s=re.sub(r'\]\(/locus-docs/([^\s)]+)\)',local_link,s)
    p.write_text(s)

assets=PAGES/'assets'; assets.mkdir(exist_ok=True)
for name in assetmap.values(): shutil.copy2(ROOT.parents[1]/'Docs'/name,assets/name)

# The appearance screenshot illustrates visible settings, not account credentials.
append('models-and-accounts.md','''## Find and customize settings

Open Settings to manage model accounts, permissions, tools, and appearance. Model account configuration is under **Models & Providers**; reusable profiles are under **Specialists & teams** in the Agent settings.

![Locus Settings showing appearance and the settings navigation](assets/locus-settings-dark.png)

*Appearance settings in the wallet-free app. The navigation also leads to model, tool, and permission controls.*
''')

append('extensions-and-mcp.md','''## Document knowledge and private profiles

[Library](working-in-locus/library-documents-and-outputs.md) adds opt-in document knowledge and saved output versions. [Identity Vault](safety-and-privacy/identity-vault.md) keeps private profile details and documents in a separate encrypted workflow with explicit review before release.
''')

# Remove obsolete current-release labels without rewriting historical release notes.
for p in PAGES.rglob('*.md'):
    if p.name == 'release-notes.md': continue
    s=p.read_text().replace('Just Chat','Ask')
    s=s.replace('Navigate Locus 2.1','Navigate Locus 2.6')
    s=s.replace('Update to 2.1','Update to 2.6').replace('update to 2.1','update to 2.6').replace('updating to 2.1','updating to 2.6')
    s=s.replace('The Runs panel has its own icon in 2.1','The Runs panel has its own icon')
    s=s.replace('In 2.1, the live page follows','The live page follows')
    p.write_text(s)

replace('developer-guide.md','Locus 2.1 is','Locus 2.6 is')
replace('developer-guide.md','the 2.1 feature-model decomposition','feature-model ownership')
replace('developer-guide/architecture-and-protocol.md','Understand the 2.1 feature-owned native client','Understand the feature-owned native client')
replace('developer-guide/architecture-and-protocol.md','AES-256-GCM memory and continuity with a Keychain-held key','AES-256-GCM memory and continuity with a user-only local `memory/master.key` file')
append('developer-guide/architecture-and-protocol.md','''## Feature ownership added in 2.5 and 2.6

Persistent goals keep durable objective state, cumulative usage, continuation reservations, and action recovery in the existing run store. The native Goal model coordinates continuation through the ordinary chat worker.

Task Capsules use a workspace-scoped SQLite store for saved plans, immutable revisions, baseline validation, and run links. Each stage resolves the exact account from its selected profile.

Library coordinates document extraction, citation locations, and immutable output snapshots with separate metadata. Identity Vault keeps its own encrypted storage and edition-specific Keychain key; its restricted task path is separate from ordinary tool dispatch.

Persistent Agents represent schedules or event/price triggers. Their definitions and shared connections remain separate from open chats. Receipt, occurrence, attempt, and execution identities remain distinct in the inspector and activity views.

Packaging selects wallet-free Locus or the separate LocusX backend and native source set. Wallet support cannot be activated in a standard staged build by changing a setting or environment variable.
''')
replace('models-and-accounts/usage-router-and-proxy-profiles.md','Solo Work and Plan requests can create temporary read-only workers when parallel investigation would help. They use the selected model and fixed safety limits; the primary agent can also finish without delegation.','Solo collaboration can use reusable research helpers and isolated coding helpers. Helpers inherit the selected provider, account, model, and reasoning settings. The coordinator remains responsible for review and combined validation; simple tasks can finish without delegation.')
append('working-in-locus/shortcuts-and-slash-commands.md','''## Library, capsules, and notes

| Shortcut | Action |
| --- | --- |
| ⇧⌘L | Open Workspace Library |
| ⌥⌘K | Open Task Capsules |
| ⇧⌘9 | Open Notebook |
| ⌘N while Notebook is frontmost | Create a standalone note |

Use **Help → Getting Started** to reopen guided setup. **Goal** beside the composer opens the ordinary chat's goal controls.
''')

# Keep the summary aligned with the published hierarchy and place new guides in context.
new_pages=[
 ('Library, Documents & Outputs','working-in-locus/library-documents-and-outputs.md'),
 ('Agents & Automation','working-in-locus/agents-and-automation.md'),
 ('Persistent Goals','working-in-locus/persistent-goals.md'),
 ('Task Capsules','working-in-locus/task-capsules.md'),
 ('Identity Vault','safety-and-privacy/identity-vault.md')]
summary=['# Table of contents','']
for row in manifest:
    rel=row['path']; title=read(rel).splitlines()[0].removeprefix('# ')
    summary.append(('  ' if '/' in rel else '')+f'* [{title}]({rel})')
    if rel=='working-in-locus/the-inspector.md':
        summary.extend(f'  * [{t}]({p})' for t,p in new_pages[:4])
    if rel=='safety-and-privacy/credentials-and-local-data.md':
        t,p=new_pages[-1]; summary.append(f'  * [{t}]({p})')
(PAGES/'SUMMARY.md').write_text('\n'.join(summary)+'\n')

changed=[]
diffs=[]
for p in sorted(PAGES.rglob('*.md')):
    if p.name=='SUMMARY.md': continue
    rel=str(p.relative_to(PAGES)); old=normalize((BEFORE/rel).read_text()) if (BEFORE/rel).exists() else ''
    if old != p.read_text():
        changed.append({'path':rel,'action':'update' if old else 'add','title':p.read_text().splitlines()[0].removeprefix('# '),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
        diffs.extend(difflib.unified_diff(old.splitlines(True),p.read_text().splitlines(True),fromfile='published/'+rel,tofile='prepared/'+rel))
(ROOT/'update.diff').write_text(''.join(diffs))
(ROOT/'manifest.json').write_text(json.dumps({'site':'https://locus-3.gitbook.io/locus-docs/','site_id':'site_vzJcu','space_id':'dQ03BivzJFZ7fKsPFhiD','release':'2.6.0','status':'prepared-not-published','pages':changed,'assets':list(assetmap.values())},indent=2)+'\n')
print(f'Prepared {len(changed)} changed or new pages with {len(assetmap)} screenshots.')
