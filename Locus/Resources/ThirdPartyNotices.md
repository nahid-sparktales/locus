# Locus Third-Party Notices

Locus itself is licensed under the Apache License 2.0, © 2026 SparkTales Inc.
The components listed below are not: each remains under its own license, and
this file exists to say which. SparkTales thanks their authors and
contributors. The corresponding license texts are retained inside the
application bundle.

## Standalone Python runtime

The bundled runtime is CPython 3.14.6 produced from the immutable
`python-build-standalone` release `20260728`.

- Source: https://github.com/astral-sh/python-build-standalone/tree/20260728
- CPython source: https://github.com/python/cpython/tree/v3.14.6
- License texts:
  `ThirdPartyLicenses/python-build-standalone-20260728/`

The runtime contains components covered by the PSF-2.0, MPL-2.0,
Apache-2.0, MIT, BSD-style, and public-domain terms retained in that
directory. The included notices cover CPython, bzip2, Expat, libffi,
liblzma, mpdecimal, OpenSSL 3, SQLite, and zlib.

The optional GNU gdbm `_dbm` extension is not distributed with Locus.
The optional `_tkinter` extension and Tcl/Tk runtime are also excluded.

## Python packages

Each package's complete license text is retained in its installed
`.dist-info` directory under `AgentRuntime/site-packages`.

| Package | Version | License |
| --- | ---: | --- |
| annotated-doc | 0.0.5 | MIT |
| annotated-types | 0.8.0 | MIT |
| anyio | 4.14.2 | MIT |
| attrs | 26.1.0 | MIT |
| certifi | 2026.7.22 | MPL-2.0 |
| cffi | 2.1.0 | MIT-0 |
| charset-normalizer | 3.4.9 | MIT |
| click | 8.4.2 | BSD-3-Clause |
| cryptography | 50.0.0 | Apache-2.0 OR BSD-3-Clause |
| fastapi | 0.141.1 | MIT |
| googleapis-common-protos | 1.75.1 | Apache-2.0 |
| h11 | 0.16.0 | MIT |
| httpcore2 | 2.9.1 | BSD-3-Clause |
| httpx2 | 2.9.1 | BSD-3-Clause |
| idna | 3.18 | BSD-3-Clause |
| jsonschema | 4.26.0 | MIT |
| jsonschema-specifications | 2025.9.1 | MIT |
| markdown-it-py | 4.2.0 | MIT |
| mcp | 2.0.0 | MIT |
| mcp-types | 2.0.0 | MIT |
| mdurl | 0.1.2 | MIT |
| opentelemetry-api | 1.44.0 | Apache-2.0 |
| opentelemetry-exporter-otlp-proto-common | 1.44.0 | Apache-2.0 |
| opentelemetry-exporter-otlp-proto-http | 1.44.0 | Apache-2.0 |
| opentelemetry-proto | 1.44.0 | Apache-2.0 |
| opentelemetry-sdk | 1.44.0 | Apache-2.0 |
| opentelemetry-semantic-conventions | 0.65b0 | Apache-2.0 |
| prompt-toolkit | 3.0.53 | BSD-3-Clause |
| protobuf | 7.35.1 | BSD-3-Clause |
| pycparser | 3.0 | BSD-3-Clause |
| pydantic | 2.13.4 | MIT |
| pydantic-core | 2.46.4 | MIT |
| Pygments | 2.20.0 | BSD-2-Clause |
| PyJWT | 2.13.0 | MIT |
| PySocks | 1.7.1 | BSD-3-Clause |
| python-multipart | 0.0.32 | Apache-2.0 |
| referencing | 0.37.0 | MIT |
| requests | 2.34.2 | Apache-2.0 |
| rich | 15.0.0 | MIT |
| rpds-py | 2026.6.3 | MIT |
| socksio | 1.0.0 | MIT |
| sse-starlette | 3.4.6 | BSD-3-Clause |
| starlette | 1.3.1 | BSD-3-Clause |
| truststore | 0.10.4 | MIT |
| typing-inspection | 0.4.2 | MIT |
| typing-extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.7.0 | MIT |
| uvicorn | 0.52.0 | BSD-3-Clause |
| wcwidth | 0.8.2 | MIT |
| websockets | 17.0 | BSD-3-Clause |

The SOCKS proxy packages' license texts are additionally retained at
`ThirdPartyLicenses/pysocks-1.7.1/` and `ThirdPartyLicenses/socksio-1.0.0/`.

## OpenAI Codex App Server

Locus includes the `codex app-server` helper built from OpenAI Codex release
`rust-v0.147.0`. It is used only for OpenAI-managed ChatGPT authentication and
agent turns selected by the user.

- Source: https://github.com/openai/codex/releases/tag/rust-v0.147.0
- Version: 0.147.0
- License: Apache License 2.0
- License and upstream notice: `ThirdPartyLicenses/openai-codex-0.147.0/`

The app bundle also contains `CodexAppServerProvenance.txt`, recording the
pinned source archive, Cargo lockfile, and helper binary SHA-256 digests.

## SwiftTerm

The native terminal uses SwiftTerm 1.18.0 at commit
`7691f85b222a67a66b58499e1b2647443cf0dda7`.

- Source: https://github.com/migueldeicaza/SwiftTerm/releases/tag/v1.18.0
- License: MIT
- License text: `ThirdPartyLicenses/SwiftTerm-1.18.0/LICENSE`

## Swift Markdown and Swift CMark

Transcript rendering uses Swift Markdown 0.8.0 at commit
`3c6f9523da3a1ec2fd829673e472d95b8097a3b8` and its Swift CMark 0.8.0 GFM
parser at commit `924936d0427cb25a61169739a7660230bffa6ea6`.

- Sources: https://github.com/swiftlang/swift-markdown/releases/tag/0.8.0 and
  https://github.com/swiftlang/swift-cmark/releases/tag/0.8.0
- Licenses: Apache License 2.0 with Runtime Library Exception and BSD-style
  permissive component licenses
- License texts: `ThirdPartyLicenses/SwiftMarkdown-0.8.0/LICENSE` and
  `ThirdPartyLicenses/SwiftCMark-0.8.0/COPYING`

## ios-mcp-server Simulator bridge

Direct-download builds include a minimal native touch and accessibility bridge
based on `ios-mcp-server` commit
`bd5aca70704fe0fb5e974abaed205f54469799b0`. It is used only with explicitly
attached Xcode iOS Simulators and is absent from the Mac App Store build.

- Source: https://github.com/martingeidobler/ios-mcp-server
- License: MIT
- License text: `ThirdPartyLicenses/ios-mcp-server-bd5aca7/LICENSE`

## Sparkle

Direct-download builds use Sparkle 2.9.6 at commit
`ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a` to verify, download, and install
Locus updates. Sparkle is not linked or bundled in the Mac App Store build.

- Source: https://github.com/sparkle-project/Sparkle/releases/tag/2.9.6
- License: MIT and bundled permissive component licenses
- License text: `ThirdPartyLicenses/Sparkle-2.9.6/LICENSE`

## Locus WalletSigner cryptography

Direct-download builds include a network-isolated Rust signing core. Its direct
dependencies are exact-version pinned and all transitive packages are sealed by
`WalletSignerCore/Cargo.lock`. The release bundle includes
`WalletSignerSBOM.cdx.json`, a CycloneDX inventory with every resolved package,
version, dependency edge, declared SPDX license expression, and the lockfile
SHA-256. Packaging stops when a dependency, source, or license expression has
not been reviewed.

The primary direct crates are Alloy 2.4.1, bip39 2.2.2,
slip10_ed25519 0.1.3, solana-pubkey 4.3.0, sui-crypto 0.3.1,
sui-sdk-types 0.3.2, and zeroize 1.9.0. The App Store build does not contain
the signer.

## Bundled development skills

Locus includes complete, offline copies of upstream skills plus lightweight
native workflow routers. Every directory has a `SOURCE.json` pinning its
source repository, path, commit, activation policy, and adaptation notes;
startup does not download or update them.

| Skill | Upstream commit | License |
| --- | --- | --- |
| Anthropic Frontend Design | `f17010c9bb483898c1d9c9f42dde2b3a98889434` | Apache-2.0 |
| Vercel React Best Practices | `7c180d9044c9ae2b442b567aad4e42a28dd5ed62` | MIT |
| Superpowers (complete 14-skill suite) | `b36e0829c6d0140e93cfef2ca599b1b07d4a7797` | MIT |
| Task Observer | `281f13466cd3a73e9ebc9d210907748e1941a3dd` | CC BY 4.0 |
| GSD (six native Locus routers) | `bdcaab2c752d9a33a1a1ca9acf3a3c81fb991815` | MIT |
| Matt Pocock Grill Me and Grilling | `068b6e0c62393147daf03530149cdce209c93da8` | MIT |
| Context Mode and Claude Mem | design references only | Elastic-2.0 / AGPL-3.0 |

License texts are retained at
`ThirdPartyLicenses/builtin-skills-anthropic/`,
`ThirdPartyLicenses/builtin-skills-vercel/`,
`ThirdPartyLicenses/builtin-skills-superpowers/`,
`ThirdPartyLicenses/builtin-skills-task-observer/`,
`ThirdPartyLicenses/builtin-skills-gsd/`, and
`ThirdPartyLicenses/builtin-skills-matt-pocock/`, and alongside each bundled
upstream skill inside the agent runtime. Context Mode and Claude Mem code,
services, hooks, workers, and databases are not distributed by Locus.

Ollama, Hugging Face services, hosted models, and model weights are not
distributed with Locus. Locus only connects to services configured by the
user.
