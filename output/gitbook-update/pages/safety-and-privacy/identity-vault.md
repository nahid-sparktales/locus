# Identity Vault

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
