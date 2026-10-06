# Locus documentation

Start with the current guides below. Dated audits, implementation reports, and
verification captures record the revisions they examined; they are evidence,
not a description of every current feature.

## Using Locus

- [Your companion](YourCompanion.md): setup, profiles, folders, inspector, and menu-bar chat.
- [Apps and plugins](AppsAndPlugins.md): optional tools and workspaces.
- [Model Context Protocol](MCPCompatibility.md): server setup and compatibility.
- [Persistent goals](PersistentGoals.md), [task capsules](TaskCapsules.md), and
  [verified recovery](VerifiedTaskRecovery.md): long-running work and restoration.
- [Library and getting started](LibraryAndGettingStarted.md): saved output and onboarding.

## Architecture and extracted components

- [Architecture and ownership](Architecture.md): the maintained system map.
- [Extraction map](extraction-map.md): component boundaries and independent repositories.
- [Runtime ownership](runtime/companion-ownership.md) and
  [runtime packaging](runtime/extraction-packaging.md).
- [Agent Worlds](AgentWorld.md), [reviewed local installation](agent-worlds-local-install.md),
  and [migration status](agent-worlds-migration-status.md).
- [Memory cutover](MemoryCutover.md) and [restore protection](MemoryRestoreProtection.md).

## Building and releasing

- [Contributing](../CONTRIBUTING.md): build, test, provenance, and commit requirements.
- [Editions and Locus releases](Editions.md): standard Locus distribution and updates.
- [Runtime release readiness](runtime/release-readiness.md): packaged-runtime checks.
- [LocusX release packaging](WalletReleasePackaging.md): the separate wallet edition.

## Verification and provenance

- [October 6 audit](TrailOfBitsAudit-2026-10-06.md) and
  [fix verification](TrailOfBitsFixes-2026-10-06.md).
- [Companion verification](YourCompanionVerification.md),
  [panel verification](CompanionTabVerification.md), and [artwork provenance](CompanionArtwork.md).
- [Agent Worlds acceptance](agent-worlds-acceptance.md) and
  [runtime extraction verification](runtime/extraction-verification.md).
- `evidence/`, `Verification/`, and `agent-worlds-verification/` retain scoped
  test records; `Assets/` holds documentation images.

Keep maintained guides and their evidence under `Docs/`. Generated architecture
scan caches and duplicate PDF/HTML exports do not belong in the source tree;
`.xray/` and the retired runtime-rescue PDF are ignored. Required vendored
packages, their source manifests, and license records remain with their owners.
