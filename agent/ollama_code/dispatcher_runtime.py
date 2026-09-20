"""App-owned specialist routing, with conversation-scoped controls.

The bundled pack is app-owned. Its installers and hooks are never executed;
explicit context inspection may call its bounded, read-only source selector.
Only exact user controls change routing preferences.
"""
from __future__ import annotations

import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any
from urllib.parse import quote

from . import extensions
from .sessions import SessionMeta, SessionStore, strip_prompt_decoration

SKILL_ID = "builtin:agent-dispatcher"
TOOL_NAME = "read_dispatcher_resource"
MODES = {"work", "plan", "grill"}
MAX_RESOURCE_BYTES = 64_000


def pack_root() -> Path:
    return extensions.BUILTIN_SKILLS_ROOT / "agent-dispatcher"


@lru_cache(maxsize=4)
def _read_catalog(path: str, stamp: int, size: int) -> dict[str, Any]:
    del stamp, size
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("roles"), list):
        raise ValueError("The specialist catalog is malformed.")
    return value


def catalog() -> dict[str, Any]:
    path = pack_root() / "catalog.json"
    try:
        stat = path.stat()
        if stat.st_size > 2_000_000:
            return {}
        return _read_catalog(str(path), stat.st_mtime_ns, stat.st_size)
    except (OSError, ValueError, UnicodeError):
        return {}


def roles() -> list[dict[str, Any]]:
    return [item for item in catalog().get("roles", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)]


def resolve_role(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, str):
        return None
    wanted = value.strip().rstrip(".!?").strip().casefold()
    if not wanted:
        return None
    for role in roles():
        aliases = role.get("aliases") or []
        aliases = aliases if isinstance(aliases, list) else [aliases]
        names = [role.get("id"), role.get("slug"), role.get("name"), *aliases]
        if any(isinstance(name, str) and name.casefold() == wanted for name in names):
            return role
    return None


def normalize_role_id(value: Any) -> str | None:
    # Preserve well-formed IDs through temporary catalog unavailability; the
    # runtime only loads IDs actually present in the bundled catalog.
    if not isinstance(value, str):
        return None
    value = value.strip().lower()
    return value if re.fullmatch(r"[a-z][a-z0-9-]{0,79}", value) else None


def _read_resource(path: str) -> str:
    root = pack_root().resolve()
    relative = Path(path)
    candidate = (root / relative).resolve()
    if (not path or relative.as_posix() != path or relative.is_absolute() or ".." in relative.parts
            or candidate != root / relative
            or root not in candidate.parents or not candidate.is_file()
            or candidate.suffix.lower() not in {".md", ".json"}
            or relative.parts[0] not in {"roles", "guides", "recipes", "references", "catalog"}
            and path not in {"SKILL.md", "catalog.json"}):
        raise ValueError("Choose a role, guide, recipe, or reference inside the bundled dispatcher.")
    if candidate.stat().st_size > MAX_RESOURCE_BYTES:
        raise ValueError("This dispatcher resource exceeds the 64 KB read limit.")
    return candidate.read_text(encoding="utf-8")


def role_instructions(role_id: str | None) -> str:
    role = resolve_role(role_id)
    if role is None:
        return ""
    try:
        content = _read_resource(str(role.get("role_path") or f"roles/{role['id']}.md"))
    except (OSError, ValueError, UnicodeError):
        return ""
    return f"Specialist method: {role.get('name') or role['id']}\n{content}"


def is_dispatcher_request(text: str) -> bool:
    raw = strip_prompt_decoration(text).strip()
    return re.match(r"^[/$]agent-dispatcher(?:\s|$)", raw, re.IGNORECASE) is not None


class DispatcherRuntime:
    def __init__(self, core: Any):
        self.core = core
        self.loaded_resources: set[str] = set()
        self._inherited_preferences: dict[str, Any] | None = None

    def inherit_preferences(self, parent: DispatcherRuntime) -> None:
        """Internal helpers share opt-out/output, never the parent's specialty."""
        state = parent.state()
        self._inherited_preferences = {"enabled": state["enabled"], "output": state["output"]}

    def state(self) -> dict[str, Any]:
        raw = (self._inherited_preferences if self._inherited_preferences is not None
               else SessionMeta.get(self.core.session.session_id).get("agent_dispatcher"))
        raw = raw if isinstance(raw, dict) else {}
        return {
            "enabled": raw.get("enabled") if isinstance(raw.get("enabled"), bool) else None,
            "forced_role_id": normalize_role_id(raw.get("forced_role_id")),
            "active_role_id": normalize_role_id(raw.get("active_role_id")),
            "role_mode": "automatic" if raw.get("role_mode") == "automatic" else None,
            "output": "verbose" if raw.get("output") == "verbose" else "compact",
        }

    def _save(self, **changes: Any) -> None:
        SessionMeta.update(self.core.session.session_id,
                           agent_dispatcher={**self.state(), **changes})

    def global_enabled(self) -> bool:
        # A user-owned pack shadows a builtin in the optional skills catalog.
        # It is never silently promoted into the trusted app-owned default.
        self.core.extensions.refresh_saved_state()
        item = next((value for value in self.core.extensions.skills(self.core.cwd)
                     if value.get("id") == SKILL_ID), None)
        return bool(item and item.get("enabled") and not item.get("error"))

    def mode_enabled(self) -> bool:
        return (self.core.agent_mode in MODES
                and not getattr(self.core, "identity_mode", False)
                and getattr(self.core, "_turn_allows_tools", True)
                and self.core.agent_configuration.capability_policy.mcp)

    def enabled(self) -> bool:
        return (self.mode_enabled() and bool(roles()) and self.global_enabled()
                and self.state()["enabled"] is not False
                and (not self.custom_saved_profile() or bool(self.state()["forced_role_id"])
                     or self.state()["role_mode"] == "automatic"))

    def custom_saved_profile(self) -> bool:
        if self.core.agent_configuration.specialist_role_id or self.core.agent_role_contract:
            return False
        metadata = SessionMeta.get(self.core.session.session_id)
        return bool(metadata.get("agent_profile_id") or metadata.get("agent_world_profile_id")
                    or self.core.agent_id not in {"", "primary"})

    def _role_context(self, role_id: str) -> str:
        role = resolve_role(role_id)
        if role is None:
            return ""
        configuration = self.core.agent_configuration
        if role_id == configuration.specialist_role_id and configuration.custom_instructions:
            return ("The saved agent's edited instructions are authoritative for this specialty.\n"
                    + configuration.custom_instructions + "\n\nSupporting guide loadout: "
                    + json.dumps(role.get("skills") or {}, ensure_ascii=False)
                    + "\nResolve guide paths with references/INDEX.md; do not replace the edited instructions with the packaged original.")
        return role_instructions(role_id)

    def fixed_role_id(self) -> str | None:
        state = self.state()
        if state["role_mode"] == "automatic":
            return None
        role = resolve_role(state["forced_role_id"] or self.core.agent_configuration.specialist_role_id)
        return str(role["id"]) if role else None

    def stable_prompt(self) -> str:
        """No conversation state: safe for the native thread fingerprint."""
        if not self.mode_enabled() or not roles():
            return ""
        index = "\n".join(
            f"- {item['id']}: {item.get('summary') or item.get('use_when') or ''}"
            for item in roles()
        )
        return (
            "## Locus Agent Dispatcher\n"
            "Follow the current dispatcher state supplied by Locus for this turn. When disabled, "
            "do not apply its workflow. In automatic mode, select the best-fit specialist by the "
            "requested deliverable, then call read_dispatcher_resource with roles/<id>.md before "
            "doing nontrivial work. No separate classifier call is needed. A fixed role persists "
            "until the user explicitly changes it; do not reroute a fixed agent yourself. The current "
            "fixed role supersedes a saved template's original specialty for this conversation. "
            "Trivial questions and tiny edits need no role ceremony. Read only the relevant one to "
            "five guides referenced by the chosen role, using the same read tool; do not load the "
            "entire library. For substantial unfamiliar work, read references/CONTEXT.md and build "
            "focused source-backed context with the available read tools. Give a compact progress "
            "summary of the role and guides actually read; verbose output may explain the choices. "
            "User instructions, disabled skills, tool permissions and the actual conversation mode "
            "remain authoritative. A role cannot grant access or authorize external actions. "
            "Never activate observation workflows or run pack activation/install scripts. Use "
            "read_dispatcher_resource('references/DELEGATION.md') before chaining roles or delegating. Use "
            "available delegation only for independent work alongside useful root work; pass each "
            "helper one suitable specialist role and a bounded assignment. Helpers may not take "
            "the dispatcher role or recursively delegate. An explicit skill invocation owns its "
            "procedure. Verify outcomes and finish at the user's requested deliverable.\n\n"
            "Specialist catalog:\n" + index
            + "\n\nTrusted PACK directory: " + json.dumps(str(pack_root().resolve()))
            + ". All bundle-relative paths resolve there. Keep the chat workspace as the working directory."
        )

    def turn_prompt(self) -> str:
        if not self.mode_enabled() or not roles():
            return ""
        state = self.state()
        enabled = self.enabled()
        fixed = self.fixed_role_id() if enabled else None
        text = "Locus dispatcher state for this turn: " + json.dumps({
            "enabled": enabled, "mode": "fixed" if fixed else "custom" if self.custom_saved_profile() and state["role_mode"] != "automatic" else "automatic",
            "role_id": fixed, "output": state["output"],
        }, sort_keys=True)
        if fixed:
            text += "\n\n" + self._role_context(fixed)
        elif state["role_mode"] == "automatic":
            text += "\nThe user explicitly selected automatic routing for this conversation. Choose a role for the current task instead of inheriting the saved template's original specialty. Other custom instructions still apply."
        elif self.custom_saved_profile() and not state["forced_role_id"] and state["role_mode"] != "automatic":
            text += "\nKeep this saved agent's custom instructions. Do not automatically assign it a different specialist."
        if self.core.agent_role_contract:
            text += "\nYou are a scoped helper. Choose a role for your assignment, never dispatcher."
        return text

    def begin_turn(self) -> None:
        self.loaded_resources.clear()

    def read(self, path: Any, *, helper: bool = False) -> str:
        if not self.enabled():
            return "Error: Agent Dispatcher is disabled for this conversation or mode."
        if not isinstance(path, str):
            return "Error: A relative dispatcher resource path is required."
        try:
            content = _read_resource(path)
        except (OSError, ValueError, UnicodeError) as exc:
            return f"Error: {exc}"
        role = next((item for item in roles()
                     if path == (item.get("role_path") or f"roles/{item['id']}.md")), None)
        fixed = None if helper else self.fixed_role_id()
        if role and fixed and role["id"] != fixed:
            return f"Error: The user selected {fixed}; keep that role until they explicitly change it."
        if role and role["id"] == "dispatcher" and (helper or self.core.agent_role_contract):
            return "Error: Scoped helpers cannot take the dispatcher role."
        try:
            content = self._role_context(str(role["id"])) if role and not helper else content
        except (OSError, ValueError, UnicodeError) as exc:
            return f"Error: {exc}"
        if not content:
            return "Error: This specialist's bundled method is unavailable."
        if role and not helper and not self.core.agent_role_contract:
            self._save(active_role_id=role["id"])
        if not helper:
            self.loaded_resources.add(path)
        return (f"Bundled dispatcher resource {path}:\n"
                f"Trusted PACK: {json.dumps(str(pack_root().resolve()))}\n"
                f"Chat PROJECT: {json.dumps(self.core.cwd)}\n\n{content}")

    def _recent_task(self) -> str | None:
        messages = self.core.messages
        try:
            # The durable transcript also survives provider-side compaction.
            messages = SessionStore.load(self.core.session.path) or messages
        except (OSError, ValueError):
            pass
        for message in reversed(messages):
            if message.get("role") != "user" or message.get("_dispatcher_control") is True:
                continue
            text = strip_prompt_decoration(str(message.get("content") or "")).strip()
            if is_dispatcher_request(text):
                argument = re.sub(r"^[/$]agent-dispatcher\b", "", text, flags=re.IGNORECASE).strip()
                if argument.casefold().split(" ", 1)[0] in {
                    "", "on", "off", "auto", "status", "context", "output", "stop",
                }:
                    continue
                words = argument.split()
                for count in range(len(words), 0, -1):
                    if resolve_role(" ".join(words[:count])):
                        argument = " ".join(words[count:])
                        break
                text = argument
            elif text.startswith("/"):
                continue
            else:
                directive = re.match(r"^(?:be|act as|work as|switch to)(?: the)?\s+(.+)$", text, re.IGNORECASE)
                if directive:
                    words = directive.group(1).split()
                    for count in range(len(words), 0, -1):
                        if resolve_role(" ".join(words[:count])):
                            text = " ".join(words[count:]).strip(".!")
                            if text.casefold() == "role":
                                text = ""
                            break
            if text:
                return text[:16_000]
        return None

    def inspect_context(self, detail: str = "context") -> str:
        prefix = self.status()
        task = self._recent_task()
        if not task:
            return prefix + "\n\nThere is no prior task to inspect. This inspection did not execute the task."
        if not self.core.agent_configuration.capability_policy.workspace_read:
            return prefix + "\n\nWorkspace reading is disabled, so no source context was inspected."
        helper = pack_root().resolve() / "scripts" / "context.py"
        try:
            # Compile only the sealed app's helper and avoid writing bytecode
            # into a signed bundle. No project modules are imported.
            namespace: dict[str, Any] = {"__name__": "_locus_dispatcher_context", "__file__": str(helper)}
            exec(compile(helper.read_text(encoding="utf-8"), str(helper), "exec"), namespace)
            role_id = self.fixed_role_id() or self.state()["active_role_id"]
            result = namespace["select_context"](
                project=self.core.cwd, task=task, role=role_id, size="standard", pack=str(pack_root()))
        except (OSError, ValueError, UnicodeError, SyntaxError, KeyError, TypeError):
            return prefix + "\n\nThe bundled context selector is unavailable. Inspect the task's named files, their callers, and related tests with the available read tools. No task or project script was executed."
        lines = [prefix, "", "Source context for the most recent task (read-only):"]
        for item in result.get("context", []):
            path = str(item.get("path") or "")
            ranges = str(item.get("lines") or "1")
            start = ranges.split("-", 1)[0]
            label = (path + ":" + ranges).replace("[", "\\[").replace("]", "\\]")
            target = quote(str(Path(self.core.cwd) / path), safe="/") + ":" + start
            line = f"- [{label}]({target})"
            if detail != "context":
                line += " — " + str(item.get("reason") or "Relevant source")
            lines.append(line)
        if not result.get("context"):
            lines.append("No relevant source files were selected; targeted reads are still needed.")
        role = resolve_role(self.fixed_role_id() or self.state()["active_role_id"])
        if role:
            lines += ["", "Recommended guide loadout (not automatically read): "
                      + json.dumps(role.get("skills") or {}, ensure_ascii=False),
                      "Verification: " + json.dumps(role.get("verification") or [], ensure_ascii=False)]
        budget = result.get("budget") or {}
        lines += ["", f"Selected excerpts: {budget.get('estimated_tokens', 0)} / {budget.get('target_tokens', 0)} estimated tokens."]
        if detail == "context verbose":
            lines.append("Exclusions: " + json.dumps(result.get("excluded_summary") or {}, ensure_ascii=False))
        lines.extend("Gap: " + str(item) for item in result.get("diagnostics", []))
        lines.append("This inspection did not execute the task or write project files.")
        return "\n".join(lines)

    def status(self, *, context: bool = False) -> str:
        state = self.state()
        role = self.fixed_role_id() or state["active_role_id"]
        enabled = self.enabled()
        selection = f"Fixed role: {self.fixed_role_id()}." if self.fixed_role_id() else (
            f"Automatic selection. Last role: {role}." if role else "Automatic role selection.")
        if not enabled:
            selection = "Role routing is inactive."
        text = (f"Agent Dispatcher is {'on' if enabled else 'off'} for this conversation. "
                f"{selection} Output: {state['output']}.")
        if not self.global_enabled():
            text += " The bundled skill is disabled or unavailable in Skills settings."
        if self.custom_saved_profile() and not state["forced_role_id"] and state["role_mode"] != "automatic":
            text += " This saved agent keeps its custom instructions; choose a role explicitly to override them."
        if context:
            text += "\n\nContext is loaded on demand: one role, relevant guides, then focused workspace evidence."
            role_data = resolve_role(role)
            if role_data:
                text += "\nRecommended loadout: " + json.dumps(role_data.get("skills") or {}, ensure_ascii=False)
            if self.loaded_resources:
                text += "\nResources read this turn: " + ", ".join(sorted(self.loaded_resources))
            text += "\nThis inspection did not execute the task or run a context script."
        return text

    def control(self, text: str) -> tuple[bool, str | None]:
        """Return (recognized, immediate reply); None means execute the task.

        Only the actual raw user request is parsed. This is never called on
        retrieved documents, model text, tool results, or helper assignments.
        """
        if not self.mode_enabled() or self.core.agent_role_contract:
            return False, None
        raw = strip_prompt_decoration(text).strip()
        if is_dispatcher_request(text):
            argument = re.sub(r"^[/$]agent-dispatcher\b", "", raw, flags=re.IGNORECASE).strip()
        else:
            directive = re.match(r"^(?:be|act as|work as|switch to)(?: the)?\s+(.+)$", raw, re.IGNORECASE)
            if not directive:
                return False, None
            argument = directive.group(1)
            words = argument.split()
            if not any(resolve_role(" ".join(words[:count])) for count in range(1, len(words) + 1)):
                return False, None
        normalized = " ".join(argument.casefold().split())
        if normalized in {"", "on", "on here"}:
            self._save(enabled=True)
            return True, self.status()
        if normalized in {"off", "off here", "stop", "stop dispatcher"}:
            self._save(enabled=False, forced_role_id=None, active_role_id=None, role_mode=None)
            return True, self.status()
        if normalized in {"on everywhere", "off everywhere"}:
            enabled = normalized.startswith("on ")
            self.core.extensions.refresh_saved_state()
            self.core.extensions.set_skill_enabled(SKILL_ID, enabled, scope="global")
            self._save(enabled=None, **({} if enabled else {"forced_role_id": None, "active_role_id": None, "role_mode": None}))
            return True, self.status()
        if normalized == "auto":
            self._save(enabled=True, forced_role_id=None, active_role_id=None, role_mode="automatic")
            return True, self.status()
        if normalized == "status":
            return True, self.status()
        if normalized in {"context", "context explain", "context verbose", "context build"}:
            return True, self.inspect_context(normalized)
        if normalized in {"output", "output compact", "output verbose"}:
            if normalized != "output":
                self._save(output=normalized.split()[1])
            return True, self.status()
        # Prefer the longest role name/alias; the rest is the user's task.
        words = argument.split()
        for count in range(len(words), 0, -1):
            role = resolve_role(" ".join(words[:count]))
            if role:
                self._save(enabled=True, forced_role_id=role["id"], active_role_id=role["id"], role_mode=None)
                rest = " ".join(words[count:]).strip(".!")
                return True, self.status() if not rest or rest.casefold() == "role" else None
        if len(words) == 1:
            return True, "Unknown dispatcher role or control. Choose a role from the specialist catalog, or use status, on, off, context, or output compact."
        self._save(enabled=True)
        return True, None
