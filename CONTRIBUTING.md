# Contributing to Locus

Thanks for your interest. Locus is a native macOS app (SwiftUI) with a bundled
Python agent, and both live in this repository.

## Licensing and provenance

Locus is licensed under the [Apache License 2.0](LICENSE). Contributions are
accepted under the same license — inbound matches outbound, so a merged pull
request is licensed exactly as the rest of the project is. Apache-2.0 includes an
express patent grant, which is part of why it was chosen; that grant covers your
contribution when you submit it.

Instead of a contributor licence agreement, this project uses the
[Developer Certificate of Origin](https://developercertificate.org/). It is a
statement that you wrote the change, or otherwise have the right to submit it
under the project's license. Sign off each commit:

```bash
git commit -s -m "Your message"
```

That appends a `Signed-off-by: Your Name <you@example.com>` line. Please use a
real name and a reachable address.

Do not paste code you do not have the right to relicense — including code from
another project under a different license, or output you are not free to
redistribute.

## Building and testing

Requires macOS 14+, Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and [Ollama](https://ollama.com) for local models.

```bash
xcodegen generate
xcodebuild test -project Locus.xcodeproj -scheme Locus \
    -destination 'platform=macOS' -only-testing:LocusTests
```

The Python agent has its own suite:

```bash
cd agent && python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest -q
```

The suite runs against a throwaway `OLLAMA_CODE_HOME` created by
`agent/tests/conftest.py`, so it cannot read or write your real `~/.ollama-code`
— and a session-wide audit hook fails the suite if anything tries. Do not
hand-roll isolation in a test module; add the constant to `_APP_DIR_CONSTANTS`
in that conftest instead.

`agent/tests/live/` holds manual smoke tests that drive a real model over the
WebSocket protocol. They are not collected by pytest. Each one starts its own
server on its own port against a throwaway agent home, and refuses to run if
`OLLAMA_CODE_HOME` overlaps your real one:

```bash
agent/.venv/bin/python agent/tests/live/ws_verify.py --model qwen3.6:27b
```

`project.yml` is the source of truth for the Xcode project — edit it and re-run
`xcodegen generate` rather than editing `Locus.xcodeproj` directly, or your
change will be overwritten.

## What makes a good change

- **Explain why in the commit message.** The history here is written to be read:
  what was wrong, and why the fix is shaped the way it is. A message that only
  restates the diff is less useful than the diff.
- **Cover the failure, not just the fix.** A test that would have caught the bug
  is worth more than one that confirms the new behaviour.
- **Keep the bundled runtime clean.** `Tools/AuditDistribution.sh` fails a release
  that ships unused copyleft components or omits license texts. If you add a
  Python dependency, pin it in `agent/requirements-runtime.lock` and add it to
  `Locus/Resources/ThirdPartyNotices.md` with its version and license.
- **Never commit credentials.** API keys belong in `~/.locus/auth.json`, written
  mode `0600` through `CredentialStore`, and reach the agent in memory only.
  Nothing key-bearing may reach the agent's `config.json`, a session transcript,
  `UserDefaults`, or any API response. Managed ChatGPT OAuth is the only
  exception: the bundled Codex helper owns it in Locus's isolated
  file-backed `CODEX_HOME`; Locus code must never read, copy, log, or pass those
  tokens through API-key routes. Any new credential store needs an explicit
  threat-model and documentation update.

## Reporting a security issue

Please do not open a public issue for a security problem. Email
`security@sparktales.io` with enough detail to reproduce it.
