#!/usr/bin/env python3
"""Move test-run litter out of a real ~/.ollama-code/sessions.

Before `agent/tests/conftest.py` existed, test modules isolated their own paths
and two of them did not — so runs of the suite wrote fixture transcripts into the
developer's real session store, and one run clobbered `config.json` with fixture
values (`max_iterations: 5` survived there for a week, invisible because the app
has no UI for that setting).

This repairs both. It is committed rather than kept as a one-off because anyone
who ran the suite before that conftest landed has the same litter, and because a
classification you can re-read is safer than a `find … -delete` someone invents
under time pressure.

Transcripts are moved with the app's own `SessionStore.move_to_trash`, so they
land in the recovery folder with a manifest and stay restorable.

    Tools/PruneAgentTestLitter.py                # classify only (default)
    Tools/PruneAgentTestLitter.py --apply        # move the litter
    Tools/PruneAgentTestLitter.py --apply --fix-config

Run it with the app quit: the agent reads `max_iterations` once at startup and
rewrites the whole config file from memory, so a repair applied underneath a
running server is silently undone.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

AGENT_DIR = Path(__file__).resolve().parent.parent / "agent"
sys.path.insert(0, str(AGENT_DIR))

#: Models that only ever appear in test fixtures. A real model name has a tag or
#: a registry path; these are bare words chosen by tests.
FIXTURE_MODELS = {"fixture", "test-model", "small-model", "test", "m"}

#: Tool-step limits the old test fixtures wrote into whatever config they could
#: reach. Both are legal values, so nothing else can tell them apart from a
#: deliberate choice — but a config that was clobbered by a test carries one of
#: these, and 5 stopped real turns early for a week without the app ever saying
#: which number it was using. Reset unless --keep-iterations says otherwise.
FIXTURE_ITERATION_LIMITS = {2, 5}

#: A transcript whose cwd is one of these was not a real piece of work. pytest's
#: tmp_path lives under `pytest-of-<user>`; the ad-hoc runs used mkdtemp and /tmp.
#: Matched as "the root itself, or a path under it" — a cwd of exactly `/tmp` is
#: as temporary as one inside it.
TEMP_ROOTS = ("/private/var/folders", "/var/folders", "/tmp", "/private/tmp")
TEMP_MARKERS = ("pytest-of-", "pytest-")


def _header(path: Path) -> dict:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.loads(handle.readline() or "{}")
    except (OSError, json.JSONDecodeError):
        return {}


def _message_count(path: Path) -> int:
    """Real conversation records in a transcript."""
    total = 0
    try:
        with path.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("type") == "message":
                    total += 1
    except OSError:
        return 0
    return total


def _is_temp_cwd(cwd: str) -> bool:
    if not cwd:
        return False
    path = cwd.rstrip("/") or "/"
    if any(path == root or path.startswith(root + "/") for root in TEMP_ROOTS):
        return True
    return any(mark in path for mark in TEMP_MARKERS)


def classify(path: Path) -> tuple[str, str]:
    """(verdict, why) for one transcript. Verdict is "litter" or "keep"."""
    header = _header(path)
    model = str(header.get("model") or "")
    cwd = str(header.get("cwd") or "")
    messages = _message_count(path)

    if model not in FIXTURE_MODELS:
        return "keep", f"real model ({model or 'none recorded'})"
    if not _is_temp_cwd(cwd):
        # A fixture model with a real cwd is the app itself, started while the
        # config was clobbered. That is evidence, not litter.
        return "keep", f"fixture model but real cwd ({cwd or 'none recorded'})"
    if messages:
        # The decisive condition. One transcript has a `test-model` header, a
        # temp cwd, and four real messages about an attached image — a genuine
        # conversation the app resumed from a file a stubbed run had created.
        # Deleting by header alone would have destroyed it.
        return "keep", f"fixture model and temp cwd, but {messages} real message(s)"
    return "litter", f"model {model}, temp cwd, no messages"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__ or "")
    parser.add_argument(
        "--apply", action="store_true",
        help="actually move the litter (default is to classify and stop)",
    )
    parser.add_argument(
        "--fix-config", action="store_true",
        help="also reset a max_iterations that a test wrote, and drop "
             "model_windows entries for models that are not installed",
    )
    parser.add_argument(
        "--keep-iterations", action="store_true",
        help="leave max_iterations alone even if it matches a fixture value",
    )
    parser.add_argument(
        "--set-iterations", type=int, default=0, metavar="N",
        help="set max_iterations to N explicitly",
    )
    args = parser.parse_args()

    if os.environ.get("OLLAMA_CODE_HOME"):
        print(f"note: OLLAMA_CODE_HOME={os.environ['OLLAMA_CODE_HOME']}")

    from ollama_code.config import (
        CONFIG_PATH,
        DEFAULTS,
        iteration_limit,
        load_config,
        save_config,
    )
    from ollama_code.sessions import SESSIONS_DIR, SessionStore

    print(f"sessions: {SESSIONS_DIR}")
    if not SESSIONS_DIR.exists():
        print("  no session store here — nothing to do")
        return 0

    litter: list[Path] = []
    kept: list[tuple[Path, str]] = []
    for path in sorted(SESSIONS_DIR.glob("*.jsonl")):
        verdict, why = classify(path)
        if verdict == "litter":
            litter.append(path)
        else:
            kept.append((path, why))

    print(f"  {len(kept)} to keep, {len(litter)} classified as test litter")
    for path in litter:
        print(f"    litter  {path.name}")
    # Only the interesting keeps: a fixture model that survived a condition.
    for path, why in kept:
        if "fixture model" in why or "real message" in why:
            print(f"    keep    {path.name}  ({why})")

    if litter and args.apply:
        count, recovery = SessionStore.move_to_trash([p.stem for p in litter])
        print(f"  moved {count} transcript(s) to {recovery}")
    elif litter:
        print("  (dry run — pass --apply to move them)")

    cfg = load_config()
    limit = cfg.get("max_iterations")
    windows = dict(cfg.get("model_windows") or {})
    phantom: list[str] = []
    try:
        from ollama_code.ollama import OllamaClient

        installed = {m.get("name") for m in OllamaClient(cfg.get("host") or "").list_models()}
    except Exception as error:  # noqa: BLE001 — advisory only
        installed = None
        print(f"config: could not list installed models ({error})")
    if installed is not None:
        phantom = [
            key for key in windows
            if key.rsplit("|", 1)[-1] in FIXTURE_MODELS
            or key.rsplit("|", 1)[-1] not in installed
        ]

    print(f"config: {CONFIG_PATH}")
    print(f"  max_iterations = {limit!r} (default {DEFAULTS['max_iterations']})")
    for key in phantom:
        print(f"  phantom model_window: {key} = {windows[key]}")

    default_limit = int(DEFAULTS["max_iterations"])
    wants_limit = args.set_iterations or (
        default_limit
        if limit in FIXTURE_ITERATION_LIMITS and not args.keep_iterations
        else 0
    )
    if wants_limit and wants_limit != limit and not args.fix_config:
        print(f"  (pass --fix-config to set it to {wants_limit})")

    if args.fix_config:
        changed = False
        # Normalisation first — an unusable value can never be kept — then the
        # fixture reset, which is a judgement about where a legal value came
        # from rather than about whether it is legal.
        normalised = iteration_limit(limit)
        target = wants_limit or normalised
        if target != limit:
            cfg["max_iterations"] = target
            print(f"  max_iterations {limit} -> {target}")
            changed = True
        for key in phantom:
            windows.pop(key, None)
            changed = True
        cfg["model_windows"] = windows
        if changed:
            save_config(cfg)
            print("  config saved")
        else:
            print("  config already clean")
    elif iteration_limit(limit) != limit or phantom:
        print("  (pass --fix-config to repair)")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
