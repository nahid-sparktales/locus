"""Permission system: decides which tool calls may run and builds previews."""
from __future__ import annotations

import difflib
import json
import re
import shlex
import threading
from pathlib import Path
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
        self._guard = threading.RLock()

    @property
    def skip_all(self) -> bool:
        return self.mode == "bypass"

    def is_auto_allowed(self, tool_name: str, inside_workspace: bool = True) -> bool:
        with self._guard:
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
        if tool_name.startswith("computer_"):
            text = json.dumps(args, ensure_ascii=False).lower()
            takeover = (
                "password", "passcode", "credential", "security interstitial",
                "sign contract", "accept contract", "final transaction",
                "confirm purchase", "place order", "wire transfer",
            )
            if any(term in text for term in takeover):
                return "user takeover is required for credentials, contracts, security interstitials, and final financial transactions"
            return None
        if tool_name in {"browser_dev_server", "background_service"}:
            # A shell command by another name gets the shell command's checks.
            # Handled here rather than in the module-level browser helpers
            # because the deny list lives on the instance.
            command = str(args.get("command", ""))
            for segment in _command_segments(command):
                for pattern in self.deny_commands:
                    if pattern and _matches_deny_pattern(segment, pattern):
                        return f"blocked by the deny list: commands matching '{pattern}'"
            if _dynamic_root_delete(command):
                return "blocked by the deny list: dynamic construction of a recursive root delete"
            return None
        if tool_name.startswith("browser_"):
            return _browser_blocked_reason(tool_name, args)
        if tool_name != "bash":
            return None
        command = str(args.get("command", ""))
        for segment in _command_segments(command):
            for pattern in self.deny_commands:
                if pattern and _matches_deny_pattern(segment, pattern):
                    return f"blocked by the deny list: commands matching '{pattern}'"
        if _dynamic_root_delete(command):
            return "blocked by the deny list: dynamic construction of a recursive root delete"
        return None

    def requires_confirmation(self, tool_name: str, args: dict[str, Any]) -> bool:
        """Actions that receive an extra confirmation outside Bypass mode.

        Hard deny-list and takeover checks live in ``blocked_reason``. The
        caller deliberately skips this softer gate when Bypass is active.
        """
        if tool_name.startswith("browser_"):
            return _browser_requires_confirmation(tool_name, args)
        if not tool_name.startswith("computer_"):
            return False
        text = json.dumps(args, ensure_ascii=False).lower()
        consequence_terms = (
            "delete", "remove permanently", "erase", "privacy", "security",
            "install", "upload", "send file", "share file", "factory reset",
        )
        return any(term in text for term in consequence_terms)

    def allow_tool(self, tool_name: str, permanent: bool = False) -> None:
        with self._guard:
            self.allowed.add(tool_name)
            if permanent:
                self.always_allow.add(tool_name)

    def set_mode(self, mode: str) -> None:
        if mode in MODES:
            with self._guard:
                self.mode = mode

    def reset(self) -> None:
        with self._guard:
            self.allowed.clear()
            self.mode = "ask"

    def state(self) -> dict[str, Any]:
        with self._guard:
            return {
                "skip_all": self.skip_all,
                "mode": self.mode,
                "allowed": sorted(self.allowed | self.always_allow),
                "always_allow": sorted(self.always_allow),
                "safe_tools": sorted(SAFE_TOOLS),
                "deny_commands": list(self.deny_commands),
            }

    def summary_lines(self) -> list[str]:
        with self._guard:
            return [
                f"mode: {self.mode} — {MODE_LABELS.get(self.mode, '')}",
                f"always-allowed this session: {', '.join(sorted(self.allowed)) or '—'}",
                f"always-allowed permanently: {', '.join(sorted(self.always_allow)) or '—'}",
                f"safe tools (never ask): {', '.join(sorted(SAFE_TOOLS))}",
                f"denied commands: {', '.join(self.deny_commands) or '—'}",
                "use '/permissions reset' to clear allowances, "
                "'/permissions mode ask|accept_edits|bypass' to change the mode",
            ]


#: Browser tools that carry content the user is about to send somewhere.
#:
#: The scan is deliberately narrow. Both guards above match substrings of the
#: whole argument dict, which is right for `computer_*` — the model has to echo
#: the element titles it read — and badly wrong for a browser. Pointed at a URL
#: it would hard-block navigating to `/settings/password` with no way to
#: override, and prompt on every address containing "install", "delete" or
#: "security", even in Bypass. It would also catch nothing real: a click's
#: argument is `ref_12`, and the meaning lives in the page, not the call. The
#: page-aware half of this gate is on the Swift side, where the element's type
#: and its form are actually known.
# `browser_input` is authorized against the actual target element by the native
# broker, where category settings and one-time-code classification are known.
# Scanning its text here would reject an enabled password just because the
# value happened to contain a word such as "secret". JavaScript has no target
# element for the native broker to classify, so its credential-content guard
# remains in place.
_BROWSER_TYPED_ARGUMENT_TOOLS = {"browser_javascript"}
_BROWSER_TYPED_KEYS = ("text", "value", "code")
_BROWSER_CREDENTIAL_TERMS = (
    "password", "passcode", "credential", "api key", "secret",
    "one-time code", "verification code", "seed phrase", "recovery phrase",
)
#: Consequential enough to ask about every time, Bypass included.
_BROWSER_ALWAYS_CONFIRM = {"browser_javascript", "browser_dev_server"}
#: What `browser_navigate` may open without asking. The broker refuses anything
#: else outright; this is the second line.
_BROWSER_SAFE_SCHEMES = {"http", "https", "about"}
#: Schemes written without `//`. Needed because a bare `localhost:3000` is a
#: host and a port, not a scheme, and treating it as one would put a
#: confirmation in front of the most common address anyone types here.
_BROWSER_COLON_SCHEMES = {"about", "javascript", "data", "mailto", "blob", "locus"}


def _browser_scheme(raw: str) -> str:
    value = raw.strip()
    if "://" in value:
        return value.split("://", 1)[0].lower()
    head, separator, _ = value.partition(":")
    if separator and head.lower() in _BROWSER_COLON_SCHEMES:
        return head.lower()
    return ""


def _browser_typed_content(args: dict[str, Any]) -> str:
    return " ".join(
        str(args.get(key, "")) for key in _BROWSER_TYPED_KEYS
    ).lower()


def _browser_blocked_reason(tool_name: str, args: dict[str, Any]) -> str | None:
    if tool_name not in _BROWSER_TYPED_ARGUMENT_TOOLS:
        return None
    typed = _browser_typed_content(args)
    if any(term in typed for term in _BROWSER_CREDENTIAL_TERMS):
        return "user takeover is required for credentials"
    return None


def _browser_requires_confirmation(tool_name: str, args: dict[str, Any]) -> bool:
    if tool_name in _BROWSER_ALWAYS_CONFIRM:
        return True
    if tool_name == "browser_navigate":
        scheme = _browser_scheme(str(args.get("url") or ""))
        return bool(scheme) and scheme not in _BROWSER_SAFE_SCHEMES
    return False


#: Wrappers that hide the real command behind themselves.
_PREFIX_WRAPPERS = {"sudo", "doas", "env", "nohup", "time", "command", "exec", "xargs"}

#: Separators that start a new command within one shell string.
_SEPARATORS = ("&&", "||", ";", "|", "&", "\n")

_WRAPPER_OPTIONS_WITH_VALUE = {
    "sudo": {
        "-C", "--close-from", "-D", "--chdir", "-g", "--group", "-h", "--host",
        "-p", "--prompt", "-R", "--chroot", "-r", "--role", "-T", "--command-timeout",
        "-t", "--type", "-u", "--user",
    },
    "doas": {"-C", "-u"},
    "env": {"-C", "--chdir", "-S", "--split-string", "-u", "--unset"},
    "time": {"-f", "--format", "-o", "--output"},
    "xargs": {
        "-a", "--arg-file", "-d", "--delimiter", "-E", "--eof", "-I", "--replace",
        "-L", "--max-lines", "-n", "--max-args", "-P", "--max-procs", "-s", "--max-chars",
    },
}


def _unwrap_command(words: list[str]) -> list[str]:
    """Remove assignments and common command wrappers, including their options."""
    remaining = list(words)
    while remaining:
        first = remaining[0]
        name = first.split("=", 1)[0]
        if "=" in first and not first.startswith("-") and "/" not in name:
            remaining.pop(0)
            continue
        program = first.split("/")[-1].lower()
        if program not in _PREFIX_WRAPPERS:
            break
        remaining.pop(0)
        options_with_value = _WRAPPER_OPTIONS_WITH_VALUE.get(program, set())
        while remaining:
            item = remaining[0]
            if item == "--":
                remaining.pop(0)
                break
            if item in options_with_value:
                remaining.pop(0)
                if remaining:
                    remaining.pop(0)
                continue
            if item.startswith("-"):
                remaining.pop(0)
                continue
            if program in {"env", "sudo", "doas"} and "=" in item:
                remaining.pop(0)
                continue
            break
    return remaining


def _command_segments(command: str) -> list[str]:
    """Split a shell string into normalized, unwrapped command segments."""
    text = command.replace("\r", "\n")
    for sep in _SEPARATORS:
        text = text.replace(sep, "\n")
    segments: list[str] = []
    for raw in text.split("\n"):
        try:
            words = shlex.split(raw)
        except ValueError:
            words = raw.replace("'", "").replace('"', "").split()
        words = _unwrap_command(words)
        if not words:
            continue
        # Compare on the program's basename so /bin/rm matches "rm".
        words = [words[0].split("/")[-1], *words[1:]]
        segments.append(shlex.join(words).lower())
        if words:
            program = words[0].lower()
            if program in {"sh", "bash", "zsh", "dash", "ksh"} and "-c" in words:
                index = words.index("-c")
                if index + 1 < len(words):
                    segments.extend(_command_segments(words[index + 1]))
            elif program == "eval" and len(words) > 1:
                segments.extend(_command_segments(" ".join(words[1:])))
    return segments


def _matches_deny_pattern(segment: str, pattern: str) -> bool:
    normalized = " ".join(segment.lower().split())
    target = " ".join(pattern.lower().split())
    if target.startswith("rm -rf /"):
        return _is_recursive_root_delete(normalized)
    if target == "mkfs":
        words = normalized.split()
        return bool(words and words[0].split("/")[-1].startswith("mkfs"))
    if target.startswith("dd if="):
        words = normalized.split()
        return bool(
            words
            and words[0].split("/")[-1] == "dd"
            and any(item.startswith("if=") for item in words[1:])
        )
    if target.startswith(":(){"):
        return ":(){:|:&};:" in re.sub(r"\s+", "", normalized)
    return normalized.startswith(target)


def _is_recursive_root_delete(segment: str) -> bool:
    try:
        words = shlex.split(segment)
    except ValueError:
        words = segment.replace("'", "").replace('"', "").split()
    if not words or words[0].split("/")[-1] != "rm":
        return False
    recursive = False
    force = False
    targets: list[str] = []
    options_done = False
    for item in words[1:]:
        if item == "--":
            options_done = True
        elif not options_done and item.startswith("--"):
            recursive = recursive or item == "--recursive"
            force = force or item == "--force"
        elif not options_done and item.startswith("-"):
            flags = item[1:]
            recursive = recursive or "r" in flags.lower()
            force = force or "f" in flags.lower()
        else:
            targets.append(item)
    return recursive and force and any(target in {"/", "/*", "//"} for target in targets)


def _dynamic_root_delete(command: str) -> bool:
    if "$(" not in command and "`" not in command:
        return False
    flattened = " ".join(command.lower().replace("\\", "").split())
    has_root_target = bool(re.search(r"(?:^|\s)/(?=\s|$|[;&|])", flattened))
    has_recursive_force = bool(
        re.search(
            r"(?:-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|--recursive|--force)",
            flattened,
        )
    )
    return has_root_target and has_recursive_force


def _shorten(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit] + f"… (+{len(text) - limit} chars)"


def build_preview(
    name: str,
    args: dict[str, Any],
    ctx: Any | None = None,
) -> tuple[str, str]:
    """Return (summary, detail) describing a pending tool call.

    ``summary`` is a one-liner shown in the compact log line and as the
    permission panel title; ``detail`` is the body shown when asking, and is
    rendered as a diff by the GUI when it looks like one.
    """
    if name in {"bash", "background_service"}:
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
        return f"write {path} ({len(lines)} lines)", _target_detail(
            path,
            head or "(empty file)",
            ctx,
        )
    if name == "apply_patch":
        from . import codex_patch

        text = str(args.get("input") or args.get("patch") or "")
        changed = codex_patch.changed_paths(text)
        if changed:
            listed = ", ".join(path for _, path in changed[:5])
            if len(changed) > 5:
                listed += f", … (+{len(changed) - 5} more)"
            summary = f"patch {len(changed)} file(s): {listed}"
        else:
            summary = "apply patch (unparsed envelope)"
        # The envelope is already diff-shaped, so the GUI renders it as one.
        return summary, _shorten(text, 20_000)
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
        return f"edit {path}{scope}", _target_detail(
            path,
            diff or "(no visible change)",
            ctx,
        )
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
        return f"edit {path} ({count} changes)", _target_detail(
            path,
            "\n".join(chunks) or "(no visible change)",
            ctx,
        )
    if name == "read_file":
        path = str(args.get("path", ""))
        extra = ""
        if args.get("offset"):
            extra += f" from line {args['offset']}"
        if args.get("limit"):
            extra += f" ({args['limit']} lines)"
        return f"read {path}{extra}", _target_detail(path, "", ctx)
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
    if name == "submit_plan":
        steps = args.get("steps")
        n = len(steps) if isinstance(steps, list) else 0
        return f"submit plan ({n} steps)", str(args.get("title") or "Implementation plan")
    if name == "web_fetch":
        url = str(args.get("url", ""))
        return f"fetch {url}", url
    # The destination is the most security-relevant thing in the whole browser
    # family, and the fallback below would render it as a JSON blob clipped at
    # 120 characters.
    if name == "browser_navigate":
        url = str(args.get("url", ""))
        if url.lower() in {"back", "forward", "reload"}:
            return f"browser {url.lower()}", ""
        return f"open {_shorten(url, 90)}", url
    if name == "browser_read_page":
        scope = str(args.get("ref_id") or "")
        return f"read the page{f' below {scope}' if scope else ''}", ""
    if name == "notes_read":
        return "read Notes", ""
    if name == "notes_update":
        action = str(args.get("action") or "replace")
        content = str(args.get("text") or "")
        return f"{action} Notes", content
    if name == "browser_input":
        action = str(args.get("action") or "click")
        target = str(args.get("ref") or args.get("from_ref") or args.get("key") or "")
        if not target and args.get("x") is not None and args.get("y") is not None:
            target = f"({args.get('x')}, {args.get('y')})"
        typed = str(args.get("text") or args.get("value") or "")
        summary = f"{action.replace('_', ' ')}{f' {target}' if target else ''}"
        return summary, typed or target
    if name == "browser_javascript":
        code = str(args.get("code") or "")
        return f"run JavaScript in the page: {_shorten(code, 70)}", code
    if name in {"browser_dev_server", "background_service"}:
        action = str(args.get("action") or "status")
        if action == "start":
            command = str(args.get("command") or "")
            return f"start dev server: $ {_shorten(command, 80)}", command
        if action == "stop":
            target = str(args.get("name") or "every server")
            return f"stop dev server ({target})", ""
        return "list dev servers", ""
    if name == "git_status":
        return "git status", ""
    if name == "git_diff":
        path = str(args.get("path", "") or "")
        return f"git diff{' ' + path if path else ''}", ""
    return (
        f"{name} {json.dumps(args, ensure_ascii=False, default=str)[:120]}",
        json.dumps(args, indent=2, ensure_ascii=False, default=str)[:2000],
    )


def file_effects(
    name: str,
    args: dict[str, Any],
    ctx: Any | None = None,
) -> list[dict[str, str]]:
    """What a pending tool call is about to do to the filesystem.

    ``[{"path": ..., "effect": "create" | "edit" | "delete"}, ...]``.

    The GUI used to recover this by scraping the summary and result strings,
    which could not tell a new file from an edited one and could not see a bare
    filename at the workspace root at all. The tool arguments already say
    exactly what will happen, so say it.

    Must be called *before* the tool runs: distinguishing a create from an
    overwrite depends on whether the target exists yet.

    Deliberately empty for ``bash``: a shell command's arguments say nothing
    about what it will write, and guessing from its output is how the old
    heuristic went wrong. The workspace watcher covers that case instead.
    """

    def relative(path: str) -> str | None:
        cleaned = path.strip()
        if not cleaned:
            return None
        if ctx is None:
            return cleaned
        try:
            resolved = ctx.resolve(cleaned)
            cwd = getattr(ctx, "cwd", "") or ""
            if cwd:
                try:
                    return str(resolved.relative_to(Path(cwd)))
                except ValueError:
                    pass
            return str(resolved)
        except (OSError, RuntimeError):
            return cleaned

    def exists(path: str) -> bool:
        if ctx is None:
            return False
        try:
            return ctx.resolve(path).exists()
        except (OSError, RuntimeError):
            return False

    try:
        if name == "write_file":
            path = str(args.get("path", ""))
            target = relative(path)
            if not target:
                return []
            return [{"path": target, "effect": "edit" if exists(path) else "create"}]
        if name in {"edit_file", "multi_edit"}:
            target = relative(str(args.get("path", "")))
            return [{"path": target, "effect": "edit"}] if target else []
        if name == "apply_patch":
            from . import codex_patch

            text = str(args.get("input") or args.get("patch") or "")
            effects: list[dict[str, str]] = []
            for marker, path in codex_patch.changed_paths(text):
                target = relative(path)
                if not target:
                    continue
                effect = {"A": "create", "D": "delete"}.get(marker, "edit")
                effects.append({"path": target, "effect": effect})
            return effects
    except (OSError, RuntimeError, ValueError):
        return []
    return []


def _target_detail(path: str, detail: str, ctx: Any | None) -> str:
    if ctx is None or not path:
        return detail
    try:
        lexical = ctx.resolve(path)
        resolved = lexical.resolve()
    except (OSError, RuntimeError):
        return detail
    if str(lexical) == str(resolved):
        return detail
    note = f"[resolves to: {resolved}]"
    return f"{detail}\n\n{note}" if detail else note
