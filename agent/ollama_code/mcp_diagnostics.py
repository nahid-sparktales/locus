"""Bounded, credential-safe diagnostics for one MCP connection attempt."""
from __future__ import annotations

import asyncio
import os
import re
import time
from collections.abc import Iterable
from typing import Any
from urllib.parse import parse_qsl, quote, urlsplit, urlunsplit

from pydantic import ValidationError

from . import proxy

_SECRET_TEXT = re.compile(
    r"(?im)(\b(?:authorization|proxy-authorization|cookie|set-cookie|password|passwd|"
    r"secret|access_token|refresh_token|api[_-]?key|token)\b[\"']?\s*[:=]\s*)"
    r"(?:[\"'][^\r\n]*?[\"']|[^\r\n,;}]+)"
)
_BEARER = re.compile(r"(?i)\b(Bearer|Basic)\s+[^\s\"',;]+")
_URL = re.compile(r"https?://[^\s<>\"']+")


def is_loopback_url(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        return parsed.hostname in {"localhost", "127.0.0.1", "::1"}
    except ValueError:
        return False


def safe_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        host = parsed.hostname or ""
        if ":" in host:
            host = f"[{host}]"
        if parsed.port is not None:
            host += f":{parsed.port}"
        query = "&".join(f"{quote(key)}=[redacted]" for key, _ in parse_qsl(parsed.query))
        return urlunsplit((parsed.scheme, host, parsed.path, query, ""))
    except ValueError:
        return "[invalid URL]"


def exception_causes(exc: BaseException) -> list[str]:
    """Walk causes as well as task groups, with cycle and output bounds."""
    seen: set[int] = set()
    output: list[str] = []

    def walk(error: BaseException, depth: int = 0) -> None:
        if id(error) in seen or depth > 12 or len(seen) >= 48:
            return
        seen.add(id(error))
        children = getattr(error, "exceptions", ())
        if not children and type(error).__name__ not in {"CancelledError", "WouldBlock"}:
            if isinstance(error, ValidationError):
                # Pydantic's normal string embeds invalid input, which can be
                # an image payload, tool arguments, or a credential value.
                issues = error.errors(include_input=False, include_context=False, include_url=False)
                value = "ValidationError: " + "; ".join(
                    f"{'.'.join(str(part) for part in issue['loc'])}: {issue['msg']}"
                    for issue in issues[:8]
                )
            else:
                value = f"{type(error).__name__}: {error}" if str(error) else type(error).__name__
            if value not in output:
                output.append(value)
        for child in children:
            walk(child, depth + 1)
        # Transport libraries often suppress a low-level context in their
        # traceback while retaining it on the exception object. It is exactly
        # the evidence a connection diagnostic needs.
        for cause in (error.__cause__, error.__context__):
            if cause is not None:
                walk(cause, depth + 1)

    walk(exc)
    return output[:12] or [type(exc).__name__]


class StderrCapture:
    """Drain a real subprocess stderr fd without retaining an unbounded log."""

    limit = 16 * 1024

    def __init__(self) -> None:
        self.loop = asyncio.get_running_loop()
        self.reader, writer = os.pipe()
        os.set_blocking(self.reader, False)
        self.writer = os.fdopen(writer, "wb", buffering=0)
        self.tail = bytearray()
        self.truncated = False
        self.closed = False
        self.loop.add_reader(self.reader, self.drain)

    def drain(self) -> None:
        if self.closed:
            return
        # Yield to protocol I/O even if a child writes continuously.
        for _ in range(32):
            try:
                chunk = os.read(self.reader, 8192)
            except (BlockingIOError, OSError):
                break
            if not chunk:
                self.loop.remove_reader(self.reader)
                break
            self.tail.extend(chunk)
            if len(self.tail) > self.limit:
                del self.tail[:-self.limit]
                self.truncated = True

    def text(self) -> str:
        self.drain()
        value = bytes(self.tail).decode("utf-8", errors="replace")
        if self.truncated:
            # Drop a partial first line: it may start halfway through a secret.
            value = value.partition("\n")[2]
            value = "[earlier STDERR omitted]\n" + value
        return value

    def close(self) -> None:
        if not self.closed:
            self.drain()
            self.loop.remove_reader(self.reader)
            self.writer.close()
            os.close(self.reader)
            self.closed = True


class ConnectionDiagnostics:
    def __init__(self, server: dict[str, Any], credentials: dict[str, Any]) -> None:
        self.server = server
        self.started = time.monotonic()
        self.stage = "configuration"
        self.http_status: int | None = None
        self.auth_present = False
        self.stderr: StderrCapture | None = None
        self.secrets: set[str] = set()
        self.add_secrets((credentials.get("env") or {}).values())
        self.add_secrets((credentials.get("headers") or {}).values())
        self.add_secrets([credentials.get("access_token")])
        self.add_secrets((server.get("env") or {}).values())
        self.add_secrets((server.get("http_headers") or {}).values())

    def add_secrets(self, values: Iterable[Any]) -> None:
        for value in values:
            if value is None or not str(value):
                continue
            text = str(value)
            self.secrets.update((text, repr(text)[1:-1], quote(text, safe=""), text.encode("unicode_escape").decode("ascii")))
            self.secrets.update(part for part in text.splitlines() if part)
            if text.lower().startswith(("bearer ", "basic ")):
                self.secrets.add(text.split(" ", 1)[1])

    def redact(self, text: str) -> str:
        value = proxy.redact(text)
        for secret in sorted(self.secrets, key=len, reverse=True):
            value = value.replace(secret, "[redacted]")
        value = _BEARER.sub(lambda match: f"{match[1]} [redacted]", value)
        value = _SECRET_TEXT.sub(r"\1[redacted]", value)
        value = _URL.sub(lambda match: safe_url(match[0]), value)
        # Server diagnostics are plain text, never terminal control sequences.
        value = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", value)
        return "".join(char for char in value if char in "\n\t" or ord(char) >= 32)

    async def response(self, response: Any) -> None:
        if response.request.method == "POST" or self.server.get("transport") == "sse":
            self.http_status = int(response.status_code)

    def failure(self, exc: BaseException) -> tuple[str, str, dict[str, Any]]:
        causes = [self.redact(item)[:1200] for item in exception_causes(exc)]
        raw = " ".join(exception_causes(exc)).lower()
        transport = str(self.server.get("transport") or "streamable_http")
        target = str(self.server.get("command") if transport == "stdio" else self.server.get("url") or "")
        target = self.redact(target) if transport == "stdio" else self.redact(safe_url(target))
        hints: list[str] = []
        state = "error"
        if self.http_status in {401, 403}:
            state = "needs_auth"
            summary = f"The MCP server rejected {'the supplied credentials' if self.auth_present else 'the unauthenticated request'} (HTTP {self.http_status})."
            hints.append("Check the server's authentication settings and reconnect its account or update its token.")
        elif "filenotfounderror" in raw:
            summary = "The MCP command or working directory could not be found."
            hints.append("Check the executable path, working directory, and whether the command is installed.")
        elif "permissionerror" in raw or "permission denied" in raw:
            summary = "Locus does not have permission to start or access this MCP server."
            hints.append("Check executable permissions and the server's required macOS permissions.")
        elif "cancellederror" in raw:
            summary = f"The MCP connection was cancelled during {self.stage.replace('_', '/')} .".replace(" .", ".")
            hints.append("Test the server again when you are ready to connect.")
        elif "timeout" in raw or "timed out" in raw:
            summary = f"The MCP connection timed out during {self.stage.replace('_', '/')} after {self.server.get('startup_timeout_sec') or 10} seconds."
            hints.append("Confirm the server is responding, or increase the connection timeout in Advanced settings.")
        elif "refused" in raw:
            summary = f"No MCP server accepted a connection at {target}."
            hints.append("Start the server and verify its configured host, port, and endpoint.")
        elif any(word in raw for word in ("gaierror", "name or service", "nodename", "name resolution")):
            summary = f"The MCP server hostname could not be resolved: {target}."
            hints.append("Check the hostname and your network or DNS settings.")
        elif any(word in raw for word in ("certificate", "ssl", "tls")):
            summary = "The MCP server's secure connection could not be verified."
            hints.append("Check the server's certificate and the configured HTTPS URL.")
        elif self.http_status and self.http_status >= 400:
            summary = f"The MCP endpoint returned HTTP {self.http_status}."
            hints.append("Check the endpoint path and selected transport against the server's setup instructions.")
        elif "closed" in raw or "endofstream" in raw:
            summary = f"The MCP server closed the connection during {self.stage.replace('_', '/')} .".replace(" .", ".")
            hints.append("Review the server output below and verify its launch arguments and protocol settings.")
        elif any(word in raw for word in ("protocol", "jsondecodeerror", "validationerror", "invalid json", "unsupported version", "unexpected message")):
            summary = f"The MCP server returned an incompatible protocol response during {self.stage.replace('_', '/')} .".replace(" .", ".")
            hints.append("Check the endpoint and transport. If the server requires older initialization, enable Legacy initialization in Advanced settings.")
        elif "connect" in raw:
            summary = f"Locus could not reach the MCP server at {target}."
            hints.append("Check that the server is running and the endpoint and network settings are correct.")
        else:
            summary = f"MCP failed during {self.stage.replace('_', '/')}: {causes[-1]}"
        if "macuse" in str(self.server.get("name") or "").lower():
            hints.append("Macuse documents port 35729 by default; verify the port in Macuse's Server settings because it can be changed.")
            if transport == "stdio":
                hints.append("Macuse's documented command is /Applications/Macuse.app/Contents/MacOS/macuse with the argument mcp. Macuse must be running or configured to auto-launch.")
        details = {
            "transport": transport, "stage": self.stage, "target": target,
            "elapsed_ms": round((time.monotonic() - self.started) * 1000),
            "auth_present": self.auth_present, "http_status": self.http_status,
            "causes": causes, "stderr_tail": self.redact(self.stderr.text())[-16384:] if self.stderr else "",
            "hints": hints,
        }
        return state, self.redact(summary)[:2000], details
