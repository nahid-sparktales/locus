**Locus**

Locus brings AI conversations, project files, a browser, tools and ongoing agent work into one Mac app\. The native interface sends work to a Python agent backend\. That backend chooses the configured model, runs permitted tools and keeps local conversation and run records\. Teams add planning and review; recurring agents start from scheduled triggers\. Other capabilities include saved goals and task plans, output libraries, extensions, Calendar, Board, mobile access and remote runtimes\. A local workspace does not mean every selected model runs locally\.

**What you can do:** Chat and work with AI; Delegate work to a team; Run recurring agents; Plan work on a shared board; Browse and inspect websites; View and create calendar events.

The full report maps all 17 identified capabilities, including ones still waiting for a walkthrough.

**What the code is made of**

**802 source files · 386,904 physical lines · 14 languages**

```text
LANGUAGE    CODE MIX                   SHARE    LINES
Swift       ███████████████▌········   64.4%  249,153
Python      ███████▎················   30.0%  115,961
TypeScript  ▌·······················    2.2%    8,387
Shell       ▎·······················    1.1%    4,174
Rust        ▎·······················    0.9%    3,514
Other (9)   ▍·······················    1.5%    5,715
```

Bars and percentages show share of physical lines.

Other includes Dart; Objective\-C; CSS; JavaScript; HTML; Solidity; C\+\+; Kotlin; C/C\+\+ headers.

Physical lines include blank lines and comments; this measures code volume, not importance.

Scope: Recognized source files in the supplied repository inventory, including tests and tools\. Physical lines include comments and blank lines; this is code volume, not importance\.

Excluded: Ignored or absent inventory entries; Vendor, third\-party, bundled skills, build and generated directories; named bundles and minified JS/CSS; Manifests, documentation, data, media and other non\-source formats; Secret files, symlinks, unreadable/binary files and source files over 8 MB \(minified means a JS/CSS line over 20k bytes\).

Measurement confidence: confirmed.

**What the code is for**

| Purpose | Files | Physical lines | Share |
|---|---:|---:|---:|
| Product | 460 | 254,238 | 65.7% |
| Tests | 247 | 113,363 | 29.3% |
| Developer tools | 13 | 2,418 | 0.6% |
| Unclassified | 82 | 16,885 | 4.4% |

Roles use explicit evidence-backed assignments; unmatched source stays unclassified. Shares use the same physical-line total as the language chart, including comments and blank lines.

| Technology | What it does |
| --- | --- |
| SwiftUI | Builds native workspace panels\. |
| Python | Runs the local agent backend\. \(configured\) |
| FastAPI | Composes domain API routes and agent transport\. |
| EventKit | Reads and creates permitted calendar events\. |
| Ollama | Streams the selected local model in the traced Ollama branch\. |
| SQLite | Stores run metadata, checkpoints and schedule records\. Chat transcripts are separate JSONL files\. |

**Important parts and their files**

Start here to understand the inspected program. These are reading priorities, not measured popularity or code quality.

| Part | Why it matters | Start with these files |
| --- | --- | --- |
| Locus desktop workspace | Connects the Mac workspace to each request and turns streamed backend events into visible replies\. | Locus/LocusApp\.swift<br>Locus/AppModel\+SendPipeline\.swift<br>Locus/AppModel\+BackendEvents\.swift<br>+ 7 other associated files in the full directory |
| Local agent API and transport | Registers backend feature routes and gates incoming chat connections before handing work to services\. | agent/ollama\_code/server\.py<br>agent/ollama\_code/api/\_\_init\_\_\.py<br>agent/ollama\_code/api/chat\_transport\.py<br>+ 6 other associated files in the full directory |
| Agent conversation engine | Runs conversations, selects the managed or classic provider path, and repeats model/tool steps on the classic path\. | agent/ollama\_code/core\.py<br>agent/ollama\_code/chat\_service\.py<br>+ 1 other associated file in the full directory |
| Permission checks and tools | Controls which proposed actions may run, requests permission when required, and dispatches tools\. | agent/ollama\_code/core\.py<br>agent/ollama\_code/tools\.py<br>agent/ollama\_code/chat\_service\.py |
| Run records and checkpoints | Keeps durable run events and recovery checkpoints in SQLite; chat transcripts live separately\. | agent/ollama\_code/runstore\.py |

**Walkthroughs selected for you**

- **Work with AI: local Ollama path** — Trigger: Send an ordinary Work message with an Ollama model selected and the direct child\-worker transport in use\. Example: a direct child worker with local Ollama\. Model and permitted tools can repeat; replies stream and records save throughout the turn\. Trace: complete; confidence: confirmed.
  Why this example: Explains the main message path: desktop, agent, model, permitted tools and saved chat\.
- **Give a coding task to a team** — Trigger: Choose a team in the composer and send a Work message\. This representative path uses the Locus\-managed engine, ordered coding jobs and a plan containing specialists and a reviewer\. A Locus\-managed team follows an approved plan: specialists gather evidence, coding jobs run, and configured reviewers check results\. Checkout creation is optional\. Trace: complete; confidence: confirmed.
  Why this example: Adds planning, specialist evidence and code review to ordinary conversation work\.
- **When a recurring agent becomes due** — Trigger: An enabled schedule reaches its next run time while the runtime is eligible to run it\. A due schedule claims its slot and queues the first agent step of a stored workflow\. This trace ends at agent execution; later completion and delivery remain untraced\. Trace: partial; confidence: confirmed.
  Unresolved: The trace covers the first solo/profile agent step of a stored workflow\. Later workflow conditions, approvals, team execution and complete end\-to\-end outcome reconciliation are not traced here\. Runtime follow\-up calls and history queries are evidenced, but actual completion, delivery of notifications and deployed availability were not exercised\.
  Why this example: Shows a different starting point: time, durable claims and background admission\.

**Where to start changing things**

- **Change the workspace panels:** Locus/InspectorView\.swift, Locus/Models/InspectorModels\.swift. These files register the panels and their visible destinations\.
- **Change model selection:** agent/ollama\_code/api/providers\.py, Locus/ProviderAccountsModel\.swift. Provider APIs accept changes; native account state owns model catalogs\.

**Scope:** First\-look source report of Locus: capability inventory across the native workspace and Python backend; three representative walkthroughs for local Ollama Work, an ordered team task, and a due recurring agent\. Other capabilities are mapped at entrypoints, not fully traced\.

These are source traces, not a claim that the app or its live services were exercised.

**Since the previous report:** 0 changed measured files, 0 added paths, 0 removed paths; 9 changes to recorded explanations. Changes to the analysis do not by themselves prove changed app behavior.

To plan an edit with related components and suggested checks, ask `$x-ray change "root_change_workspace"` (or `/x-ray change "root_change_workspace"` in Claude Code).

To explore **Plan work on a shared board**, use `$x-ray focus "board"` (or `/x-ray focus "board"` in Claude Code).

[Explore the interactive Locus report](report.html)

The PDF includes connected diagrams, walkthroughs, change guidance and the component/file directory.

[Read the full Locus X\-Ray report \(PDF\)](report.pdf)
