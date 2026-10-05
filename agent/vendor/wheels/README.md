# Historical wheel provenance

Current builds download the versioned wheel from the
[Locus Memory release](https://github.com/nahid-sparktales/locus-memory/releases/tag/v0.2.1)
using the exact URL and SHA-256 in `agent/requirements-runtime.lock`.
Development installs use the same URL with its hash in `agent/pyproject.toml`.
Pip verifies the wheel before installation; desktop and remote builders bundle
it into the finished runtime. App users need no package installation or network
access for memory at launch. This directory is no longer a dependency source.

The retained patches document the initial extraction before release publication.
The former `locus_memory-0.2.0-py3-none-any.whl` was built from `locus-memory` commit
`4368e931ba62226f6123f26cc75b00bff87818b1` with these patches applied in order:

1. `patches/0001-preserve-rollback-source-bindings.patch`
2. `patches/0002-extract-host-memory-architecture.patch`

Its wheel SHA-256 was `780b63a0a74a8e97401bbfb3f094f846b17ce9a4b0161538e38344152c901b5e`.
The second patch SHA-256 is
`345c8fd679da218a7e57e6c370c369e08343ad6fd71818dee7cf37334b36cc06`; the first is
`bdc11081ec8e572f7e9eeb68c4708f5ddb6ae1acc13e44a3465a7b9996499a31`.

The first patch preserves source session/run bindings through rollback. The
second contains the remaining architecture extraction, its regression tests,
version metadata and updated source attribution. The actual implementations
live in the public `locus-memory` repository. These source patches preserve
the original integration's reproducible source snapshot.

The original build used CPython 3.14.6, setuptools 84.0.0, wheel 0.48.0 and
`SOURCE_DATE_EPOCH=1791154744`. Export the recorded base with `git archive`
into an empty directory and apply both patches, then build:

```sh
git -C /path/to/exported/locus-memory apply \
  /path/to/locus/agent/vendor/wheels/patches/0001-preserve-rollback-source-bindings.patch
git -C /path/to/exported/locus-memory apply \
  /path/to/locus/agent/vendor/wheels/patches/0002-extract-host-memory-architecture.patch
SOURCE_DATE_EPOCH=1791154744 python -m pip wheel --no-deps --no-build-isolation \
  --wheel-dir /path/to/wheel-output /path/to/exported/locus-memory
```

The wheel includes its Apache-2.0 license, source notice, typed marker and
interchange schema. No additional runtime dependency was introduced.

To regenerate the lock without upgrading its other pins:

```sh
agent/.venv/bin/pip-compile --generate-hashes \
  --output-file=agent/requirements-runtime.lock agent/requirements-runtime.in
```
