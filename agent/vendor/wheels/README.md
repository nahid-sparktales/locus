# Dependency and historical wheel provenance

Current builds download the versioned wheel from the
[Locus Memory release](https://github.com/nahid-sparktales/locus-memory/releases/tag/v0.3.0)
using the exact URL and SHA-256 in `agent/requirements-runtime.lock`.
Development installs use the same URL with its hash in `agent/pyproject.toml`.
Pip verifies the wheel before installation; desktop and remote builders bundle
it into the finished runtime. App users need no package installation or network
access for memory at launch.

## Locus Runtime extraction candidate

This directory also supplies `locus_runtime-0.1.0-py3-none-any.whl`, selected by
the exact `locus-runtime==0.1.0` dependency. `runtime-release.json` records its
source repository identity, committed source revision, reproducible build epoch,
artifact name, and SHA-256. `Tools/RuntimePackage.py verify --agent agent`
validates the wheel and compatible product pin before builds reuse a cache or
install dependencies. No remote runtime release is implied by this vendored
candidate. Do not rebuild or overwrite an active installed runtime.

Both product builders install from this directory with `--find-links` and the
hash-pinned lock, then record both product and runtime provenance. There is no
first-launch install or sibling-source import. A developer may explicitly
replace the installed dependency with `pip install -e ../locus-runtime` in a
disposable environment after installing Locus; that override is not a release
or package-verification path.

The runtime wheel retains its own Apache-2.0 `LICENSE` and `NOTICE` in wheel
metadata. Product staging generates the trusted Locus host entry-point metadata
from `agent/pyproject.toml` alongside the selected product edition, without
duplicating backend source in the runtime wheel.

The candidate was built twice from clean `git archive` exports of the local
`locus-runtime` commit `db1955b106d747ff715885ff6d68c834e2d3129d`; both wheels have
SHA-256 `8c7cdbc0d623f9c1cde600c2dd49af8460f3b558bd26d4576f794a759b292c36`.
The source is public at [nahid-sparktales/locus-runtime](https://github.com/nahid-sparktales/locus-runtime);
no runtime wheel release has been published. Reproduce the pinned wheel with
Python 3.14.6, build 1.5.0, setuptools 83.0.0 and wheel 0.47.0:

```sh
git -C /path/to/locus-runtime archive db1955b106d747ff715885ff6d68c834e2d3129d \
  | tar -x -C /path/to/empty-export
SOURCE_DATE_EPOCH=1791228931 python -m build --wheel --no-isolation \
  --outdir /path/to/wheel-output /path/to/empty-export
python Tools/RuntimePackage.py verify --agent agent
```

## Locus Memory provenance

The current 0.3.0 wheel SHA-256 is
`aafdbdf72b04aa2e83589cf0b88f1f9c8493b6ab9e97b65b6deac6dd5802d4b6`.
It was built from source commit `ec7e87d821af064c5cd7fc680357f58b3ecc9a22`,
with CPython 3.14.6, setuptools 84.0.0, wheel 0.48.0 and
`SOURCE_DATE_EPOCH=1791196800`. Repeated builds are byte-identical. The release
includes `SHA256SUMS` and `release-provenance.json`; the anonymous public wheel
download was checked against this hash before updating the runtime lock.

The 0.3.0 API is required: 0.2.1 lacks the encrypted transcript-cache module used
by the backend. Desktop preparation probes the new cache/submission APIs, and
remote packaging imports the actual server with a disposable profile. The
package's [validation record](https://github.com/nahid-sparktales/locus-memory/blob/v0.3.0/docs/release-0.3.0.md)
records installed-wheel tests, supported interpreter checks and remaining limits.

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
  --find-links=agent/vendor/wheels --no-emit-find-links \
  --output-file=agent/requirements-runtime.lock agent/requirements-runtime.in
```
