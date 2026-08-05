"""Structured git status and diffs for the GUI's Changes panel.

`tools.py` already shells out to git for the *model*, returning flattened text.
This module is the structured counterpart for the UI: parsed porcelain v2 and
diff hunks with resolved line numbers, so the client never has to implement a
diff parser.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

from .proxy import sanitized_child_environment

GIT = "git"
DEFAULT_TIMEOUT = 15.0
MAX_STATUS_BYTES = 400_000
MAX_DIFF_BYTES = 200_000
MAX_FILES = 2_000

#: Diffing an untracked file needs a base; this is git's empty tree.
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


class GitUnavailable(Exception):
    """git is not installed, or could not be executed."""


def run_git(
    cwd: str,
    *args: str,
    timeout: float = DEFAULT_TIMEOUT,
    max_bytes: int = MAX_STATUS_BYTES,
) -> tuple[int, bytes, str, bool]:
    """Run git and return (returncode, stdout, stderr, truncated).

    Hardened deliberately:
    - `--literal-pathspecs` so a path such as ``:(glob)**`` is a filename, not
      pathspec magic.
    - `core.quotepath=false` so non-ASCII filenames come back as real UTF-8.
    - `GIT_OPTIONAL_LOCKS=0` so a status read never takes ``index.lock`` and
      races the agent's own git calls.
    - Output is read up to a cap rather than buffered whole: a huge diff would
      otherwise be held entirely in memory.
    """
    command = [
        GIT,
        "--literal-pathspecs",
        "-c", "core.quotepath=false",
        "-c", "color.ui=false",
        *args,
    ]
    # Stripped of proxy credentials: status reads are local, but git can be
    # configured to run helpers, and no child gets the secret.
    env = sanitized_child_environment({
        **os.environ,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
    })
    try:
        proc = subprocess.Popen(
            command,
            cwd=cwd or None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
    except FileNotFoundError as e:
        raise GitUnavailable("git is not installed") from e
    except OSError as e:
        raise GitUnavailable(str(e)) from e

    truncated = False
    chunks: list[bytes] = []
    total = 0
    assert proc.stdout is not None
    try:
        while True:
            chunk = proc.stdout.read(65_536)
            if not chunk:
                break
            if total < max_bytes:
                allowed = max_bytes - total
                chunks.append(chunk[:allowed])
                if len(chunk) > allowed:
                    truncated = True
            else:
                truncated = True
            total += len(chunk)
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        raise GitUnavailable(f"git timed out after {timeout}s") from None
    finally:
        stderr_bytes = proc.stderr.read() if proc.stderr else b""
        proc.stdout.close()
        if proc.stderr:
            proc.stderr.close()

    stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
    return proc.returncode, b"".join(chunks), stderr, truncated


def repo_root(cwd: str) -> str | None:
    """The repository root, or None when `cwd` is not in one.

    Raises GitUnavailable when git itself cannot run — "git is missing" and
    "this folder is not a repository" are different answers for the UI.
    """
    code, out, _, _ = run_git(cwd, "rev-parse", "--show-toplevel")
    if code != 0:
        return None
    root = out.decode("utf-8", errors="replace").strip()
    return root or None


def _split_z(data: bytes) -> list[str]:
    """Split NUL-delimited git output, dropping the trailing empty field."""
    text = data.decode("utf-8", errors="replace")
    fields = text.split("\0")
    if fields and fields[-1] == "":
        fields.pop()
    return fields


_XY_STATUS = {
    "M": "modified",
    "A": "added",
    "D": "deleted",
    "R": "renamed",
    "C": "copied",
    "T": "typechange",
}


def _classify(index_status: str, work_status: str) -> str:
    for code in (index_status, work_status):
        mapped = _XY_STATUS.get(code)
        if mapped:
            return mapped
    return "modified"


def _numstat(cwd: str, *extra: str) -> dict[str, tuple[int | None, int | None]]:
    """path -> (additions, deletions); (None, None) for binary files."""
    try:
        code, out, _, _ = run_git(cwd, "diff", "--numstat", "-z", *extra)
    except GitUnavailable:
        return {}
    if code != 0:
        return {}
    fields = _split_z(out)
    counts: dict[str, tuple[int | None, int | None]] = {}
    i = 0
    while i < len(fields):
        parts = fields[i].split("\t")
        if len(parts) < 3:
            i += 1
            continue
        added, deleted, path = parts[0], parts[1], parts[2]
        if path == "":
            # A rename in -z mode emits "add\tdel\t" then old and new paths as
            # two further NUL-separated fields.
            if i + 2 < len(fields):
                path = fields[i + 2]
                i += 2
        i += 1
        pair: tuple[int | None, int | None]
        if added == "-" or deleted == "-":
            pair = (None, None)
        else:
            try:
                pair = (int(added), int(deleted))
            except ValueError:
                pair = (None, None)
        counts[path] = pair
    return counts


def parse_porcelain_v2(data: bytes) -> dict[str, Any]:
    """Parse `git status --porcelain=v2 --branch -z` into files and branch info.

    The trap this exists to handle: a ``2 `` (rename/copy) record consumes TWO
    NUL-terminated fields. A loop that advances one field per record silently
    corrupts every entry after the first rename.
    """
    fields = _split_z(data)
    branch: str | None = None
    upstream: str | None = None
    ahead = behind = 0
    detached = False
    files: list[dict[str, Any]] = []

    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if not entry:
            continue

        if entry.startswith("# "):
            header = entry[2:]
            if header.startswith("branch.head "):
                value = header[len("branch.head "):].strip()
                if value == "(detached)":
                    detached = True
                else:
                    branch = value
            elif header.startswith("branch.upstream "):
                upstream = header[len("branch.upstream "):].strip()
            elif header.startswith("branch.ab "):
                for token in header[len("branch.ab "):].split():
                    try:
                        if token.startswith("+"):
                            ahead = int(token[1:])
                        elif token.startswith("-"):
                            behind = int(token[1:])
                    except ValueError:
                        pass
            continue

        kind = entry[:1]
        if kind == "?":
            files.append({
                "path": entry[2:],
                "orig_path": None,
                "index_status": ".",
                "work_status": "?",
                "status": "untracked",
                "staged": False,
                "unstaged": True,
                "untracked": True,
            })
            continue

        if kind == "u":
            parts = entry.split(" ", 10)
            files.append({
                "path": parts[-1] if parts else entry,
                "orig_path": None,
                "index_status": "U",
                "work_status": "U",
                "status": "unmerged",
                "staged": False,
                "unstaged": True,
                "untracked": False,
            })
            continue

        if kind not in ("1", "2"):
            continue

        parts = entry.split(" ", 8)
        if len(parts) < 9:
            continue
        xy = parts[1]
        index_status, work_status = xy[0], xy[1]
        path = parts[8]
        orig_path = None
        if kind == "2":
            # Field 8 of a rename/copy record is "<X><score> <path>" — the
            # similarity score is part of the field, not a separate one. The
            # original path then follows as its own NUL-separated field.
            _, _, path = path.partition(" ")
            if index < len(fields):
                orig_path = fields[index]
                index += 1

        files.append({
            "path": path,
            "orig_path": orig_path,
            "index_status": index_status,
            "work_status": work_status,
            "status": _classify(index_status, work_status),
            "staged": index_status not in (".", "?"),
            "unstaged": work_status not in (".", "?"),
            "untracked": False,
        })

    return {
        "branch": branch,
        "detached": detached,
        "upstream": upstream,
        "ahead": ahead,
        "behind": behind,
        "files": files,
    }


def status(cwd: str, untracked: str = "normal", max_files: int = MAX_FILES) -> dict[str, Any]:
    """Working-tree status. Never raises; a non-repo is a normal answer."""
    empty = {
        "ok": True, "is_repo": False, "error": None, "root": None, "cwd": cwd,
        "branch": None, "detached": False, "upstream": None,
        "ahead": 0, "behind": 0, "has_commits": False,
        "files": [], "counts": {"staged": 0, "unstaged": 0, "untracked": 0, "total": 0},
        "truncated": False,
    }
    if not cwd or not Path(cwd).is_dir():
        return {**empty, "ok": False, "error": "workspace folder is unavailable"}

    try:
        root = repo_root(cwd)
        if root is None:
            return {**empty, "reason": "not a git repository"}

        code, out, stderr, truncated = run_git(
            cwd,
            "status", "--porcelain=v2", "--branch", "-z",
            f"--untracked-files={'all' if untracked == 'all' else 'normal'}",
        )
        if code != 0:
            return {**empty, "ok": False, "is_repo": True, "root": root,
                    "error": stderr.splitlines()[0] if stderr else "git status failed"}

        parsed = parse_porcelain_v2(out)
        has_commits = run_git(cwd, "rev-parse", "--verify", "HEAD")[0] == 0

        unstaged_counts = _numstat(cwd)
        staged_counts = _numstat(cwd, "--cached")

        files = parsed["files"][:max_files]
        for item in files:
            additions = deletions = None
            binary = False
            if item["untracked"]:
                additions, deletions = _count_untracked_lines(cwd, item["path"])
                binary = additions is None
            else:
                counts = unstaged_counts.get(item["path"]) or staged_counts.get(item["path"])
                if counts is not None:
                    additions, deletions = counts
                    binary = counts == (None, None)
            item["additions"] = additions
            item["deletions"] = deletions
            item["binary"] = binary

        return {
            "ok": True, "is_repo": True, "error": None, "root": root, "cwd": cwd,
            "branch": parsed["branch"], "detached": parsed["detached"],
            "upstream": parsed["upstream"], "ahead": parsed["ahead"],
            "behind": parsed["behind"], "has_commits": has_commits,
            "files": files,
            "counts": {
                "staged": sum(1 for f in files if f["staged"]),
                "unstaged": sum(1 for f in files if f["unstaged"] and not f["untracked"]),
                "untracked": sum(1 for f in files if f["untracked"]),
                "total": len(files),
            },
            "truncated": truncated or len(parsed["files"]) > max_files,
        }
    except GitUnavailable as e:
        return {**empty, "ok": False, "error": str(e)}


def _count_untracked_lines(cwd: str, path: str) -> tuple[int | None, int]:
    """Line count of a new file, for its `+N` badge. None when binary/large."""
    target = Path(cwd) / path
    try:
        if not target.is_file() or target.stat().st_size > 512_000:
            return None, 0
        raw = target.read_bytes()
    except OSError:
        return None, 0
    if b"\0" in raw[:4096]:
        return None, 0
    return raw.count(b"\n") + (0 if raw.endswith(b"\n") or not raw else 1), 0


def file_diff(
    cwd: str,
    path: str,
    staged: bool = False,
    context: int = 3,
    max_bytes: int = MAX_DIFF_BYTES,
) -> dict[str, Any]:
    """Unified diff for one file, as raw patch text plus a truncation flag."""
    result: dict[str, Any] = {
        "ok": True, "path": path, "staged": staged, "binary": False,
        "truncated": False, "raw": "", "error": None,
    }
    if not path:
        return {**result, "ok": False, "error": "path is required"}

    try:
        root = repo_root(cwd) or cwd
    except GitUnavailable as e:
        return {**result, "ok": False, "error": str(e)}
    try:
        resolved = (Path(root) / path).resolve()
        if Path(root).resolve() not in resolved.parents and resolved != Path(root).resolve():
            return {**result, "ok": False, "error": "path is outside the workspace"}
    except OSError:
        return {**result, "ok": False, "error": "path is unavailable"}

    context = max(0, min(context, 20))
    try:
        tracked = run_git(cwd, "ls-files", "--error-unmatch", "--", path)[0] == 0
        if not tracked:
            # --no-index exits 1 to mean "there are differences" — not failure.
            code, out, stderr, truncated = run_git(
                cwd, "diff", "--no-index", f"-U{context}", "--", os.devnull, path,
                max_bytes=max_bytes,
            )
            if code > 1:
                return {**result, "ok": False, "error": stderr or "git diff failed"}
        else:
            args = ["diff", f"-U{context}"]
            if staged:
                args.append("--cached")
            code, out, stderr, truncated = run_git(
                cwd, *args, "--", path, max_bytes=max_bytes
            )
            if code > 1:
                return {**result, "ok": False, "error": stderr or "git diff failed"}
    except GitUnavailable as e:
        return {**result, "ok": False, "error": str(e)}

    text = out.decode("utf-8", errors="replace")
    binary = "Binary files" in text or "GIT binary patch" in text
    return {
        **result,
        "binary": binary,
        "truncated": truncated,
        "raw": "" if binary else text,
    }
