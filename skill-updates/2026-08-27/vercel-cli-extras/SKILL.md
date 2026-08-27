---
name: vercel-cli-extras
description: Add production-safety guardrails to Vercel CLI repository linking, root-directory changes, preview deployment, promotion, aliasing, and rollback. Use alongside the base Vercel CLI skill whenever an action can affect production, a fallback artifact is considered, or READY and HTTP status need browser-level validation.
---

# Vercel CLI Safety Extras

Created by Nahid and OpenAI Codex. This is an open-source methodology licensed under CC BY 4.0. Send corrections or safety feedback to the skill owner.

Use this skill together with the current Vercel CLI skill, which remains authoritative for command syntax and platform behavior.

## Core invariant

A READY deployment and a successful HTTP response do not prove that the intended application works. Never link a repository, promote a deployment, or move a production alias without both a recorded known-good target and browser verification of the candidate.

## 1. Confirm the application boundary

Before linking or changing build settings, inspect the repository root and candidate app directory for its manifest, lockfile, framework configuration, source tree, and expected output. Confirm the selected revision and monorepo workspace.

Stop if the candidate is documentation, infrastructure, a generated artifact, or the wrong package. If the request is diagnostic, do not mutate project linkage or production settings.

## 2. Record a concrete rollback target

Capture the current production state before any change:

- Immutable deployment URL or deployment ID.
- Current production aliases.
- Team and project identity.
- Source revision and configured root directory.
- The exact restoration action supported by the current base Vercel CLI skill.

Verify that the immutable target still exists and is accessible. A branch name, latest-build label, or mutable alias is not a sufficient rollback target.

## 3. Link and build without moving production

Create the first candidate as a preview or otherwise isolated deployment. Validate its logs against the expected framework, dependency install, build command, output directory, root directory, and source revision.

Abort when the app manifest is missing, the wrong workspace built, the output is unexpectedly flattened, or the build succeeded by serving a placeholder instead of the application.

## 4. Preserve source and artifacts

Prefer the repository's normal build pipeline and preserve the original output. Do not repair a deployment by editing compiled JavaScript with regular expressions, shell inlining, or other transformations that cannot be traced back to source.

If a fallback artifact is unavoidable, build it from reviewed source with the normal toolchain, label it as a fallback, and keep it isolated from production until it passes the same verification as the primary candidate.

## 5. Verify in a real browser

Before promotion, verify the preview as a user would:

- The page contains meaningful application content, not an error shell or placeholder.
- Console output and network requests show no blocking script, module, API, or asset failures.
- At least one JavaScript-driven interaction succeeds.
- A nested route loads directly and survives a full reload.
- A revision marker or equivalent evidence matches the intended source.

Record the candidate's immutable deployment identity with the verification result.

## 6. Promote, recheck, and roll back on failure

Move production only after the candidate passes. Repeat the browser checks through the production domain because aliases, environment variables, redirects, caching, and domain settings can differ from preview.

If production fails any required check, restore the recorded immutable target immediately using the current base Vercel CLI procedure, then verify the restored production domain. Preserve the failed candidate and logs for diagnosis unless the user asks to remove them.

## Pre-delivery checklist

- [ ] The app root, framework, workspace, and source revision are confirmed.
- [ ] A verified immutable rollback target and restoration action are recorded.
- [ ] The candidate was deployed without moving production.
- [ ] Build logs match the intended application and configuration.
- [ ] No unreviewed compiled-artifact rewrite was used.
- [ ] Browser checks passed on preview, including interaction and nested-route reload.
- [ ] Browser checks passed again through the production domain.
- [ ] A failed promotion was rolled back and the restored target was reverified.
