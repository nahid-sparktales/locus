# Locus application audit

For the later committed checkpoint, current failures, and release blockers, see
[WalletVerificationProgress.md](WalletVerificationProgress.md). The results
below remain historical and must not be relabeled as final-candidate evidence.

Date: 2026-09-04. Baseline source revision: `79bbec9daed03c84c0b4d250c171110235dc6f6e`, plus the application fixes described below in the integration working tree. These results are development verification, not signed release evidence. Repeat release checks after the final source commit is fixed.

This audit reviewed the native app's local backend and mobile-companion boundaries, credential persistence, agent permission checks, file and subprocess operations, crash/reconnect handling, dependency checks, CI, and accessibility-test coverage. Wallet activation and transaction authorization are reviewed separately in the wallet gate work. The visual and interaction review is recorded in `Docs/LocusUXAudit.md`.

This was a repository review with local automated tests. It does not substitute for independent application penetration testing, an accessibility study with users, a second-Mac packaging audit, or real-wallet testnet evidence.

## Findings and changes

| Severity | Finding | Status | Evidence and behavior |
| --- | --- | --- | --- |
| Medium | HTTP size enforcement trusted `Content-Length`. A chunked request, omitted length, or false small length bypassed the intended 2 MiB body limit. | Fixed | `agent/ollama_code/http_limits.py` counts received bytes before invoking a route. It rejects oversized, duplicate, negative, malformed, and unbounded numeric length headers. HTTP authentication remains outside the body reader. Chunked requests within the limit are replayed intact. The new tests also prove that unauthenticated requests are rejected without consuming their body. |
| Medium | Two authenticated companion sockets could execute the same request twice while the first awaited the native command handler. The result cache was populated only after execution. | Fixed | `Locus/CompanionGateway.swift` claims each device/request key before awaiting the handler. An overlapping retry receives `request_in_progress`; a completed retry receives the cached result. Admitted work remains deduplicated when Mobile Access is stopped, because hiding its completion would make a subsequent retry execute the action again. New deterministic async tests hold the first handler at a continuation and exercise the concurrent retry and stop/retry cases. |
| Medium | Replacing an event-connector Keychain credential deleted the previous item before attempting to add its replacement. A locked Keychain or failed add could lose a valid connection credential. | Fixed | `Locus/ConnectorCredentialStore.swift` updates first, inserts only after `errSecItemNotFound`, and retries update if another save created the item concurrently. Four injected Keychain tests cover update success, preservation on failure, first save, and duplicate-item races without accessing a user's real Keychain. |
| Medium | Mobile Access stop did not revoke an outstanding pairing nonce, and queued socket callbacks did not recheck whether the socket still belonged to the active gateway. | Fixed; live TLS lifecycle validation remains | Stop revokes all pairing nonces. Incoming callbacks require the running gateway and the original live connection; completions are not sent through a removed socket. Existing nonce tests cover one-use and expiry semantics. A real device disable/re-enable and queued-frame test is still required for release evidence. |
| Medium | Accessibility audits unconditionally accepted all contrast findings on settings, agent-editor, and wallet surfaces. | Fixed; focused UI checks passed, full matrix remains | The whole-surface exception was removed. Findings now reach the existing rendered-pixel contrast measurement and element diagnostics. `Docs/LocusUXAudit.md` records the visual changes and remaining accessibility checks. |
| Low | Secret scanning classified three Swift type declarations as credentials, causing the full-history gate to fail. | Fixed | `.gitleaks.toml` now exempts only the exact declaration shapes in the exact two Reown source paths and the connection-manifest test helper. The scan still examines all other content in those files. The repeated 366-commit scan passed. |
| Low | Existing accessibility exceptions accept identified menu descriptions and certain menu actions broadly. | Open | Narrow these only after native-menu/VoiceOver evidence identifies the framework false positives. Identifiers alone do not prove a user receives an understandable spoken name. This audit does not claim every menu has been exercised with VoiceOver. |
| Low | Large stateful source files increase the difficulty of reviewing lifecycle changes. | Open, maintainability | The reviewability report flags `WorkspaceView.swift`, `BrowserService.swift`, `core.py`, and `runstore.py`, among others. Extract feature-owned responsibilities in independently tested changes. A size threshold is not itself a security defect, and a broad rewrite during release verification would invalidate evidence. |

## Boundaries checked

- The app-launched backend binds to loopback and uses a per-launch capability header. HTTP and WebSocket paths reject unapproved browser origins. A non-loopback standalone server requires a configured token. Request-owned service context and the app factory prevent one app instance from resolving another instance's service.
- The backend is intentionally able to run user-approved commands with the user's privileges. Permission modes are not a sandbox. File operations resolve symlinks before determining workspace ownership; subprocess output and runtime limits are bounded. Browser-derived tool results carry an untrusted-content notice.
- Provider/MCP credentials use the documented owner-only `auth.json` storage model. This is protection from other operating-system users, not from a process running as the same user. Event connector secrets use their dedicated Keychain service. This audit did not change those product trust models.
- Proxy secrets use a startup pipe rather than the persistent process argument/environment snapshot. Child-environment sanitization and proxy-error redaction have regression coverage. Provider configuration excludes the API-key field from persisted configuration.
- Run history uses a separate SQLite ledger, bounded/sanitized event records, transactions, and read-only behavior for a newer schema or failed migration. Telemetry is opt-in, has metadata/content policy separation, requires HTTPS for remote endpoints, and refuses redirects.
- Mobile Access uses TLS with a pinned certificate fingerprint in the pairing payload, expiring one-use nonces, hashed device tokens, revocation, bounded frames/connections, per-device rate limits, and response/event sanitization. Disabling the transport cannot undo a native action that has already been admitted; retries retain deduplication so this does not introduce a second action.
- Downloaded native components are checksum-checked and must satisfy the expected binary identifier and Developer ID team before publication. Component installation preserves the prior version on failure. The CI source includes separate Direct/Mac App Store build checks and packaged binary/resource audits, but this sub-audit did not create a signed release artifact.

## Executed verification

| Check | Result |
| --- | --- |
| Full Python test suite | **856 passed**, 48.67 seconds, using `/tmp/locus-wallet-mainnet-ga-pyenv/bin/python` with test-home isolation. This includes release packaging, connector configuration, actual activation-signing CLI fixtures, and the user-requested removal of default skill activation. |
| New HTTP boundary plus app-factory and existing body-limit regression tests | **17 passed**. The older limit test was updated to create an application after setting its test limit, matching middleware construction semantics. |
| Python lint across `agent` and reviewability tooling | Passed. |
| Locked Python runtime dependency advisory audit | No known vulnerabilities reported. This is advisory-database coverage at audit time, not a guarantee of no vulnerability. |
| Installed Python environment dependency consistency | Passed (`pip check`). |
| Full Git-history secret scan | Passed after the three reviewed declaration-only exceptions; **366 commits**, approximately **21.93 MB** scanned. |
| Current native-source and backend-directory secret scans | Passed; approximately **5.44 MB** and **8.56 MB** scanned respectively. |
| Design-system source audit | Passed at the point checked. It is a ratchet against the checked-in baseline, not a claim of zero existing exceptions. |
| Shared protocol manifest | Current, revision 2. This is the app/agent manifest revision, not the wallet signer protocol version. |
| Release-script syntax and whitespace checks | Passed at the point checked. |
| Dormant archive/export provenance fixtures | **16 passed**. Mutation of recorded source, signature, profile or content is rejected; profile fixtures reject expired or unauthorized distribution authority; an actual temporary macOS executable proves signature-independent hashing does not modify the input. Canary/GA legacy input and output inside the sealed app are rejected before any app mutation. No Developer ID credentials were used. |
| Connector configuration parity and rejection fixtures | **27 Python tests passed**, and the matching native tests passed in the complete 1,157-test app-target run below. Public synthetic vectors bind the exact Phantom/Reown identifiers and redirects, MetaMask reviewed provider selection, and fixed Slush/browser modes. Missing, changed, malformed or unreviewed configuration fails closed. |
| Actual activation-signing CLI fixtures | **14 passed** with an ephemeral CryptoKit fixture key and a locally compiled Swift signing tool. Cases cover newer asset provenance, changed configuration identity, broadened review, mismatched source/CodeDirectory/archive/evidence identities, noncanonical outer dates and signature tampering. The emitted signature is independently checked. These fixtures carry no mainnet grants and are not release activation evidence. |
| Optional skill activation and migration behavior | **23 extension tests passed**. Ordinary turns inject no startup skill; retained bundled skills require an explicit user mention; stale startup metadata cannot restore automatic loading; user-owned skill policies remain intact. |
| Complete native app unit suite | **1,157 passed, 0 failed, 0 skipped**, serially on macOS 26.4.1 arm64. Includes the six credential/companion tests and wallet/configuration/lifecycle regressions. Result: `/tmp/locus-wallet-unit-final-rerun.xcresult`; log: `/tmp/locus-wallet-unit-final-rerun.log`. |
| Rust signer unit suite | **29 passed** with the locked dependency set. |
| Rust sanitizer-backed fuzz smoke | **Five targets passed**, each for 61 wall-clock seconds: EVM FFI, Solana FFI, Sui FFI, authorization FFI and calldata FFI. Production Rust uses AddressSanitizer and checked arithmetic; this is not Rust UBSan coverage or the required 24 CPU-hours per target. Logs: `/tmp/locus-wallet-rust-fuzz-audit/`. |
| Debug, Direct Release and ReleaseMAS builds | Passed in separate DerivedData directories. Backend bundling was skipped and distribution signing was not performed; these are compile/link checks, not packaged release evidence. Logs: `/tmp/locus-wallet-browser-fixture-build.log`, `/tmp/locus-wallet-release-build.log`, `/tmp/locus-wallet-release-mas-build-guarded.log`. |
| Paired linked-app wallet boundary audit | Passed for 11 Direct Mach-O executables and the one MAS executable. MAS checks found no forbidden signer, connector, Reown or activation configuration/resources/symbols. Backend packaging was skipped, so the complete exported distribution still requires its own audit. Log: `/tmp/locus-wallet-build-boundary-audit.log`. |
| Focused native UI checks | Eight scenarios passed across the initial and corrected runs, including both ownership approval paths, invalid-recipient correction, receive guidance, expiry and compact Settings accessibility. This is not a complete UI/theme/VoiceOver matrix; exact result bundles are recorded in `Docs/LocusUXAudit.md`. |
| Reviewability report | Completed; advisory size/change findings remain visible and are not treated as a passing security certification. |

No credential values, raw wallet payloads, session secrets, or private recovery material were included in this report. Secret-scan findings were inspected through a redacted report.

## User-requested default skill removal

Task Observer is no longer shipped in Locus's agent runtime or third-party
notices. Its six bundled source/license files and one copied distribution
license were removed; the tracked originals remain recoverable from Git
history. The remaining 25 bundled skills are an optional, explicit-invocation
catalog. Both their provenance and the loader enforce this policy, including
when stale metadata still requests startup or automatic activation. Existing
user-imported, workspace and plugin skill choices were preserved. The packaged
distribution audit rejects removed Task Observer remnants or any non-explicit
bundled activation policy. This changes product defaults at the user's request;
it is not presented as a vulnerability finding.

## Remaining release evidence

### Follow-up wallet findings

The follow-up review found additional release-blocking correctness gaps. These
have implementation changes and passing local regression coverage in the
working tree. A clean committed candidate and the complete release matrix are
still required before treating them as closed release evidence:

- External transfers could select the vault execution UI path. Approval now
  branches on account ownership; the gateway independently rejects external
  accounts at the vault execution entry point.
- Connection replacement/revocation cancelled router entries without clearing
  every pending review and preparation. Cleanup now covers the authoritative
  records, visible confirmation, waiters and client preparation packets, with
  authority rechecked after asynchronous user presence and provider work.
- A failed activation-cache write could bypass accepted restriction cleanup.
  Enforcement and expiry scheduling now precede best-effort persistence.
- Independent bootstrap signer instances and a mutable revision high-water
  record allowed stale concurrent activation state. Bootstrap endpoints now
  share signer state; immutable revision records and release-boundary checks
  reject stale authority.
- Incident restrictions were only fetched on explicit Wallet refresh. A
  coalesced periodic/wake/foreground check now keeps running sessions updated.
- Exact finite external swap allowance setup was blocked by the dapp router.
  A non-serializable internal-only route now admits active reviewed setup;
  ordinary dapp approvals and automated setup remain rejected.
- The first ReleaseMAS check found unguarded references to Direct-only
  activation types. The corrected conditional compilation passes ReleaseMAS
  and the linked-app exclusion audit without linking the activation runtime
  into the App Store target.
- The first complete Swift run exposed three crashes when dormant
  WalletConnect cleanup accessed an unconfigured networking SDK. Cleanup now
  checks for an initialized client, with a repeated-suspend regression test.
  Signed browser fixtures and stale expectations were also corrected without
  weakening production grants. The final complete rerun passed all 1,157 tests.

The user also requested removing Task Observer and default skill activation.
That product/configuration cleanup is separate from wallet authorization and
does not count as a wallet release gate.

The native unit suite and local builds pass, but the source remains an integration working tree rather than a clean final candidate commit. Remaining engineering work includes the full stateful Anvil, Solana and Sui local-chain matrices; execution of the Swift libFuzzer targets; release-duration sanitizer campaigns; the complete UI/accessibility matrix; and activation sequence/restart/remote-restriction evidence. Signed distribution identity, notarization, stapling, update-feed verification, and two-clean-clone/second-machine reproduction must be recorded against the final candidate revision. No packaging, canary, or GA gate is completed merely by the local build results above.

The independent signer audit, application/dapp penetration test, counsel decisions, live connector matrices, provider load/failover testing, incident drill, derivation reproduction, invited cohort, transaction counts, and continuous canary soak remain external release gates. Repository tests and this report do not complete them or enable mainnet.
