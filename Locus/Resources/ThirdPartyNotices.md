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
| prompt-toolkit | 3.0.53 | BSD-3-Clause |
| pycparser | 3.0 | BSD-3-Clause |
| pydantic | 2.13.4 | MIT |
| pydantic-core | 2.46.4 | MIT |
| Pygments | 2.20.0 | BSD-2-Clause |
| PyJWT | 2.13.0 | MIT |
| python-multipart | 0.0.32 | Apache-2.0 |
| referencing | 0.37.0 | MIT |
| requests | 2.34.2 | Apache-2.0 |
| rich | 15.0.0 | MIT |
| rpds-py | 2026.6.3 | MIT |
| sse-starlette | 3.4.6 | BSD-3-Clause |
| starlette | 1.3.1 | BSD-3-Clause |
| truststore | 0.10.4 | MIT |
| typing-inspection | 0.4.2 | MIT |
| typing-extensions | 4.16.0 | PSF-2.0 |
| urllib3 | 2.7.0 | MIT |
| uvicorn | 0.52.0 | BSD-3-Clause |
| wcwidth | 0.8.2 | MIT |
| websockets | 15.0.1 | BSD-3-Clause |

Ollama, Hugging Face services, hosted models, and model weights are not
distributed with Locus. Locus only connects to services configured by the
user.
