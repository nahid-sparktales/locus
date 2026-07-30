"""Tool implementations and Ollama tool schemas.

Schemas are deliberately flat with one-sentence descriptions so that small
local models (8B-class) can follow them reliably.
"""
from __future__ import annotations

import difflib
import fnmatch
import glob as globmod
import html as html_module
import json
import os
import re
import signal
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import USER_AGENT

MAX_OUTPUT = 30_000
MAX_LIST_ENTRIES = 300
MAX_GREP_MATCHES = 200
MAX_GLOB_RESULTS = 200
BASH_TIMEOUT = 120

IGNORE_DIRS = {
    ".git", ".hg", ".svn", ".venv", "venv", "env", "node_modules",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    "dist", "build", ".idea", ".tox", ".next", "target",
}

#: Read-only tools that never require permission.
SAFE_TOOLS = {"read_file", "glob", "grep", "list_dir", "todo_write"}

#: Tools that modify files — auto-allowed in the "accept_edits" mode.
EDIT_TOOLS = {"write_file", "edit_file", "multi_edit"}


@dataclass
class ToolContext:
    """Mutable per-session state shared with tools."""

    todos: list[dict[str, str]] = field(default_factory=list)
    cwd: str = ""
    #: Files read this turn, so edit_file can warn about blind edits.
    read_files: set[str] = field(default_factory=set)

    def resolve(self, path: str) -> Path:
        """Resolve a possibly-relative path against the agent's cwd."""
        p = Path(path).expanduser()
        if not p.is_absolute() and self.cwd:
            p = Path(self.cwd) / p
        return p

    def is_inside_workspace(self, path: Path) -> bool:
        """True when ``path`` resolves inside the workspace.

        Symlinks are resolved first, so a link inside the workspace pointing
        outside it does not count as inside.
        """
        if not self.cwd:
            return True
        try:
            root = Path(self.cwd).resolve()
            target = path.resolve() if path.exists() else path.parent.resolve() / path.name
        except (OSError, RuntimeError):
            return False
        return target == root or root in target.parents


def _truncate(text: str, limit: int = MAX_OUTPUT) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n... [truncated, {len(text) - limit} more chars]"


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------------------
# implementations


def _impl_read_file(args: dict[str, Any], ctx: ToolContext) -> str:
    path = str(args.get("path", "")).strip()
    if not path:
        return "Error: 'path' is required."
    p = ctx.resolve(path)
    if not p.exists():
        return f"Error: file not found: {path}"
    if p.is_dir():
        return f"Error: {path} is a directory. Use list_dir instead."
    try:
        raw = p.read_bytes()
    except OSError as e:
        return f"Error reading {path}: {e}"
    if b"\0" in raw[:4096]:
        return f"Error: {path} looks like a binary file ({len(raw)} bytes)."
    lines = raw.decode("utf-8", errors="replace").splitlines()
    total = len(lines)
    offset = _as_int(args.get("offset"), 0)
    limit = _as_int(args.get("limit"), 0)
    start = max(offset - 1, 0) if offset else 0
    end = min(start + limit, total) if limit else total
    if total > 0 and start >= total:
        return f"Error: offset {offset} is beyond the end of {path} ({total} lines)."
    body = "\n".join(f"{n}\t{line}" for n, line in enumerate(lines[start:end], start + 1))
    note = f"# {p} — {total} lines"
    if start > 0 or end < total:
        note += f" (showing {start + 1}-{end})"
    if end < total:
        note += f". Use offset={end + 1} to continue."
    ctx.read_files.add(str(p))
    return _truncate(note + "\n" + (body or "(empty)"))


def _impl_write_file(args: dict[str, Any], ctx: ToolContext) -> str:
    path = str(args.get("path", "")).strip()
    content = args.get("content", "")
    if not path:
        return "Error: 'path' is required."
    if not isinstance(content, str):
        content = json.dumps(content, indent=2, ensure_ascii=False)
    p = ctx.resolve(path)
    existed = p.is_file()
    if p.is_symlink():
        # The permission preview showed this path; writing through a link
        # would modify a different file than the one the user approved.
        return (
            f"Error: {path} is a symlink. Write to its target explicitly if that "
            "is really what you want."
        )
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
    except OSError as e:
        return f"Error writing {path}: {e}"
    ctx.read_files.add(str(p))
    verb = "Overwrote" if existed else "Wrote"
    return f"{verb} {p} ({len(content)} chars, {content.count(chr(10)) + 1} lines)."


def _apply_edit(p: Path, old: str, new: str, replace_all: bool) -> str:
    text = p.read_text(encoding="utf-8", errors="replace")
    count = text.count(old)
    if count == 0:
        return (
            f"Error: old_string not found in {p}. "
            "Read the file to get its exact contents (check whitespace and indentation)."
        )
    if count > 1 and not replace_all:
        return (
            f"Error: old_string occurs {count} times in {p}; it must be unique. "
            "Include more surrounding context, or set replace_all to true."
        )
    p.write_text(text.replace(old, new) if replace_all else text.replace(old, new, 1), encoding="utf-8")
    return f"replaced {count if replace_all else 1} occurrence(s)"


def _impl_edit_file(args: dict[str, Any], ctx: ToolContext) -> str:
    path = str(args.get("path", "")).strip()
    old = args.get("old_string", "")
    new = args.get("new_string", "")
    if not path or not isinstance(old, str) or not isinstance(new, str):
        return "Error: 'path', 'old_string' and 'new_string' are required."
    if old == new:
        return "Error: old_string and new_string are identical."
    p = ctx.resolve(path)
    if not p.is_file():
        return f"Error: file not found: {path}"
    result = _apply_edit(p, old, new, bool(args.get("replace_all")))
    if result.startswith("Error"):
        return result
    return f"Edited {p}: {result} ({len(old)} -> {len(new)} chars)."


def _impl_multi_edit(args: dict[str, Any], ctx: ToolContext) -> str:
    """Apply several edits to one file atomically (all succeed or none)."""
    path = str(args.get("path", "")).strip()
    edits = args.get("edits")
    if not path or not isinstance(edits, list) or not edits:
        return "Error: 'path' and a non-empty 'edits' list are required."
    p = ctx.resolve(path)
    if not p.is_file():
        return f"Error: file not found: {path}"
    try:
        original = p.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        return f"Error reading {path}: {e}"
    text = original
    applied = 0
    for i, edit in enumerate(edits, 1):
        if not isinstance(edit, dict):
            return f"Error: edit {i} is not an object."
        old = edit.get("old_string")
        new = edit.get("new_string")
        if not isinstance(old, str) or not isinstance(new, str):
            return f"Error: edit {i} needs string 'old_string' and 'new_string'."
        if old == new:
            return f"Error: edit {i} has identical old_string and new_string."
        count = text.count(old)
        replace_all = bool(edit.get("replace_all"))
        if count == 0:
            return f"Error: edit {i}: old_string not found in {path}. No edits were applied."
        if count > 1 and not replace_all:
            return (
                f"Error: edit {i}: old_string occurs {count} times; it must be unique. "
                "No edits were applied."
            )
        text = text.replace(old, new) if replace_all else text.replace(old, new, 1)
        applied += count if replace_all else 1
    try:
        p.write_text(text, encoding="utf-8")
    except OSError as e:
        return f"Error writing {path}: {e}"
    return f"Edited {p}: applied {len(edits)} edit(s), {applied} replacement(s)."


def _impl_bash(args: dict[str, Any], ctx: ToolContext) -> str:
    command = str(args.get("command", "")).strip()
    if not command:
        return "Error: 'command' is required."
    timeout = _as_int(args.get("timeout"), BASH_TIMEOUT) or BASH_TIMEOUT
    timeout = max(1, min(timeout, 600))
    # Output goes to temp files rather than pipes: a command that prints
    # hundreds of megabytes would otherwise be buffered entirely in memory
    # (and a full pipe buffer can deadlock the child).
    with tempfile.TemporaryFile(mode="w+b") as out_file, \
            tempfile.TemporaryFile(mode="w+b") as err_file:
        try:
            # start_new_session puts the command in its own process group so
            # the timeout can kill the whole tree; killing just the shell
            # leaves a compound command's children running.
            proc = subprocess.Popen(  # noqa: S602 - running shell commands is the point
                command,
                shell=True,
                stdout=out_file,
                stderr=err_file,
                cwd=ctx.cwd or None,
                start_new_session=True,
            )
        except OSError as e:
            return f"Error running command: {e}"
        timed_out = False
        try:
            proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill_process_group(proc)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        stdout = _read_capped(out_file)
        stderr = _read_capped(err_file)

    if timed_out:
        partial = _truncate((stdout + stderr).strip(), 4000)
        suffix = f"\nPartial output:\n{partial}" if partial else ""
        return f"Error: command timed out after {timeout}s and was terminated.{suffix}"
    out = stdout
    if stderr:
        out += ("\n[stderr]\n" if out else "[stderr]\n") + stderr
    if proc.returncode != 0:
        out += f"\n[exit code {proc.returncode}]"
    out = out.strip()
    return _truncate(out or f"(no output, exit code {proc.returncode})")


def _read_capped(handle: Any, limit: int = MAX_OUTPUT) -> str:
    """Read at most ``limit`` bytes from each end of a command's output."""
    try:
        size = handle.seek(0, os.SEEK_END)
        if size <= limit:
            handle.seek(0)
            return handle.read().decode("utf-8", errors="replace")
        head_size = limit // 2
        handle.seek(0)
        head = handle.read(head_size).decode("utf-8", errors="replace")
        handle.seek(size - (limit - head_size))
        tail = handle.read().decode("utf-8", errors="replace")
        skipped = size - limit
        return f"{head}\n... [truncated, {skipped} bytes omitted]\n{tail}"
    except OSError:
        return ""


def signal_process_group(proc: subprocess.Popen, sig: int) -> bool:
    """Send `sig` to the command's whole process group. True if delivered."""
    try:
        os.killpg(os.getpgid(proc.pid), sig)
        return True
    except (ProcessLookupError, PermissionError, OSError):
        if sig in (signal.SIGKILL, signal.SIGTERM):
            try:
                proc.kill()
                return True
            except OSError:
                return False
        return False


def _kill_process_group(proc: subprocess.Popen) -> None:
    signal_process_group(proc, signal.SIGKILL)


def _impl_glob(args: dict[str, Any], ctx: ToolContext) -> str:
    pattern = str(args.get("pattern", "")).strip()
    if not pattern:
        return "Error: 'pattern' is required."
    root = str(args.get("path") or ctx.cwd or ".")
    base = ctx.resolve(root) if root else Path(".")
    search = pattern if Path(pattern).is_absolute() else str(base / pattern)
    try:
        matches = globmod.glob(search, recursive=True)
    except (re.error, ValueError) as e:
        return f"Error: bad pattern: {e}"
    timed: list[tuple[float, str]] = []
    for m in matches:
        if any(part in IGNORE_DIRS for part in Path(m).parts):
            continue
        try:
            timed.append((Path(m).stat().st_mtime, m))
        except OSError:
            timed.append((0.0, m))
    timed.sort(reverse=True)  # newest first
    if not timed:
        return f"No files match '{pattern}'."
    out = [m for _, m in timed[:MAX_GLOB_RESULTS]]
    if len(timed) > MAX_GLOB_RESULTS:
        out.append(f"... [{len(timed) - MAX_GLOB_RESULTS} more]")
    return "\n".join(out)


def _impl_grep(args: dict[str, Any], ctx: ToolContext) -> str:
    pattern = str(args.get("pattern", ""))
    path = str(args.get("path") or ctx.cwd or ".")
    glob_filter = str(args.get("glob", "") or "")
    if not pattern:
        return "Error: 'pattern' is required."
    flags = re.IGNORECASE if args.get("ignore_case") else 0
    try:
        rx = re.compile(pattern, flags)
    except re.error as e:
        return f"Error: invalid regex: {e}"
    base = ctx.resolve(path)
    files: list[Path] = []
    if base.is_file():
        files = [base]
    elif base.is_dir():
        for p in sorted(base.rglob("*")):
            if len(files) >= 5000:
                break
            if not p.is_file():
                continue
            if any(part in IGNORE_DIRS for part in p.parts):
                continue
            if glob_filter and not (
                p.match(glob_filter) or fnmatch.fnmatch(p.name, glob_filter)
            ):
                continue
            files.append(p)
    else:
        return f"Error: path not found: {path}"
    matches: list[str] = []
    for f in files:
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        if "\0" in text[:2048]:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            if rx.search(line):
                matches.append(f"{f}:{i}:{line.strip()[:200]}")
                if len(matches) >= MAX_GREP_MATCHES:
                    return "\n".join(matches) + f"\n... [{MAX_GREP_MATCHES} match limit reached]"
    return "\n".join(matches) if matches else "No matches found."


def _impl_list_dir(args: dict[str, Any], ctx: ToolContext) -> str:
    path = str(args.get("path") or ctx.cwd or ".").strip()
    base = ctx.resolve(path)
    if not base.is_dir():
        return f"Error: not a directory: {path}"
    lines = [str(base) + "/"]
    state = {"count": 0, "truncated": False}
    max_depth = max(1, min(_as_int(args.get("depth"), 3) or 3, 6))

    def walk(d: Path, prefix: str, depth: int) -> None:
        if depth > max_depth or state["truncated"]:
            return
        try:
            entries = sorted(d.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except OSError:
            return
        entries = [e for e in entries if e.name not in IGNORE_DIRS and not e.name.startswith(".")]
        for i, e in enumerate(entries):
            if state["count"] >= MAX_LIST_ENTRIES:
                lines.append(prefix + "... [truncated]")
                state["truncated"] = True
                return
            last = i == len(entries) - 1
            connector = "└── " if last else "├── "
            suffix = "/" if e.is_dir() else ""
            lines.append(prefix + connector + e.name + suffix)
            state["count"] += 1
            if e.is_dir():
                walk(e, prefix + ("    " if last else "│   "), depth + 1)

    walk(base, "", 1)
    return "\n".join(lines)


def _impl_todo_write(args: dict[str, Any], ctx: ToolContext) -> str:
    todos = args.get("todos")
    if not isinstance(todos, list):
        return "Error: 'todos' must be a list of {content, status} objects."
    clean: list[dict[str, str]] = []
    for t in todos:
        if not isinstance(t, dict):
            continue
        content = str(t.get("content", "")).strip()
        status = str(t.get("status", "pending")).strip()
        if status not in ("pending", "in_progress", "completed"):
            status = "pending"
        if content:
            clean.append({"content": content, "status": status})
    ctx.todos = clean
    done = sum(1 for t in clean if t["status"] == "completed")
    return f"Todo list updated: {len(clean)} task(s), {done} completed."


def _impl_web_fetch(args: dict[str, Any], ctx: ToolContext) -> str:
    url = str(args.get("url", "")).strip()
    if not url:
        return "Error: 'url' is required."
    if not url.startswith(("http://", "https://")):
        url = "https://" + url
    import requests

    try:
        r = requests.get(url, timeout=20, headers={"User-Agent": USER_AGENT})
        r.raise_for_status()
    except Exception as e:  # noqa: BLE001 - surface any fetch failure to the model
        return f"Error fetching {url}: {e}"
    text = r.text
    text = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", text)
    text = re.sub(r"(?s)<!--.*?-->", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html_module.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    return _truncate(text or "(empty page)")


def _run_git(ctx: ToolContext, *git_args: str) -> str:
    try:
        proc = subprocess.run(
            ["git", *git_args],
            capture_output=True,
            text=True,
            timeout=30,
            errors="replace",
            cwd=ctx.cwd or None,
        )
    except FileNotFoundError:
        return "Error: git is not installed."
    except subprocess.TimeoutExpired:
        return "Error: git timed out."
    out = (proc.stdout or "") + (("\n" + proc.stderr) if proc.stderr else "")
    return _truncate(out.strip() or "(no output)")


def _impl_git_status(args: dict[str, Any], ctx: ToolContext) -> str:
    status = _run_git(ctx, "status", "--short", "--branch")
    if status.startswith("Error"):
        return status
    return status


def _impl_git_diff(args: dict[str, Any], ctx: ToolContext) -> str:
    path = str(args.get("path", "") or "")
    git_args = ["diff", "--stat" if args.get("stat") else "--unified=3"]
    if args.get("staged"):
        git_args.append("--staged")
    if path:
        git_args += ["--", path]
    return _run_git(ctx, *git_args)


_IMPLS: dict[str, Callable[[dict[str, Any], ToolContext], str]] = {
    "read_file": _impl_read_file,
    "write_file": _impl_write_file,
    "edit_file": _impl_edit_file,
    "multi_edit": _impl_multi_edit,
    "bash": _impl_bash,
    "glob": _impl_glob,
    "grep": _impl_grep,
    "list_dir": _impl_list_dir,
    "todo_write": _impl_todo_write,
    "web_fetch": _impl_web_fetch,
    "git_status": _impl_git_status,
    "git_diff": _impl_git_diff,
}


def execute_tool(name: str, arguments: dict[str, Any], ctx: ToolContext) -> str:
    """Run a tool by name. Never raises; errors are returned as text."""
    impl = _IMPLS.get(name)
    if impl is None:
        known = ", ".join(sorted(_IMPLS))
        return f"Error: unknown tool '{name}'. Available tools: {known}."
    if not isinstance(arguments, dict):
        return f"Error: arguments for {name} must be an object."
    try:
        return impl(arguments, ctx)
    except Exception as e:  # noqa: BLE001 - tool errors must not crash the agent
        return f"Error: {name} failed: {e}"


# ---------------------------------------------------------------------------
# schemas (Ollama /api/chat "tools" format)


def _schema(name: str, description: str, properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


TOOL_SCHEMAS: list[dict[str, Any]] = [
    _schema(
        "read_file",
        "Read a text file and return its contents with line numbers.",
        {
            "path": {"type": "string", "description": "Path to the file."},
            "offset": {"type": "integer", "description": "1-based line to start from. Optional."},
            "limit": {"type": "integer", "description": "Maximum number of lines to read. Optional."},
        },
        ["path"],
    ),
    _schema(
        "write_file",
        "Create or overwrite a file with the given content, creating parent directories.",
        {
            "path": {"type": "string", "description": "Path of the file to write."},
            "content": {"type": "string", "description": "Full content to write."},
        },
        ["path", "content"],
    ),
    _schema(
        "edit_file",
        "Replace an exact unique string in a file with a new string.",
        {
            "path": {"type": "string", "description": "Path of the file to edit."},
            "old_string": {"type": "string", "description": "Exact text to find. Must occur exactly once."},
            "new_string": {"type": "string", "description": "Replacement text."},
            "replace_all": {"type": "boolean", "description": "Replace every occurrence. Optional, default false."},
        },
        ["path", "old_string", "new_string"],
    ),
    _schema(
        "multi_edit",
        "Apply several find-and-replace edits to one file in order; all or nothing.",
        {
            "path": {"type": "string", "description": "Path of the file to edit."},
            "edits": {
                "type": "array",
                "description": "Edits applied in order.",
                "items": {
                    "type": "object",
                    "properties": {
                        "old_string": {"type": "string", "description": "Exact text to find."},
                        "new_string": {"type": "string", "description": "Replacement text."},
                        "replace_all": {"type": "boolean", "description": "Replace every occurrence."},
                    },
                    "required": ["old_string", "new_string"],
                },
            },
        },
        ["path", "edits"],
    ),
    _schema(
        "bash",
        "Run a shell command in the working directory and return its output.",
        {
            "command": {"type": "string", "description": "The shell command to run."},
            "timeout": {"type": "integer", "description": "Seconds before the command is killed. Optional, default 120."},
        },
        ["command"],
    ),
    _schema(
        "glob",
        "Find files matching a glob pattern, newest first.",
        {
            "pattern": {"type": "string", "description": "Glob pattern, e.g. '**/*.py'."},
            "path": {"type": "string", "description": "Directory to search from. Optional."},
        },
        ["pattern"],
    ),
    _schema(
        "grep",
        "Search file contents with a regex and return file:line:content matches.",
        {
            "pattern": {"type": "string", "description": "Regular expression to search for."},
            "path": {"type": "string", "description": "File or directory to search. Optional, default the working directory."},
            "glob": {"type": "string", "description": "Only search files matching this glob, e.g. '*.py'. Optional."},
            "ignore_case": {"type": "boolean", "description": "Case-insensitive search. Optional."},
        },
        ["pattern"],
    ),
    _schema(
        "list_dir",
        "List a directory as a tree, directories first.",
        {
            "path": {"type": "string", "description": "Directory to list. Optional, default the working directory."},
            "depth": {"type": "integer", "description": "How many levels deep. Optional, default 3."},
        },
        [],
    ),
    _schema(
        "todo_write",
        "Replace the current task list to plan and track multi-step work.",
        {
            "todos": {
                "type": "array",
                "description": "The complete new task list.",
                "items": {
                    "type": "object",
                    "properties": {
                        "content": {"type": "string", "description": "Task description."},
                        "status": {"type": "string", "enum": ["pending", "in_progress", "completed"]},
                    },
                    "required": ["content", "status"],
                },
            }
        },
        ["todos"],
    ),
    _schema(
        "web_fetch",
        "Fetch a URL and return its text content with HTML stripped.",
        {
            "url": {"type": "string", "description": "The URL to fetch."},
        },
        ["url"],
    ),
    _schema(
        "git_status",
        "Show the current git branch and working-tree status.",
        {},
        [],
    ),
    _schema(
        "git_diff",
        "Show the git diff of the working tree.",
        {
            "path": {"type": "string", "description": "Limit the diff to this path. Optional."},
            "staged": {"type": "boolean", "description": "Diff staged changes instead. Optional."},
            "stat": {"type": "boolean", "description": "Summarize as a diffstat. Optional."},
        },
        [],
    ),
]

TOOL_NAMES = [s["function"]["name"] for s in TOOL_SCHEMAS]
