# Social Studio for Locus

Social Studio is an optional native social media workspace, installed and opened
the same way as Agent World. It follows [OpenPost's](https://github.com/getopenpost/openpost)
create → adapt → plan → publish workflow while using Locus's fonts, colors,
appearance, controls, conversations, and project boundaries.

## Install

Build the version of Locus in this repository. In **Settings → Extensions**, add
this repository as a local marketplace if the workspace has not discovered it
already. Install **Social Studio**, review its `social.workspace` capability,
and choose **Open Social Studio**. The **Work → Social Studio…** menu reopens it.
Each project has its own window, drafts, brand voice, and OpenPost connection.
Older Locus builds show the capability as unsupported rather than loading an
untrusted web bridge.

## Write and plan

- **Drafts:** create, edit, duplicate, search, remove, copy, and export local
  drafts. Start from a product update, lesson, or conversation prompt.
- **Compose:** keep an original and independent channel versions, preview text,
  and choose a local planned date. **Adapt with Locus** prepares a new editable
  chat request with the draft and brand voice.
- **Calendar:** see local plans alongside the latest 100 loaded OpenPost
  publications with schedule dates. All display times use the Mac's timezone.
  Planning a date does not schedule publishing.
- **Research:** enter a topic and choose **Research last 30 days** to prepare a
  new Locus chat explicitly invoking the bundled `last30days` skill. The request
  asks for dated sources and usable post angles. **Brainstorm post ideas** uses
  the same brand context. These actions do not submit a model request; send the
  editable chat when ready. Copy useful results into a draft.
- **Brand voice:** save the name, audience, tone, and content themes for this
  project. Assistant requests include them.

## Connect and publish

1. Connect social accounts in your OpenPost workspace.
2. Create a developer token in OpenPost **Settings → Personal → Developer**
   with the API access you need. Choose **Accounts → Connect OpenPost** in
   Locus, supply the instance origin and token, and choose an accessible workspace.
   Hosted defaults to `https://app.openpo.st`; local self-hosted instances may
   use `http://localhost:PORT`. Other origins require HTTPS.
3. Save a local draft and choose **Send to OpenPost**. Select connected accounts;
   matching platform versions are sent to them. Sending creates an unpublished
   OpenPost draft. You can also send a draft without destinations and finish it
   in OpenPost.
4. In **Activity**, review the actual returned publication. Use **Schedule…**
   for a saved future date or **Publish now…**. The native review presents the
   text and destination versions; OpenPost validates before the action. A
   request being accepted does not mean a post has published. **Refresh** loads
   delivery states, provider links, and destination errors. **Cancel schedule…**
   requests cancellation through OpenPost.

After transfer begins, the local copy is frozen. Duplicate it for a new version,
or edit the remote publication in OpenPost. A failed or interrupted transfer
can retry its exact saved request without creating a duplicate. Reconnect the
original instance and workspace before retrying. Publishing uses the revision
reviewed by the user; conflicts require refresh and a new review.

The initial native composer focuses on text. OpenPost's image/carousel/video
editors, media library, inbox, engagement analytics, and remote editing remain
available through **Open OpenPost**. Media-required providers will fail OpenPost
validation until their content is completed there. Locus displays actual
delivery outcomes, not simulated engagement metrics.

## Data and permissions

`social.workspace` opens Locus's native implementation. Plugin HTML is not run
and receives no data or credentials. It grants local project drafts, native
assistant handoffs, and user-operated OpenPost controls; it cannot be combined
with agent/world web bridge capabilities. Disabling or uninstalling the plugin
closes its windows and revokes further actions. OpenPost jobs already accepted
continue on its server.

Drafts and public connection identifiers are atomically saved below the app's
Application Support directory in `Locus/Social Studio/<workspace-hash>.json`
(`LocusX` uses its own directory). Tokens stay in the edition's connector
Keychain store, outside draft files, chat prompts, plugin snapshots, and exports.
Exports include draft content and brand notes only. Export a backup before
removing drafts. Disconnecting removes the saved token but does not revoke it
on OpenPost or cancel remote posts.

## Development and provenance

The native implementation lives in `Locus/SocialStudio*.swift` and
`Locus/OpenPostClient.swift`. The package is discovered through the repository's
`.agents/plugins/marketplace.json`. It introduces no web framework, backend
service, or runtime dependency.

This is an original Apache-2.0 implementation. No OpenPost source code or assets
are bundled. OpenPost is a separate service, licensed by its authors; Social
Studio is not an official OpenPost product. The adapter follows the documented
[HTTP API](https://openpo.st/docs/api-reference) and
[publication lifecycle](https://openpo.st/docs/automate/api/publications), checked
on September 23, 2026. Its wire contract is described by OpenPost's
`/api/v1/openapi.json`.

Validation:

```sh
agent/.venv/bin/python -m pytest agent/tests/test_social_studio.py agent/tests/test_extensions.py -q
xcodegen generate
xcodebuild test -project Locus.xcodeproj -scheme Locus -destination 'platform=macOS' \
  -only-testing:LocusTests/SocialStudioTests -only-testing:LocusTests/AgentWorldTests \
  -only-testing:LocusUITests/SocialStudioUITests CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

Tests cover catalog trust/install, capability isolation, persistence/corruption,
project isolation, token storage, exact transfer retries, remote workspace
binding, validation/revision conflicts, revocation, and the native workflow in
light and dark appearances. Live publication requires a user-configured OpenPost
instance and token; automated tests use isolated stores and simulated responses.
