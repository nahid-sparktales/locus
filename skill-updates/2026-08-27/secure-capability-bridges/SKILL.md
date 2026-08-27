---
name: secure-capability-bridges
description: Design and review fail-closed bridges that let AI systems invoke privileged native or remote capabilities. Use for wallets, payments, credentials, browser or computer control, filesystem mutation, deployments, hardware access, or any tool where schema visibility, authorization, request brokering, cancellation, and policy enforcement must remain independent.
---

# Secure Capability Bridges

Created by Nahid and OpenAI Codex. This is an open-source methodology licensed under CC BY 4.0. Send corrections or safety feedback to the skill owner.

## Core invariant

A privileged operation is allowed only when all of these are true at execution time:

- A live provider has announced the capability for the current session.
- The active access ceiling permits the exact operation and scope.
- A request broker correlates the request to one bounded result.
- Native policy approves the exact, decoded intent.
- The executor acts on the stored approved payload, not a replacement supplied later.

Hiding a tool schema is useful for reducing accidental use, but it is never an authorization boundary.

## 1. Classify the capability

Classify every operation as read-only, sensitive-read, mutating, destructive, or irreversible. Define its scope in concrete terms such as resource, account, origin, network, recipient, contract, or environment. Split broad tools when their operations need different policy or approval behavior.

Treat secret-bearing reads and signing requests as privileged even when they do not directly mutate external state.

## 2. Establish a default-off session

Require an authenticated session handshake that includes a protocol version and the provider's supported operations. Expose a capability only when both its feature gate and a live, authorized provider are present. Withdraw it immediately when the provider disconnects, locks, loses authorization, or becomes incompatible.

Re-evaluate the access ceiling at the schema, direct lookup, dispatcher, broker, and native policy layers. A guessed tool name or stale schema must not bypass a later gate.

## 3. Broker exactly one bounded result

Assign every request a unique correlation ID, operation, deadline, and cancellation token. Accept at most one matching result. Reject malformed, mismatched, duplicated, or unsolicited responses without leaking sensitive payloads.

Use a bounded timeout. Cancel pending work on provider disconnect, interruption, pause, quit, update, signer or helper crash, and session expiry. Ignore late responses after cancellation or completion. Return structured, redacted errors instead of raw transport or secret material.

## 4. Separate preparation from execution

For security-sensitive mutation, preparation must produce an immutable intent containing:

- A unique intent ID and canonical digest.
- Decoded effects, targets, assets, permissions, and fees.
- Simulation or validation results and the policy decision.
- Nonce, expiry, network, account, and other replay boundaries.

Execution signs or submits only the stored prepared payload. It must recheck authorization, nonce, expiry, provider state, and policy immediately before use, then consume the intent so it cannot be replayed. Never accept a caller-supplied replacement payload under an approved intent ID.

Default-deny blind signing, undecodable calls, arbitrary messages, unlimited approvals, unbounded spending, and any operation whose final effects cannot be represented to the user or policy engine.

## 5. Revoke on lifecycle changes

Lock the provider and cancel pending requests on pause, user switch, origin change, sleep when appropriate, timeout, helper crash, quit, update, and relaunch. Session approval and autonomous budgets should expire unless an explicit product requirement and threat model justify persistence. Persist reusable templates separately from live authorization.

## Verification matrix

Test the bridge as an adversarial boundary, including:

- Provider absent, locked, disconnected, stale, or version-incompatible.
- Direct lookup and guessed names when schemas are hidden.
- Read-only modes attempting sensitive or mutating operations.
- Duplicate, late, mismatched, malformed, and unsolicited responses.
- Interruption and every lifecycle cancellation path.
- Nonce changes, expiry, replay, and replacement-payload attempts.
- Hostile origins and cross-origin account or permission disclosure.
- Logs, analytics, crash reports, and error paths for secret leakage.

## Pre-delivery checklist

- [ ] Every operation has a risk class and explicit scope.
- [ ] Availability and authorization are checked independently at every entry path.
- [ ] The broker guarantees one correlated result, a timeout, and cancellation.
- [ ] Privileged mutation uses immutable prepare-then-execute intents.
- [ ] Lifecycle events revoke authorization and cancel pending requests.
- [ ] Errors, logs, analytics, and model-visible data contain no secrets.
- [ ] The adversarial verification matrix passes before enabling production access.
