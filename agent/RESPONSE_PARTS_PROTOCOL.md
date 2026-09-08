# Response document protocol, version 1

Assistant messages retain `content` as the complete Markdown fallback. Optional
`response_parts` is a document `{version: 1, parts: [...]}`. A capable client renders
the document instead of `content`; older clients render `content`. Unknown versions
or invalid documents fall back to `content` without rendering partial duplicates.
The backend persists the document as `_response_parts`, alongside `_item_id`,
`_phase`, `_reasoning_format` and `run_id`. Underscore fields are excluded from
provider request messages. Resume and export expose the corresponding public keys.

Part types:

- `markdown`: `id`, `text`.
- `file_collection`: `id`, optional `title`, `workspace`, `entries`, `complete`,
  optional `total_count`, `show_hidden` (default false) and `collapsed` (default false). A change-check answer can
  collapse the full inventory while summarizing verified additions/removals; an
  explicit list-again request leaves it expanded. Each entry contains `path`, runtime-derived `name`,
  `exists`, optional `kind` (`file`, `directory` or `symlink`), `size`, and model-provided
  optional `description`.
- `writing`: `id`, `variant`, `body`, optional `title`, `subject`. Variants are
  `email`, `chat`, `chat_message`, `document`, `standard`, `social_post`.
- `artifact`: `id`, `workspace`, `path`, optional `title`, `description`.
- `sources`: `id`, optional `title`, `references`. Each reference contains `id`,
  optional `title`, and either an HTTP(S) `url` or `document` containing `workspace`,
  `path`, optional `content_hash` and `location` (the existing document locator).
- `image`: `id`, `workspace`, `path` (workspace-relative, an existing PNG, JPEG, GIF
  or WebP file of at most 50 MB), runtime-derived `width`, `height`, `format`
  (`png`, `jpeg`, `gif`, `webp`) and `size`, `alt` (at most 400 characters; when
  omitted it is derived from the title, truncated to 400 characters, or else the
  filename), optional `title`, `prompt` (at most 4000 characters) and `source_path`
  (the existing regular workspace file the image was edited from; a directory or a
  symlink is refused exactly as `path` refuses them). Dimensions and format always
  come from the file header; values in the tool input are ignored. `generate_image` and `edit_image` stage this part on
  their own; scripts stage a chart through `attach_output_parts`. Gated by the
  `image_generation_v1` capability. Fallback: `![alt](absolute path)` followed by a
  caption paragraph (`title`, else `prompt`, else `Image saved to <path>`, with
  ` — edited from <source>` appended for edits), so older clients render it inline.
- `interactive`: `id`, `title` (1–200 characters, default `Interactive explanation`),
  required `summary` (1–4000 characters), `html` (a self-contained body fragment of
  at most 262,144 bytes; inline `<style>`/`<script>` only) and `height` (an integer
  160–720, default 360; `null` means unset, a Boolean is refused). The fragment is
  rejected when it contains a document, base, link, iframe, frame, object, embed or
  applet tag or the `http-equiv` token; inline SVG `<metadata>` is fine. Locus for Mac
  renders it inside a sealed offline web view that injects the CSS variables the tool
  schema names (`--locus-ink`, `--locus-ink-soft`, `--locus-paper`, `--locus-paper-deep`,
  `--locus-panel`, `--locus-line`, `--locus-muted`, `--locus-accent`, `--locus-danger`,
  `--locus-success`, `--locus-warning`, `--locus-font`, `--locus-mono`); every other
  client shows the fallback: `### title`, the summary, and `Interactive version
  available in Locus for Mac.` Gated by the `interactive_answers_v1` capability.

`attach_output_parts({parts: [...]})` stages validated parts in the active visible
workspace turn. A repeated part ID replaces its prior value while retaining its
position. Validation is atomic. The call does not modify user files, prompt for
permission, or emit a tool activity row. It is available on classic and native tool
routes, and unavailable in Just Chat and background worker roles.

Normal assistant prose continues streaming. At final completion it becomes the
first `markdown` part with reserved ID `__prose__`; staged parts follow in order.
The runtime generates the complete fallback once. A typed deliverable counts as a
written answer when the model ends without additional prose. Staging is cleared at
new-turn/retry boundaries and never promoted when interrupted. Provisional staging
is recorded as `response_parts_staged` in the session journal for diagnostics;
completed documents live in ordinary assistant messages and therefore survive
checkpoints, history reloads and exports. Provisional journal entries do not become
answers when an old task is reopened.

Limits: 40 staged parts, 500 file entries or references, and 1 MB of staged JSON;
an image file may be at most 50 MB and an interactive fragment at most 256 KB.
File paths must resolve inside the active workspace. Workspace read capability is
checked before filesystem inspection. Input metadata and completeness claims are
ignored. A file collection may additionally supply the tool-input-only `directory`
field: the runtime compares its entries with the nonrecursive directory before
setting `complete: true`. The default visible scope excludes dot names and macOS
hidden flags, matching Files; `show_hidden: true` includes them. Generated
directories remain included. Explicit entries outside that visible scope make the
collection partial. Contained symlinks retain their lexical leaf path and are not
expanded. Repeated resolved entry paths are rejected. Large or ambiguous listings
remain incomplete. File links never grant access.

Classic `message_start` and `message_end` include stable `item_id`; completed
`message_end` adds authoritative `phase` (`commentary` for a tool-bearing response,
`final_answer` otherwise), `reasoning_format`, and optional `response_parts`.
Durable final-event envelopes preserve full fallback/document strings through
reconnect. Ordinary tool/log events retain their existing bounds, and credential
redaction remains in effect.

Native `assistant_item_*` messages retain their provider IDs and expose the same
completion fields. User and assistant text are no longer truncated on history
reload. `run_id` is persisted with the corresponding assistant message.

`reasoning_format: native` means reasoning has already been separated by the
backend or provider. Renderers must not scan that answer for textual reasoning
tags. Historical messages without provenance remain compatible with their legacy
renderer. Local legacy tagged output is filtered with one Markdown-aware
streaming scanner; fenced/inline/indented code and escaped examples remain
literal even across token boundaries. Typed writing bodies are never passed
through tag stripping.

Successful known operations may carry a runtime-derived `activity_label` on
`tool_result` and tool history/export records (`Checked directory`, `Read path`,
`Updated path`). Labels are absent for errors, denied operations and arbitrary
commands. Clients show a supplied label only on a completed successful record,
keeping their generic fallback for other tools. Native tool labels are persisted
as display-only tool records, excluded from provider request history.

`POST /api/response-preview` accepts optional `agent_config`, `mode`, `provider`
(`ollama`, `remote`, `chatgpt`), `model`, and Boolean `native_mode`. Selected route overrides are read-only;
an unavailable selected native ChatGPT runtime returns 409 instead of silently
showing a classic prompt. It returns
`provider`, `model`, `mode`, `route`, effective Locus `layers`, `text`, and a `base_prompt`
explanation. It does not mutate the active task. The native provider's own private
base instructions are outside the preview; the displayed Locus developer text is
the exact stable text supplied by the runtime. Editable behavior is rendered by
the same deterministic helper in classic and native routes. Changing a persistent
setting replaces a native thread once; unchanged settings keep its fingerprint.
