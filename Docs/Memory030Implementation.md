# Locus Memory 0.3.0 integration

Reusable memory behavior remains in the `locus-memory` package. Locus supplies the
inspector/review UI, authenticated agent identity, local Ollama calls, actual task verification,
approved disposable evaluation execution and the signed macOS Keychain helper.

The required [0.3.0 dependency is published](https://github.com/nahid-sparktales/locus-memory/releases/tag/v0.3.0)
and all three dependency declarations plus the distribution audit pin the same
verified wheel. Its SHA-256 is
`aafdbdf72b04aa2e83589cf0b88f1f9c8493b6ab9e97b65b6deac6dd5802d4b6`.
Desktop and remote build probes now check the newly required APIs and backend
imports. The completed canonical cutover was not repeated; no real user profile
was changed during verification.

The user authorized release verification on October 5, superseding the earlier
RAM-related pause. The exact wheel passed 1,590 package tests on Python 3.10.22
(one optional historical parity fixture skipped), 46 focused release regressions
on Python 3.14.6 and 218 host memory/runtime tests. Both interpreters passed all
75 package imports and standalone CLI/quickstart checks. Two builds were
byte-identical; public download bytes match the recorded hash.

Five frozen held-out synthetic seeds passed retrieval/privacy gates: recall@5
0.9737–1.0, abstention accuracy 1.0, zero false abstentions and zero scope, deletion,
corrected-history or plaintext leaks. The [full package validation record](https://github.com/nahid-sparktales/locus-memory/blob/v0.3.0/docs/release-0.3.0.md)
preserves the original benchmark and exact commands. The first live local campaign
still passed 2/6 tasks in both arms; no live-task quality gain is claimed, and no
new live-model or semantic quality campaign was run. Semantic search remains
optional with keyword retrieval as the default. App build/UI verification is
recorded separately with the Locus 4.0.0 release.

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
evaluation worker has not started yet. These boundaries are covered by the final installed-wheel host test suite.
