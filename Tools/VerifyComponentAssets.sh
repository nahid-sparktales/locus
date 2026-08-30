#!/bin/zsh
# Verifies that a release staging directory carries the ChatGPT-plan component
# feed alongside the app. Installed 2.0.0+ apps resolve LocusComponentFeedURL
# against releases/latest/download, so whichever release is "latest" must
# serve components.json plus every archive it references — publishing one
# without them 404s the ChatGPT-plan download for every installed copy, not
# just users of the new version.
#
# Usage: VerifyComponentAssets.sh <release-staging-directory>
# Diagnostics go to stderr; stdout is the verified archive filenames, one per
# line, so callers can name them in their upload instructions.
set -euo pipefail

staging="${1:?usage: VerifyComponentAssets.sh <release-staging-directory>}"
feed="${staging}/components.json"

[[ -f "${feed}" ]] || {
    echo "error: ${feed} is missing." >&2
    echo "Every GitHub release must republish components.json and the archive(s)" >&2
    echo "it references: installed apps fetch them via releases/latest/download," >&2
    echo "so a release without them breaks the ChatGPT-plan download everywhere." >&2
    echo "Run Tools/PackageComponents.sh \"${staging}\" first (or copy the assets" >&2
    echo "from the previous release if the component is unchanged)." >&2
    exit 1
}

# One line per component: "<archive-filename>\t<sha256>". Structural problems
# (wrong schema, no components, a URL that does not point at this repository's
# releases) fail here, before any hashing.
entries="$(/usr/bin/python3 - "${feed}" <<'PYEOF'
import json
import sys
import urllib.parse

with open(sys.argv[1], encoding="utf-8") as handle:
    feed = json.load(handle)
if feed.get("schemaVersion") != 1:
    sys.exit(f"error: components.json has unsupported schemaVersion {feed.get('schemaVersion')!r}")
components = feed.get("components")
if not isinstance(components, list) or not components:
    sys.exit("error: components.json lists no components")
for component in components:
    url = component.get("url", "")
    sha256 = component.get("sha256", "")
    split = urllib.parse.urlsplit(url)
    name = split.path.rsplit("/", 1)[-1]
    if split.scheme != "https" or split.netloc != "github.com" \
            or not split.path.startswith("/nahid-sparktales/locus/releases/"):
        sys.exit(f"error: component URL does not point at this repository's releases: {url!r}")
    if not name or len(sha256) != 64:
        sys.exit(f"error: malformed component entry: {json.dumps(component)}")
    print(f"{name}\t{sha256}")
PYEOF
)"

archives=()
while IFS=$'\t' read -r name sha256; do
    archive="${staging}/${name}"
    [[ -f "${archive}" ]] || {
        echo "error: components.json references ${name}, which is not in ${staging}." >&2
        echo "The feed and its archive must be published as a pair; run" >&2
        echo "Tools/PackageComponents.sh \"${staging}\" to rebuild both together." >&2
        exit 1
    }
    actual="$(/usr/bin/shasum -a 256 "${archive}" | /usr/bin/awk '{print $1}')"
    [[ "${actual}" == "${sha256}" ]] || {
        echo "error: ${name} does not match the sha256 recorded in components.json." >&2
        echo "Clients verify that hash before installing, so publishing this pair" >&2
        echo "would fail on every machine; run Tools/PackageComponents.sh" >&2
        echo "\"${staging}\" to rebuild the feed and archive together." >&2
        exit 1
    }
    archives+=("${name}")
done <<< "${entries}"

echo "Component feed verified: ${(j:, :)archives} staged with matching SHA-256." >&2
printf '%s\n' "${archives[@]}"
