# Credentials & Local Data

Understand what Locus stores locally, what leaves the Mac, and how credentials, notes, Autofill, and wallet material are handled.

## Local by default

Session transcripts, chat organization, Notebook and Notes, run records, checkpoints, schedules, workspace indexes, usage summaries, Browser Autofill data, and encrypted continuity live on the Mac. Local Ollama prompts and screenshots stay on the configured Ollama route.

Hosted providers receive only requests you send through their route. Automatic hosted team routing requires separate consent. Optional ChatGPT web search sends search queries to OpenAI only when its per-account toggle is on.

## Credentials

API keys, managed account state, MCP tokens, mobile keys, memory keys, and Browser Autofill records are kept in macOS Keychain or scoped user-readable credential stores designed for their owning helper. They are never returned through ordinary model-visible APIs. Authenticated non-loopback provider endpoints require HTTPS and cannot redirect credentials.

ChatGPT-plan OAuth stays inside the isolated Codex helper. Team workers reach it through an authenticated local broker and never receive the OAuth material.

Browser Autofill stores passwords, contacts, and payment cards in Keychain. Agent access is opt-in by category; password access is limited to the current origin. Page scripts cannot enumerate the vault.

## What is persisted

* Transcripts are append-only local JSONL with separate organizer metadata.
* Run history is a local SQLite store with credentials, hidden reasoning, provider signatures, and secure-field values removed.
* Approved memory and continuity snapshots are encrypted with AES-256-GCM; the backend key is a local `memory/master.key` file with user-only access. Identity Vault uses its own edition-specific Keychain key.
* Notes save locally under a one-way hash of their resolved chat, workspace, or shared owner; the Notebook adds searchable owner labels and preserves unmatched older notes under Unlinked.
* Attachment names can appear in transcripts, but image/file bytes are not persisted in normal chat history.
* Exporting with attachments deliberately copies those bytes into the exported artifact.
* Browser data is ephemeral by default; an optional per-workspace persistent profile stores its own cookies, local storage, and browsing history.
* Mobile pairs a pinned certificate and scoped device record; no cloud relay stores the conversation.

## Editions and Identity Vault

Standard Locus excludes cryptocurrency wallets, wallet tools, and browser wallet-provider injection. LocusX is a separate edition with an independent app profile. Existing wallet files and Keychain entries are left untouched, with no automatic import or migration.

[Identity Vault](identity-vault.md) encrypts reusable private details and documents separately. Exporting a version creates a decrypted file at a destination you choose. Approved releases and generated model replies have their own retention; revocation cannot recall already shared data.

Deleting a chat moves it to recoverable local storage and does not delete workspace files.

## Library and saved outputs

Document knowledge is opt-in per workspace. Import copies external documents into the workspace's visible `Locus Documents` folder. Chat attachments do not automatically enable persistent knowledge.

Outputs stores metadata and immutable file snapshots locally under Application Support. These are ordinary local deliverable snapshots, separate from the encrypted Identity Vault. Removing output history does not delete original files; reaching a storage budget does not silently purge saved history.
