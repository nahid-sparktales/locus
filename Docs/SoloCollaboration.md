# Solo collaboration and optional questions

Implemented September 6, 2026. Policy identifier: `balanced-v2`.

Solo now offers reusable research and coding helpers through Locus's provider adapters. The root can continue while a helper runs, exchange messages, interrupt one helper, and reuse its conversation in another turn. Optional questions return immediately and display a recommendation with a 60-second timer. Required questions and permission requests retain their separate contracts.

## Audit and repaired behavior

The historical audit found no launches in the latest 100 saved eligible Solo runs. Many runs were brief, so that does not establish 100 missed opportunities or a global tool-disable defect. Offline inspection showed that delegation tools and instructions were exposed.

The repairs address concrete failures:

- Workers use the parent's active execution checkout, including a parent worktree, instead of its project identity/source checkout.
- ChatGPT native Plan workers receive canonical read/search capabilities independent of native shell aliases. Research helpers cannot gain editing permissions by requesting aliases.
- Explicit requests for one helper are supported. Balanced instructions recommend delegation for substantial independent work, including root-plus-one-helper tasks, and keep simple or tightly sequential work with the root. There is no additional classification model call.
- ChatGPT guidance uses `turn/steer` with the expected turn ID and correlated client message ID. Answers arriving during finalization use a correlated `turn/start` continuation. Outboxes remain accepted until the provider records the input; exhausted budgets and failed writes cannot silently mark them applied. Uncertain delivery is reconciled against recorded thread input before retrying.
- A failed native turn now produces a failure instead of an empty successful result. Account/model rejection is surfaced accurately.
- Request-time availability, actual advertised tools, provider/model, policy version, launches, rejections, and budget exhaustion are recorded. These diagnostic records omit credentials and conversation content. The activity interface uses factual descriptions such as “No helpers used.”

## Runtime and workspace ownership

`collaboration.py` owns durable helper conversations, attempts, mailboxes, the shared usage ledger, and integration receipts. `collaboration_bridge.py` supplies independent provider/runtime instances and connects their events to the owning Solo task. Old `delegate_read_only` calls adapt to this runtime; Team mode retains its existing path.

Root tools are `spawn_agent`, `list_agents`, `read_agent`, `send_agent_message`, `followup_agent`, `interrupt_agent`, `resume_agent`, `wait_agents`, and `integrate_agent`. `spawn_agent` returns a stable ID without waiting for completion. `send_agent_message` does not launch an idle helper; follow-up and resume are explicit. Helpers can send progress or clarification to the root with `send_parent_message`, but cannot recursively create helpers or ask the user directly.

Each parent run permits three concurrent helpers and six new helper IDs, with an aggregate 24 delegated model calls and 250,000 metered tokens. Eight-call checkpoints pause unfinished work for root-directed continuation. Follow-ups retain the ledger rather than resetting it. Metered usage can arrive after a provider has already generated tokens; exhaustion stops further work once observed. Paused or exhausted attempts are not represented as completed results.

Helpers inherit the parent's provider/account/model/reasoning settings, applicable instructions, completed context, selected files, and attachments. Mutable root state is not shared. Native/external actions remain subject to existing permissions and resource locks. Individual interruption cancels that helper's outstanding actions; root Stop and parent finalization quiesce owned execution. Idle conversation records remain reusable in later parent runs; restart does not silently relaunch interrupted work.

Coding helpers start from a snapshot of the active checkout, preserving its relative working directory, current changes, supported untracked/binary files, and permitted `.worktreeinclude` files. Unsupported snapshots and non-Git projects fall back to research rather than shared writes or automatic Git initialization.

A coding result freezes its baseline, changed paths, patch, and validation evidence. The root reviews it before integration. Integration serializes against root mutations, preflights the complete patch, and records before/after state and an idempotent receipt. Conflicts leave the parent unchanged and preserve the helper result. A repair starts a fresh generation from the latest parent; an integrated helper also receives a fresh generation on follow-up while retaining its conversation. Ambiguous interrupted applications are inspected instead of blindly replayed or rolled back. The root is instructed to validate the combined checkout after integration; the runtime does not guess a project's test command.

## Optional question contract

`question_service.py` persists requests, frozen recommendations, timer state, revisions, answer provenance, and a delivery outbox. `ask_question_async` creates at most one outstanding batch of up to three optional questions per root task. It can also explicitly supersede a question that is no longer needed.

The nonmodal card sits above the composer, with options, free text, Send answer, Skip, and remaining time. Real selection or editing starts a renewable lease, refreshed every five seconds and stale after fifteen. Focus alone does not pause the timer. Blur, navigation, disconnection, and expired leases resume the remaining backend-owned time.

Skip immediately defaults unanswered questions to their displayed recommendations. Timeout does the same after 60 unpaused seconds. Submitted answers remain intact; unsubmitted drafts are retained for a later follow-up. Defaults are labeled `skip` or `timeout`, never user approval. Required decisions are untimed; skipping provides no answer and does not authorize dependent work.

The initial tool result is only `pending`. Answers later arrive as contextual input at safe model/tool boundaries, with separate accepted/applied states. Duplicate submissions and simultaneous desktop/mobile responses are resolved atomically by request identity and revision. Native drafts survive navigation and reconnect, and submissions remain queued until acceptance is acknowledged. Mobile uses its own question request/response routes, separate from permissions.

If independent work finishes first, finalization waits without repeated model calls. Stop cancels automatic defaults and continuation. A process restart restores saved cards and drafts in a suspended state rather than restarting work. Reconnecting to a still-running process releases stale editing leases and replays pending cards while its original timer continues.

## Compatibility and verification

The native client announces `async_questions_v1` and `collaboration_v1`. The backend defaults both off until negotiated, and replacement connections must announce their own support; older clients retain blocking questions and legacy delegation. The current desktop build includes the matching UI and enables the supported workflow through that handshake. Existing transcripts, schedules, and Team mode remain supported.

Final automated verification: **672 backend tests passed**, **12 desktop model tests passed**, and **8 mobile tests passed** with no analyzer issues. The mobile SDK was recovered at the project's exact Flutter 3.47.1 / Dart 3.13.1 revision without changing its constraints or lockfile. Four seeded UI scenarios passed across their individual runs after fixing the focus-only timer regression. The last combined UI rerun and its retry were blocked before product assertions by macOS XCTest timing out while enabling automation mode. The desktop build and embedded-backend smoke check passed; the installed app was not replaced.

Verification includes focused Python runtime/transport tests, native model and seeded UI tests, mobile widget tests and analysis, controlled model-backed fixtures, and an embedded-runtime smoke harness. Reproduction commands:

```sh
agent/.venv/bin/python -m pytest agent/tests/test_collaboration.py agent/tests/test_collaboration_bridge.py agent/tests/test_collaboration_runtime.py agent/tests/test_async_questions.py agent/tests/test_async_question_transport.py agent/tests/test_context_delivery.py -q

agent/.venv/bin/python agent/tests/live/collaboration_eval.py --provider ollama --model MODEL --case explicit_one --output /tmp/locus-collaboration-eval.json

agent/.venv/bin/python agent/tests/live/packaged_collaboration_smoke.py --app /path/to/Locus.app --output /tmp/locus-packaged-smoke.json
```

The ChatGPT live harness additionally takes `--managed-home` and `--helper`; its app server owns credentials. Fixtures use disposable homes and checkouts and never drive the user's open task. The question harness is `agent/tests/live/question_eval.py`.

Sanitized live evidence is in [Verification/SoloCollaboration-2026-09-06.json](Verification/SoloCollaboration-2026-09-06.json):

| Controlled case | Provider/model | Observed result |
| --- | --- | --- |
| Simple arithmetic | ChatGPT / gpt-5.6-terra | Zero helper launches; correct answer |
| Explicit one-helper Plan task | ChatGPT / gpt-5.6-terra | One helper; actual file read; both fixture identifiers reported |
| Isolated coding and integration | ChatGPT / gpt-5.6-terra | One helper; one integration; combined test passed; no errors |
| Automatic independent review | ChatGPT / gpt-5.6-terra | Three helpers; 19 helper read/search results |
| Explicit one-helper task | Ollama / qwen3.6:27b | One helper; actual reads and correct identifiers |
| Question while reading files | ChatGPT / gpt-5.6-terra | Immediate pending result; two independent reads; one accepted and applied native steer; chosen answer used |
| Answer at finalization | ChatGPT / gpt-5.6-terra | Both reads finished first; outbox stayed accepted until one correlated continuation recorded it; one applied event; chosen answer used |

These fixtures establish functioning exposure, launches, isolation, and answer delivery. They do not measure population spawning frequency or prove model behavior across every provider. All adapters use the shared runtime, but live remote-provider evaluation requires an available authenticated endpoint. The configured ChatGPT account rejected `gpt-5.6-sol`; the evaluation used its advertised `gpt-5.6-terra` model without changing the user's saved selection.
