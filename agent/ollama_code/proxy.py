"""Proxy configuration handed down by the app, minus the credential.

The app injects credential-free proxy URLs at agent spawn — ``HTTP_PROXY``/
``HTTPS_PROXY`` for a manual HTTP proxy, ``ALL_PROXY=socks5h://…`` for SOCKS —
plus ``NO_PROXY``. Startup secrets never travel in the environment: the app
sets a non-secret stdin flag, writes one bounded JSON line containing an
optional percent-encoded proxy credential, then closes the pipe. The legacy
proxy-only stdin form remains accepted.
requests and httpx read proxies straight from ``os.environ``, so folding that
credential into the URL variables is all this process needs to authenticate.

Why stdin and not an environment variable: ``os.environ.pop`` only edits this
process's in-memory copy. On macOS the *exec-time* environment block stays
readable for the life of the process through ``KERN_PROCARGS2`` — which is what
``ps -Eww -p <pid>`` prints — so a secret handed over in the environment stays
readable by anything the model runs, popped or not. A secret that never enters
that block leaves no such trace.

The reason this is a module and not three lines in server.py: every shell tool,
git call and MCP plugin runs code this process does not own,
and each of those children inherits an environment. The credential must be
usable by this process and invisible to all of them, which takes both halves
below — ``activate_from_env`` embeds it here, ``sanitized_child_environment``
strips it back out of everything spawned.
"""
from __future__ import annotations

import json
import os
import sys
from collections.abc import Mapping
from urllib.parse import urlsplit, urlunsplit

#: Every environment variable that may carry a proxy URL. Both cases on
#: purpose: the app sets both, requests honours the lowercase names first,
#: and child processes may read either.
PROXY_URL_VARS = (
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
)

#: The bypass list travels with the proxy URLs but never carries a secret.
_BYPASS_VARS = ("NO_PROXY", "no_proxy")

#: The handoff variables. ``LOCUS_PROXY_CREDENTIAL_STDIN`` is only a flag;
#: ``LOCUS_PROXY_CREDENTIAL`` is read by nothing and is listed here purely so a
#: stray value cannot be inherited by a child (see ``activate_from_env``).
_CREDENTIAL_VARS = (
    "LOCUS_PROXY_CREDENTIAL", "LOCUS_PROXY_CREDENTIAL_STDIN",
    "LOCUS_BOOTSTRAP_SECRETS_STDIN",
)

#: Whether activate_from_env folded a credential into this process's proxy
#: URLs. A bool for tests and diagnostics — deliberately never the secret.
#: Also the gate on ``sanitized_child_environment``: what Locus did not inject
#: into a child that inherits the whole environment is not Locus's to remove.
#: It deliberately does *not* gate ``child_proxy_env`` — see that docstring.
credential_applied = False


def activate_from_env() -> None:
    """Fold the app's proxy credential into this process's proxy URL variables.

    Called once at server startup, before uvicorn is running and before
    anything can make an outbound request.

    The credential arrives on stdin, and only on stdin, when the app sets
    ``LOCUS_PROXY_CREDENTIAL_STDIN=1``; that flag is popped, as is
    ``LOCUS_PROXY_CREDENTIAL``, whose value is read by nothing. Taking a secret
    from the environment is precisely the exposure the stdin handoff exists to
    eliminate, so a value found in that variable is discarded, never used —
    there is no app binary that sets it and no compatibility to preserve.
    Reading stdin here steals nothing: the
    server entry point is ``ollama_code.server.main`` and nothing it imports
    touches ``sys.stdin`` — the only ``sys.stdin`` use in the package is
    app.py's interactive REPL, a different entry point (``ollama_code.app``)
    that this process never runs.

    Safe to call with no credential, no proxy variables, or no readable stdin
    at all, and idempotent: a second call finds nothing to consume and changes
    nothing.
    """
    global credential_applied
    bootstrap_stdin = os.environ.pop("LOCUS_BOOTSTRAP_SECRETS_STDIN", None) == "1"
    from_stdin = os.environ.pop("LOCUS_PROXY_CREDENTIAL_STDIN", None) == "1"
    # Popped and dropped on the floor: whatever put a value here, it is not the
    # app, and it must not survive into a child's environment.
    os.environ.pop("LOCUS_PROXY_CREDENTIAL", None)
    credential = ""
    if bootstrap_stdin:
        try:
            stream = getattr(sys.stdin, "buffer", sys.stdin)
            raw = stream.readline(32_768)
            if isinstance(raw, str):
                raw = raw.encode()
            payload = json.loads(raw.decode("utf-8")) if raw else {}
            if isinstance(payload, dict):
                credential = str(payload.get("proxy_credential") or "").strip()
        except (AttributeError, OSError, UnicodeDecodeError, ValueError, json.JSONDecodeError):
            credential = ""
    elif from_stdin:
        credential = _credential_from_stdin()
    if not credential:
        return
    # user and pass are each percent-encoded by the app, so the first ":" is
    # the separator even when the password contains an encoded one (%3A), and
    # the halves are embedded verbatim — re-encoding here would corrupt any
    # password containing "%".
    user, _, password = credential.partition(":")
    userinfo = f"{user}:{password}"
    for name in PROXY_URL_VARS:
        value = os.environ.get(name)
        if not value:
            continue
        rewritten = _with_userinfo(value, userinfo)
        if rewritten is not None:
            os.environ[name] = rewritten
            credential_applied = True


def sanitized_child_environment(base: Mapping[str, str] | None = None) -> dict[str, str]:
    """A copy of ``base`` (default: os.environ) without Locus's proxy credential.

    This is the environment every model-visible child process gets: the proxy
    URLs survive so the child's own network traffic still routes correctly, the
    ``user:pass@`` embedded by activate_from_env does not. A value that does not
    parse as a URL is passed through unchanged — a child that cannot use it is
    no worse off, and a malformed value must not stop a spawn.

    The userinfo strip is gated on ``credential_applied``. With Locus set to
    "Direct connection" the proxy variables here are the user's own, inherited
    from their shell, and a ``user:pass@`` in them is theirs: stripping it would
    break the git and curl authentication they had before Locus was involved.
    Only what activate_from_env put there is Locus's to remove.
    """
    environment = dict(os.environ if base is None else base)
    # Unconditional, and deliberately not behind credential_applied: this also
    # covers any spawn that happens before — or in a process without —
    # activate_from_env, where the raw handoff would otherwise still be sitting
    # in the environment for the child to read.
    for name in _CREDENTIAL_VARS:
        environment.pop(name, None)
    if credential_applied:
        for name in PROXY_URL_VARS:
            value = environment.get(name)
            if value:
                environment[name] = _without_userinfo(value)
    return environment


def child_proxy_env(environ: Mapping[str, str] | None = None) -> dict[str, str]:
    """Only the proxy-related variables, credential-free.

    For environments assembled from an allowlist rather than inherited whole —
    the mcp SDK's get_default_environment, notably, drops the proxy variables,
    so a stdio MCP server would silently bypass the proxy without this merge.

    The strip here is unconditional, and deliberately *not* gated on
    ``credential_applied`` the way ``sanitized_child_environment``'s is. That
    difference is the whole point of the two functions. A child that inherits
    the environment whole always had whatever ``user:pass@`` the user's own
    shell exported, so stripping a credential Locus never injected would take
    away authentication that child had before Locus existed. A child built from
    an allowlist had *none* of these variables — the allowlist is HOME, PATH and
    friends — so every value returned here is one Locus is handing over for the
    first time. Passing the user's own proxy password on to a third-party plugin
    process would be a new disclosure, not a preserved one.
    """
    source = os.environ if environ is None else environ
    result: dict[str, str] = {}
    for name in PROXY_URL_VARS:
        value = source.get(name)
        if value:
            result[name] = _without_userinfo(value)
    for name in _BYPASS_VARS:
        value = source.get(name)
        if value:
            result[name] = value
    return result


def redact(text: str) -> str:
    """``text`` with any credentialed proxy URL replaced by its clean form.

    Exception text is where the credential escapes on its own: requests raises
    ``InvalidURL: Failed to parse: http://alice:s3cret@proxy%.corp:3128`` when
    urllib3 cannot parse the proxy host, and that string goes on to be shown in
    chat or handed to the model. Substring replacement rather than parsing,
    because the message is prose with a URL somewhere inside it. Apply it where
    exception text reaches a person or the model, not as blanket output
    filtering.
    """
    if not text:
        return text
    for name in PROXY_URL_VARS:
        value = os.environ.get(name)
        if not value:
            continue
        clean = _without_userinfo(value)
        if clean != value:
            text = text.replace(value, clean)
    return text


def ensure_no_proxy_host(url: str) -> None:
    """Add ``url``'s host to NO_PROXY/no_proxy so this process reaches it directly.

    The Ollama host is the one endpoint that must never be proxied: it is the
    user's own runtime, frequently on the LAN, and a corporate proxy has no
    route to it. The app can only guess that host at spawn time — it builds
    NO_PROXY from a default before the agent has read its config, and the host
    can change again at runtime through ``POST /api/provider`` with no respawn —
    so the agent, which is the authority on its own Ollama host, appends it
    itself.

    A no-op when no proxy is configured (a bypass list without a proxy is a
    confusing artefact), when ``url`` yields no usable host, and when the host
    is already listed. Existing entries are preserved verbatim, and a bypass
    list that exists in only one case seeds the other, because requests reads
    ``no_proxy`` in preference to ``NO_PROXY``: creating a lowercase variable
    holding just this host would otherwise *replace* the app's list rather than
    extend it.
    """
    if not any(os.environ.get(name) for name in PROXY_URL_VARS):
        return
    host = _hostname(url)
    if not host:
        return
    present = {name: os.environ[name] for name in _BYPASS_VARS if os.environ.get(name)}
    baseline = next(iter(present.values()), "")
    for name in _BYPASS_VARS:
        entries = [item.strip() for item in present.get(name, baseline).split(",")]
        entries = [item for item in entries if item]
        if any(item.lower() == host for item in entries):
            continue
        os.environ[name] = ",".join([*entries, host])


def _with_userinfo(url: str, userinfo: str) -> str | None:
    """``url`` with its userinfo replaced, or None when it has no host."""
    try:
        parts = urlsplit(url)
        if not parts.netloc:
            return None
        hostport = parts.netloc.rpartition("@")[2]
        return urlunsplit(parts._replace(netloc=f"{userinfo}@{hostport}"))
    except ValueError:
        return None


def _without_userinfo(url: str) -> str:
    """``url`` with any userinfo stripped; malformed input comes back as-is."""
    try:
        parts = urlsplit(url)
        if not parts.netloc:
            # No "//" authority to strip: urlsplit puts a schemeless
            # "user:pass@host:port" entirely in `path`, and curl accepts that
            # form for http_proxy, so the credential would otherwise survive.
            return _without_schemeless_userinfo(url)
        if "@" not in parts.netloc:
            return url
        return urlunsplit(parts._replace(netloc=parts.netloc.rpartition("@")[2]))
    except ValueError:
        return url


def _without_schemeless_userinfo(value: str) -> str:
    """``user:pass@host:port`` minus the userinfo; anything else, unchanged.

    Re-parsed as a bare authority to be sure it is one. Anything that does not
    come back with a host and a usable port keeps the "garbage in, same garbage
    out" contract the sanitizer depends on.
    """
    if "@" not in value or "/" in value:
        return value
    try:
        parts = urlsplit(f"//{value}")
        hostport = parts.netloc.rpartition("@")[2]
        # .hostname and .port validate the remainder: a non-numeric or
        # out-of-range port raises, which means this was never an authority.
        if not parts.hostname or (parts.port is None and ":" in hostport):
            return value
    except ValueError:
        return value
    return hostport


def _hostname(url: str) -> str:
    """The bare host of ``url``, or "" when there is not one to be had."""
    if not url:
        return ""
    try:
        parts = urlsplit(url if "//" in url else f"//{url}")
        host = (parts.hostname or "").strip()
    except ValueError:
        return ""
    # A host with a separator in it would corrupt the comma-joined bypass list;
    # junk input earns a no-op, never a broken NO_PROXY.
    if not host or any(character in host for character in ", \t"):
        return ""
    return host


def _credential_from_stdin() -> str:
    """One line from stdin, or "" when there is nothing to read.

    EOF, an already-closed stdin and a process with no stdin at all are the
    same answer: no credential. The proxy then fails to authenticate, which is
    visible and fixable — a crash at startup is neither.
    """
    try:
        line = sys.stdin.readline()
    except Exception:  # noqa: BLE001 - detached, closed, or non-text stdin
        return ""
    return line.strip()
