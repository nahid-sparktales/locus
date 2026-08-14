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

## Sparkle

Direct-download builds use Sparkle 2.9.4 at commit
`b6496a74a087257ef5e6da1c5b29a447a60f5bd7` to verify, download, and install
Locus updates. Sparkle is not linked or bundled in the Mac App Store build.

- Source: https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4
- License: MIT and bundled permissive component licenses
- License text: `ThirdPartyLicenses/Sparkle-2.9.4/LICENSE`

## Bundled coding skills

Locus includes complete, offline copies of five skill directories. Their
`SOURCE.json` records pin the source repository, path, and commit; startup
does not download or update them.

| Skill | Upstream commit | License |
| --- | --- | --- |
| Anthropic Frontend Design | `f17010c9bb483898c1d9c9f42dde2b3a98889434` | Apache-2.0 |
| Vercel React Best Practices | `7c180d9044c9ae2b442b567aad4e42a28dd5ed62` | MIT |
| Superpowers Systematic Debugging | `44c9b2d6e889982ac18c27d05a19fefe335194e1` | MIT |
| Superpowers Test-Driven Development | `44c9b2d6e889982ac18c27d05a19fefe335194e1` | MIT |
| Superpowers Verification Before Completion | `44c9b2d6e889982ac18c27d05a19fefe335194e1` | MIT |

License texts are retained at
`ThirdPartyLicenses/builtin-skills-anthropic/`,
`ThirdPartyLicenses/builtin-skills-vercel/`, and
`ThirdPartyLicenses/builtin-skills-superpowers/`, and alongside each skill
inside the bundled agent runtime.

Ollama, Hugging Face services, hosted models, and model weights are not
distributed with Locus. Locus only connects to services configured by the
user.
