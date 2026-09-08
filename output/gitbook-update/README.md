# Locus GitBook update — prepared, not published

The GitBook plugin is confirmed installed and enabled, but this running task exposes no GitBook read or edit actions. No pages or assets have been written to GitBook.

## Prepared content

Released-version documentation for Locus 2.6.0, verified against the repository and the public GitHub release on September 8, 2026. The published GitBook described 2.1. Existing page addresses and older release notes are preserved.

- New guides: Agents & Automation; Persistent Goals; Task Capsules; Library, Documents & Outputs; Identity Vault.
- Updated installation, workspace, inspector, model, team, privacy, troubleshooting, and developer guidance.
- Corrected wallet-free Locus versus LocusX, manual updates in 2.6.0, and the backend memory-key storage location.
- Four existing demonstration screenshots: workspace, Overview, scheduled Agent, and appearance/settings navigation. The screenshot images were visually inspected and copied without alterations.
- Unreleased automatic-update work in the dirty checkout is excluded from the released-version instructions.

## Review files

- [Table of contents](pages/SUMMARY.md)
- [Locus overview](pages/locus.md)
- [Exact content diff](update.diff)
- [Page and asset manifest](manifest.json)
- [Portable Markdown and screenshots ZIP](locus-gitbook-2.6-update.zip)

## Publication handoff

Target: https://locus-3.gitbook.io/locus-docs/

Site: `site_vzJcu`; existing space: `dQ03BivzJFZ7fKsPFhiD`.

Use the existing space and a change request. Match existing pages by their preserved paths; add the five new guides under the sections shown in SUMMARY.md. Upload the four local assets and replace local Markdown image paths with their GitBook asset references. Preserve the existing mobile screenshots. Merge the reviewed change request, then fetch the public pages and verify updated text, links, and images. Do not create a duplicate space or import blindly over existing pages.

## Verification

All local Markdown destinations and screenshot references resolve. Every page has a title, and code fences are balanced. The 2.6.0 public release was verified as published. Existing public pages were saved in `before/` for comparison. The full source snapshot is `published-before.txt`.

The package is prepared for publication; publication and the rendered GitBook image check are still pending.
