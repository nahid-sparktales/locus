# Locus Memory 0.3.0 integration

Reusable memory behavior remains in the `locus-memory` package. Locus supplies the
inspector/review UI, authenticated agent identity, local Ollama calls, actual task verification,
approved disposable evaluation execution and the signed macOS Keychain helper.

Source changes are present for all six workstreams. Full tests, evaluation reruns and builds
are **deferred at the user's request to reduce RAM use**. The published wheel, exact lock and
installed Locus runtime remain 0.2.1 until acceptance; do not point the lock at an unpublished
0.3.0 asset or rerun the completed cutover.

The detailed implementation, completed focused checks, unsuccessful initial quality gates
and serial validation/release checklist are in the sibling package's
`docs/release-0.3.0.md`. Its original benchmark remains unchanged. The first local campaign
passed 2/6 tasks in both arms; this is no demonstrated improvement. Later retrieval fixes
are untested. Semantic search remains optional with keyword retrieval as the default.

New user surfaces:

- Memory on chat turns and agent runs: references to the final revalidated submission,
  current authorized content, matching/exclusion reasons and delivery state.
- Per-agent native Codex memory opt-in; allowed memory search/proposal tools only.
- Suggest workspace memory on helper results; human review before recall.
- Local semantic model settings; installed-model selection, no automatic download.
- Verified learning: task episodes, procedure nomination, explicit test-suite approval,
  evaluation and human approval. Approval does not install instructions.
- Restore-protection status; macOS Keychain custody and offline recovery tooling.

Raw transcript files stay outside saved-chat cache encryption. Prior provider context cannot
be retracted. Recovery checkpoints detect missing deletion history but cannot recreate it.

Procedure review carries the displayed suite's fingerprint back to the host. A suite edit
requires a fresh review before approval; execution remains bound to the approved procedure,
suite and workspace fixtures. A cancellation after admission is preserved even when the
evaluation worker has not started yet. These final source fixes have not been tested.
