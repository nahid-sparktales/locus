> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/developer-guide.md).

# Developer Guide

Build, test, package, and understand the native Locus app and bundled agent.

Locus 2.1 is an Apache-2.0 SwiftUI application with a bundled Python agent, optional Codex helpers, and a shared mobile protocol.

* [Build & Test](/locus-docs/developer-guide/build-and-test.md) covers Xcode 26, Rust, XcodeGen, native tests, Python tests, mobile checks, and component packaging.
* [Architecture & Protocol](/locus-docs/developer-guide/architecture-and-protocol.md) explains the 2.1 feature-model decomposition, process ownership, loopback communication, Codex-plan routing, persistence, and security boundaries.

## Repository map

```
Locus/             SwiftUI application, feature models, and native brokers
LocusTests/        Swift unit tests
LocusUITests/      macOS UI tests with isolated fixture storage
agent/             Bundled Python agent service and domain API modules
mobile/            Locus Mobile source and shared protocol client
ProtocolFixtures/  Shared Mac/mobile wire envelopes
Tools/             Build, packaging, appcast, audit, and reviewability scripts
Docs/              Guides, architecture notes, and screenshots
```

AppModel and agent/server.py are composition roots, not default homes for new feature behavior. Add native state and actions to the matching observable feature model, and add service routes and request behavior to the matching domain API module.

Read the repository CONTRIBUTING guide before changing provider routing, credentials, protocol contracts, permissions, packaging, or third-party inventory.
