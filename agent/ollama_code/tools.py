"""Tool implementations and Ollama tool schemas.

Schemas are deliberately flat with one-sentence descriptions so that small
local models (8B-class) can follow them reliably.
"""
from __future__ import annotations

import fcntl
import fnmatch
import glob as globmod
import html as html_module
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import tempfile
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import USER_AGENT, proxy

MAX_OUTPUT = 30_000
MAX_WEB_FETCH_BYTES = 2 * 1024 * 1024
MAX_TEXT_FILE_BYTES = 8 * 1024 * 1024
MAX_LIST_ENTRIES = 300
MAX_DIRECTORY_SCAN = 5_000
MAX_GREP_MATCHES = 200
MAX_GLOB_RESULTS = 200
MAX_GLOB_SCAN = 5_000
BASH_TIMEOUT = 120

IGNORE_DIRS = {
    ".git", ".hg", ".svn", ".venv", "venv", "env", "node_modules",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    "dist", "build", ".idea", ".tox", ".next", "target",
}

#: Read-only tools that never require permission.
SAFE_TOOLS = {
    "read_file", "glob", "grep", "list_dir", "todo_write", "submit_plan",
    "search_workspace_knowledge", "search_memory", "propose_memory",
    "record_skill_observation", "capture_context_snapshot",
    "computer_list_apps", "computer_get_state",
    # Reading a page never prompts. Note this is a deliberate departure from
    # `web_fetch`, which is not here: these are the first never-ask tools that
    # pull remote, attacker-controlled text into a context that also holds
    # `bash`, so every result is wrapped as untrusted evidence.
    #
    # `browser_tabs` is here despite being able to open and close one: its
    # reach is the calling session's own tabs, a new tab is blank, and going
    # anywhere with it needs `browser_navigate`, which is not safe-listed.
    "browser_read_page", "browser_get_text", "browser_find", "browser_screenshot",
    "browser_wait_for", "browser_console", "browser_network", "browser_tabs",
}

#: Tools that modify files — auto-allowed in the "accept_edits" mode.
#: `apply_patch` is the Codex-parity edit tool; it changes files and nothing
#: else, so it belongs to the same permission class as the native editors.
EDIT_TOOLS = {"write_file", "edit_file", "multi_edit", "apply_patch"}


@dataclass
class ToolContext:
    """Mutable per-session state shared with tools."""

    todos: list[dict[str, str]] = field(default_factory=list)
    plan_document: dict[str, Any] | None = None
    cwd: str = ""
    #: Files read this turn, so edit_file can warn about blind edits.
    read_files: set[str] = field(default_factory=set)
    #: Cooperative cancellation supplied by the agent turn.
    should_stop: Callable[[], bool] | None = None
    memory_workspace: str = ""
    memory_agent_id: str = "primary"
    memory_scopes: tuple[str, ...] = ("personal", "workspace", "agent")
    memory_search_enabled: bool = True
    memory_proposals_enabled: bool = True
    memory_session_id: str = ""
    memory_run_id: str = ""
    cross_chat_context_enabled: bool = True
    #: App-owned process broker. Work submitted here is detached from the
    #: current turn and therefore survives Stop.
    background_service: Callable[[dict[str, Any]], str] | None = None
    #: Per-turn adaptive Solo executor. It is installed only for eligible Solo
    #: turns and removed before the turn identity is released.
    delegate_read_only: Callable[[dict[str, Any]], str] | None = None

    def stopped(self) -> bool:
        return bool(self.should_stop and self.should_stop())

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

    def symlink_component(self, path: Path) -> Path | None:
        """First hidden symlink below the workspace, or a linked target."""
        if path.is_symlink():
            return path
        if not self.cwd:
            return None
        lexical_root = Path(os.path.abspath(self.cwd))
        resolved_root = lexical_root.resolve()
        absolute = Path(os.path.abspath(path))
        try:
            relative = absolute.relative_to(lexical_root)
        except ValueError:
            try:
                relative = absolute.relative_to(resolved_root)
            except ValueError:
                return None
        current = resolved_root
        for part in relative.parts:
            current /= part
            try:
                if current.is_symlink():
                    return current
            except OSError:
                return current
        return None


def _truncate(text: str, limit: int = MAX_OUTPUT) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n... [truncated, {len(text) - limit} more chars]"


def truncate_output(text: str, limit: int = MAX_OUTPUT) -> str:
    """The same bound the built-in tools apply, for callers outside this module.

    Native brokers hand back a string that no other layer trims, and a session
    record above ``MAX_SESSION_LINE_BYTES`` is written and then skipped on read
    — so an unbounded page dump silently loses the turn it belonged to.
    """
    return _truncate(text, limit)


def _as_int(value: Any, default: int = 0) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


def _atomic_write_text(
    path: Path,
    content: str,
    workspace_root: Path | None = None,
) -> None:
    """Replace a text file atomically without following the final directory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    directory_flags = os.O_RDONLY
    directory_flags |= getattr(os, "O_DIRECTORY", 0)
    directory_flags |= getattr(os, "O_NOFOLLOW", 0)
    directory_fd = os.open(path.parent, directory_flags)
    temporary_name = f".{path.name}.{secrets.token_hex(8)}.tmp"
    try:
        if workspace_root is not None:
            opened_parent = _directory_path(directory_fd)
            root = workspace_root.resolve()
            if opened_parent is None or (
                opened_parent != root and root not in opened_parent.parents
            ):
                raise OSError("the destination directory moved outside the workspace")
        temporary_fd = os.open(
            temporary_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=directory_fd,
        )
        with os.fdopen(temporary_fd, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        try:
            current = os.stat(path.name, dir_fd=directory_fd, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None:
            if stat.S_ISLNK(current.st_mode):
                raise OSError("the destination became a symlink")
            os.chmod(
                temporary_name,
                stat.S_IMODE(current.st_mode),
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        else:
            os.chmod(
                temporary_name,
                0o644,
                dir_fd=directory_fd,
                follow_symlinks=False,
            )
        os.replace(
            temporary_name,
            path.name,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
        )
        os.fsync(directory_fd)
        temporary_name = ""
    finally:
        if temporary_name:
            try:
                os.unlink(temporary_name, dir_fd=directory_fd)
            except OSError:
                pass
        os.close(directory_fd)


def _directory_path(directory_fd: int) -> Path | None:
    """Resolve an open directory descriptor for a post-open containment check."""
    try:
        raw = fcntl.fcntl(directory_fd, 50, b"\0" * 1024)
        path = Path(raw.split(b"\0", 1)[0].decode())
        if path.is_dir():
            return path.resolve()
    except (OSError, UnicodeDecodeError):
        pass
    for prefix in ("/dev/fd", "/proc/self/fd"):
        try:
            descriptor_path = f"{prefix}/{directory_fd}"
            resolved = Path(os.path.realpath(descriptor_path))
            if str(resolved) != descriptor_path and resolved.is_dir():
                return resolved
        except OSError:
            continue
    return None


def _workspace_write_root(ctx: ToolContext, path: Path) -> Path | None:
    if not ctx.cwd:
        return None
    lexical_root = Path(os.path.abspath(ctx.cwd))
    try:
        Path(os.path.abspath(path)).relative_to(lexical_root)
    except ValueError:
        return None
    return lexical_root.resolve()


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
    if not p.is_file():
        return f"Error: {path} is not a regular file."
    try:
        size = p.stat().st_size
        if size > MAX_TEXT_FILE_BYTES:
            return (
                f"Error: {path} is larger than the "
                f"{MAX_TEXT_FILE_BYTES // (1024 * 1024)} MB text-read limit."
            )
        with p.open("rb") as handle:
            raw = handle.read(MAX_TEXT_FILE_BYTES + 1)
        if len(raw) > MAX_TEXT_FILE_BYTES:
            return (
                f"Error: {path} grew beyond the "
                f"{MAX_TEXT_FILE_BYTES // (1024 * 1024)} MB text-read limit."
            )
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
    if link := ctx.symlink_component(p):
        return (
            f"Error: {path} crosses symlink {link}. Write to the resolved target "
            "explicitly if that is really what you want."
        )
    try:
        _atomic_write_text(p, content, _workspace_write_root(ctx, p))
    except OSError as e:
        return f"Error writing {path}: {e}"
    ctx.read_files.add(str(p))
    verb = "Overwrote" if existed else "Wrote"
    return f"{verb} {p} ({len(content)} chars, {content.count(chr(10)) + 1} lines)."


def _apply_edit(
    p: Path,
    old: str,
    new: str,
    replace_all: bool,
    workspace_root: Path | None = None,
) -> str:
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
    _atomic_write_text(
        p,
        text.replace(old, new) if replace_all else text.replace(old, new, 1),
        workspace_root,
    )
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
    if link := ctx.symlink_component(p):
        return (
            f"Error: {path} crosses symlink {link}. Edit the resolved target "
            "explicitly if that is really what you want."
        )
    if not p.is_file():
        return f"Error: file not found: {path}"
    result = _apply_edit(
        p,
        old,
        new,
        bool(args.get("replace_all")),
        _workspace_write_root(ctx, p),
    )
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
    if link := ctx.symlink_component(p):
        return (
            f"Error: {path} crosses symlink {link}. Edit the resolved target "
            "explicitly if that is really what you want."
        )
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
        _atomic_write_text(p, text, _workspace_write_root(ctx, p))
    except OSError as e:
        return f"Error writing {path}: {e}"
    return f"Edited {p}: applied {len(edits)} edit(s), {applied} replacement(s)."


def _impl_apply_patch(args: dict[str, Any], ctx: ToolContext) -> str:
    """Apply one Codex ``*** Begin Patch`` envelope. Parity-suite edit tool."""
    from . import codex_patch

    text = str(args.get("input") or args.get("patch") or "")
    if not text.strip():
        return "Error: 'input' must contain a *** Begin Patch envelope."
    try:
        return codex_patch.apply_patch(text, ctx)
    except codex_patch.PatchError as error:
        return f"Error: {error}"
    except OSError as error:
        return f"Error applying patch: {error}"


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
                # Never this process's stdin: that is the pipe the app hands
                # the proxy credential over. It is consumed and at EOF long
                # before any tool runs, but a model-authored command has no
                # business reading the agent's input either way.
                stdin=subprocess.DEVNULL,
                cwd=ctx.cwd or None,
                start_new_session=True,
                # Model-authored commands must not see the proxy credential
                # folded into this process's proxy URLs at startup.
                env=proxy.sanitized_child_environment(),
            )
        except OSError as e:
            return f"Error running command: {e}"
        stop_reason = _wait_interruptibly(proc, timeout, ctx)
        stdout = _read_capped(out_file)
        stderr = _read_capped(err_file)

    if stop_reason:
        partial = _truncate((stdout + stderr).strip(), 4000)
        suffix = f"\nPartial output:\n{partial}" if partial else ""
        if stop_reason == "interrupted":
            return f"Error: command interrupted and terminated.{suffix}"
        return f"Error: command timed out after {timeout}s and was terminated.{suffix}"
    out = stdout
    if stderr:
        out += ("\n[stderr]\n" if out else "[stderr]\n") + stderr
    if proc.returncode != 0:
        out += f"\n[exit code {proc.returncode}]"
    out = out.strip()
    return _truncate(out or f"(no output, exit code {proc.returncode})")


def _impl_background_service(args: dict[str, Any], ctx: ToolContext) -> str:
    if ctx.background_service is None:
        return "Error: managed background services are unavailable in this client."
    return ctx.background_service(args)


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


def _wait_interruptibly(
    proc: subprocess.Popen,
    timeout: int,
    ctx: ToolContext,
) -> str | None:
    """Wait for a child while honoring Stop; return its forced-stop reason."""
    deadline = time.monotonic() + timeout
    while proc.poll() is None:
        reason = None
        if ctx.stopped():
            reason = "interrupted"
        elif time.monotonic() >= deadline:
            reason = "timeout"
        if reason:
            _kill_process_group(proc)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            return reason
        time.sleep(0.05)
    return None


def _impl_glob(args: dict[str, Any], ctx: ToolContext) -> str:
    pattern = str(args.get("pattern", "")).strip()
    if not pattern:
        return "Error: 'pattern' is required."
    root = str(args.get("path") or ctx.cwd or ".")
    base = ctx.resolve(root) if root else Path(".")
    search = pattern if Path(pattern).is_absolute() else str(base / pattern)
    timed: list[tuple[float, str]] = []
    try:
        for scanned, m in enumerate(globmod.iglob(search, recursive=True), 1):
            if ctx.stopped():
                return "Error: glob interrupted."
            if scanned > MAX_GLOB_SCAN:
                break
            if any(part in IGNORE_DIRS for part in Path(m).parts):
                continue
            if ctx.symlink_component(Path(m)) is not None:
                continue
            try:
                timed.append((Path(m).stat().st_mtime, m))
            except OSError:
                timed.append((0.0, m))
    except (re.error, ValueError) as e:
        return f"Error: bad pattern: {e}"
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
        for root, directories, names in os.walk(base, followlinks=False):
            if ctx.stopped():
                return "Error: grep interrupted."
            directories[:] = sorted(
                name
                for name in directories
                if name not in IGNORE_DIRS
                and not name.startswith(".")
                and not (Path(root) / name).is_symlink()
            )
            for name in sorted(names):
                p = Path(root) / name
                if name.startswith(".") or p.is_symlink() or not p.is_file():
                    continue
                if glob_filter and not (
                    p.match(glob_filter) or fnmatch.fnmatch(p.name, glob_filter)
                ):
                    continue
                files.append(p)
                if len(files) >= MAX_DIRECTORY_SCAN:
                    break
            if len(files) >= MAX_DIRECTORY_SCAN:
                break
    else:
        return f"Error: path not found: {path}"
    matches: list[str] = []
    for f in files:
        try:
            if f.stat().st_size > MAX_TEXT_FILE_BYTES:
                continue
            with f.open("rb") as handle:
                raw = handle.read(MAX_TEXT_FILE_BYTES + 1)
            if len(raw) > MAX_TEXT_FILE_BYTES:
                continue
            text = raw.decode("utf-8", errors="replace")
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
    state = {"count": 0, "scanned": 0, "truncated": False}
    max_depth = max(1, min(_as_int(args.get("depth"), 3) or 3, 6))

    def walk(d: Path, prefix: str, depth: int) -> None:
        if depth > max_depth or state["truncated"]:
            return
        try:
            entries: list[Path] = []
            for entry in d.iterdir():
                if ctx.stopped():
                    state["truncated"] = True
                    return
                state["scanned"] += 1
                if state["scanned"] > MAX_DIRECTORY_SCAN:
                    state["truncated"] = True
                    break
                if entry.name in IGNORE_DIRS or entry.name.startswith("."):
                    continue
                entries.append(entry)
                if len(entries) > MAX_LIST_ENTRIES - state["count"]:
                    state["truncated"] = True
                    break
            entries.sort(key=lambda p: (not p.is_dir(), p.name.lower()))
        except OSError:
            return
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
            if e.is_dir() and not e.is_symlink():
                walk(e, prefix + ("    " if last else "│   "), depth + 1)

    walk(base, "", 1)
    if ctx.stopped():
        return "Error: directory listing interrupted."
    if state["truncated"] and not lines[-1].endswith("[truncated]"):
        lines.append("... [truncated]")
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

    watcher_done = threading.Event()
    watcher: threading.Thread | None = None
    try:
        with requests.get(
            url,
            timeout=(10, 20),
            headers={"User-Agent": USER_AGENT},
            stream=True,
            allow_redirects=False,
        ) as response:
            if ctx.should_stop is not None:
                watcher = threading.Thread(
                    target=_close_response_when_stopped,
                    args=(response, ctx.should_stop, watcher_done),
                    daemon=True,
                )
                watcher.start()
            if 300 <= response.status_code < 400:
                return (
                    "Error fetching the approved URL: it redirects elsewhere. "
                    "Fetch the final URL explicitly."
                )
            response.raise_for_status()
            raw = bytearray()
            for chunk in response.iter_content(chunk_size=64 * 1024):
                if ctx.stopped():
                    return "Error: web fetch interrupted."
                if not chunk:
                    continue
                if len(raw) + len(chunk) > MAX_WEB_FETCH_BYTES:
                    return (
                        "Error fetching the approved URL: response exceeds the "
                        f"{MAX_WEB_FETCH_BYTES // (1024 * 1024)} MB safety limit."
                    )
                raw.extend(chunk)
            if ctx.stopped():
                return "Error: web fetch interrupted."
            text = raw.decode(response.encoding or "utf-8", errors="replace")
    except Exception as e:  # noqa: BLE001 - surface any fetch failure to the model
        if ctx.stopped():
            return "Error: web fetch interrupted."
        # Redacted because requests names the proxy URL — credential included —
        # in InvalidURL and connection errors, and this string goes to the model.
        return proxy.redact(f"Error fetching {url}: {e}")
    finally:
        watcher_done.set()
        if watcher is not None:
            watcher.join(timeout=0.2)
    text = re.sub(r"(?is)<(script|style|noscript)[^>]*>.*?</\1>", " ", text)
    text = re.sub(r"(?s)<!--.*?-->", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html_module.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n+", "\n\n", text).strip()
    return _truncate(text or "(empty page)")


def _run_git(ctx: ToolContext, *git_args: str) -> str:
    with tempfile.TemporaryFile(mode="w+b") as out_file, \
            tempfile.TemporaryFile(mode="w+b") as err_file:
        try:
            proc = subprocess.Popen(
                ["git", *git_args],
                stdout=out_file,
                stderr=err_file,
                # As above: git never needs this process's stdin, and that is
                # where the proxy credential arrives.
                stdin=subprocess.DEVNULL,
                cwd=ctx.cwd or None,
                start_new_session=True,
                # git may reach the network (and run hooks); like the bash
                # tool, it gets the proxy URLs without the credential.
                env=proxy.sanitized_child_environment(),
            )
        except FileNotFoundError:
            return "Error: git is not installed."
        except OSError as e:
            return f"Error running git: {e}"
        stop_reason = _wait_interruptibly(proc, 30, ctx)
        stdout = _read_capped(out_file)
        stderr = _read_capped(err_file)
    if stop_reason == "interrupted":
        return "Error: git interrupted."
    if stop_reason == "timeout":
        return "Error: git timed out."
    out = stdout + (("\n" + stderr) if stderr else "")
    return _truncate(out.strip() or "(no output)")


def _close_response_when_stopped(
    response: Any,
    should_stop: Callable[[], bool],
    done: threading.Event,
) -> None:
    while not done.wait(0.05):
        if should_stop():
            response.close()
            return


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


def _impl_submit_plan(args: dict[str, Any], ctx: ToolContext) -> str:
    title = str(args.get("title") or "Implementation plan").strip()[:160]
    summary = str(args.get("summary") or "").strip()[:4_000]
    raw_steps = args.get("steps")
    raw_tests = args.get("tests")
    if not isinstance(raw_steps, list):
        return "Error: 'steps' must be an array."
    steps = [str(item).strip()[:1_000] for item in raw_steps if str(item).strip()][:100]
    tests = (
        [str(item).strip()[:1_000] for item in raw_tests if str(item).strip()][:100]
        if isinstance(raw_tests, list) else []
    )
    if not steps:
        return "Error: submit_plan requires at least one non-empty step."
    plan_id = secrets.token_hex(8)
    ctx.plan_document = {
        "id": plan_id,
        "title": title or "Implementation plan",
        "summary": summary,
        "steps": steps,
        "tests": tests,
    }
    ctx.todos = [{"content": step, "status": "pending"} for step in steps]
    return f"Plan submitted for approval ({len(steps)} steps)."


def _impl_search_workspace_knowledge(args: dict[str, Any], ctx: ToolContext) -> str:
    query = str(args.get("query") or "").strip()
    if not query:
        return "Error: 'query' is required."
    if not ctx.cwd:
        return "Error: workspace knowledge requires an active workspace."
    if ctx.stopped():
        return "Error: workspace knowledge search interrupted."
    from .knowledge import KnowledgeError, KnowledgeStore, format_search_results

    try:
        store = KnowledgeStore(ctx.cwd)
        results = store.search(query, limit=max(1, min(_as_int(args.get("limit"), 8), 20)))
    except KnowledgeError as exc:
        return f"Error: {exc}"
    if ctx.stopped():
        return "Error: workspace knowledge search interrupted."
    return format_search_results(results)


def _impl_search_memory(args: dict[str, Any], ctx: ToolContext) -> str:
    if not ctx.memory_search_enabled:
        return "Error: memory search is disabled for this agent."
    query = str(args.get("query") or "").strip()
    if not query:
        return "Error: 'query' is required."
    requested = args.get("scopes")
    requested = requested if isinstance(requested, list) else list(ctx.memory_scopes)
    scopes = [str(scope) for scope in requested if str(scope) in ctx.memory_scopes]
    from .memory import MemoryError, MemoryVault, format_memory_results

    try:
        embedding_model = ""
        ollama_host = "http://127.0.0.1:11434"
        try:
            from .knowledge import KnowledgeStore
            knowledge = KnowledgeStore(ctx.memory_workspace or ctx.cwd).settings()
            embedding_model = str(knowledge.get("embedding_model") or "")
            ollama_host = str(knowledge.get("ollama_host") or ollama_host)
        except Exception:
            pass
        results = MemoryVault().search(
            query,
            workspace=ctx.memory_workspace or ctx.cwd,
            agent_id=ctx.memory_agent_id,
            scopes=scopes,
            limit=max(1, min(_as_int(args.get("limit"), 8), 20)),
            embedding_model=embedding_model,
            ollama_host=ollama_host,
        )
    except MemoryError as exc:
        return f"Error: {exc}"
    return format_memory_results(results)


def _impl_propose_memory(args: dict[str, Any], ctx: ToolContext) -> str:
    from .memory import MemoryError, MemoryVault

    vault = MemoryVault()
    event_context = {
        "workspace": ctx.memory_workspace or ctx.cwd,
        "agent_id": ctx.memory_agent_id,
        "session_id": ctx.memory_session_id,
        "run_id": ctx.memory_run_id,
    }
    vault.record_event(
        "policy", "evaluated",
        reason_code="enabled" if ctx.memory_proposals_enabled else "disabled",
        **event_context,
    )
    if not ctx.memory_proposals_enabled:
        vault.record_event("proposal", "rejected", reason_code="policy_disabled", **event_context)
        return "Error: memory suggestions are disabled for this agent."
    content = str(args.get("content") or "").strip()
    if not content:
        vault.record_event("proposal", "rejected", reason_code="empty_content", **event_context)
        return "Error: 'content' is required."
    scope = str(args.get("scope") or "workspace")
    if scope not in ctx.memory_scopes:
        vault.record_event("proposal", "rejected", reason_code="scope_disabled", **event_context)
        return "Error: that memory scope is disabled for this agent."

    try:
        candidate = vault.save(
            {
                "title": str(args.get("title") or "Suggested memory"),
                "content": content,
                "tags": args.get("tags") if isinstance(args.get("tags"), list) else [],
                "reason": str(args.get("reason") or ""),
                "scope": scope,
                "status": "candidate",
                "kind": str(args.get("kind") or "fact"),
                "confidence": args.get("confidence", 1.0),
                "valid_until": args.get("valid_until"),
                "source_session_id": ctx.memory_session_id or None,
                "source_run_id": ctx.memory_run_id or None,
            },
            workspace=ctx.memory_workspace or ctx.cwd,
            agent_id=ctx.memory_agent_id,
            default_status="candidate",
        )
    except MemoryError as exc:
        vault.record_event("proposal", "rejected", reason_code="validation_error", **event_context)
        return f"Error: {exc}"
    vault.record_event(
        "proposal", "accepted", memory_id=candidate["id"], **event_context
    )
    vault.record_event(
        "candidate", "created", memory_id=candidate["id"], **event_context
    )
    return (
        f"Memory suggestion {candidate['id']} was added to the Memory Inbox. "
        "It will not affect future answers unless the user approves it."
    )


def _impl_record_skill_observation(args: dict[str, Any], ctx: ToolContext) -> str:
    """Store evidence-backed observer notes outside the user's repository."""
    from .continuity import ContinuityError, ContinuityStore

    payload = {
        **args,
        "source_session_id": ctx.memory_session_id,
        "source_run_id": ctx.memory_run_id,
    }
    try:
        item = ContinuityStore().record_observation(
            ctx.memory_workspace or ctx.cwd, payload
        )
    except ContinuityError as exc:
        return f"Error: {exc}"
    if item.get("checkpoint_only"):
        return "Skill-observation checkpoint recorded; no repository file was created."
    return (
        f"Skill observation #{item['number']} recorded for user review. "
        "No skill was changed automatically."
    )


def _impl_capture_context_snapshot(args: dict[str, Any], ctx: ToolContext) -> str:
    """Explicitly replace this session's encrypted workspace handoff."""
    if not ctx.cross_chat_context_enabled:
        return "Error: cross-chat context is disabled for this agent."
    from .continuity import ContinuityError, ContinuityStore, workspace_changed_files

    pending = str(args.get("pending") or "").strip()
    if not pending:
        pending = "; ".join(
            str(item.get("content") or "")
            for item in ctx.todos
            if item.get("status") != "completed" and item.get("content")
        )
    try:
        snapshot = ContinuityStore().save_snapshot(
            ctx.memory_workspace or ctx.cwd,
            ctx.memory_session_id,
            {
                "goal": args.get("goal"),
                "outcome": args.get("outcome"),
                "mode": args.get("mode") or "work",
                "plan": ctx.plan_document,
                "todos": ctx.todos,
                "changed_files": workspace_changed_files(ctx.memory_workspace or ctx.cwd),
                "pending": pending,
            },
            pinned=bool(args.get("pinned")),
        )
    except ContinuityError as exc:
        return f"Error: {exc}"
    return f"Encrypted context handoff saved for session {snapshot['session_id']}."


def _impl_delegate_read_only(args: dict[str, Any], ctx: ToolContext) -> str:
    if ctx.delegate_read_only is None:
        return "Error: Solo delegation is not active for this turn."
    return ctx.delegate_read_only(args)


_IMPLS: dict[str, Callable[[dict[str, Any], ToolContext], str]] = {
    "read_file": _impl_read_file,
    "write_file": _impl_write_file,
    "edit_file": _impl_edit_file,
    "multi_edit": _impl_multi_edit,
    "apply_patch": _impl_apply_patch,
    "bash": _impl_bash,
    "background_service": _impl_background_service,
    "glob": _impl_glob,
    "grep": _impl_grep,
    "list_dir": _impl_list_dir,
    "todo_write": _impl_todo_write,
    "web_fetch": _impl_web_fetch,
    "git_status": _impl_git_status,
    "git_diff": _impl_git_diff,
    "submit_plan": _impl_submit_plan,
    "search_workspace_knowledge": _impl_search_workspace_knowledge,
    "search_memory": _impl_search_memory,
    "propose_memory": _impl_propose_memory,
    "record_skill_observation": _impl_record_skill_observation,
    "capture_context_snapshot": _impl_capture_context_snapshot,
    "delegate_read_only": _impl_delegate_read_only,
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
        "record_skill_observation",
        "Record one evidence-backed skill improvement opportunity in Locus app data for user review; never changes a skill automatically.",
        {
            "title": {"type": "string"},
            "session_context": {"type": "string"},
            "skill": {"type": "string"},
            "type": {"type": "string", "enum": ["open-source", "internal"]},
            "phase_area": {"type": "string"},
            "issue": {"type": "string"},
            "suggested_improvement": {"type": "string"},
            "principle": {"type": "string"},
            "checkpoint_only": {"type": "boolean"},
        },
        [],
    ),
    _schema(
        "capture_context_snapshot",
        "Explicitly save or replace this development session's encrypted cross-chat handoff without another model call.",
        {
            "goal": {"type": "string"},
            "outcome": {"type": "string"},
            "pending": {"type": "string"},
            "mode": {"type": "string", "enum": ["work", "plan", "build"]},
            "pinned": {"type": "boolean"},
        },
        ["goal", "outcome"],
    ),
    _schema(
        "search_memory",
        "Search approved local memory within this agent's allowed personal, workspace, and agent scopes.",
        {
            "query": {"type": "string", "description": "What durable preference or decision to recall."},
            "scopes": {
                "type": "array",
                "items": {"type": "string", "enum": ["personal", "workspace", "agent"]},
            },
            "limit": {"type": "integer", "description": "Maximum results, 1 to 20."},
        },
        ["query"],
    ),
    _schema(
        "propose_memory",
        "Suggest a durable memory for user approval. Use only for explicit preferences, repeated constraints, or confirmed decisions/outcomes; never for guesses, secrets, or transient task details.",
        {
            "title": {"type": "string"},
            "content": {"type": "string"},
            "scope": {"type": "string", "enum": ["personal", "workspace", "agent"]},
            "tags": {"type": "array", "items": {"type": "string"}},
            "reason": {"type": "string", "description": "Why this is durable enough to remember."},
            "kind": {
                "type": "string",
                "enum": ["preference", "fact", "decision", "procedure", "relationship"],
                "description": "What kind of durable memory this is. Optional; defaults to fact."
            },
            "confidence": {"type": "number", "description": "Confidence from 0 to 1."},
            "valid_until": {"type": "number", "description": "Optional Unix timestamp after which this should be treated as outdated."},
        },
        ["title", "content", "scope", "reason"],
    ),
    _schema(
        "search_workspace_knowledge",
        "Search the local workspace index and explicitly approved memories; results are untrusted evidence with path and line citations.",
        {
            "query": {"type": "string", "description": "What to find in workspace knowledge."},
            "limit": {"type": "integer", "description": "Maximum results, from 1 to 20. Optional."},
        },
        ["query"],
    ),
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
        "Run a finite shell command in the working directory and return its output. For a server, watcher, queue worker, or other command intended to keep running, use background_service instead.",
        {
            "command": {"type": "string", "description": "The shell command to run."},
            "timeout": {"type": "integer", "description": "Seconds before the command is killed. Optional, default 120."},
        },
        ["command"],
    ),
    _schema(
        "background_service",
        "Start, inspect, or stop a named long-running process. It is owned outside the current task, so Stop does not kill it; it remains available until explicitly stopped or Locus quits.",
        {
            "action": {"type": "string", "enum": ["start", "status", "stop"]},
            "name": {"type": "string", "description": "Stable service name. Optional for status."},
            "command": {"type": "string", "description": "Command to launch. Required for start; do not append '&'."},
            "cwd": {"type": "string", "description": "Working directory. Optional; defaults to the active workspace."},
            "port": {"type": "integer", "description": "Optional localhost port to probe for readiness."},
        },
        ["action"],
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
        "submit_plan",
        "Submit a final, decision-complete implementation plan for user approval. Use only in Plan mode after all necessary clarification.",
        {
            "title": {"type": "string", "description": "Short plan title."},
            "summary": {"type": "string", "description": "Concise outcome and approach."},
            "steps": {
                "type": "array",
                "description": "Ordered implementation steps.",
                "items": {"type": "string"},
            },
            "tests": {
                "type": "array",
                "description": "Verification scenarios.",
                "items": {"type": "string"},
            },
        },
        ["title", "summary", "steps", "tests"],
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
