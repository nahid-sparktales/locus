# Locus UI and user-experience audit

The later complete-suite attempts and still-open matrix gates are recorded in
[WalletVerificationProgress.md](WalletVerificationProgress.md). The focused
passes below do not imply that the full UI matrix is complete.

Date: 2026-09-04. Scope: the native Wallet Hub, transaction and connection review, send/receive correction loops, shared Settings navigation copy, shared accessibility styling, and the UI audit harness. This is an engineering audit; it is not a study with external users or a claim that every Locus screen was visually inspected.

## Changes implemented

| Finding | Result |
| --- | --- |
| Human-originated external transfers could enter the vault execution branch even though their connector operation was already waiting for confirmation. | Confirmation dispatch now checks account ownership. Human vault requests execute their prepared intent; external and Phantom requests resume their existing approval continuation. External send forms present their review as a nested sheet. The gateway independently rejects external accounts from its vault execution entry point. |
| Connection and approval buttons admitted repeat clicks before their asynchronous work set a busy state. | Local state is claimed before launching the task. Pending actions show progress and disable repeat submissions; disconnect/cancel operations are tracked per connection. |
| A swap form could show changed input beside an earlier quote and still offer review of that quote. | Swap and allowance review require the displayed account, assets, amount, and slippage to match the quote. Expired quotes visibly require a refresh. |
| Swap amount errors silently did nothing, and the fee field required raw wei. | Invalid or zero amounts cannot request a quote and receive an inline explanation. Users enter a fee in ETH; checked decimal conversion supplies base units to the existing preparation API. Slippage is displayed as a percentage. |
| Connection review exposed internal method names and could grow beyond the usable window. | Permission and network labels are readable, peer addresses remain selectable, content scrolls, and Reject/Approve remain in a fixed footer. Expired proposals cannot be approved. |
| Different signing ownership models were not clear at the point of approval. | MetaMask/Slush review says wallet approval comes next. Phantom review explains that exact Locus approval is the approval step and that no separate Phantom prompt follows. Connection copy states that these accounts cannot automate. |
| A failed pairing erased the pasted link before the user could correct it. | The transient secure field is cleared after successful pairing; failures preserve it for correction and display the error in Connections. Pairing contents are masked from the accessibility value and nothing in this UI change persists them. |
| QR controls appeared under the external-account group, and selected image decoding was unbounded. | QR actions are grouped with WalletConnect. The selected file is limited to 10 MiB, 8,192 pixels per edge, and 16 million pixels before decoding. |
| Unavailable connectors offered disabled controls without a specific explanation. | Each connector names the unavailable-network condition. Active/history rows use readable lifecycle labels, show session expiry, and explain how to reconnect. |
| Recipient mistakes had no inline explanation. | The send form names the recipient field, explains invalid addresses on the selected network, preserves input, and disables review. It displays only errors from its own preparation attempt. |
| Receive offered no visible confirmation after copying and buried the network guidance in implementation details. | Copy changes to “Address Copied”; the receive sheet names the required network beside the public address. Escape dismisses the sheet. |
| Transaction confirmation could remain visually enabled past expiry and did not show an execution failure locally. | Review updates its expiry state, prevents duplicate submissions, displays submission failures, and names swap/allowance actions explicitly. |
| Wallet navigation relied on tint alone for its selected state. | Selection is exposed through accessibility traits and the horizontal overflow affordance is visible. |
| Settings forced a 920 × 680 layout inside smaller windows, clipping navigation and footer controls. | Settings now adapts between its minimum and preferred dimensions. Compact-window tests assert the search field, header close action, and footer remain inside the window before auditing accessibility. Shared group headings use a readable caption role and expose heading semantics. |
| The Settings subtitle described all connectors as external approval wallets. | It now describes the vault, connected accounts, and transaction approvals without misrepresenting Phantom. |
| The UI audit skipped every contrast finding on Wallet, Settings, and agent-editor surfaces. | That blanket exception was removed. Findings now reach the existing rendered-pixel measurement or fail with element identity and geometry. |

The Apple design guidance influenced the correction loops, clear status feedback, fixed review actions, and readable ownership-specific approval language. Existing semantic colors, typography, focus rings, reduced-motion handling, and increased-contrast surfaces were retained.

## Verification and evidence

- Swift syntax parsing and the repository design-system audit pass for the changed UI sources.
- A complete ad-hoc Debug test build compiled the UI changes. The first automated run could not launch its app because simultaneous test builds registered the same bundle identifier; its result is not counted as a UI pass.
- The exact isolated Debug executable was launched directly and inspected with native accessibility and screenshots. Wallet Portfolio, Connections, Send, and invalid-recipient correction were inspected. The invalid Sui address remained visible, its inline explanation was readable, Review Transaction stayed disabled, and Escape returned to the Send screen. No transaction or connector authorization was submitted.
- The first executed eight-case run passed invalid-recipient preservation, receive-copy/network guidance, unavailable connector explanations, the existing exact review, and live expiry. Its three failures exposed synthetic external accounts being replaced by live connector refresh and the clipped/low-emphasis Settings navigation described above.
- The corrected three-case run passed both ownership-specific approval/cancel flows and compact-window accessibility: `/tmp/locus-wallet-dd-ui/Logs/Test/Test-Locus-2026.09.04_17-16-48--0400.xcresult` (3 tests, 0 failures). The fixture now isolates both status callbacks and explicit connection refresh. This evidence uses macOS 26.4.1 on arm64 and an ad-hoc Debug build; it is engineering evidence, not a notarized release approval.
- After the responsive Settings change, the compact test passed again with the new control-containment assertions and the strict accessibility audit: `/tmp/locus-wallet-dd-ui/Logs/Test/Test-Locus-2026.09.04_17-18-58--0400.xcresult` (1 test, 0 failures). This build includes the final UI source changes described here.

## Remaining verification

- Re-run the complete UI suite serially against one registered build, including light/dark, increased contrast, reduced motion, and compact windows. The focused pass does not substitute for that matrix.
- Real connector approval, rejection, unavailable-wallet, timeout, restore, and app-restart flows require release configuration and test accounts. The deterministic fixtures exercise presentation and cancellation without vendor sessions or real funds.
- External and Phantom send review presentation must also be exercised with actual connector preparation; fixtures do not prove the real wallet prompt or broadcast/reconciliation path.
- Connection review currently accepts or rejects the bounded proposal as a whole. Any future permission/account subset editor must be backed by a driver contract that applies exactly that selection.
- The accessibility harness retains named platform exceptions and broad native menu-wrapper exceptions. Narrow those menu exceptions to verified controls when the full platform matrix produces attributable evidence; do not infer accessible names merely from nonempty test identifiers.
- Conduct an invited usability pass on unfamiliar-account connection, first receive, first send, rejection recovery, expired review, and reconnect. Record task success, correction attempts, and confusion about approval ownership separately from transaction success counts.
