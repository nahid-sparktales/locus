#!/usr/bin/env python3
"""Verify local fixture inputs without mistaking a source catalog for run evidence."""

import argparse
import hashlib
import json
import re
from pathlib import Path


def verify(directory: Path) -> list[str]:
    directory = directory.resolve()
    lock = json.loads((directory / "local-fixtures.lock.json").read_text())
    if lock.get("schemaVersion") != 1 or lock.get("productionAuthority") is not False:
        raise ValueError("Invalid local fixture lock authority")
    sources = lock.get("sourceSHA256")
    if not isinstance(sources, dict) or not sources or "scenarios.json" not in sources:
        raise ValueError("Missing local fixture source identities")
    for name, expected in sources.items():
        source = (directory / name).resolve()
        if not source.is_relative_to(directory) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError("Invalid local fixture source identity")
        if hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError(f"Local fixture input changed: {name}")
    catalog = json.loads((directory / "scenarios.json").read_text())
    if catalog.get("schemaVersion") != 1 or catalog.get("evidenceStatus") != "not-run-by-this-catalog":
        raise ValueError("A local fixture catalog cannot supply execution evidence")
    scenarios = catalog.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        raise ValueError("Missing local fixture scenarios")
    ids: set[str] = set()
    blockers: list[str] = []
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            raise ValueError("Invalid local fixture scenario")
        identifier = scenario.get("id", "")
        if not re.fullmatch(r"(?:evm|solana|sui)\.[a-z0-9.-]+", identifier) or identifier in ids:
            raise ValueError("Invalid or duplicate local fixture scenario")
        ids.add(identifier)
        if scenario.get("implementation") == "missing":
            blockers.append(identifier)
        elif scenario.get("implementation") != "implemented" or not scenario.get("test"):
            raise ValueError("Scenario implementation does not identify a test")
    missing_inputs = lock.get("requiredMissingInputs")
    if not isinstance(missing_inputs, list) or any(not isinstance(item, str) or not item for item in missing_inputs):
        raise ValueError("Missing explicit fixture input readiness")
    blockers.extend(missing_inputs)
    tools = lock.get("tools", {})
    for name in ("anvil", "agave", "sui", "solc", "postgresql"):
        tool = tools.get(name, {})
        hashes = tool.get("archiveSHA256", {})
        if not tool.get("version") or not hashes:
            blockers.append(f"tool-identity:{name}")
        elif any(not re.fullmatch(r"[0-9a-f]{64}", digest) for digest in hashes.values()):
            raise ValueError("Invalid tool archive identity")
    artifacts = lock.get("compiledFixtureArtifacts")
    if not isinstance(artifacts, list):
        raise ValueError("Invalid compiled fixture artifact inventory")
    if not artifacts:
        blockers.append("compiled-fixture-artifacts")
    seen_artifacts: set[str] = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ValueError("Invalid compiled fixture artifact identity")
        name = artifact.get("path")
        digest = artifact.get("sha256")
        compiler = artifact.get("compilerTool")
        inputs = artifact.get("sourcePaths")
        if not isinstance(name, str) or name in seen_artifacts or not isinstance(digest, str) \
                or not re.fullmatch(r"[0-9a-f]{64}", digest) or compiler not in tools \
                or not isinstance(inputs, list) or not inputs or any(item not in sources for item in inputs):
            raise ValueError("Invalid compiled fixture artifact identity")
        path = (directory / name).resolve()
        if not path.is_relative_to(directory) or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError("Compiled fixture artifact changed or escaped its fixture root")
        seen_artifacts.add(name)
    return blockers


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path(__file__).parent / "Fixtures")
    parser.add_argument("--require-ready", action="store_true")
    args = parser.parse_args()
    try:
        blockers = verify(args.directory)
    except (OSError, ValueError, TypeError) as error:
        print(f"Local fixture verification failed: {error}")
        return 1
    print(f"Local fixture input hashes verified; {len(blockers)} readiness blockers remain.")
    if args.require_ready and blockers:
        for blocker in blockers:
            print(f"BLOCKED {blocker}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
