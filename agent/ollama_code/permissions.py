"""Permission system: decides which tool calls may run and builds previews."""
from __future__ import annotations

import difflib
import json
import shlex
from typing import Any

from .tools import EDIT_TOOLS, SAFE_TOOLS

MODES = ("ask", "accept_edits", "bypass")

MODE_LABELS = {
    "ask": "ask before every write, command, or fetch",
    "accept_edits": "file edits run automatically; commands still ask",
    "bypass": "every tool runs automatically",
}


class PermissionManager:
    """Tracks what the user has allowed, for this session and permanently."""

    def __init__(
        self,
        skip_all: bool = False,
        mode: str = "ask",
        always_allow: list[str] | None = None,
        deny_commands: list[str] | None = None,
    ) -> None:
        self.mode = "bypass" if skip_all else (mode if mode in MODES else "ask")
        #: Allowed for this session only.
        self.allowed: set[str] = set()
        #: Allowed across sessions (persisted in the config file).
        self.always_allow: set[str] = set(always_allow or [])
        self.deny_commands: list[str] = list(deny_commands or [])

    @property
    def skip_all(self) -> bool:
        return self.mode == "bypass"

    def is_auto_allowed(self, tool_name: str, inside_workspace: bool = True) -> bool:
        if self.mode == "bypass":
            return True
        if tool_name in SAFE_TOOLS:
            # Reading is only automatic inside the workspace; anything outside
            # it (dotfiles, ~/.ssh, another project) still asks.
            return inside_workspace
        if tool_name in self.allowed or tool_name in self.always_allow:
            return True
        if self.mode == "accept_edits" and tool_name in EDIT_TOOLS:
            return inside_workspace
        return False

    def blocked_reason(self, tool_name: str, args: dict[str, Any]) -> str | None:
        """A hard block that no permission answer can override.

        This is a guard rail against an obviously catastrophic command, not a
        sandbox: the agent runs with the user's privileges by design. Each
        chained segment is checked so a safe prefix cannot smuggle one in.
        """
        if tool_name != "bash":
            return None
        for segment in _command_segments(str(args.get("command", ""))):
            for pattern in self.deny_commands:
                if pattern and segment.startswith(pattern.lower()):
                    return f"blocked by the deny list: commands matching '{pattern}'"
        return None

    def allow_tool(self, tool_name: str, permanent: bool = False) -> None:
        self.allowed.add(tool_name)
        if permanent:
            self.always_allow.add(tool_name)

    def set_mode(self, mode: str) -> None:
        if mode in MODES:
            self.mode = mode

    def reset(self) -> None:
        self.allowed.clear()
        self.mode = "ask"

    def state(self) -> dict[str, Any]:
        return {
            "skip_all": self.skip_all,
            "mode": self.mode,
            "allowed": sorted(self.allowed | self.always_allow),
            "always_allow": sorted(self.always_allow),
            "safe_tools": sorted(SAFE_TOOLS),
            "deny_commands": list(self.deny_commands),
        }

    def summary_lines(self) -> list[str]:
        return [
            f"mode: {self.mode} — {MODE_LABELS.get(self.mode, '')}",
            f"always-allowed this session: {', '.join(sorted(self.allowed)) or '—'}",
            f"always-allowed permanently: {', '.join(sorted(self.always_allow)) or '—'}",
            f"safe tools (never ask): {', '.join(sorted(SAFE_TOOLS))}",
            f"denied commands: {', '.join(self.deny_commands) or '—'}",
            "use '/permissions reset' to clear allowances, "
            "'/permissions mode ask|accept_edits|bypass' to change the mode",
        ]


#: Wrappers that hide the real command behind themselves.
_PREFIX_WRAPPERS = {"sudo", "doas", "env", "nohup", "time", "command", "exec", "xargs"}

#: Separators that start a new command within one shell string.
_SEPARATORS = ("&&", "||", ";", "|", "&", "\n")


def _command_segments(command: str) -> list[str]:
    """Split a shell string into normalized, unwrapped command segments."""
    text = command.replace("\r", "\n")
    for sep in _SEPARATORS:
        text = text.replace(sep, "\n")
    segments: list[str] = []
    for raw in text.split("\n"):
        words = raw.split()
        # Drop leading VAR=value assignments and wrapper programs so
        # "sudo env X=1 rm -rf /" still reads as "rm -rf /".
        while words:
            first = words[0]
            if first in _PREFIX_WRAPPERS:
                words = words[1:]
                continue
            name = first.split("=", 1)[0]
            if "=" in first and not first.startswith("-") and "/" not in name:
                words = words[1:]
                continue
            break
        if not words:
            continue
        # Compare on the program's basename so /bin/rm matches "rm".
        words = [words[0].split("/")[-1], *words[1:]]
        segments.append(" ".join(words).lower())
    return segments


def _shorten(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + f"… (+{len(text) - limit} chars)"


def build_preview(name: str, args: dict[str, Any]) -> tuple[str, str]:
    """Return (summary, detail) describing a pending tool call.

    ``summary`` is a one-liner shown in the compact log line and as the
    permission panel title; ``detail`` is the body shown when asking, and is
    rendered as a diff by the GUI when it looks like one.
    """
    if name == "bash":
        command = str(args.get("command", ""))
        try:
            program = shlex.split(command)[0] if command.strip() else ""
        except ValueError:
            program = command.split()[0] if command.split() else ""
        label = f"$ {_shorten(command, 90)}"
        detail = command
        if program:
            detail = f"{command}\n\n[runs: {program}]"
        return label, detail
    if name == "write_file":
        path = str(args.get("path", ""))
        content = args.get("content", "")
        if not isinstance(content, str):
            content = json.dumps(content, indent=2, ensure_ascii=False)
        lines = content.splitlines()
        head = "\n".join(f"+{line}" for line in lines[:30])
        if len(lines) > 30:
            head += f"\n... ({len(lines) - 30} more lines)"
        return f"write {path} ({len(lines)} lines)", head or "(empty file)"
    if name == "edit_file":
        path = str(args.get("path", ""))
        old = str(args.get("old_string", ""))
        new = str(args.get("new_string", ""))
        diff = "\n".join(
            difflib.unified_diff(
                old.splitlines(), new.splitlines(),
                fromfile=f"a/{path}", tofile=f"b/{path}", lineterm="", n=2,
            )
        )
        # replace_all changes how many places this rewrites, so it belongs in
        # the summary the user approves — not just in the arguments.
        scope = " (every occurrence)" if args.get("replace_all") else ""
        return f"edit {path}{scope}", diff or "(no visible change)"
    if name == "multi_edit":
        path = str(args.get("path", ""))
        edits = args.get("edits")
        count = len(edits) if isinstance(edits, list) else 0
        chunks: list[str] = []
        if isinstance(edits, list):
            for i, edit in enumerate(edits[:5], 1):
                if not isinstance(edit, dict):
                    continue
                old = str(edit.get("old_string", ""))
                new = str(edit.get("new_string", ""))
                scope = " (every occurrence)" if edit.get("replace_all") else ""
                chunks.append(
                    f"--- edit {i}{scope} ---\n"
                    + "\n".join(
                        difflib.unified_diff(
                            old.splitlines(), new.splitlines(),
                            fromfile="before", tofile="after", lineterm="", n=1,
                        )
                    )
                )
            if count > 5:
                chunks.append(f"... ({count - 5} more edits)")
        return f"edit {path} ({count} changes)", "\n".join(chunks) or "(no visible change)"
    if name == "read_file":
        path = str(args.get("path", ""))
        extra = ""
        if args.get("offset"):
            extra += f" from line {args['offset']}"
        if args.get("limit"):
            extra += f" ({args['limit']} lines)"
        return f"read {path}{extra}", ""
    if name == "glob":
        return f"glob {args.get('pattern', '')}", ""
    if name == "grep":
        pat = str(args.get("pattern", ""))
        path = str(args.get("path", ".") or ".")
        glob_f = str(args.get("glob", "") or "")
        suffix = f" matching {glob_f}" if glob_f else ""
        return f"grep /{pat}/ in {path}{suffix}", ""
    if name == "list_dir":
        return f"ls {args.get('path', '.') or '.'}", ""
    if name == "todo_write":
        todos = args.get("todos")
        n = len(todos) if isinstance(todos, list) else 0
        detail = ""
        if isinstance(todos, list):
            detail = "\n".join(
                f"[{t.get('status', '?')}] {t.get('content', '')}"
                for t in todos if isinstance(t, dict)
            )
        return f"update task list ({n} tasks)", detail
    if name == "web_fetch":
        url = str(args.get("url", ""))
        return f"fetch {url}", url
    if name == "git_status":
        return "git status", ""
    if name == "git_diff":
        path = str(args.get("path", "") or "")
        return f"git diff{' ' + path if path else ''}", ""
    return (
        f"{name} {json.dumps(args, ensure_ascii=False, default=str)[:120]}",
        json.dumps(args, indent=2, ensure_ascii=False, default=str)[:2000],
    )
