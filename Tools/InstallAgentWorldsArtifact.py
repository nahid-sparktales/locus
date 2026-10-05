#!/usr/bin/env python3
"""Review/install a pinned local Agent Worlds ZIP using Locus's plugin manager.

Quit Locus and its backend before install/rollback. No network, marketplace
registration, app launch, profile migration or implicit default state directory.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "agent"))
from ollama_code.extensions import ExtensionManager, _tree_digest, parse_plugin
from VerifyAgentWorldsArtifact import extract_candidate

PLUGIN_ID = "locus/agent-world"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_pin(value: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{64}", value):
        raise ValueError("A complete SHA-256 pin is required")
    return value.lower()


@contextmanager
def candidate(archive: Path | None, pin: str | None, development_directory: Path | None = None):
    if (archive is None) == (development_directory is None):
        raise ValueError("Choose exactly one ZIP or development directory")
    if development_directory is not None and pin is not None:
        raise ValueError("ZIP checksum is not accepted in development directory mode")
    if archive is not None:
        pin = require_pin(pin or "")
    if archive is not None and archive.stat().st_size > 260 * 1024 * 1024:
        raise ValueError("Artifact exceeds the bounded ZIP size")
    with tempfile.TemporaryDirectory(prefix="locus-artifact-review-") as temporary:
        root = Path(temporary)
        # Hash and extract this one private byte snapshot, not a mutable input path.
        destination = root / "plugin"
        if archive is not None:
            copied = root / "candidate.zip"
            shutil.copyfile(archive, copied)
            extract_candidate(copied, pin, destination)
        else:
            if not development_directory.is_dir() or development_directory.is_symlink():
                raise ValueError("Development source must be an explicit regular directory")
            rows = list(development_directory.rglob("*"))
            if len(rows) > 5_000 or any(path.is_symlink() for path in rows) \
                    or sum(path.stat().st_size for path in rows if path.is_file()) > 250 * 1024 * 1024:
                raise ValueError("Development directory exceeds bounds or contains symbolic links")
            if any(set(path.relative_to(development_directory).parts) & {".git", "node_modules", "outpost"} for path in rows):
                raise ValueError("Choose the built plugin directory, without development dependencies or archives")
            shutil.copytree(development_directory, destination, symlinks=True)
            if any(path.is_symlink() for path in destination.rglob("*")):
                raise ValueError("Development source changed during staging")
            manifest_path = destination / ".codex-plugin/plugin.json"
            marked = json.loads(manifest_path.read_text())
            marked.setdefault("interface", {})["displayName"] = "Agent Worlds (development)"
            for screen in marked.get("locus", {}).get("screens", []):
                screen["title"] = "Agent Worlds (development)"
            manifest_path.write_text(json.dumps(marked, indent=2) + "\n")
        parsed = parse_plugin(destination)
        manifest = json.loads((destination / ".codex-plugin/plugin.json").read_text())
        screen = parsed["screens"]
        if parsed["name"] != "agent-world" or not re.fullmatch(r"0\.2\.\d+", parsed["version"]):
            raise ValueError("Expected agent-world identity and supported 0.2.x version")
        if len(screen) != 1 or screen[0]["id"] != "agent-world" or screen[0]["version"] != 2 \
                or screen[0]["entrypoint"] != "ui/index.html" \
                or screen[0]["capabilities"] != ["agents.interact", "agents.read", "world.preferences"]:
            raise ValueError("Unexpected screen identity, protocol, entrypoint or capabilities")
        if any(parsed[key] for key in ["skills", "mcp_servers", "panels", "scripts", "unsupported"]):
            raise ValueError("Artifact requests features outside the reviewed Agent Worlds screen")
        metadata = manifest.get("agentWorlds", {})
        if metadata.get("worlds") != ["local-line"] or metadata.get("bridgeVersion") != 2 \
                or metadata.get("sdkVersion") != 1 or metadata.get("runtimeVersion") != parsed["version"]:
            raise ValueError("Unexpected Agent Worlds runtime metadata")
        world = json.loads((destination / "ui/world.json").read_text())
        if world.get("id") != "local-line" or world.get("version") != parsed["version"]:
            raise ValueError("Expected matching Local Line world metadata")
        files = [{"path": str(path.relative_to(destination)), "bytes": path.stat().st_size, "sha256": sha256(path)}
                 for path in sorted(destination.rglob("*")) if path.is_file()]
        report = {"mode": "development" if development_directory else "artifact",
                  "development_directory": str(development_directory.resolve()) if development_directory else None, "artifact_sha256": pin, "plugin_digest": _tree_digest(destination), "installation_id": PLUGIN_ID,
                  "version": parsed["version"], "protocol": 2, "manifest": manifest, "world": world,
                  "trust": ExtensionManager._trust_summary(parsed), "file_count": len(files), "files": files}
        yield destination, report


def review(archive: Path | None, pin: str | None, extract_to: Path | None = None, *, development_directory: Path | None = None) -> dict:
    with candidate(archive, pin, development_directory) as (source, report):
        if extract_to is not None:
            # copytree refuses an existing destination; review never overwrites files.
            shutil.copytree(source, extract_to)
        return report


def read_state(root: Path) -> dict:
    path = root / "state.json"
    if not path.exists():
        return ExtensionManager._defaults()
    if path.is_symlink() or path.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Extension state is not a bounded regular state file")
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get("version") != 3 \
            or any(not isinstance(value.get(key), list) for key in ["marketplaces", "plugins", "standalone_skills", "builtin_skill_overrides", "mcp_servers"]) \
            or not isinstance(value.get("mcp_policies"), dict):
        raise ValueError("Unsupported or corrupt extension state; open compatible Locus to migrate it first")
    return value


@contextmanager
def offline_manager(root: Path):
    root.mkdir(parents=True, exist_ok=True)
    # This serializes CLI instances. Locus's manager has only an in-process lock,
    # so the app/backend must be stopped to avoid a second state writer.
    with (root / ".agent-worlds-install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        read_state(root)  # Refuse the manager's degraded-read fallback for mutations.
        with tempfile.TemporaryDirectory(prefix="locus-artifact-cwd-") as cwd:
            yield cwd


class ArtifactManager(ExtensionManager):
    """Adapt one reviewed directory to the existing install_plugin source seam.

    No catalog is added, renamed or replaced. The manager retains responsibility
    for validated copying, immutable version roots, scope, history and state commit.
    """
    artifact: Path

    def _catalog_entry(self, marketplace_id: str, name: str) -> dict:
        if marketplace_id == "locus" and name == "agent-world":
            return {"name": name, "available": True, "marketplace_root": str(self.artifact.parent),
                    "source": {"source": "local", "path": "./" + self.artifact.name}}
        return super()._catalog_entry(marketplace_id, name)


def checked_record(state: dict) -> dict | None:
    if any(not isinstance(row, dict) for row in state["plugins"]):
        raise ValueError("Corrupt plugin records")
    matches = [row for row in state["plugins"] if row.get("id") == PLUGIN_ID]
    if len(matches) > 1:
        raise ValueError("Duplicate Agent Worlds installation identity")
    if matches and (matches[0].get("name") != "agent-world" or matches[0].get("marketplace_id") != "locus"):
        raise ValueError("Installed identity is inconsistent")
    return matches[0] if matches else None


def checked_cached_root(state_root: Path, record: dict) -> Path:
    path = Path(str(record.get("root", "")))
    cache = (state_root / "plugins/cache/locus/agent-world").resolve()
    if not path.is_absolute() or path.is_symlink() or not path.resolve().is_relative_to(cache):
        raise ValueError("Installed plugin is outside its expected version cache")
    if _tree_digest(path) != record.get("digest"):
        raise ValueError("Cached plugin contents no longer match their recorded digest")
    if parse_plugin(path)["name"] != "agent-world":
        raise ValueError("Cached plugin identity is inconsistent")
    return path


def install(archive: Path | None, pin: str | None, reviewed_digest: str, state_root: Path, *, workspace: str = "",
            scope: str = "workspace", upgrade_legacy_v1: bool = False, development_directory: Path | None = None) -> dict:
    reviewed_digest = require_pin(reviewed_digest)
    if scope not in {"workspace", "global"} or (scope == "workspace" and not workspace):
        raise ValueError("Workspace scope requires an explicit workspace directory")
    with candidate(archive, pin, development_directory) as (source, report):
        if report["plugin_digest"] != reviewed_digest:
            raise ValueError("Artifact contents changed after review")
        with offline_manager(state_root) as cwd:
            state = read_state(state_root)
            existing = checked_record(state)
            if existing:
                old = parse_plugin(checked_cached_root(state_root, existing))
                if any(screen["version"] == 1 for screen in old["screens"]) and not upgrade_legacy_v1:
                    raise ValueError("Legacy screen protocol 1 upgrade requires --upgrade-legacy-v1")
            manager = ArtifactManager(cwd, root=state_root)
            # Retain a content-addressed source so installed provenance never names
            # a deleted temporary directory. No marketplace discovery is introduced.
            retained = state_root / "plugins/artifacts" / (report["artifact_sha256"] or ("development-" + reviewed_digest))
            retained.parent.mkdir(parents=True, exist_ok=True)
            if retained.exists():
                if retained.is_symlink() or _tree_digest(retained) != reviewed_digest:
                    raise ValueError("Retained artifact does not match its reviewed digest")
            else:
                with tempfile.TemporaryDirectory(prefix=".artifact.", dir=retained.parent) as temporary:
                    staged = Path(temporary) / "plugin"
                    shutil.copytree(source, staged)
                    staged.replace(retained)
            manager.artifact = retained
            destination = manager.plugins_root / "locus/agent-world" / report["version"]
            if destination.is_symlink():
                raise ValueError("Cached version must not be a symbolic link")
            if destination.exists() and _tree_digest(destination) != reviewed_digest:
                destination = destination.with_name(destination.name + "-" + reviewed_digest[:12])
            if destination.is_symlink() or (destination.exists() and _tree_digest(destination) != reviewed_digest):
                raise ValueError("Cached version conflicts with the reviewed artifact")
            inspection = manager.inspect_catalog_plugin("locus", "agent-world")
            result = manager.install_plugin("locus", "agent-world", scope=scope, workspace=workspace,
                                            expected_digest=reviewed_digest)
            return {"installation_id": result["id"], "version": result["version"], "plugin_digest": result["digest"],
                    "artifact_sha256": report["artifact_sha256"], "mode": report["mode"], "root": result["root"],
                    "enabled_global": result["enabled_global"], "enabled_workspaces": result["enabled_workspaces"],
                    "capability_diff": inspection["capability_diff"], "previous_versions": result["previous_versions"]}


def rollback(state_root: Path, current_digest: str, target_digest: str) -> dict:
    current_digest, target_digest = require_pin(current_digest), require_pin(target_digest)
    with offline_manager(state_root) as cwd:
        record = checked_record(read_state(state_root))
        if not record or record.get("digest") != current_digest:
            raise ValueError("Installed version changed after rollback review")
        checked_cached_root(state_root, record)
        previous = record.get("previous", [])
        if not previous or previous[0].get("digest") != target_digest:
            raise ValueError("Rollback target is not the reviewed previous version")
        checked_cached_root(state_root, previous[0])
        result = ExtensionManager(cwd, root=state_root).rollback_plugin(PLUGIN_ID)
        return {"installation_id": result["id"], "version": result["version"], "plugin_digest": result["digest"],
                "root": result["root"], "enabled_global": result["enabled_global"], "enabled_workspaces": result["enabled_workspaces"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("review", help="Read-only ZIP and file inventory review")
    add = commands.add_parser("install", help="Install/upgrade only after reviewing the content digest")
    back = commands.add_parser("rollback", help="Restore a reviewed cached version atomically")
    for command in (inspect, add):
        source = command.add_mutually_exclusive_group(required=True)
        source.add_argument("--artifact", type=Path)
        source.add_argument("--development-directory", type=Path, help="Explicit built plugin snapshot; marked development before review")
        command.add_argument("--sha256", help="Required for a ZIP artifact")
    inspect.add_argument("--extract-to", type=Path, help="Optional new folder for full file-content inspection")
    add.add_argument("--review-digest", required=True)
    add.add_argument("--scope", choices=["workspace", "global"], default="workspace")
    add.add_argument("--workspace", default="")
    add.add_argument("--upgrade-legacy-v1", action="store_true")
    for command in (add, back):
        command.add_argument("--state-root", required=True, type=Path, help="Explicit Locus extensions state folder; app/backend must be stopped")
    back.add_argument("--current-digest", required=True)
    back.add_argument("--target-digest", required=True)
    args = parser.parse_args()
    try:
        if args.command == "review": result = review(args.artifact, args.sha256, args.extract_to, development_directory=args.development_directory)
        elif args.command == "install": result = install(args.artifact, args.sha256, args.review_digest, args.state_root.expanduser().resolve(), workspace=args.workspace, scope=args.scope, upgrade_legacy_v1=args.upgrade_legacy_v1, development_directory=args.development_directory)
        else: result = rollback(args.state_root.expanduser().resolve(), args.current_digest, args.target_digest)
        print(json.dumps(result, indent=2))
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        parser.exit(1, f"Artifact operation failed: {error}\n")


if __name__ == "__main__":
    main()
