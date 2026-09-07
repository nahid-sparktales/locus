# Identity Vault

Identity Vault stores reusable personal, business, and career profiles, original document versions, signatures, and editable writing drafts on the Mac. Open it below Library or choose **Use Identity Vault…** in the composer. It has no cloud sync and does not import existing contacts, Library files, or browser autofill records automatically.

## Résumés and cover letters

Import a PDF, DOCX, TXT, PNG, or JPEG up to 100 MB. PDF text extraction, image/scanned PDF recognition, and Word extraction run locally. Review the extracted text, save the original, then choose **Create career profile from text…** and correct the proposed fields. Uncertain content remains in the original document text.

Choose **Write with AI** on a career profile to create a separate Identity task. Approve only the career details needed for writing. Review generated claims before saving the draft. **Create PDF & Word** produces a single-column PDF and editable DOCX, with private contact details inserted locally. Both files and the editable draft stay in the encrypted vault; previous versions remain available. **Export this version…** creates an ordinary decrypted file at a location you choose.

## Private applications

An Identity task can open an HTTPS application in a fresh, nonpersistent browser context. Existing browser logins are not copied. The browser's **Fill from Profile…** and **Attach Document…** controls work locally without sending the page or private values to an AI provider. Review exact values, document versions, destination, and controls before release. Unclear matches remain blank. Unsupported and embedded forms require completing the step yourself.

**Continue with AI…** requests a native review of one exact page-text snapshot. Only approved text reaches the selected provider/account. Future snapshots need another review. Agent-driven website actions receive a native confirmation, including actions that may submit. A website may receive information immediately when fields are filled or documents are attached.

Signature images support private preview and explicitly approved uploads. Applying signatures to PDFs and filling PDF forms are outside this release.

## Privacy boundaries

- Metadata, original bytes, extracted text, drafts, and disclosure snapshots use AES-GCM with an edition-specific Keychain key. Atomic commits preserve the prior state on failure. Search and previews use decrypted memory; there is no plaintext vault index or preview cache.
- Sharing is bound to the requesting task and actual provider/account, endpoint, and model. Chat storage retains opaque source references; content is resolved only for authorized provider requests. Restoring or changing context requires renewed review. Generated replies use normal chat retention.
- Identity tasks restrict tool dispatch even under Bypass mode. General browser observations, JavaScript, shell/filesystem, MCP, Computer Control, teams, automatic provider fallback, and background execution are unavailable.
- Private application contexts suppress ordinary page text, screenshots, titles, URLs, history, console/network observations, dialogs, and page-derived errors. Native Locus capture and automation stop while a protected surface is open.
- Lock, sleep, and quit clear decrypted vault state, cancel reviews and document work, and close private browser contexts. Unlocking the Mac makes the vault available without a second authentication prompt.
- Sharing History records completed releases, destinations, item references, and timestamps. Revocation blocks future source use; it cannot recall previously sent data. Exported copies and generated AI replies follow their own retention.
- Uploads briefly materialize a narrowly scoped temporary file outside workspaces, with cancellation, completion, and startup cleanup.

The protected workflow currently supports Local Ollama and API providers. Managed ChatGPT-plan tasks are disabled because their retained provider-side tool context cannot yet enforce this source boundary. Protection covers Locus's supported private workflow, not unrelated processes on the Mac.

## Verification

Native tests cover encrypted persistence, tampering, missing keys, failed commits, document bounds, cancellation, profile revisions, task/provider ownership, revocation, capture blocking, ephemeral browser storage, changed controls, single-use fill/click approvals, upload bytes and cleanup, and local filling without provider disclosure. Python tests cover dispatch restrictions, Bypass, restore boundaries, ephemeral source injection, transport cancellation, document helper bounds, and DOCX generation/extraction. UI verification uses synthetic profiles in an in-memory fixture app.
