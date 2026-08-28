#!/usr/bin/env python3
"""Emit advisory size and change-slice signals without failing the build."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION_ROOTS = (ROOT / "Locus", ROOT / "agent" / "ollama_code")
SOURCE_SUFFIXES = {".swift", ".py"}
SKIPPED_PARTS = {".build", ".venv", "__pycache__", "Resources"}
FILE_WARNING_LINES = 800
FILE_ATTENTION_LINES = 1_500
CHANGE_WARNING_LINES = 400
CHANGE_TOTAL_WARNING_LINES = 1_500
MAX_FILE_FINDINGS = 15
APP_MODEL_PATH = "Locus/AppModel.swift"
SERVER_PATH = "agent/ollama_code/server.py"
APP_MODEL_STATE = re.compile(r"^\s{4}@Published\b")
APP_MODEL_ACTION = re.compile(r"^\s{4}(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)")
SERVER_FUNCTION = re.compile(r"^(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)")
ROUTE_HANDLER = re.compile(r"handlers\.([A-Za-z_][A-Za-z0-9_]*)")
DOMAIN_HANDLER_LEGACY_ALLOWLIST = {
    "continuity.py": set(),
    "evaluations.py": set(),
    "extensions.py": set(),
    "knowledge.py": set(),
    "providers.py": set(),
    "schedules.py": set(),
    "sessions.py": set(),
    "system.py": set(),
    "workspace.py": set(),
}


@dataclass(frozen=True)
class Finding:
    level: str
    subject: str
    detail: str


def _relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def _source_files() -> list[Path]:
    files: list[Path] = []
    for source_root in PRODUCTION_ROOTS:
        for path in source_root.rglob("*"):
            if (
                path.is_file()
                and path.suffix in SOURCE_SUFFIXES
                and not SKIPPED_PARTS.intersection(path.parts)
            ):
                files.append(path)
    return sorted(files)


def _line_count(path: Path) -> int:
    with path.open("rb") as handle:
        return sum(1 for _ in handle)


def file_findings() -> list[Finding]:
    ranked: list[tuple[int, Finding]] = []
    for path in _source_files():
        lines = _line_count(path)
        if lines >= FILE_ATTENTION_LINES:
            ranked.append(
                (
                    lines,
                    Finding(
                        "attention",
                        _relative(path),
                        f"{lines:,} lines; identify the next feature-owned extraction.",
                    ),
                )
            )
        elif lines >= FILE_WARNING_LINES:
            ranked.append(
                (
                    lines,
                    Finding(
                        "watch",
                        _relative(path),
                        f"{lines:,} lines; keep new responsibilities out of this file.",
                    ),
                )
            )
    ranked.sort(key=lambda item: (-item[0], item[1].subject))
    findings = [finding for _, finding in ranked[:MAX_FILE_FINDINGS]]
    suppressed = len(ranked) - len(findings)
    if suppressed > 0:
        findings.append(
            Finding(
                "info",
                "Additional large files",
                f"{suppressed} lower-priority signals omitted; run locally when choosing the next extraction.",
            )
        )
    return findings


def _git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def _valid_base(base: str) -> bool:
    if not base or set(base) == {"0"}:
        return False
    return _git("cat-file", "-e", f"{base}^{{commit}}").returncode == 0


def change_findings(base: str) -> tuple[list[Finding], str]:
    if not _valid_base(base):
        return [], "No reachable comparison commit; file-size signals only."
    result = _git("diff", "--numstat", f"{base}...HEAD")
    if result.returncode != 0:
        return [], "The comparison diff was unavailable; file-size signals only."

    findings: list[Finding] = []
    total = 0
    changed_files = 0
    for row in result.stdout.splitlines():
        added, deleted, path = row.split("\t", 2)
        if not added.isdigit() or not deleted.isdigit():
            continue
        changed = int(added) + int(deleted)
        total += changed
        changed_files += 1
        if changed >= CHANGE_WARNING_LINES:
            findings.append(
                Finding(
                    "watch",
                    path,
                    f"{changed:,} changed lines; confirm this is one mechanical move or one behavior.",
                )
            )
    if total >= CHANGE_TOTAL_WARNING_LINES:
        findings.insert(
            0,
            Finding(
                "attention",
                "Review slice",
                f"{total:,} changed lines across {changed_files} files; consider independently green commits.",
            ),
        )
    return (
        findings,
        f"Compared `{base[:12]}...HEAD`: {total:,} changed lines in {changed_files} files.",
    )


def _added_lines(patch: str) -> list[str]:
    return [
        line[1:]
        for line in patch.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    ]


def _registered_server_handlers() -> set[str]:
    handlers: set[str] = set()
    for path in (ROOT / "agent" / "ollama_code" / "api").glob("*.py"):
        handlers.update(ROUTE_HANDLER.findall(path.read_text(encoding="utf-8")))
    return handlers


def _composition_root_patch_finding(
    path: str,
    patch: str,
    *,
    registered_server_handlers: set[str] | None = None,
) -> Finding | None:
    added = _added_lines(patch)
    if path == APP_MODEL_PATH:
        state_count = sum(bool(APP_MODEL_STATE.match(line)) for line in added)
        action_count = sum(bool(APP_MODEL_ACTION.match(line)) for line in added)
        if not state_count and not action_count:
            return None
        parts = []
        if state_count:
            parts.append(f"{state_count} published state declaration(s)")
        if action_count:
            parts.append(f"{action_count} view-facing action(s)")
        return Finding(
            "attention",
            path,
            f"Adds {' and '.join(parts)}; put feature state and actions in a feature owner.",
        )
    if path == SERVER_PATH:
        registered = registered_server_handlers or set()
        handler_names = {
            match.group(1)
            for line in added
            if (match := SERVER_FUNCTION.match(line)) and match.group(1) in registered
        }
        if not handler_names:
            return None
        return Finding(
            "attention",
            path,
            f"Adds {len(handler_names)} registered API handler(s); put behavior in the owning domain module.",
        )
    return None


def composition_root_findings(base: str) -> list[Finding]:
    if not _valid_base(base):
        return []
    handlers = _registered_server_handlers()
    findings: list[Finding] = []
    for path in (APP_MODEL_PATH, SERVER_PATH):
        result = _git("diff", "--unified=0", f"{base}...HEAD", "--", path)
        if result.returncode != 0:
            continue
        finding = _composition_root_patch_finding(
            path,
            result.stdout,
            registered_server_handlers=handlers,
        )
        if finding is not None:
            findings.append(finding)
    return findings


def boundary_findings() -> list[Finding]:
    findings: list[Finding] = []
    api_root = ROOT / "agent" / "ollama_code" / "api"
    for path in sorted(api_root.glob("*.py")):
        source = path.read_text(encoding="utf-8")
        if "from .. import server" in source or "from ..server import" in source:
            findings.append(
                Finding(
                    "attention",
                    _relative(path),
                    "API modules must receive handlers/dependencies; they cannot import the composition root.",
                )
            )
        if path.name in DOMAIN_HANDLER_LEGACY_ALLOWLIST:
            allowed = DOMAIN_HANDLER_LEGACY_ALLOWLIST[path.name]
            unexpected = set(ROUTE_HANDLER.findall(source)) - allowed
            if unexpected:
                findings.append(
                    Finding(
                        "attention",
                        _relative(path),
                        "Domain-owned routes must register local handlers; "
                        f"unexpected server handlers: {', '.join(sorted(unexpected))}.",
                    )
                )
    server = ROOT / "agent" / "ollama_code" / "server.py"
    for line_number, line in enumerate(
        server.read_text(encoding="utf-8").splitlines(), 1
    ):
        if line.lstrip().startswith("@api."):
            findings.append(
                Finding(
                    "attention",
                    f"{_relative(server)}:{line_number}",
                    "Declare public routes in the matching agent/ollama_code/api module.",
                )
            )
    return findings


def render(base: str) -> str:
    changes, comparison = change_findings(base)
    groups = (
        ("Architecture boundaries", boundary_findings()),
        ("Composition-root growth", composition_root_findings(base)),
        ("Change slice", changes),
        ("Large production files", file_findings()),
    )
    lines = [
        "## Reviewability report (advisory)",
        "",
        comparison,
        "Threshold findings never fail CI; they are prompts for reviewer judgment.",
    ]
    for title, findings in groups:
        lines.extend(("", f"### {title}", ""))
        if not findings:
            lines.append("No signals.")
            continue
        for finding in findings:
            lines.append(
                f"- **{finding.level.upper()}** `{finding.subject}` — {finding.detail}"
            )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--base",
        default=os.environ.get("LOCUS_REVIEW_BASE", ""),
        help="base commit used for advisory diff sizing",
    )
    parser.add_argument(
        "--summary",
        default=os.environ.get("GITHUB_STEP_SUMMARY", ""),
        help="optional Markdown file to append (for example GITHUB_STEP_SUMMARY)",
    )
    args = parser.parse_args()
    report = render(args.base.strip())
    print(report, end="")
    if args.summary:
        summary = Path(args.summary)
        with summary.open("a", encoding="utf-8") as handle:
            handle.write(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
