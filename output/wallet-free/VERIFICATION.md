# Wallet-free Locus verification

Verified locally on September 6, 2026. Installation instructions are in
[README.md](README.md).

## Delivered artifact

- **Locus.app** — version 2.4.0 (24), Apple Silicon, macOS 14 or later.
- **Locus-macOS.zip** — approximately 175 MB compressed; app approximately 482 MB.
- Developer ID signed, with hardened runtime. Notarization and public publishing
  are intentionally deferred.
- Standalone Python 3.14.6 and the Codex 0.147.0 helpers are bundled.
- Rebuilt from clean source revision `2cfb9572f4648beb1215bcaceca6b1340d9305c5`,
  including the restored Settings dimensions. Subsequent CI test and documentation
  edits do not change the app payload.
- ZIP SHA-256: `c4bb87062b2f1c05d044c405999c52e1ce3880a096e23229d6bfa7abcd3b9193`.

## Build and automated checks

| Check | Result |
|---|---|
| Wallet-free Locus optimized Release build | Passed |
| Restored Settings layout | 920 × 680 on a regular window, bounded by available space on smaller windows; manually inspected |
| Full Python regression suite after CI fixes | 1,551 passed |
| UI discovery and exact edition accounting | 68 passed; 137 standard and 153 LocusX tests compiled |
| LocusX Debug build with full bundled backend | Passed |
| Full LocusX edition artifact audit | Passed; 36 Mach-O files and its bundled wallet backend present |
| App Store ReleaseMAS build, including final title changes | Passed |
| Common native tests hosted in Locus | 1,109 passed, zero failures |
| LocusX common and wallet native tests | 1,403 passed, zero failures in hosted CI |
| Local-chain integration tests | Anvil: 6 passed; Solana: 5 passed; Sui: 2 passed; zero failures |
| Backend regression group | 391 passed |
| Product-specific backend group | 7 passed, including two simultaneous HTTP/WebSocket servers with separate temporary profiles |
| Live bundled Release backend smoke | Passed with a disposable profile and local scripted model |
| Edition, packaging, CI, and wallet-exclusion regression group | 208 passed |
| Pinned CPython symbol-inventory and fuzz-exclusion group | 121 passed |
| Final full distribution audit | Passed |
| Strict nested code-signature verification | Passed before and after exercising the bundled runtime |
| ZIP extraction and signature round trip | Passed |
| Whitespace/error check on source changes | Passed |

Test groups overlap; these counts are not a combined test total. Detailed native
results and packaging logs are retained in the source checkout under
`build/editions/logs/`.

## Wallet exclusion

The final standard app audit inspected **29 Mach-O files** and **5,945 backend
and resource files**, including the complete bundled Python application. It
verified the fixed standard feature factory, app identity, URL registration,
resources, helper boundaries, and absence of wallet code markers.

Standard Locus excludes wallet Swift files, Reown/WalletConnect dependencies,
connector JavaScript, signer and recovery helpers, wallet notices/configuration,
wallet settings/search, provider injection, and wallet protocol handlers. The
App Store target uses the same wallet-free source boundary. Legacy settings,
environment flags, capability messages, and guessed wallet tool names do not
enable the packaged backend's empty implementation.

The distribution audit retains its fuzz-runtime checks. It recognizes only the
exact pinned upstream CPython interpreter and shared library's local smoke-test
callback; identity and binary-content checks prevent a general exemption.
Separate raw-string and signature checks still apply. No runtime binary was
patched to pass this check.

## Native interface checks

Manual native UI checks passed in isolated fixtures for both editions:

- Locus has no Wallets category; searching for “wallet” returns no results,
  including when legacy wallet environment flags are present.
- The optimized Locus browser panel opens, expands, and restores alongside a
  long conversation fixture.
- LocusX retains Wallets and wallet search results, with the wallet disabled.
- Both editions show manual app-update instructions and no automatic-update
  controls. The component remains present.
- Settings again uses its 920 × 680 layout on a regular window. The Appearance
  page and complete wallet-free navigation were inspected in the rebuilt app.

Hosted CI runs the full native UI suites for both editions. Current results and
downloadable test receipts are available in the [CI workflow](https://github.com/nahid-sparktales/locus/actions/workflows/ci.yml).

The automated macOS UI runner could not initialize automation mode on this
machine, so its UI run is **not** counted as passing. Manual UI checks supplement
the native unit and backend tests. No overall frame-rate or smoothness guarantee
is claimed.

A normal simultaneous native launch with fully temporary profiles remains
**unverified**. On this Mac, `CFFIXED_USER_HOME` redirects Foundation file paths
but the actual app identities still read their saved UserDefaults. That launch
was skipped to avoid resuming saved schedules. The verified alternatives are
isolated native fixtures, native profile/credential/browser/callback tests, and
two simultaneously running backend processes with temporary state. These do not
claim full end-to-end native first-run isolation.

A brief normal LocusX launch during UI inspection initialized its separate
Application Support folders and an unused X autofill Keychain item. The app was
stopped; those new X items were preserved. No existing Locus or wallet item was
deleted or migrated.

## Data and capability checks

Native tests verify unchanged Locus profile locations and independent LocusX
Application Support paths, credentials, Keychain services, browser identifiers,
mobile identity labels, backend/Codex homes, and callbacks. Live staged backend
tests verify isolated chat/configuration, encrypted memory, extension state,
authentication-token rejection across processes, and fixed OAuth callbacks.

The actual bundled Release interpreter and backend additionally passed live
session/settings operations, three chat turns, harmless terminal execution,
browser request/result exchange, delegated file access, and an encrypted-memory
round trip with no plaintext marker in its database. It exposed 28 normal tools,
rejected legacy wallet messages despite spoofed flags, and could not import the
private LocusX module. This smoke used a local scripted model and a simulated
native browser reply, with all temporary state removed afterward. Its report is
`build/editions/logs/packaged-backend-smoke.md`.

Common coverage includes chat and workers, browser/autofill, terminal, encrypted
memory, and mobile-pairing logic. The wallet regression tests retain signing,
recovery, and authorization checks. No wallet was enabled, no mainnet transaction
was submitted, and no real funds or wallet migration were used.

Existing Locus data and wallet files are preserved. LocusX Google registration,
real-provider sign-in, a new physical-phone pairing, notarization, public update
feeds, and public release testing are outside this local delivery.

Unrelated rendering fixes and the existing lazy wallet-connector changes were
preserved in the checkout.
