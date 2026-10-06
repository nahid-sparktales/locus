#!/usr/bin/env python3
"""Keep Locus an artifact-consuming host, without an embedded world implementation."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

BACKDROPS = {"CaptainDeck", "Quarters-drum", "Quarters-elbaf", "Quarters-marineford", "Quarters-wano", "Quarters-water-seven"}
GENERATOR_FILES = {
    "GenerateAgentWorldAssets.py", "GenerateGrandLineIslands.py", "GenerateGrandLineBudgetIslands.py",
    "OptimizeGrandLineAssets.py", "PackageGrandLineIslands.py", "VerifyAgentWorldPackage.py",
}


def verify_resources(resources: Path) -> int:
    if not resources.is_dir():
        raise ValueError("Built app Resources directory does not exist")
    checked = 0
    for path in resources.rglob("*"):
        relative = path.relative_to(resources)
        if any(part in {"AgentWorldWeb", "agent-world", "grand-line", "outpost"} for part in relative.parts) \
                or path.name in {"world.js", "world.css"} or path.stem in BACKDROPS:
            raise ValueError(f"Embedded world resource: {relative}")
        checked += path.is_file()
    return checked


def verify(root: Path, resources: Path | None = None) -> dict:
    forbidden = [root / "AgentWorldWeb", root / "plugins/agent-world"]
    forbidden.extend(root / "Locus/Resources/Assets.xcassets" / f"{name}.imageset" for name in BACKDROPS)
    forbidden.extend(root / "Tools" / name for name in GENERATOR_FILES)
    forbidden.extend((root / "Tools").glob("GrandLine*Prompts.json"))
    remaining = sorted(str(path.relative_to(root)) for path in forbidden if path.exists())
    if remaining:
        raise ValueError("Legacy world implementation remains: " + ", ".join(remaining))
    marketplace = json.loads((root / ".agents/plugins/marketplace.json").read_text())
    if any(row.get("name") == "agent-world" for row in marketplace["plugins"]):
        raise ValueError("Bundled marketplace still advertises the removed Agent World source")
    workflow = (root / ".github/workflows/ci.yml").read_text()
    if any(value in workflow for value in ["working-directory: AgentWorldWeb", "Tools/VerifyAgentWorldPackage.py", "../plugins/agent-world/ui"]):
        raise ValueError("CI still builds or verifies the removed embedded renderer")
    return {"source_boundary": "passed", "local_catalog": "passed", "old_build_pipeline": "absent",
            "built_loose_resources": verify_resources(resources) if resources is not None else "not-requested",
            "compiled_asset_catalog": "covered by native bundle image tests"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, help="Optional freshly built .app/Contents/Resources directory")
    args = parser.parse_args()
    print(json.dumps(verify(Path(__file__).resolve().parents[1], args.resources), indent=2))


if __name__ == "__main__":
    main()
