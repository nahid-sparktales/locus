"""Codex-compatible plugins, marketplaces, skills, and MCP configuration.

The extension manager deliberately owns only durable, non-secret state.  The
native app remains the credential broker: bearer tokens, OAuth refresh tokens,
header values, and secret environment values are handed to the MCP runtime in
memory and never reach this module's JSON files.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import urlencode, urlparse

import requests

from .paths import APP_DIR
from .proxy import sanitized_child_environment

MAX_PLUGIN_FILES = 5_000
MAX_PLUGIN_BYTES = 250 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_SKILL_BYTES = 256 * 1024
MAX_SKILL_RESOURCE_BYTES = 8 * 1024 * 1024
MAX_MARKETPLACE_BYTES = 4 * 1024 * 1024
MAX_GIT_OUTPUT = 16_000
MAX_OAUTH_METADATA_BYTES = 1024 * 1024
BUILTIN_SKILLS_ROOT = Path(__file__).resolve().parent / "builtin_skills"

def _load_mcp_catalog() -> tuple[int, tuple[dict[str, Any], ...]]:
    """Load the immutable catalog bundled with this exact app/backend build."""
    path = Path(__file__).resolve().parent / "catalogs/mcp-presets-v1.json"
    value = _read_json(path, 256 * 1024)
    version = value.get("version")
    presets = value.get("presets")
    if version != 2 or not isinstance(presets, list) or len(presets) != 5 \
            or any(not isinstance(item, dict) for item in presets):
        raise RuntimeError("the bundled MCP preset catalog is invalid")
    return version, tuple(dict(item) for item in presets)


_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,79}$")
_GITHUB_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:@[^/]+)?$")
_SKILL_MENTION_RE = re.compile(r"(?<![\w$])\$([a-zA-Z0-9][a-zA-Z0-9._:-]{0,159})")


class ExtensionError(ValueError):
    """An extension is malformed, unsafe, unavailable, or unsupported."""


def _slug(value: str, fallback: str = "extension") -> str:
    cleaned = re.sub(r"[^a-z0-9._-]+", "-", value.strip().lower()).strip("-._")
    return (cleaned or fallback)[:80]


def _safe_name(value: Any, field: str = "name") -> str:
    name = str(value or "").strip().lower()
    if not _NAME_RE.fullmatch(name):
        raise ExtensionError(f"{field} must use lowercase letters, numbers, '.', '_' or '-'")
    return name


def _read_json(path: Path, limit: int) -> dict[str, Any]:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise ExtensionError(f"cannot read {path}: {exc}") from exc
    if size > limit:
        raise ExtensionError(f"{path.name} exceeds the {limit // 1024} KB limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExtensionError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ExtensionError(f"{path} must contain a JSON object")
    return value


# Merely loading this local catalog performs no network I/O. A user must review
# and materialize a preset before the MCP runtime can see it.
MCP_CATALOG_VERSION, MCP_PRESETS = _load_mcp_catalog()


def _inside(root: Path, candidate: Path) -> bool:
    try:
        resolved_root = root.resolve()
        resolved = candidate.resolve()
    except (OSError, RuntimeError):
        return False
    return resolved == resolved_root or resolved_root in resolved.parents


def _component_path(root: Path, value: Any, default: str | None = None) -> Path | None:
    raw = str(value or default or "").strip()
    if not raw:
        return None
    if not raw.startswith("./"):
        raise ExtensionError(f"component path must start with './': {raw}")
    candidate = root / raw[2:]
    if not _inside(root, candidate):
        raise ExtensionError(f"component path escapes the plugin: {raw}")
    return candidate


def _tree_digest(root: Path) -> str:
    digest = hashlib.sha256()
    files = 0
    total = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        try:
            stat = path.lstat()
        except OSError as exc:
            raise ExtensionError(f"cannot inspect {path}: {exc}") from exc
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = path.resolve()
            if not _inside(root, target):
                raise ExtensionError(f"symlink escapes plugin root: {relative}")
            digest.update(f"link:{relative}:{os.readlink(path)}\n".encode())
            continue
        if path.is_dir():
            continue
        files += 1
        total += stat.st_size
        if files > MAX_PLUGIN_FILES:
            raise ExtensionError(f"plugin contains more than {MAX_PLUGIN_FILES} files")
        if total > MAX_PLUGIN_BYTES:
            raise ExtensionError(
                f"plugin exceeds the {MAX_PLUGIN_BYTES // (1024 * 1024)} MB unpacked limit"
            )
        digest.update(f"file:{relative}:{stat.st_size}\n".encode())
        try:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(128 * 1024), b""):
                    digest.update(chunk)
        except OSError as exc:
            raise ExtensionError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def _frontmatter(text: str) -> tuple[dict[str, str], str]:
    if not text.startswith("---\n"):
        return {}, text
    marker = text.find("\n---", 4)
    if marker < 0:
        return {}, text
    raw = text[4:marker]
    body = text[marker + 4 :].lstrip("\r\n")
    values: dict[str, str] = {}
    current = ""
    for line in raw.splitlines():
        if line[:1].isspace() and current:
            values[current] = f"{values[current]} {line.strip()}".strip()
            continue
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        current = key.strip()
        values[current] = value.strip().strip("\"'")
    return values, body


def parse_skill(path: Path, *, source: str, plugin_id: str | None = None) -> dict[str, Any]:
    if path.name != "SKILL.md" or not path.is_file():
        raise ExtensionError(f"skill is missing SKILL.md: {path}")
    try:
        if path.stat().st_size > MAX_SKILL_BYTES:
            raise ExtensionError(f"{path} exceeds the {MAX_SKILL_BYTES // 1024} KB skill limit")
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ExtensionError(f"cannot read skill {path}: {exc}") from exc
    metadata, _ = _frontmatter(text)
    if not str(metadata.get("name") or "").strip():
        raise ExtensionError(f"skill {path.parent.name} must declare a name")
    name = _safe_name(metadata.get("name"), "skill name")
    description = str(metadata.get("description") or "").strip()
    if not description:
        raise ExtensionError(f"skill {name} must declare a description")
    implicit = True
    openai: dict[str, Any] = {}
    openai_metadata = path.parent / "agents/openai.yaml"
    if openai_metadata.is_file():
        try:
            raw = openai_metadata.read_text(encoding="utf-8")[:64_000]
            match = re.search(r"(?m)^\s*allow_implicit_invocation\s*:\s*(true|false)\s*$", raw)
            if match:
                implicit = match.group(1) == "true"
            for key in ("display_name", "short_description", "default_prompt"):
                scalar = re.search(
                    rf"(?m)^\s*{key}\s*:\s*([^#\n]+?)\s*$", raw
                )
                if scalar:
                    openai[key] = scalar.group(1).strip().strip("\"'")[:4_000]
        except (OSError, UnicodeDecodeError):
            pass
    skill_id = f"{plugin_id}:{name}" if plugin_id else name
    return {
        "id": skill_id,
        "name": name,
        "display_name": openai.get("display_name") or name.replace("-", " ").title(),
        "description": description,
        "path": str(path),
        "root": str(path.parent),
        "source": source,
        "plugin_id": plugin_id,
        "allow_implicit_invocation": implicit,
        "activation": "automatic" if implicit else "explicit",
        "openai_metadata": openai,
        "enabled": True,
        "error": None,
    }


def parse_plugin(root: Path) -> dict[str, Any]:
    root = root.resolve()
    manifest_path = root / ".codex-plugin/plugin.json"
    if not manifest_path.is_file():
        raise ExtensionError("plugin is missing .codex-plugin/plugin.json")
    manifest = _read_json(manifest_path, MAX_MANIFEST_BYTES)
    name = _safe_name(manifest.get("name"), "plugin name")
    version = str(manifest.get("version") or "local").strip()[:80] or "local"
    description = str(manifest.get("description") or "").strip()
    if not description:
        raise ExtensionError(f"plugin {name} must declare a description")
    interface = manifest.get("interface") if isinstance(manifest.get("interface"), dict) else {}
    author = manifest.get("author") if isinstance(manifest.get("author"), dict) else {}

    skills_root = _component_path(root, manifest.get("skills"), "./skills/")
    skills: list[dict[str, Any]] = []
    skill_errors: list[str] = []
    if skills_root and skills_root.is_dir():
        for skill_file in sorted(skills_root.glob("*/SKILL.md")):
            try:
                skills.append(parse_skill(skill_file, source="plugin", plugin_id=name))
            except ExtensionError as exc:
                skill_errors.append(str(exc))

    mcp_path = _component_path(root, manifest.get("mcpServers"), "./.mcp.json")
    mcp_servers: list[dict[str, Any]] = []
    if mcp_path and mcp_path.is_file():
        mcp_raw = _read_json(mcp_path, MAX_MANIFEST_BYTES)
        servers = mcp_raw.get("mcpServers", mcp_raw.get("mcp_servers", mcp_raw))
        if not isinstance(servers, dict):
            raise ExtensionError(".mcp.json must contain a server map")
        for raw_name, raw_config in servers.items():
            if not isinstance(raw_config, dict):
                continue
            server_name = _safe_name(raw_name, "MCP server name")
            config = _normalize_mcp_config(raw_config)
            config.update({
                "id": f"plugin:{name}:{server_name}",
                "name": server_name,
                "origin": "plugin",
                "plugin_id": name,
                "plugin_root": str(root),
                "plugin_data": "",
                "enabled_global": True,
                "enabled_workspaces": [],
            })
            mcp_servers.append(config)

    unsupported: list[str] = []
    for key, label in (
        ("hooks", "hooks"), ("apps", "registered apps"), ("agents", "agents"),
        ("lspServers", "LSP servers"),
    ):
        if manifest.get(key):
            unsupported.append(label)
    for path, label in (
        (root / "hooks", "hooks"), (root / ".app.json", "registered apps"),
        (root / "agents", "agents"), (root / ".lsp.json", "LSP servers"),
        (root / "package.json", "npm package"),
    ):
        if path.exists() and label not in unsupported:
            unsupported.append(label)
    scripts = []
    scripts_root = root / "scripts"
    if scripts_root.is_dir():
        scripts = [
            item.relative_to(root).as_posix()
            for item in sorted(scripts_root.rglob("*"))
            if item.is_file()
        ][:200]

    return {
        "name": name,
        "version": version,
        "description": description,
        "display_name": str(interface.get("displayName") or name.replace("-", " ").title()),
        "short_description": str(interface.get("shortDescription") or description),
        "long_description": str(interface.get("longDescription") or description),
        "category": str(interface.get("category") or "Other"),
        "author": {
            "name": str(author.get("name") or interface.get("developerName") or ""),
            "url": str(author.get("url") or manifest.get("homepage") or ""),
        },
        "homepage": str(manifest.get("homepage") or ""),
        "repository": str(manifest.get("repository") or ""),
        "license": str(manifest.get("license") or ""),
        "skills": skills,
        "skill_errors": skill_errors,
        "mcp_servers": mcp_servers,
        "scripts": scripts,
        "unsupported": unsupported,
        "manifest": manifest,
    }


def _normalize_mcp_config(raw: dict[str, Any]) -> dict[str, Any]:
    url = str(raw.get("url") or "").strip()
    command = str(raw.get("command") or "").strip()
    if bool(url) == bool(command):
        raise ExtensionError("MCP server must declare exactly one of url or command")
    if url:
        parsed = urlparse(url)
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            raise ExtensionError("MCP URL must use http or https")
        if parsed.scheme == "http" and parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
            raise ExtensionError("remote MCP URLs must use HTTPS")
        transport = "streamable_http"
    else:
        transport = "stdio"
    args = raw.get("args") if isinstance(raw.get("args"), list) else []
    env = raw.get("env") if isinstance(raw.get("env"), dict) else {}
    headers = raw.get("http_headers") if isinstance(raw.get("http_headers"), dict) else (
        raw.get("headers") if isinstance(raw.get("headers"), dict) else {}
    )
    env_headers = raw.get("env_http_headers") if isinstance(raw.get("env_http_headers"), dict) else {}
    enabled_tools = raw.get("enabled_tools") if isinstance(raw.get("enabled_tools"), list) else []
    disabled_tools = raw.get("disabled_tools") if isinstance(raw.get("disabled_tools"), list) else []
    enabled_resources = raw.get("enabled_resources") if isinstance(raw.get("enabled_resources"), list) else []
    enabled_prompts = raw.get("enabled_prompts") if isinstance(raw.get("enabled_prompts"), list) else []
    oauth_raw = raw.get("oauth") if isinstance(raw.get("oauth"), dict) else {}
    oauth = {
        "issuer": str(oauth_raw.get("issuer") or "").rstrip("/"),
        "authorization_endpoint": str(oauth_raw.get("authorization_endpoint") or ""),
        "token_endpoint": str(oauth_raw.get("token_endpoint") or ""),
        "client_id": str(oauth_raw.get("client_id") or ""),
        "scopes": [str(value) for value in oauth_raw.get("scopes", [])]
        if isinstance(oauth_raw.get("scopes"), list) else [],
        "redirect_uri": str(oauth_raw.get("redirect_uri") or "locus://mcp/oauth"),
    }
    auth = str(raw.get("auth") or ("bearer" if raw.get("bearer_token_env_var") else "none")).lower()
    if auth not in {"none", "bearer", "headers", "oauth", "auto"}:
        raise ExtensionError("MCP auth must be none, bearer, headers, oauth, or auto")
    if auth == "oauth":
        if oauth["issuer"]:
            issuer = urlparse(oauth["issuer"])
            if issuer.scheme != "https" or not issuer.hostname \
                    or issuer.username or issuer.password or issuer.query or issuer.fragment:
                raise ExtensionError("OAuth issuer must be a credential-free HTTPS URL")
        for field in ("authorization_endpoint", "token_endpoint"):
            endpoint = urlparse(oauth[field])
            if endpoint.scheme != "https" or not endpoint.hostname:
                raise ExtensionError(f"OAuth {field} must use HTTPS")
        if not oauth["client_id"]:
            raise ExtensionError("OAuth client_id is required")
        redirect = urlparse(oauth["redirect_uri"])
        if redirect.scheme != "locus":
            raise ExtensionError("OAuth redirect_uri must use the locus callback scheme")
    try:
        startup_timeout = max(1, min(int(raw.get("startup_timeout_sec") or 10), 120))
        tool_timeout = max(1, min(int(raw.get("tool_timeout_sec") or 60), 600))
    except (TypeError, ValueError) as exc:
        raise ExtensionError("MCP timeouts must be whole numbers") from exc
    return {
        "transport": transport,
        "url": url,
        "command": command,
        "args": [str(value) for value in args[:100]],
        "cwd": str(raw.get("cwd") or ""),
        # Values from plugin files are configuration, not secrets supplied by
        # the app. They remain visible in the install trust review.
        "env": {str(key): str(value) for key, value in env.items()},
        "env_vars": [str(value) for value in raw.get("env_vars", [])]
        if isinstance(raw.get("env_vars"), list) else [],
        "http_headers": {str(key): str(value) for key, value in headers.items()},
        "env_http_headers": {str(key): str(value) for key, value in env_headers.items()},
        "bearer_token_env_var": str(raw.get("bearer_token_env_var") or ""),
        "startup_timeout_sec": startup_timeout,
        "tool_timeout_sec": tool_timeout,
        "enabled": bool(raw.get("enabled", True)),
        "enabled_tools": [str(value) for value in enabled_tools],
        "disabled_tools": [str(value) for value in disabled_tools],
        # Resources are evidence and are discoverable by default. Prompts are
        # instructions, so their allowlist deliberately defaults to empty.
        "enabled_resources": [str(value) for value in enabled_resources],
        "enabled_prompts": [str(value) for value in enabled_prompts],
        "approval_mode": str(raw.get("default_tools_approval_mode") or "annotations").lower(),
        "tool_policies": raw.get("tools") if isinstance(raw.get("tools"), dict) else {},
        "status": "disconnected",
        "error": None,
        "tools": [],
        "requires_auth": auth != "none" or bool(raw.get("bearer_token_env_var")),
        "auth": auth,
        "oauth": oauth if auth in {"oauth", "auto"} else None,
    }


def discover_oauth_metadata(raw: dict[str, Any]) -> dict[str, Any]:
    """Resolve and validate an explicitly configured OAuth issuer."""
    value = dict(raw)
    oauth = dict(value.get("oauth") or {})
    issuer = str(oauth.get("issuer") or "").rstrip("/")
    if str(value.get("auth") or "").lower() != "oauth" or not issuer:
        return value
    parsed = urlparse(issuer)
    if parsed.scheme != "https" or not parsed.hostname \
            or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ExtensionError("OAuth issuer must be a credential-free HTTPS URL")
    metadata_url = issuer + "/.well-known/oauth-authorization-server"
    try:
        response = requests.get(
            metadata_url,
            headers={"Accept": "application/json"},
            timeout=(5, 15),
            allow_redirects=False,
        )
    except requests.RequestException as exc:
        raise ExtensionError(f"OAuth metadata discovery failed: {exc}") from exc
    if 300 <= response.status_code < 400:
        raise ExtensionError("OAuth metadata redirects are not followed")
    if response.status_code != 200 or len(response.content) > MAX_OAUTH_METADATA_BYTES:
        raise ExtensionError("OAuth metadata discovery returned an invalid response")
    try:
        metadata = response.json()
    except (ValueError, requests.JSONDecodeError) as exc:
        raise ExtensionError("OAuth metadata is not valid JSON") from exc
    if not isinstance(metadata, dict) or str(metadata.get("issuer") or "").rstrip("/") != issuer:
        raise ExtensionError("OAuth metadata issuer does not exactly match the configured issuer")
    for key in ("authorization_endpoint", "token_endpoint"):
        endpoint = str(metadata.get(key) or "")
        parsed_endpoint = urlparse(endpoint)
        if parsed_endpoint.scheme != "https" or not parsed_endpoint.hostname:
            raise ExtensionError(f"OAuth metadata has no valid {key}")
        configured = str(oauth.get(key) or "")
        if configured and configured != endpoint:
            raise ExtensionError(f"configured OAuth {key} does not match issuer metadata")
        oauth[key] = endpoint
    oauth["issuer"] = issuer
    value["oauth"] = oauth
    return value


class ExtensionManager:
    """Persistent extension catalog and validated filesystem access."""

    def __init__(
        self,
        cwd: str,
        root: Path | None = None,
        *,
        sandboxed: bool | None = None,
    ) -> None:
        self.cwd = str(Path(cwd).expanduser())
        self.root = (root or APP_DIR / "extensions").expanduser()
        self.state_path = self.root / "state.json"
        self.plugins_root = self.root / "plugins/cache"
        self.plugin_data_root = self.root / "plugins/data"
        self.marketplaces_root = self.root / "marketplaces"
        self.skills_root = self.root / "skills"
        self.sandboxed = bool(os.environ.get("APP_SANDBOX_CONTAINER_ID")) \
            if sandboxed is None else sandboxed
        self._guard = threading.RLock()
        # Before _load_state, which reports a degraded read through it.
        self._errors: list[str] = []
        self._state = self._load_state()
        if self._migrate_state():
            self._save()
        self._credential_values: dict[str, dict[str, Any]] = {}
        self.discover_workspace_marketplaces()

    @staticmethod
    def _defaults() -> dict[str, Any]:
        return {
            "version": 3,
            "marketplaces": [],
            "plugins": [],
            "standalone_skills": [],
            "builtin_skill_overrides": [],
            "mcp_servers": [],
            "mcp_policies": {},
        }

    def _load_state(self) -> dict[str, Any]:
        """Read the on-disk state, degrading to defaults rather than failing.

        A degraded read is recorded in ``self._errors`` so the snapshot can say
        so. Clients treat a snapshot with errors as possibly-partial — the app
        reclaims orphaned MCP credentials against this list, and reclaiming
        against a silently empty one would delete live OAuth tokens. No file at
        all is not a degradation: that is a first run, and the empty lists are
        the truth.
        """
        defaults = self._defaults()
        try:
            if not self.state_path.is_file():
                return defaults
            value = _read_json(self.state_path, 4 * 1024 * 1024)
        except ExtensionError as exc:
            self._errors.append(
                f"Extension state at {self.state_path} could not be read ({exc}). "
                "Installed extensions are not listed."
            )
            return defaults
        for key in (
            "marketplaces", "plugins", "standalone_skills",
            "builtin_skill_overrides", "mcp_servers",
        ):
            if isinstance(value.get(key), list):
                defaults[key] = value[key]
            elif key in value:
                self._errors.append(
                    f"Extension state key {key!r} is not a list; that section is not listed."
                )
        if isinstance(value.get("mcp_policies"), dict):
            defaults["mcp_policies"] = value["mcp_policies"]
        return defaults

    def _migrate_state(self) -> bool:
        """Restore preset provenance without touching auth material or user scope."""
        changed = self._state.get("version") != 3
        self._state["version"] = 3
        github = next(item for item in MCP_PRESETS if item.get("id") == "github")
        canonical_url = str(github["url"]).rstrip("/")
        for record in self._state.get("mcp_servers") or []:
            if not isinstance(record, dict):
                continue
            is_github_preset = record.get("preset_id") == "github"
            is_canonical_github = (
                str(record.get("name") or "").lower() == "github"
                and str(record.get("url") or "").rstrip("/") == canonical_url
            )
            if not (is_github_preset or is_canonical_github):
                continue
            restored = {
                "preset_id": "github",
                "oauth_strategy": "github_device",
                "auth_fallback": github.get("fallback"),
                "preset_provenance": {
                    "catalog_version": MCP_CATALOG_VERSION,
                    "template_url": github["url"],
                    "source_url": github.get("source_url"),
                },
            }
            for key, value in restored.items():
                if record.get(key) != value:
                    record[key] = value
                    changed = True
        return changed

    def _save(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        temporary = self.state_path.with_suffix(f".json.{uuid.uuid4().hex}.tmp")
        temporary.write_text(json.dumps(self._state, indent=2) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.state_path)

    def set_cwd(self, cwd: str) -> None:
        self.cwd = str(Path(cwd).expanduser())
        self.discover_workspace_marketplaces()

    def discover_workspace_marketplaces(self) -> None:
        """Register the nearest repository's Codex marketplace automatically."""
        current = Path(self.cwd).expanduser()
        discovered_root: Path | None = None
        while current.is_dir():
            if (current / ".agents/plugins/marketplace.json").is_file():
                discovered_root = current.resolve()
                break
            if (current / ".git").exists() or current.parent == current:
                break
            current = current.parent
        with self._guard:
            retained = [
                item for item in self._state["marketplaces"]
                if not item.get("workspace_discovered")
                or (discovered_root is not None and item.get("source") == str(discovered_root))
            ]
            changed = len(retained) != len(self._state["marketplaces"])
            self._state["marketplaces"] = retained
            if discovered_root is not None and not any(
                item.get("workspace_discovered") and item.get("source") == str(discovered_root)
                for item in retained
            ):
                identifier = "workspace-" + hashlib.sha256(
                    str(discovered_root).encode()
                ).hexdigest()[:10]
                self._state["marketplaces"].append({
                    "id": identifier,
                    "name": f"{discovered_root.name} Workspace",
                    "kind": "local",
                    "source": str(discovered_root),
                    "ref": "",
                    "sparse_paths": [],
                    "root": str(discovered_root),
                    "catalog_name": "",
                    "catalog": [],
                    "last_refreshed": None,
                    "error": None,
                    "workspace_discovered": True,
                })
                changed = True
            if changed:
                self._save()
        if discovered_root is not None:
            record = next(
                (item for item in self._state["marketplaces"] if item.get("workspace_discovered")),
                None,
            )
            if record:
                self.refresh_marketplace(str(record["id"]))

    def capabilities(self) -> dict[str, Any]:
        return {
            "streamable_http": True,
            "stdio": not self.sandboxed,
            "oauth": True,
            "mcp_apps": False,
            "hooks": False,
            "npm_marketplaces": False,
            "ssh_marketplaces": False,
            "sandboxed": self.sandboxed,
        }

    def snapshot(self) -> dict[str, Any]:
        with self._guard:
            skills = self.skills()
            servers = self.mcp_servers()
            return {
                "capabilities": self.capabilities(),
                "marketplaces": [dict(item) for item in self._state["marketplaces"]],
                "plugins": [self._plugin_view(item) for item in self._state["plugins"]],
                "skills": skills,
                "mcp_servers": [self._public_server(server) for server in servers],
                "mcp_presets": self.mcp_presets(),
                "errors": list(self._errors),
            }

    # ----------------------------------------------------------- marketplaces

    def add_marketplace(
        self,
        source: str,
        *,
        name: str = "",
        ref: str = "",
        sparse_paths: list[str] | None = None,
    ) -> dict[str, Any]:
        normalized = source.strip()
        if not normalized:
            raise ExtensionError("marketplace source is required")
        kind, location, embedded_ref = self._normalize_marketplace_source(normalized)
        ref = ref.strip() or embedded_ref
        marketplace_id = _slug(name or Path(location.rstrip("/")).stem or "marketplace")
        existing_ids = {str(item.get("id")) for item in self._state["marketplaces"]}
        base_id = marketplace_id
        suffix = 2
        while marketplace_id in existing_ids:
            marketplace_id = f"{base_id}-{suffix}"
            suffix += 1
        record = {
            "id": marketplace_id,
            "name": name.strip() or marketplace_id.replace("-", " ").title(),
            "kind": kind,
            "source": location,
            "ref": ref,
            "sparse_paths": [str(value) for value in (sparse_paths or [])],
            "root": "",
            "catalog_name": "",
            "catalog": [],
            "last_refreshed": None,
            "error": None,
            "workspace_discovered": False,
        }
        with self._guard:
            self._state["marketplaces"].append(record)
            self._save()
        return self.refresh_marketplace(marketplace_id)

    def _normalize_marketplace_source(self, value: str) -> tuple[str, str, str]:
        path = Path(value).expanduser()
        if path.exists():
            if not path.is_dir():
                raise ExtensionError("local marketplace source must be a directory")
            return "local", str(path.resolve()), ""
        if _GITHUB_RE.fullmatch(value):
            owner_repo, _, ref = value.partition("@")
            return "git", f"https://github.com/{owner_repo}.git", ref
        parsed = urlparse(value)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ExtensionError("remote marketplaces must use an HTTPS Git URL")
        return "git", value, ""

    def refresh_marketplace(self, marketplace_id: str) -> dict[str, Any]:
        with self._guard:
            record = self._marketplace(marketplace_id)
            try:
                root = self._materialize_marketplace(record)
                catalog_path = self._marketplace_file(root)
                raw = _read_json(catalog_path, MAX_MARKETPLACE_BYTES)
                plugins = raw.get("plugins")
                if not isinstance(plugins, list):
                    raise ExtensionError("marketplace.json must contain a plugins array")
                catalog = []
                for entry in plugins:
                    try:
                        catalog.append(self._normalize_catalog_entry(entry, root, record["id"]))
                    except ExtensionError as exc:
                        invalid_id = f"{record['id']}/invalid-{len(catalog) + 1}"
                        catalog.append({
                            "id": invalid_id,
                            "name": "Invalid entry",
                            "marketplace_id": record["id"],
                            "category": "Other",
                            "source": {},
                            "available": False,
                            "error": str(exc),
                        })
                interface = raw.get("interface") if isinstance(raw.get("interface"), dict) else {}
                record["catalog_name"] = str(interface.get("displayName") or raw.get("name") or record["name"])
                record["catalog"] = catalog
                record["root"] = str(root)
                record["last_refreshed"] = __import__("datetime").datetime.now().astimezone().isoformat()
                record["error"] = None
            except ExtensionError as exc:
                record["error"] = str(exc)
            self._save()
            return dict(record)

    def _materialize_marketplace(self, record: dict[str, Any]) -> Path:
        if record.get("kind") == "local":
            root = Path(str(record.get("source") or "")).expanduser()
            if not root.is_dir():
                raise ExtensionError("local marketplace folder is unavailable")
            return root.resolve()
        destination = self.marketplaces_root / str(record["id"])
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix=f".{record['id']}.", dir=destination.parent))
        try:
            command = [
                "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "clone",
                "--depth", "1", "--no-tags", "--no-recurse-submodules",
            ]
            sparse = record.get("sparse_paths") or []
            if sparse:
                command += ["--filter=blob:none", "--sparse"]
            command += [str(record["source"]), str(temporary)]
            self._run_git(command)
            if record.get("ref"):
                self._run_git([
                    "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(temporary),
                    "fetch", "--depth", "1", "origin", str(record["ref"]),
                ])
                self._run_git([
                    "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(temporary),
                    "checkout", "--detach", "FETCH_HEAD",
                ])
            if sparse:
                self._run_git([
                    "/usr/bin/git", "-C", str(temporary), "sparse-checkout", "set", "--",
                    *[str(value) for value in sparse],
                ])
            _tree_digest(temporary)
            previous = destination.with_name(destination.name + ".previous")
            if previous.exists():
                shutil.rmtree(previous)
            if destination.exists():
                destination.replace(previous)
            try:
                temporary.replace(destination)
            except Exception:
                if previous.exists() and not destination.exists():
                    previous.replace(destination)
                raise
            if previous.exists():
                shutil.rmtree(previous)
            return destination
        except Exception:
            if temporary.exists():
                shutil.rmtree(temporary, ignore_errors=True)
            raise

    @staticmethod
    def _run_git(command: list[str]) -> str:
        try:
            completed = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=180,
                # Marketplace clones go through the proxy like everything
                # else, but the credential stays out of the child.
                env=sanitized_child_environment(
                    {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
                ),
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ExtensionError(f"Git failed: {exc}") from exc
        output = completed.stdout[-MAX_GIT_OUTPUT:].strip()
        if completed.returncode != 0:
            raise ExtensionError(output or f"Git exited with {completed.returncode}")
        return output

    @staticmethod
    def _marketplace_file(root: Path) -> Path:
        for relative in (".agents/plugins/marketplace.json", "marketplace.json"):
            candidate = root / relative
            if candidate.is_file():
                return candidate
        raise ExtensionError("marketplace source has no .agents/plugins/marketplace.json")

    def _normalize_catalog_entry(
        self, entry: Any, root: Path, marketplace_id: str
    ) -> dict[str, Any]:
        if not isinstance(entry, dict):
            raise ExtensionError("marketplace plugin entry must be an object")
        name = _safe_name(entry.get("name"), "marketplace plugin name")
        source = entry.get("source")
        if isinstance(source, str):
            source = {"source": "local", "path": source}
        if not isinstance(source, dict):
            raise ExtensionError(f"plugin {name} has no source")
        source_kind = str(source.get("source") or "local")
        available = source_kind in {"local", "url", "git-subdir"}
        error = None
        if source_kind == "npm":
            error = "npm plugin sources are not supported in Locus V1"
        elif source_kind not in {"local", "url", "git-subdir"}:
            error = f"unsupported plugin source: {source_kind}"
        normalized_source = {key: str(value) for key, value in source.items() if key in {
            "source", "path", "url", "ref", "sha"
        }}
        policy = entry.get("policy") if isinstance(entry.get("policy"), dict) else {}
        installation = str(policy.get("installation") or "AVAILABLE")
        if installation == "NOT_AVAILABLE":
            available = False
            error = error or "plugin is not available from this marketplace"
        return {
            "id": f"{marketplace_id}/{name}",
            "name": name,
            "marketplace_id": marketplace_id,
            "category": str(entry.get("category") or "Other"),
            "source": normalized_source,
            "available": available,
            "error": error,
            "authentication": str(policy.get("authentication") or "ON_INSTALL"),
            "marketplace_root": str(root),
        }

    def catalog(self, query: str = "", marketplace_id: str = "") -> list[dict[str, Any]]:
        term = query.strip().lower()
        installed = {str(item.get("id")): item for item in self._state["plugins"]}
        out: list[dict[str, Any]] = []
        for marketplace in self._state["marketplaces"]:
            if marketplace_id and marketplace.get("id") != marketplace_id:
                continue
            for entry in marketplace.get("catalog") or []:
                item = dict(entry)
                plugin = installed.get(str(item.get("id")))
                item["installed"] = plugin is not None
                item["installed_version"] = plugin.get("version") if plugin else None
                item["display_name"] = str(item.get("name") or "").replace("-", " ").title()
                item["description"] = ""
                if item.get("available") and item.get("source", {}).get("source") == "local":
                    try:
                        parsed = parse_plugin(self._catalog_local_path(item))
                        item.update({
                            "display_name": parsed["display_name"],
                            "description": parsed["description"],
                            "version": parsed["version"],
                            "author": parsed["author"].get("name") or None,
                            "capabilities": self._trust_summary(parsed),
                        })
                    except ExtensionError as exc:
                        item["available"] = False
                        item["error"] = str(exc)
                haystack = f"{item.get('name', '')} {item.get('display_name', '')} {item.get('description', '')} {item.get('category', '')}".lower()
                if not term or term in haystack:
                    out.append(item)
        return out

    def remove_marketplace(self, marketplace_id: str) -> None:
        with self._guard:
            if any(item.get("marketplace_id") == marketplace_id for item in self._state["plugins"]):
                raise ExtensionError("uninstall this marketplace's plugins before removing it")
            before = len(self._state["marketplaces"])
            self._state["marketplaces"] = [
                item for item in self._state["marketplaces"] if item.get("id") != marketplace_id
            ]
            if len(self._state["marketplaces"]) == before:
                raise ExtensionError("marketplace not found")
            snapshot = self.marketplaces_root / marketplace_id
            if snapshot.exists():
                shutil.rmtree(snapshot, ignore_errors=True)
            self._save()

    # --------------------------------------------------------------- plugins

    def inspect_catalog_plugin(self, marketplace_id: str, plugin_name: str) -> dict[str, Any]:
        entry = self._catalog_entry(marketplace_id, plugin_name)
        root, cleanup = self._materialize_catalog_plugin(entry)
        try:
            parsed = parse_plugin(root)
            digest = _tree_digest(root)
            return {
                "plugin": self._parsed_plugin_view(parsed),
                "digest": digest,
                "trust": self._trust_summary(parsed),
                "source": entry.get("source"),
                "capability_diff": self._capability_diff(
                    f"{marketplace_id}/{parsed['name']}", parsed
                ),
            }
        finally:
            if cleanup:
                shutil.rmtree(root, ignore_errors=True)

    def install_plugin(
        self,
        marketplace_id: str,
        plugin_name: str,
        *,
        scope: str = "global",
        workspace: str = "",
        expected_digest: str = "",
    ) -> dict[str, Any]:
        entry = self._catalog_entry(marketplace_id, plugin_name)
        source_root, cleanup = self._materialize_catalog_plugin(entry)
        try:
            parsed = parse_plugin(source_root)
            digest = _tree_digest(source_root)
            if not expected_digest:
                raise ExtensionError("a trust-review digest is required before installation")
            if expected_digest != digest:
                raise ExtensionError("plugin changed after trust review; review it again")
            version = _slug(str(parsed["version"]), "local")
            destination = self.plugins_root / marketplace_id / parsed["name"] / version
            destination.parent.mkdir(parents=True, exist_ok=True)
            plugin_id = f"{marketplace_id}/{parsed['name']}"
            previous = next(
                (item for item in self._state["plugins"] if item.get("id") == plugin_id), None
            )
            if destination.exists() and _tree_digest(destination) != digest:
                destination = destination.with_name(f"{version}-{digest[:12]}")
            if not destination.exists():
                temporary = Path(tempfile.mkdtemp(prefix=".install.", dir=destination.parent))
                try:
                    shutil.copytree(source_root, temporary / "plugin", symlinks=True, dirs_exist_ok=True)
                    copied = temporary / "plugin"
                    copied_digest = _tree_digest(copied)
                    if copied_digest != digest:
                        raise ExtensionError("plugin contents changed while being installed")
                    copied.replace(destination)
                finally:
                    shutil.rmtree(temporary, ignore_errors=True)
            record = {
                "id": plugin_id,
                "marketplace_id": marketplace_id,
                "name": parsed["name"],
                "version": parsed["version"],
                "root": str(destination),
                "digest": digest,
                "source": entry.get("source"),
                "enabled_global": scope == "global",
                "enabled_workspaces": [self._workspace(workspace)] if scope == "workspace" else [],
                "disabled_workspaces": [],
                "previous": [],
                "installed_at": __import__("datetime").datetime.now().astimezone().isoformat(),
            }
            with self._guard:
                if previous:
                    history = list(previous.get("previous") or [])
                    if previous.get("digest") != digest:
                        history.insert(0, {
                            "version": previous.get("version"),
                            "root": previous.get("root"),
                            "digest": previous.get("digest"),
                        })
                    record["previous"] = history[:2]
                    record["enabled_global"] = bool(previous.get("enabled_global"))
                    record["enabled_workspaces"] = list(previous.get("enabled_workspaces") or [])
                    record["disabled_workspaces"] = list(previous.get("disabled_workspaces") or [])
                    self._state["plugins"] = [
                        item for item in self._state["plugins"] if item.get("id") != plugin_id
                    ]
                self._state["plugins"].append(record)
                self._save()
            return self._plugin_view(record)
        finally:
            if cleanup:
                shutil.rmtree(source_root, ignore_errors=True)

    def update_plugin(self, identifier: str, *, expected_digest: str) -> dict[str, Any]:
        """Update an installed plugin after a fresh capability/trust review."""
        record = self._plugin(identifier)
        return self.install_plugin(
            str(record.get("marketplace_id") or ""),
            str(record.get("name") or ""),
            expected_digest=expected_digest,
        )

    def _materialize_catalog_plugin(self, entry: dict[str, Any]) -> tuple[Path, bool]:
        source = entry.get("source") or {}
        kind = str(source.get("source") or "local")
        if kind == "local":
            return self._catalog_local_path(entry), False
        url = str(source.get("url") or "").strip()
        if not url:
            raise ExtensionError("Git plugin source is missing its URL")
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ExtensionError("Git plugin URL must use HTTPS")
        temporary = Path(tempfile.mkdtemp(prefix="locus-plugin-"))
        command = [
            "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "clone", "--depth", "1",
            "--no-tags", "--no-recurse-submodules",
        ]
        ref = str(source.get("sha") or source.get("ref") or "").strip()
        command += [url, str(temporary)]
        try:
            self._run_git(command)
            if ref:
                self._run_git([
                    "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(temporary),
                    "fetch", "--depth", "1", "origin", ref,
                ])
                self._run_git([
                    "/usr/bin/git", "-c", "core.hooksPath=/dev/null", "-C", str(temporary),
                    "checkout", "--detach", "FETCH_HEAD",
                ])
            root = temporary
            if kind == "git-subdir":
                raw_path = str(source.get("path") or "").strip()
                if not raw_path.startswith("./"):
                    raise ExtensionError("git-subdir path must start with './'")
                root = temporary / raw_path[2:]
                if not _inside(temporary, root) or not root.is_dir():
                    raise ExtensionError("git-subdir path is unavailable or unsafe")
            elif (temporary / ".git").exists():
                shutil.rmtree(temporary / ".git")
            return root, True
        except Exception:
            shutil.rmtree(temporary, ignore_errors=True)
            raise

    @staticmethod
    def _catalog_local_path(entry: dict[str, Any]) -> Path:
        root = Path(str(entry.get("marketplace_root") or "")).resolve()
        raw = str((entry.get("source") or {}).get("path") or "").strip()
        if not raw.startswith("./"):
            raise ExtensionError("local plugin source path must start with './'")
        candidate = root / raw[2:]
        if not _inside(root, candidate) or not candidate.is_dir():
            raise ExtensionError("local plugin source is unavailable or escapes its marketplace")
        return candidate

    def set_plugin_enabled(
        self,
        plugin_id: str,
        enabled: bool,
        *,
        scope: str = "global",
        workspace: str = "",
    ) -> dict[str, Any]:
        with self._guard:
            record = self._plugin(plugin_id)
            self._set_scope(record, enabled, scope, workspace)
            self._save()
            return self._plugin_view(record)

    def rollback_plugin(self, plugin_id: str) -> dict[str, Any]:
        with self._guard:
            record = self._plugin(plugin_id)
            previous = list(record.get("previous") or [])
            if not previous:
                raise ExtensionError("no previous plugin version is available")
            target = previous.pop(0)
            current = {
                "version": record.get("version"),
                "root": record.get("root"),
                "digest": record.get("digest"),
            }
            record.update(target)
            record["previous"] = [current, *previous][:2]
            self._save()
            return self._plugin_view(record)

    def uninstall_plugin(self, plugin_id: str) -> None:
        with self._guard:
            record = self._plugin(plugin_id)
            roots = [record.get("root")] + [item.get("root") for item in record.get("previous") or []]
            self._state["plugins"] = [
                item for item in self._state["plugins"] if item.get("id") != plugin_id
            ]
            self._save()
        for raw in roots:
            if raw:
                root = Path(str(raw))
                if _inside(self.plugins_root, root):
                    shutil.rmtree(root, ignore_errors=True)

    # ---------------------------------------------------------------- skills

    def import_skill(
        self,
        source: str,
        *,
        scope: str = "global",
        workspace: str = "",
    ) -> dict[str, Any]:
        source_root = Path(source).expanduser().resolve()
        skill_file = source_root / "SKILL.md" if source_root.is_dir() else source_root
        parsed = parse_skill(skill_file, source="imported")
        destination = self.skills_root / parsed["name"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = Path(tempfile.mkdtemp(prefix=".skill.", dir=destination.parent))
        try:
            shutil.copytree(skill_file.parent, temporary / "skill", symlinks=True, dirs_exist_ok=True)
            _tree_digest(temporary / "skill")
            if destination.exists():
                shutil.rmtree(destination)
            (temporary / "skill").replace(destination)
        finally:
            shutil.rmtree(temporary, ignore_errors=True)
        record = {
            "id": parsed["name"],
            "name": parsed["name"],
            "root": str(destination),
            "enabled_global": scope == "global",
            "enabled_workspaces": [self._workspace(workspace)] if scope == "workspace" else [],
            "disabled_workspaces": [],
        }
        with self._guard:
            self._state["standalone_skills"] = [
                item for item in self._state["standalone_skills"] if item.get("id") != record["id"]
            ]
            self._state["standalone_skills"].append(record)
            self._save()
        return next(item for item in self.skills() if item["id"] == record["id"])

    def skills(self, workspace: str = "") -> list[dict[str, Any]]:
        workspace = self._workspace(workspace)
        records: list[dict[str, Any]] = []
        errors: list[dict[str, Any]] = []
        for item in self._state["standalone_skills"]:
            try:
                parsed = parse_skill(Path(str(item["root"])) / "SKILL.md", source="imported")
                parsed["enabled"] = self._active(item, workspace)
                parsed["enabled_global"] = bool(item.get("enabled_global"))
                parsed["enabled_workspaces"] = list(item.get("enabled_workspaces") or [])
                parsed["disabled_workspaces"] = list(item.get("disabled_workspaces") or [])
                records.append(parsed)
            except ExtensionError as exc:
                errors.append(self._skill_error(str(item.get("id") or "skill"), "imported", str(exc)))
        for plugin in self._state["plugins"]:
            try:
                parsed_plugin = parse_plugin(Path(str(plugin["root"])))
                for skill in parsed_plugin["skills"]:
                    skill["id"] = f"{plugin['name']}:{skill['name']}"
                    skill["plugin_id"] = plugin["id"]
                    skill["enabled"] = self._active(plugin, workspace)
                    records.append(skill)
                for message in parsed_plugin["skill_errors"]:
                    errors.append(self._skill_error(str(plugin["name"]), "plugin", message))
            except ExtensionError as exc:
                errors.append(self._skill_error(str(plugin.get("name") or "plugin"), "plugin", str(exc)))
        records.extend(self._repo_skills(workspace))
        # A user-controlled copy always wins by name. The built-in remains in
        # Settings for provenance and toggling, but is suppressed from the
        # agent index so an unqualified invocation cannot become ambiguous.
        user_names = {str(item.get("name")) for item in records if not item.get("error")}
        for skill_file in sorted(BUILTIN_SKILLS_ROOT.glob("*/SKILL.md")):
            try:
                parsed = parse_skill(skill_file, source="builtin")
                parsed["id"] = f"builtin:{parsed['name']}"
                override = next(
                    (
                        item for item in self._state["builtin_skill_overrides"]
                        if item.get("id") == parsed["id"]
                    ),
                    None,
                ) or {
                    "id": parsed["id"],
                    "enabled_global": True,
                    "enabled_workspaces": [],
                    "disabled_workspaces": [],
                }
                parsed["enabled"] = self._active(override, workspace) \
                    and parsed["name"] not in user_names
                parsed["enabled_global"] = bool(override.get("enabled_global", True))
                parsed["enabled_workspaces"] = list(override.get("enabled_workspaces") or [])
                parsed["disabled_workspaces"] = list(override.get("disabled_workspaces") or [])
                parsed["builtin"] = True
                parsed["shadowed"] = parsed["name"] in user_names
                metadata_path = skill_file.parent / "SOURCE.json"
                provenance = _read_json(metadata_path, 64_000) \
                    if metadata_path.is_file() else {}
                parsed["provenance"] = provenance
                # Startup activation is a trusted built-in capability. User,
                # workspace, and plugin skills may shadow a built-in but never
                # inherit the right to enter every development prompt.
                activation = str(provenance.get("activation") or parsed["activation"])
                parsed["activation"] = activation \
                    if activation in {"startup", "automatic", "explicit"} \
                    else parsed["activation"]
                if parsed["activation"] == "explicit":
                    parsed["allow_implicit_invocation"] = False
                records.append(parsed)
            except ExtensionError as exc:
                errors.append(self._skill_error(skill_file.parent.name, "builtin", str(exc)))
        # Namespaced ids remain unique. Unnamespaced duplicates are retained
        # in the UI, but explicit lookup requires the source-qualified id.
        seen: set[str] = set()
        out: list[dict[str, Any]] = []
        for record in [*records, *errors]:
            identifier = str(record["id"])
            if identifier in seen:
                suffix = hashlib.sha256(str(record.get("path", "")).encode()).hexdigest()[:6]
                record = {**record, "id": f"{identifier}:{suffix}"}
            seen.add(str(record["id"]))
            out.append(record)
        return sorted(out, key=lambda item: (not bool(item.get("enabled")), str(item.get("id"))))

    @staticmethod
    def _skill_error(identifier: str, source: str, message: str) -> dict[str, Any]:
        return {
            "id": identifier,
            "name": identifier,
            "display_name": identifier,
            "description": "",
            "path": "",
            "root": "",
            "source": source,
            "plugin_id": None,
            "allow_implicit_invocation": False,
            "activation": "explicit",
            "enabled": False,
            "error": message,
        }

    def _repo_skills(self, workspace: str) -> list[dict[str, Any]]:
        start = Path(workspace)
        if not start.is_dir():
            return []
        candidates: list[Path] = []
        current = start
        while True:
            candidates.append(current / ".agents/skills")
            if (current / ".git").exists() or current.parent == current:
                break
            current = current.parent
        out: list[dict[str, Any]] = []
        for skills_root in reversed(candidates):
            if not skills_root.is_dir():
                continue
            for skill_file in sorted(skills_root.glob("*/SKILL.md")):
                try:
                    out.append(parse_skill(skill_file, source="workspace"))
                except ExtensionError as exc:
                    out.append(self._skill_error(skill_file.parent.name, "workspace", str(exc)))
        return out

    def skill_index(self, context_window: int = 0, workspace: str = "") -> str:
        limit = min(context_window * 8 // 100, 8_000) if context_window else 8_000
        lines = [
            "Available skills (call load_skill before following an automatically selected skill):"
        ]
        for skill in self.skills(workspace):
            if not skill.get("enabled") or skill.get("error"):
                continue
            if skill.get("activation") == "startup":
                # Already present in the turn context; do not spend eager-index
                # tokens advertising startup skills a second time.
                continue
            policy = " [explicit invocation only]" if not skill.get("allow_implicit_invocation", True) else ""
            path = str(skill.get("path") or "")
            location = f" ({path})" if path else ""
            invocation = skill["name"] if skill.get("builtin") else skill["id"]
            line = f"- ${invocation}{policy}{location}: {skill['description']}"
            if len("\n".join([*lines, line])) > limit:
                lines.append("- … additional skills omitted to protect the context window")
                break
            lines.append(line)
        return "\n".join(lines) if len(lines) > 1 else ""

    def startup_skills(self, workspace: str = "") -> list[dict[str, Any]]:
        """Return enabled trusted startup skills in deterministic policy order."""
        return sorted(
            (
                item for item in self.skills(workspace)
                if item.get("enabled")
                and not item.get("error")
                and item.get("builtin") is True
                and item.get("activation") == "startup"
            ),
            key=lambda item: (
                int((item.get("provenance") or {}).get("startup_order") or 1_000),
                str(item.get("id") or ""),
            ),
        )

    def explicit_skill_ids(self, text: str, workspace: str = "") -> list[str]:
        enabled = [item for item in self.skills(workspace) if item.get("enabled")]
        available = {str(item["id"]).lower(): str(item["id"]) for item in enabled}
        by_name: dict[str, list[str]] = {}
        for item in enabled:
            by_name.setdefault(str(item["name"]).lower(), []).append(str(item["id"]))
        for name, identifiers in by_name.items():
            if len(identifiers) == 1:
                available[name] = identifiers[0]
        return [available[name.lower()] for name in _SKILL_MENTION_RE.findall(text) if name.lower() in available]

    def load_skill(self, identifier: str, workspace: str = "") -> str:
        skill = self._skill(identifier, workspace)
        path = Path(str(skill["path"]))
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise ExtensionError(f"cannot load skill {identifier}: {exc}") from exc
        resources = [
            item.relative_to(path.parent).as_posix()
            for item in sorted(path.parent.rglob("*"))
            if item.is_file() and item != path
        ][:200]
        suffix = "\n\nSupporting files:\n" + "\n".join(f"- {item}" for item in resources) if resources else ""
        return text + suffix

    def read_skill_file(self, identifier: str, relative_path: str, workspace: str = "") -> str:
        skill = self._skill(identifier, workspace)
        root = Path(str(skill["root"])).resolve()
        candidate = root / relative_path
        if not relative_path or Path(relative_path).is_absolute() or not _inside(root, candidate):
            raise ExtensionError("skill resource path must stay inside the skill")
        if not candidate.is_file():
            raise ExtensionError(f"skill resource not found: {relative_path}")
        if candidate.stat().st_size > MAX_SKILL_RESOURCE_BYTES:
            raise ExtensionError("skill resource exceeds the 8 MB text limit")
        raw = candidate.read_bytes()
        if b"\0" in raw[:4096]:
            raise ExtensionError("skill resource is binary")
        return raw.decode("utf-8", errors="replace")

    def remove_skill(self, identifier: str) -> None:
        with self._guard:
            record = next((item for item in self._state["standalone_skills"] if item.get("id") == identifier), None)
            if not record:
                raise ExtensionError("only imported standalone skills can be removed")
            self._state["standalone_skills"].remove(record)
            self._save()
        root = Path(str(record.get("root") or ""))
        if _inside(self.skills_root, root):
            shutil.rmtree(root, ignore_errors=True)

    def set_skill_enabled(
        self,
        identifier: str,
        enabled: bool,
        *,
        scope: str = "global",
        workspace: str = "",
    ) -> dict[str, Any]:
        with self._guard:
            record = next(
                (item for item in self._state["standalone_skills"] if item.get("id") == identifier),
                None,
            )
            if not record:
                builtin_name = identifier.removeprefix("builtin:")
                builtin_id = f"builtin:{builtin_name}"
                builtin = BUILTIN_SKILLS_ROOT / builtin_name / "SKILL.md"
                if not builtin.is_file():
                    raise ExtensionError("only imported or built-in skills can be enabled directly")
                record = next(
                    (
                        item for item in self._state["builtin_skill_overrides"]
                        if item.get("id") == builtin_id
                    ),
                    None,
                )
                if record is None:
                    record = {
                        "id": builtin_id,
                        "enabled_global": True,
                        "enabled_workspaces": [],
                        "disabled_workspaces": [],
                    }
                    self._state["builtin_skill_overrides"].append(record)
            self._set_scope(record, enabled, scope, workspace)
            self._save()
        resolved = identifier if identifier.startswith("builtin:") else f"builtin:{identifier}"
        return next(item for item in self.skills(workspace) if item["id"] in {identifier, resolved})

    # ----------------------------------------------------------- MCP configs

    def mcp_presets(self) -> list[dict[str, Any]]:
        """Return the inert bundled catalog with materialization provenance."""
        installed = {
            str(item.get("preset_id")): str(item.get("id"))
            for item in self._state["mcp_servers"]
            if item.get("preset_id")
        }
        return [
            {
                **preset,
                "catalog_version": MCP_CATALOG_VERSION,
                "installed": preset["id"] in installed,
                "server_id": installed.get(str(preset["id"])),
                "default_tools_approval_mode": "annotations",
                "resources_discoverable": True,
                "prompts_enabled": False,
            }
            for preset in MCP_PRESETS
        ]

    def materialize_mcp_preset(
        self,
        preset_id: str,
        *,
        project_ref: str = "",
    ) -> dict[str, Any]:
        """Copy a reviewed preset into editable, disabled user state once."""
        preset = next((item for item in MCP_PRESETS if item["id"] == preset_id), None)
        if not preset:
            raise ExtensionError("recommended MCP preset not found")
        existing = next(
            (item for item in self._state["mcp_servers"] if item.get("preset_id") == preset_id),
            None,
        )
        if existing:
            return self._public_server(existing)

        url = str(preset["url"])
        if preset.get("requires_project_ref"):
            scoped = project_ref.strip()
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{3,79}", scoped):
                raise ExtensionError("Supabase setup requires a valid project reference")
            url = f"{url}?{urlencode({'project_ref': scoped, 'read_only': 'true'})}"
        identifier = f"user:{preset_id}:preset"
        return self.upsert_mcp_server({
            "name": preset["name"],
            "url": url,
            "auth": preset["auth"],
            "enabled": True,
            "enabled_global": False,
            "default_tools_approval_mode": "annotations",
            "enabled_prompts": [],
            "preset_id": preset_id,
            "auth_fallback": preset.get("fallback"),
            "oauth_strategy": preset.get("oauth_strategy"),
            "fallback_header": preset.get("fallback_header"),
            "optional_header": preset.get("optional_header"),
            "preset_provenance": {
                "catalog_version": MCP_CATALOG_VERSION,
                "template_url": preset["url"],
                "source_url": preset.get("source_url"),
            },
        }, server_id=identifier)

    def mcp_servers(self, workspace: str = "") -> list[dict[str, Any]]:
        workspace = self._workspace(workspace)
        out: list[dict[str, Any]] = []
        for raw in self._state["mcp_servers"]:
            record = dict(raw)
            self._apply_mcp_policy(record)
            record["active"] = self._active(record, workspace) and bool(record.get("enabled", True))
            out.append(record)
        for plugin in self._state["plugins"]:
            try:
                parsed = parse_plugin(Path(str(plugin["root"])))
            except ExtensionError:
                continue
            for server in parsed["mcp_servers"]:
                self._apply_mcp_policy(server)
                server["plugin_id"] = plugin["id"]
                server["plugin_data"] = str(self.plugin_data_root / _slug(plugin["id"]))
                server["enabled_global"] = bool(plugin.get("enabled_global"))
                server["enabled_workspaces"] = list(plugin.get("enabled_workspaces") or [])
                server["disabled_workspaces"] = list(plugin.get("disabled_workspaces") or [])
                server["active"] = self._active(plugin, workspace) and bool(server.get("enabled", True))
                out.append(server)
        return out

    def upsert_mcp_server(self, raw: dict[str, Any], server_id: str = "") -> dict[str, Any]:
        # Standalone secret values are accepted only as transient credentials.
        # Plugin manifests are parsed elsewhere and remain visible in trust review.
        sanitized = discover_oauth_metadata(raw)
        transient_env = sanitized.pop("env", {}) if isinstance(sanitized.get("env"), dict) else {}
        transient_headers = (
            sanitized.pop("http_headers", {})
            if isinstance(sanitized.get("http_headers"), dict) else {}
        )
        config = _normalize_mcp_config(sanitized)
        identifier = server_id or f"user:{_slug(str(raw.get('name') or 'mcp'))}:{uuid.uuid4().hex[:8]}"
        name = _safe_name(raw.get("name") or identifier.split(":")[-2], "MCP server name")
        record = {
            **config,
            "id": identifier,
            "name": name,
            "origin": "user",
            "plugin_id": None,
            "plugin_root": "",
            "plugin_data": str(self.plugin_data_root / _slug(identifier)),
            "enabled_global": bool(raw.get("enabled_global", True)),
            "enabled_workspaces": [str(value) for value in raw.get("enabled_workspaces", [])]
            if isinstance(raw.get("enabled_workspaces"), list) else [],
            "disabled_workspaces": [str(value) for value in raw.get("disabled_workspaces", [])]
            if isinstance(raw.get("disabled_workspaces"), list) else [],
            "preset_id": str(raw.get("preset_id") or "") or None,
            "oauth_strategy": str(raw.get("oauth_strategy") or "") or None,
            "auth_fallback": str(raw.get("auth_fallback") or "") or None,
            "fallback_header": str(raw.get("fallback_header") or "") or None,
            "optional_header": str(raw.get("optional_header") or "") or None,
            "preset_provenance": dict(raw.get("preset_provenance") or {})
            if isinstance(raw.get("preset_provenance"), dict) else {},
        }
        with self._guard:
            self._state["mcp_servers"] = [
                item for item in self._state["mcp_servers"] if item.get("id") != identifier
            ]
            self._state["mcp_servers"].append(record)
            self._save()
        if transient_env or transient_headers:
            existing = self.credentials(identifier)
            self.set_credentials(identifier, {
                **existing,
                "env": {**(existing.get("env") or {}), **transient_env},
                "headers": {**(existing.get("headers") or {}), **transient_headers},
            })
        return self._public_server(record)

    def remove_mcp_server(self, server_id: str) -> None:
        with self._guard:
            before = len(self._state["mcp_servers"])
            self._state["mcp_servers"] = [
                item for item in self._state["mcp_servers"] if item.get("id") != server_id
            ]
            if len(self._state["mcp_servers"]) == before:
                raise ExtensionError("standalone MCP server not found")
            self._credential_values.pop(server_id, None)
            self._save()

    def set_mcp_enabled(
        self,
        server_id: str,
        enabled: bool,
        *,
        scope: str = "global",
        workspace: str = "",
    ) -> dict[str, Any]:
        with self._guard:
            record = next(
                (item for item in self._state["mcp_servers"] if item.get("id") == server_id),
                None,
            )
            if not record:
                raise ExtensionError("standalone MCP server not found")
            self._set_scope(record, enabled, scope, workspace)
            self._save()
            record = dict(record)
            record["active"] = self._active(record, self._workspace(workspace))
            return self._public_server(record)

    def set_mcp_policy(
        self,
        server_id: str,
        mode: str,
        *,
        tool_name: str = "",
    ) -> dict[str, Any]:
        normalized = mode.strip().lower()
        if normalized not in {"annotations", "ask", "allow", "disabled"}:
            raise ExtensionError("tool policy must be annotations, ask, allow, or disabled")
        if not any(server.get("id") == server_id for server in self.mcp_servers()):
            raise ExtensionError("MCP server not found")
        with self._guard:
            policies = self._state.setdefault("mcp_policies", {})
            record = policies.setdefault(server_id, {"default": "annotations", "tools": {}})
            if tool_name:
                record.setdefault("tools", {})[tool_name] = normalized
            else:
                record["default"] = normalized
            self._save()
        server = next(item for item in self.mcp_servers() if item.get("id") == server_id)
        return self._public_server(server)

    def set_credentials(self, server_id: str, values: dict[str, Any]) -> None:
        # Deliberately memory-only. Never call _save from here.
        if not server_id or not any(
            server.get("id") == server_id for server in self.mcp_servers()
        ):
            raise ExtensionError("MCP server not found")
        # Registration records, client secrets, and refresh tokens stay in the
        # native app's user-only credential file. Reject them at this boundary
        # as defense in depth even if a future client accidentally includes them.
        allowed = {"access_token", "headers", "env"}
        self._credential_values[server_id] = {
            key: value for key, value in values.items() if key in allowed
        }

    def credentials(self, server_id: str) -> dict[str, Any]:
        return dict(self._credential_values.get(server_id) or {})

    def _apply_mcp_policy(self, server: dict[str, Any]) -> None:
        policy = (self._state.get("mcp_policies") or {}).get(str(server.get("id"))) or {}
        if policy.get("default"):
            server["approval_mode"] = str(policy["default"])
        configured = dict(server.get("tool_policies") or {})
        configured.update(policy.get("tools") or {})
        server["tool_policies"] = configured

    # --------------------------------------------------------------- helpers

    def _marketplace(self, identifier: str) -> dict[str, Any]:
        record = next((item for item in self._state["marketplaces"] if item.get("id") == identifier), None)
        if not record:
            raise ExtensionError("marketplace not found")
        return record

    def _catalog_entry(self, marketplace_id: str, name: str) -> dict[str, Any]:
        marketplace = self._marketplace(marketplace_id)
        entry = next((item for item in marketplace.get("catalog") or [] if item.get("name") == name), None)
        if not entry:
            raise ExtensionError("plugin not found in marketplace")
        if not entry.get("available"):
            raise ExtensionError(str(entry.get("error") or "plugin is unavailable"))
        return entry

    def _plugin(self, identifier: str) -> dict[str, Any]:
        record = next((item for item in self._state["plugins"] if item.get("id") == identifier), None)
        if not record:
            raise ExtensionError("plugin not installed")
        return record

    def _plugin_view(self, record: dict[str, Any]) -> dict[str, Any]:
        try:
            parsed = parse_plugin(Path(str(record["root"])))
            view = self._parsed_plugin_view(parsed)
            view.update({
                "id": record["id"],
                "marketplace_id": record.get("marketplace_id"),
                "root": record.get("root"),
                "digest": record.get("digest"),
                "enabled_global": bool(record.get("enabled_global")),
                "enabled_workspaces": list(record.get("enabled_workspaces") or []),
                "disabled_workspaces": list(record.get("disabled_workspaces") or []),
                "previous_versions": [item.get("version") for item in record.get("previous") or []],
                "update_available": self._plugin_update_available(record),
                "error": None,
            })
            return view
        except ExtensionError as exc:
            return {
                "id": record.get("id"),
                "name": record.get("name"),
                "version": record.get("version"),
                "enabled_global": bool(record.get("enabled_global")),
                "enabled_workspaces": list(record.get("enabled_workspaces") or []),
                "disabled_workspaces": list(record.get("disabled_workspaces") or []),
                "update_available": False,
                "error": str(exc),
            }

    def _plugin_update_available(self, record: dict[str, Any]) -> bool:
        try:
            marketplace = self._marketplace(str(record.get("marketplace_id") or ""))
            entry = next(
                item for item in marketplace.get("catalog") or []
                if item.get("name") == record.get("name")
            )
            if (entry.get("source") or {}).get("source") != "local":
                return False
            return _tree_digest(self._catalog_local_path(entry)) != record.get("digest")
        except (ExtensionError, StopIteration):
            return False

    @staticmethod
    def _parsed_plugin_view(parsed: dict[str, Any]) -> dict[str, Any]:
        view = {
            key: parsed[key] for key in (
                "name", "version", "description", "display_name", "short_description",
                "long_description", "category", "homepage", "repository", "license",
                "skills", "mcp_servers", "scripts", "unsupported",
            )
        }
        view["author"] = parsed["author"].get("name") or None
        return view

    @staticmethod
    def _trust_summary(parsed: dict[str, Any]) -> dict[str, Any]:
        return {
            "skills": len(parsed["skills"]),
            "skill_scripts": list(parsed["scripts"]),
            "mcp_servers": [
                {
                    "name": server["name"],
                    "transport": server["transport"],
                    "url": server["url"],
                    "command": server["command"],
                    "args": list(server["args"]),
                    "cwd": server["cwd"],
                    "requested_env": sorted(set(server["env"]) | set(server["env_vars"])),
                    "requested_headers": sorted(
                        set(server["http_headers"]) | set(server["env_http_headers"])
                    ),
                }
                for server in parsed["mcp_servers"]
            ],
            "unsupported": list(parsed["unsupported"]),
        }

    def _capability_diff(self, plugin_id: str, parsed: dict[str, Any]) -> dict[str, Any]:
        previous = next(
            (item for item in self._state["plugins"] if item.get("id") == plugin_id), None
        )
        if not previous:
            return {"kind": "new_install", "requires_renewed_trust": True, "changes": []}
        try:
            old = parse_plugin(Path(str(previous["root"])))
        except ExtensionError:
            return {
                "kind": "update",
                "requires_renewed_trust": True,
                "changes": ["The installed version can no longer be inspected."],
            }
        changes: list[str] = []
        added_scripts = sorted(set(parsed["scripts"]) - set(old["scripts"]))
        if added_scripts:
            changes.append("Adds scripts: " + ", ".join(added_scripts))
        old_servers = {item["name"]: item for item in old["mcp_servers"]}
        for server in parsed["mcp_servers"]:
            if server["name"] not in old_servers:
                changes.append(f"Adds MCP server {server['name']}")
                continue
            old_server = old_servers[server["name"]]
            old_connection = (
                old_server["transport"], old_server["url"], old_server["command"]
            )
            new_connection = (server["transport"], server["url"], server["command"])
            if old_connection != new_connection:
                changes.append(f"Changes MCP connection for {server['name']}")
            old_credentials = (
                set(old_server["env"]) | set(old_server["env_vars"]),
                set(old_server["http_headers"]) | set(old_server["env_http_headers"]),
                old_server.get("auth"),
            )
            new_credentials = (
                set(server["env"]) | set(server["env_vars"]),
                set(server["http_headers"]) | set(server["env_http_headers"]),
                server.get("auth"),
            )
            if old_credentials != new_credentials:
                changes.append(f"Changes credentials requested by {server['name']}")
        added_unsupported = sorted(set(parsed["unsupported"]) - set(old["unsupported"]))
        if added_unsupported:
            changes.append("Adds unsupported components: " + ", ".join(added_unsupported))
        return {
            "kind": "update",
            "requires_renewed_trust": bool(changes),
            "changes": changes,
        }

    @staticmethod
    def _public_server(server: dict[str, Any]) -> dict[str, Any]:
        secret_header_names = set((server.get("env_http_headers") or {}).keys())
        public = {
            key: value for key, value in server.items()
            if key not in {"env", "http_headers"}
        }
        public["env_keys"] = sorted((server.get("env") or {}).keys())
        public["header_keys"] = sorted(set((server.get("http_headers") or {}).keys()) | secret_header_names)
        public["has_credentials"] = False
        return public

    def _skill(self, identifier: str, workspace: str = "") -> dict[str, Any]:
        exact = [item for item in self.skills(workspace) if item.get("id") == identifier and item.get("enabled")]
        if len(exact) == 1:
            return exact[0]
        by_name = [item for item in self.skills(workspace) if item.get("name") == identifier and item.get("enabled")]
        if len(by_name) == 1:
            return by_name[0]
        if len(by_name) > 1:
            raise ExtensionError(f"skill name is ambiguous; use one of: {', '.join(item['id'] for item in by_name)}")
        raise ExtensionError(f"skill not found or disabled: {identifier}")

    def _active(self, record: dict[str, Any], workspace: str) -> bool:
        if workspace in set(record.get("disabled_workspaces") or []):
            return False
        return bool(record.get("enabled_global")) or workspace in set(record.get("enabled_workspaces") or [])

    def _set_scope(
        self,
        record: dict[str, Any],
        enabled: bool,
        scope: str,
        workspace: str,
    ) -> None:
        if scope == "global":
            record["enabled_global"] = enabled
            return
        if scope != "workspace":
            raise ExtensionError("scope must be global or workspace")
        path = self._workspace(workspace)
        values = set(str(value) for value in record.get("enabled_workspaces") or [])
        disabled = set(str(value) for value in record.get("disabled_workspaces") or [])
        if enabled:
            values.add(path)
            disabled.discard(path)
        else:
            values.discard(path)
            disabled.add(path)
        record["enabled_workspaces"] = sorted(values)
        record["disabled_workspaces"] = sorted(disabled)

    def _workspace(self, workspace: str = "") -> str:
        return str(Path(workspace or self.cwd).expanduser().resolve())


__all__ = [
    "ExtensionError", "ExtensionManager", "parse_plugin", "parse_skill",
]
