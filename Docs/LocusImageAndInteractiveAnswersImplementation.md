# Locus image generation and interactive answers

Implementation notes for the 2.7 image-generation and interactive-answer work. The wire contract for answer parts is in [RESPONSE_PARTS_PROTOCOL.md](../agent/RESPONSE_PARTS_PROTOCOL.md); the routes are in [PROTOCOL.md](../agent/PROTOCOL.md).

## User-visible changes

- **Image generation and editing:** with an OpenAI API or compatible account chosen under Settings › Models & Providers › Image generation, the agent gains `generate_image` and `edit_image`. A generated picture is saved as a PNG under `Locus Images` inside the workspace and appears in the answer as an image card with a caption, Open, Reveal, Edit in chat, Copy Image, and Save As…. Edits are saved beside their source and record it. Inline workspace images written by scripts gain the same actions.
- **Permission and spend:** every generation asks for permission outside Bypass mode. The prompt names the prompt text, model, size, quality, provider host and account, destination file, and how many images this turn and session have used; edits also list the files that leave the Mac. `generate_image` may be allowed for the rest of the session; `edit_image` asks every time because it uploads the user's own image bytes. At most 4 images per turn and 24 per session are generated, in every permission mode. Unattended runs (schedules, event triggers, workflows) cannot generate images.
- **Interactive explanations:** an answer can include a self-contained interactive widget (inline HTML with its own styles and scripts, up to 256 KB) rendered in a sealed web view at a fixed height (160–720 pt) with Open larger, Copy HTML, and Save As…. The widget follows Light/Dark appearance live. A written summary is required and stands in for the widget on the phone, in exports, and when “Render interactive answers” is switched off in Settings.
- **Reload, Outputs, and export:** both part types persist with the answer and survive reload. Generated images are captured into Outputs with their run. Markdown export copies generated images into the export’s assets folder and writes each interactive widget as a sealed `.html` beside the chat; plain-text export names images; PDF export embeds them.

## Response data and compatibility

Two additional answer part kinds ride the existing response document:

- `image`: `{type, id, workspace, path, width, height, format, size, alt, title?, prompt?, source_path?}`. The runtime verifies the file inside the active workspace and reads the dimensions from the file header; model-supplied metadata is ignored. Only PNG, JPEG, GIF, and WebP files up to 50 MB are accepted. The Markdown fallback is `![alt](<absolute path, percent-encoded>)` followed by a caption line, so older clients and the phone still see the image link and the caption.
- `interactive`: `{type, id, title, summary, html, height}`. `html` must be a body fragment: document, `base`, `link`, `iframe`, `frame`, `object`, `embed`, and `applet` tags and `http-equiv` are rejected by the runtime so the app owns the entire document head. The Markdown fallback is the title, the summary, and a note that the interactive version is available in Locus for Mac.

Both kinds are additive under the existing limits (40 parts, 1 MB document) and are gated by the `image_generation_v1` and `interactive_answers_v1` capability flags, which are on by default and can be disabled with `LOCUS_CAPABILITY_IMAGE_GENERATION_V1=0` and `LOCUS_CAPABILITY_INTERACTIVE_ANSWERS_V1=0`. Swift falls back to the Markdown content for any document containing an unsupported part, as before.

## Image generation lifecycle and limits

The app pushes the chosen account to the agent with `POST /api/images/provider`, exactly as the chat provider key is pushed: in memory only, on launch, on Settings changes, after a key rotation, and as `enabled: false` when the account is removed. The key lives only in the agent’s `ImageGenerationService`, never in its config file, provider state, events, or error text. `GET /api/images/provider` reports the configuration without the key.

The tools are advertised only while a provider is configured, on both the classic and ChatGPT-native routes, outside Plan mode, and only when the agent’s capability policy allows network and workspace write access; a guessed call is refused at dispatch under the same rules. They are unavailable to Just Chat, private Identity tasks, role-contracted specialists, Solo helpers, and read-only agents.

Requests go to `POST {base}/images/generations` (JSON) and `POST {base}/images/edits` (multipart) on the validated base URL with a bearer key, never follow redirects, refuse provider-returned URLs, stream the body under a 40 MB cap, and stop on interrupt without writing. The provider must return PNG bytes; the file is written atomically as `Locus Images/<slug>.png` (never overwriting; `-2`, `-3`, … on collision) with an optional workspace-relative `filename` that must stay inside the workspace, contain no `..` or dot-prefixed component, and pass the same symlink checks as file tools. The written part is staged for the final answer automatically, and the tool result names the path and dimensions only; image bytes never enter the transcript.

Configuring or clearing the image provider changes the ChatGPT-native tool set, which restarts a live native thread once.

## Interactive answer isolation

Interactive HTML runs only inside a dedicated `WKWebView` that is never a browser tab:

- the fragment is always wrapped in a Locus-authored document whose Content Security Policy (`default-src 'none'`, inline script and style only, `img-src`/`media-src` limited to `data:` and `blob:`, `connect-src 'none'`, no frames, workers, objects, forms, or `base`) precedes any model content;
- a compiled `WKContentRuleList` independently blocks every subresource and child-frame load except `data:` and `blob:` images, fonts, and media;
- the page loads from `about:blank` with a non-persistent data store, has no script message handlers, cannot open windows, dismisses JavaScript dialogs immediately, cannot present a file chooser, and every navigation after the initial load is cancelled;
- theme variables are injected into an isolated content world and updated in place when the appearance changes;
- a 2-second ping with a 3-second deadline tears down a hung page, at most four hosts are live at once (older ones show “Show interactive content”), a terminated page shows “Reload” and never reloads on its own, and a user setting turns rendering off entirely.

The exported `.html` keeps the same policy so it stays offline in a browser. The web view captures scroll-wheel events inside its own frame; the fixed height bounds this.

## Verification status

- **Backend:** the full pytest suite passes (see the pull request for the exact count), including the new `test_image_files.py` and `test_image_generation.py` suites and the extended response-part, capability, answer-contract, native-route, and route-contract tests. Lint (`ruff`) passes.
- **Native:** the unit suites pass through the injected-host runner, including the new `InteractiveAnswerSandboxTests` (real `WKWebView` proofs that inline scripts run while fetch, XMLHttpRequest, WebSocket, beacons, dynamic import, remote images, scripts, styles, fonts, and frames are blocked, navigation and `window.open` are inert, the watchdog and host budget tear pages down, and the saved document keeps its policy), `ChatExportPartsTests`, `ImageGenerationSettingsTests`, and the extended response output/event tests. The design-system audit and generated-project check pass.
- **UI automation** (`ResponseOutputUITests`) gained a generated-image test and an interactive-answer test; local UI runs remain unavailable with Developer Mode disabled, so hosted CI is the gate. VoiceOver traversal inside interactive answers is listed as manual evidence still required.
- **Not exercised here:** no live provider request was made; the outbound client is verified against stubbed responses only.
