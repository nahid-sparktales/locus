"""Proxy credential containment: ollama_code.proxy and every spawn site.

The app injects credential-free proxy URLs at agent spawn and hands the
password over on stdin; ``activate_from_env`` folds it into this process's
proxy URLs, and every model-visible child must get a stripped copy. The spawn
tests monkeypatch the module's subprocess entry and assert on the environment
that actually reached the child — "the sanitizer works" is not evidence that a
given spawn site calls it.

Two invariants get their own tests throughout because they pull in opposite
directions: Locus's own credential must never leave this process, and a
credential Locus did not inject (the user's own proxy, with Locus set to
"Direct connection") must pass through untouched to children that inherit the
environment whole — those children always had it. Children assembled from an
allowlist are the exception on the second point and get their own tests: they
never had any proxy variable, so handing one over with a password in it is a
new disclosure whoever owns the password.
"""
from __future__ import annotations

import io
import json
import os
import subprocess

import pytest

from ollama_code import proxy

CREDENTIALED = "http://alice:s3cret@proxy.example:3128"
CLEAN = "http://proxy.example:3128"


@pytest.fixture(autouse=True)
def clean_proxy_state(monkeypatch):
    """Fresh module state, and no proxy noise leaking in from the host env."""
    monkeypatch.setattr(proxy, "credential_applied", False)
    for name in (
        *proxy.PROXY_URL_VARS,
        "NO_PROXY",
        "no_proxy",
        "LOCUS_PROXY_CREDENTIAL",
        "LOCUS_PROXY_CREDENTIAL_STDIN",
        "LOCUS_BOOTSTRAP_SECRETS_STDIN",
    ):
        monkeypatch.delenv(name, raising=False)


@pytest.fixture
def credentialed_environ(clean_proxy_state, monkeypatch):
    """What this process looks like after activate_from_env embedded a secret."""
    monkeypatch.setenv("HTTP_PROXY", CREDENTIALED)
    monkeypatch.setenv("NO_PROXY", "localhost")
    monkeypatch.setattr(proxy, "credential_applied", True)


@pytest.fixture
def inherited_environ(clean_proxy_state, monkeypatch):
    """The user's own credentialed proxy, with Locus injecting nothing."""
    monkeypatch.setenv("HTTP_PROXY", CREDENTIALED)
    monkeypatch.setenv("https_proxy", CREDENTIALED)


def _stdin(text: str, monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO(text))


def _recording(real):
    """A wrapper that records (args, kwargs) and delegates to the real call."""
    calls: list[tuple[tuple, dict]] = []

    def wrapper(*args, **kwargs):
        calls.append((args, kwargs))
        return real(*args, **kwargs)

    return wrapper, calls


# --------------------------------------------------------- activate_from_env


def test_activate_reads_the_credential_from_stdin(monkeypatch):
    """The secret never enters the environment: popping it would not help,
    because `ps -E` reads the exec-time block for the life of the process."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("http_proxy", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("alice:s3cret\n", monkeypatch)

    proxy.activate_from_env()

    assert "LOCUS_PROXY_CREDENTIAL_STDIN" not in os.environ
    assert os.environ["HTTP_PROXY"] == CREDENTIALED
    assert os.environ["http_proxy"] == CREDENTIALED
    assert "HTTPS_PROXY" not in os.environ, "absent vars stay absent"
    assert proxy.credential_applied


def test_activate_reads_proxy_secret_from_one_json_line(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_BOOTSTRAP_SECRETS_STDIN", "1")
    payload = json.dumps({"proxy_credential": "alice:s3cret"})
    monkeypatch.setattr("sys.stdin", io.TextIOWrapper(io.BytesIO((payload + "\n").encode())))

    proxy.activate_from_env()

    assert "LOCUS_BOOTSTRAP_SECRETS_STDIN" not in os.environ
    assert os.environ["HTTP_PROXY"] == CREDENTIALED


def test_activate_ignores_stdin_without_the_flag(monkeypatch):
    """No flag, no read: whatever is on stdin belongs to someone else."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    _stdin("alice:s3cret\n", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == CLEAN
    assert not proxy.credential_applied


def test_activate_survives_an_empty_stdin(monkeypatch):
    """EOF before the line arrives means no credential, not a failed startup."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == CLEAN
    assert not proxy.credential_applied


def test_activate_survives_a_closed_stdin(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    monkeypatch.setattr("sys.stdin", None)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == CLEAN
    assert not proxy.credential_applied


def test_activate_reads_one_line_only(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("alice:s3cret\nnot-the-credential\n", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == CREDENTIALED


def test_activate_ignores_and_removes_a_stray_credential_var(monkeypatch):
    """stdin is the only handoff. Accepting the secret from the environment is
    the exposure stdin exists to avoid, so a value found in the variable is
    dropped rather than used — but it is still dropped, so nothing inherits it."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL", "alice:s3cret")

    proxy.activate_from_env()

    assert "LOCUS_PROXY_CREDENTIAL" not in os.environ, "children must not read it"
    assert os.environ["HTTP_PROXY"] == CLEAN, "the env var is not a credential source"
    assert not proxy.credential_applied


def test_activate_rewrites_a_socks_url(monkeypatch):
    monkeypatch.setenv("ALL_PROXY", "socks5h://proxy.example:1080")
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("alice:s3cret\n", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["ALL_PROXY"] == "socks5h://alice:s3cret@proxy.example:1080"


def test_activate_without_credential_is_a_noop(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == CLEAN
    assert not proxy.credential_applied


def test_activate_consumes_the_credential_even_without_proxy_vars(monkeypatch):
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("alice:s3cret\n", monkeypatch)

    proxy.activate_from_env()

    assert "LOCUS_PROXY_CREDENTIAL_STDIN" not in os.environ
    assert not proxy.credential_applied


def test_percent_encoded_credentials_are_embedded_verbatim(monkeypatch):
    """The app already encoded each half; a second pass would corrupt any
    password containing a literal %."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("user%40corp:p%25ss\n", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == "http://user%40corp:p%25ss@proxy.example:3128"


def test_password_with_encoded_colon_survives_the_first_colon_split(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    _stdin("alice:pa%3Ass\n", monkeypatch)

    proxy.activate_from_env()

    assert os.environ["HTTP_PROXY"] == "http://alice:pa%3Ass@proxy.example:3128"


# --------------------------------------------- sanitized_child_environment


def test_sanitize_strips_userinfo_from_upper_and_lower_vars(monkeypatch):
    monkeypatch.setattr(proxy, "credential_applied", True)
    base = {
        "HTTP_PROXY": CREDENTIALED,
        "https_proxy": "http://bob:pw@other.example:8080",
        "ALL_PROXY": "socks5h://alice:s3cret@proxy.example:1080",
        "NO_PROXY": "localhost,.corp.example",
        "PATH": "/usr/bin",
    }

    clean = proxy.sanitized_child_environment(base)

    assert clean["HTTP_PROXY"] == CLEAN
    assert clean["https_proxy"] == "http://other.example:8080"
    assert clean["ALL_PROXY"] == "socks5h://proxy.example:1080"
    assert clean["NO_PROXY"] == "localhost,.corp.example"
    assert clean["PATH"] == "/usr/bin"
    assert base["HTTP_PROXY"] == CREDENTIALED, "the input mapping is not mutated"


def test_sanitize_strips_a_schemeless_userinfo(monkeypatch):
    """curl accepts `user:pass@host:port` for http_proxy, and urlsplit parses
    no authority out of it — so a netloc-only strip would let it through."""
    monkeypatch.setattr(proxy, "credential_applied", True)
    base = {"HTTP_PROXY": "alice:s3cret@proxy.example:3128", "all_proxy": "alice:s3cret@host"}

    clean = proxy.sanitized_child_environment(base)

    assert clean["HTTP_PROXY"] == "proxy.example:3128"
    assert clean["all_proxy"] == "host"


def test_sanitize_leaves_inherited_proxy_credentials_alone(inherited_environ):
    """Locus set to "Direct connection": these are the user's own variables,
    and stripping them would break the git/curl auth they had before Locus."""
    clean = proxy.sanitized_child_environment()

    assert clean["HTTP_PROXY"] == CREDENTIALED
    assert clean["https_proxy"] == CREDENTIALED


def test_sanitize_drops_the_raw_credential_vars_without_activation(monkeypatch):
    """Defence in depth: a spawn before — or without — activate_from_env must
    not hand the handoff itself to a child."""
    base = {
        "LOCUS_PROXY_CREDENTIAL": "alice:s3cret",
        "LOCUS_PROXY_CREDENTIAL_STDIN": "1",
        "PATH": "/usr/bin",
    }

    clean = proxy.sanitized_child_environment(base)

    assert "LOCUS_PROXY_CREDENTIAL" not in clean
    assert "LOCUS_PROXY_CREDENTIAL_STDIN" not in clean
    assert clean["PATH"] == "/usr/bin"
    assert not proxy.credential_applied, "no activation happened"


def test_sanitize_leaves_garbage_values_unchanged(monkeypatch):
    """A value that does not parse must come back as-is — never an exception,
    because this runs on the way into every spawn."""
    monkeypatch.setattr(proxy, "credential_applied", True)
    base = {"HTTP_PROXY": "http://[not-a-url", "ALL_PROXY": "::@@:%", "http_proxy": "@"}

    clean = proxy.sanitized_child_environment(base)

    assert clean["HTTP_PROXY"] == "http://[not-a-url"
    assert clean["ALL_PROXY"] == "::@@:%"
    assert clean["http_proxy"] == "@"


def test_sanitize_defaults_to_os_environ(credentialed_environ):
    clean = proxy.sanitized_child_environment()

    assert clean["HTTP_PROXY"] == CLEAN
    assert clean["PATH"] == os.environ["PATH"]


# ------------------------------------------------------------ child_proxy_env


def test_child_proxy_env_returns_only_proxy_vars_credential_free(monkeypatch):
    monkeypatch.setattr(proxy, "credential_applied", True)
    base = {
        "HTTP_PROXY": CREDENTIALED,
        "no_proxy": "localhost",
        "PATH": "/usr/bin",
        "LOCUS_AGENT_TOKEN": "not-a-proxy-var",
    }

    assert proxy.child_proxy_env(base) == {"HTTP_PROXY": CLEAN, "no_proxy": "localhost"}


def test_child_proxy_env_strips_an_inherited_credential_too(inherited_environ):
    """The one place ``credential_applied`` must NOT gate the strip. The
    recipient is an allowlisted environment that had no proxy variable at all,
    so passing the user's own password along is a fresh disclosure to a
    third-party plugin, not authentication the child already had."""
    assert not proxy.credential_applied, "Locus injected nothing here"

    result = proxy.child_proxy_env()

    assert result["HTTP_PROXY"] == CLEAN
    assert result["https_proxy"] == CLEAN
    assert "s3cret" not in str(result)


# ------------------------------------------------------------------- redact


def test_redact_replaces_the_credentialed_url_in_exception_text(credentialed_environ):
    """requests names the proxy URL in InvalidURL, and that text is shown to
    the model and in chat."""
    message = f"Error fetching https://x.example: Failed to parse: {CREDENTIALED}"

    redacted = proxy.redact(message)

    assert "s3cret" not in redacted
    assert redacted.endswith(f"Failed to parse: {CLEAN}")


def test_redact_covers_every_proxy_variable(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CREDENTIALED)
    monkeypatch.setenv("ALL_PROXY", "socks5h://bob:pw@socks.example:1080")

    redacted = proxy.redact(f"one {CREDENTIALED} two socks5h://bob:pw@socks.example:1080")

    assert redacted == f"one {CLEAN} two socks5h://socks.example:1080"


def test_redact_leaves_unrelated_text_alone(credentialed_environ):
    assert proxy.redact("connection refused") == "connection refused"
    assert proxy.redact("") == ""


def test_redact_is_a_noop_without_a_credentialed_proxy(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)

    assert proxy.redact(f"cannot reach {CLEAN}") == f"cannot reach {CLEAN}"


# ------------------------------------------------------- ensure_no_proxy_host


def test_ensure_no_proxy_host_appends_to_both_cases(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("NO_PROXY", "localhost,127.0.0.1")
    monkeypatch.setenv("no_proxy", "localhost,127.0.0.1")

    proxy.ensure_no_proxy_host("http://ollama.lan:11434")

    assert os.environ["NO_PROXY"] == "localhost,127.0.0.1,ollama.lan"
    assert os.environ["no_proxy"] == "localhost,127.0.0.1,ollama.lan"


def test_ensure_no_proxy_host_is_idempotent(monkeypatch):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("NO_PROXY", "localhost")

    proxy.ensure_no_proxy_host("http://ollama.lan:11434")
    proxy.ensure_no_proxy_host("http://OLLAMA.lan:11434/")
    proxy.ensure_no_proxy_host("http://ollama.lan:11434")

    assert os.environ["NO_PROXY"] == "localhost,ollama.lan"
    assert os.environ["no_proxy"] == "localhost,ollama.lan"


def test_ensure_no_proxy_host_seeds_the_missing_case_from_the_existing_list(monkeypatch):
    """requests reads no_proxy in preference to NO_PROXY, so a lowercase
    variable holding only this host would replace the app's list, not extend it."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("NO_PROXY", "localhost,.corp.example")

    proxy.ensure_no_proxy_host("http://ollama.lan:11434")

    assert os.environ["NO_PROXY"] == "localhost,.corp.example,ollama.lan"
    assert os.environ["no_proxy"] == "localhost,.corp.example,ollama.lan"


def test_ensure_no_proxy_host_without_a_proxy_writes_nothing(monkeypatch):
    proxy.ensure_no_proxy_host("http://ollama.lan:11434")

    assert "NO_PROXY" not in os.environ
    assert "no_proxy" not in os.environ


def test_ensure_no_proxy_host_creates_the_list_when_the_proxy_has_none(monkeypatch):
    monkeypatch.setenv("ALL_PROXY", "socks5h://proxy.example:1080")

    proxy.ensure_no_proxy_host("http://127.0.0.1:11434")

    assert os.environ["NO_PROXY"] == "127.0.0.1"
    assert os.environ["no_proxy"] == "127.0.0.1"


@pytest.mark.parametrize("url", ["", "   ", "http://", "not a url", ":://"])
def test_ensure_no_proxy_host_ignores_junk(monkeypatch, url):
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("NO_PROXY", "localhost")

    proxy.ensure_no_proxy_host(url)

    assert os.environ["NO_PROXY"] == "localhost", "an existing list is never corrupted"


def test_agent_core_bypasses_its_own_ollama_host(monkeypatch, tmp_path):
    """The app builds NO_PROXY from a default host at spawn; the agent is the
    one that knows where Ollama actually is."""
    monkeypatch.setenv("HTTP_PROXY", CLEAN)
    monkeypatch.setenv("NO_PROXY", "localhost")
    from ollama_code.core import AgentCore

    core = AgentCore(host="http://ollama.lan:11434", cwd=str(tmp_path), config={})

    assert "ollama.lan" in os.environ["NO_PROXY"]

    monkeypatch.setattr("ollama_code.core.save_config", lambda _config: None)
    core.use_ollama(host="http://other-box.lan:11434")

    assert "other-box.lan" in os.environ["NO_PROXY"]
    assert "ollama.lan" in os.environ["NO_PROXY"], "the earlier host stays bypassed"
    core.mcp.close()


# ------------------------------------------------------------- spawn sites


def test_bash_tool_child_env_is_credential_stripped(tmp_path, monkeypatch, credentialed_environ):
    from ollama_code import tools as tools_mod
    from ollama_code.tools import ToolContext, execute_tool

    wrapper, calls = _recording(subprocess.Popen)
    monkeypatch.setattr(tools_mod.subprocess, "Popen", wrapper)

    result = execute_tool("bash", {"command": "true"}, ToolContext(cwd=str(tmp_path)))

    assert not result.startswith("Error")
    env = calls[0][1]["env"]
    assert env["HTTP_PROXY"] == CLEAN
    assert env["NO_PROXY"] == "localhost"
    assert "s3cret" not in str(env)


def test_git_tool_child_env_is_credential_stripped(tmp_path, monkeypatch, credentialed_environ):
    from ollama_code import tools as tools_mod
    from ollama_code.tools import ToolContext, execute_tool

    wrapper, calls = _recording(subprocess.Popen)
    monkeypatch.setattr(tools_mod.subprocess, "Popen", wrapper)

    execute_tool("git_status", {}, ToolContext(cwd=str(tmp_path)))

    env = calls[0][1]["env"]
    assert env["HTTP_PROXY"] == CLEAN
    assert "s3cret" not in str(env)


def test_gitinfo_child_env_is_credential_stripped(tmp_path, monkeypatch, credentialed_environ):
    from ollama_code import gitinfo

    wrapper, calls = _recording(subprocess.Popen)
    monkeypatch.setattr(gitinfo.subprocess, "Popen", wrapper)

    gitinfo.run_git(str(tmp_path), "version")

    env = calls[0][1]["env"]
    assert env["HTTP_PROXY"] == CLEAN
    assert env["GIT_OPTIONAL_LOCKS"] == "0", "gitinfo's own overrides survive"
    assert "s3cret" not in str(env)


def test_extensions_git_env_is_credential_stripped(monkeypatch, credentialed_environ):
    from ollama_code import extensions as extensions_mod
    from ollama_code.extensions import ExtensionManager

    wrapper, calls = _recording(subprocess.run)
    monkeypatch.setattr(extensions_mod.subprocess, "run", wrapper)

    ExtensionManager._run_git(["git", "version"])

    env = calls[0][1]["env"]
    assert env["HTTP_PROXY"] == CLEAN
    assert "s3cret" not in str(env)


def test_spawned_child_never_sees_the_raw_credential_var(tmp_path, monkeypatch):
    """Belt and braces at a real spawn site: even if activate_from_env never
    ran, the handoff variables do not reach the child."""
    from ollama_code import tools as tools_mod
    from ollama_code.tools import ToolContext, execute_tool

    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL", "alice:s3cret")
    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL_STDIN", "1")
    wrapper, calls = _recording(subprocess.Popen)
    monkeypatch.setattr(tools_mod.subprocess, "Popen", wrapper)

    execute_tool("bash", {"command": "true"}, ToolContext(cwd=str(tmp_path)))

    assert "s3cret" not in str(calls[0][1]["env"])


def test_web_fetch_error_text_is_redacted(monkeypatch, credentialed_environ):
    """requests raises InvalidURL naming the whole proxy URL when urllib3
    cannot parse the proxy host, and this string goes straight to the model."""
    import requests

    from ollama_code.tools import ToolContext, execute_tool

    def explode(*_args, **_kwargs):
        raise requests.exceptions.InvalidURL(f"Failed to parse: {CREDENTIALED}")

    monkeypatch.setattr(requests, "get", explode)

    result = execute_tool(
        "web_fetch", {"url": "https://example.com"}, ToolContext(cwd=".")
    )

    assert result.startswith("Error fetching")
    assert "s3cret" not in result
    assert CLEAN in result


def test_remote_client_error_text_is_redacted(monkeypatch, credentialed_environ):
    import requests

    from ollama_code.ollama import OllamaError
    from ollama_code.remote import RemoteClient

    def explode(*_args, **_kwargs):
        raise requests.exceptions.InvalidURL(f"Failed to parse: {CREDENTIALED}")

    monkeypatch.setattr(requests, "get", explode)
    client = RemoteClient(base_url="https://endpoint.example/v1", api_key="k")

    with pytest.raises(OllamaError) as excinfo:
        client.check()
    assert "s3cret" not in str(excinfo.value)

    with pytest.raises(OllamaError) as excinfo:
        client.list_models()
    assert "s3cret" not in str(excinfo.value)


# ---------------------------------------------------------------- MCP stdio


def test_stdio_mcp_env_gains_credential_free_proxy_vars(credentialed_environ):
    """The mcp SDK's get_default_environment is an allowlist that drops proxy
    vars entirely — without the merge a stdio server bypasses the proxy."""
    from ollama_code.mcp_runtime import _stdio_environment

    environment = _stdio_environment({}, {}, "")

    assert environment["HTTP_PROXY"] == CLEAN
    assert environment["NO_PROXY"] == "localhost"
    assert "PATH" in environment, "the SDK's own allowlist is still present"
    assert "s3cret" not in str(environment)


def test_stdio_mcp_server_env_overrides_the_merged_proxy(credentialed_environ):
    from ollama_code.mcp_runtime import _stdio_environment

    server = {"env": {"HTTP_PROXY": "http://server-specific.example:9"}}

    environment = _stdio_environment(server, {}, "")

    assert environment["HTTP_PROXY"] == "http://server-specific.example:9"
    assert environment["NO_PROXY"] == "localhost", "the rest of the merge survives"


def test_stdio_mcp_env_vars_passthrough_cannot_name_the_credential(
    credentialed_environ, monkeypatch
):
    """A plugin manifest asking for HTTP_PROXY by name used to be handed the
    credentialed URL straight out of os.environ."""
    from ollama_code.mcp_runtime import _stdio_environment

    monkeypatch.setenv("LOCUS_PROXY_CREDENTIAL", "alice:s3cret")
    monkeypatch.setenv("PLUGIN_TOKEN", "plugin-value")
    server = {
        "env_vars": ["HTTP_PROXY", "https_proxy", "LOCUS_PROXY_CREDENTIAL", "PLUGIN_TOKEN"]
    }

    environment = _stdio_environment(server, {}, "")

    assert "s3cret" not in str(environment)
    assert environment["HTTP_PROXY"] == CLEAN
    assert "https_proxy" not in environment, "an unset variable is still not invented"
    assert "LOCUS_PROXY_CREDENTIAL" not in environment
    assert environment["PLUGIN_TOKEN"] == "plugin-value", "non-proxy vars are unchanged"


def test_stdio_mcp_env_never_carries_an_inherited_credential_either(inherited_environ):
    """The user's own proxy password, with Locus injecting nothing. A bash or
    git child keeps it — it always had it — but get_default_environment is an
    allowlist of HOME/PATH/SHELL/TERM/USER/LOGNAME, so this plugin process had
    no proxy variable at all. Handing it one with the password embedded would
    disclose the password to a third party for the first time."""
    from ollama_code.mcp_runtime import _stdio_environment

    assert not proxy.credential_applied, "Locus injected nothing here"

    environment = _stdio_environment({}, {}, "")

    assert environment["HTTP_PROXY"] == CLEAN, "the proxy is still reachable"
    assert environment["https_proxy"] == CLEAN
    assert "s3cret" not in str(environment)


def test_stdio_mcp_env_vars_cannot_ask_for_the_credential_by_name(inherited_environ):
    """The same disclosure by the other route. A manifest naming HTTP_PROXY in
    ``env_vars`` is asking for the variable, not for a password it never had:
    the passthrough reads the same sanitized snapshot the merge does."""
    from ollama_code.mcp_runtime import _stdio_environment

    assert not proxy.credential_applied, "Locus injected nothing here"

    environment = _stdio_environment({"env_vars": ["HTTP_PROXY", "https_proxy"]}, {}, "")

    assert environment["HTTP_PROXY"] == CLEAN, "asked for it by name, still gets it — clean"
    assert environment["https_proxy"] == CLEAN
    assert "s3cret" not in str(environment)


def test_stdio_mcp_env_vars_passthrough_outranks_the_manifest_env(credentialed_environ, monkeypatch):
    """Documented order: merged proxy vars, then ``env``, then ``env_vars``."""
    from ollama_code.mcp_runtime import _stdio_environment

    monkeypatch.setenv("SHARED_KEY", "from-parent")
    server = {"env": {"SHARED_KEY": "from-manifest"}, "env_vars": ["SHARED_KEY"]}

    environment = _stdio_environment(server, {}, "")

    assert environment["SHARED_KEY"] == "from-parent"


def test_stdio_mcp_stored_credentials_still_win(credentialed_environ, monkeypatch):
    """The stdio half of the invariant ``test_http_mcp_stored_credentials_still_win``
    pins for headers: ``credentials['env']`` is last, so it outranks the merged
    proxy variables, the manifest's own ``env`` map and the ``env_vars``
    passthrough alike."""
    from ollama_code.mcp_runtime import _stdio_environment

    monkeypatch.setenv("PASSTHROUGH_KEY", "from-parent")
    server = {
        "env": {"MANIFEST_KEY": "from-manifest", "HTTP_PROXY": "http://manifest.example:9"},
        "env_vars": ["PASSTHROUGH_KEY"],
    }
    credentials = {
        "env": {
            "MANIFEST_KEY": "from-store",
            "PASSTHROUGH_KEY": "from-store",
            "HTTP_PROXY": "http://store.example:9",
        }
    }

    environment = _stdio_environment(server, credentials, "")

    assert environment["MANIFEST_KEY"] == "from-store"
    assert environment["PASSTHROUGH_KEY"] == "from-store"
    assert environment["HTTP_PROXY"] == "http://store.example:9"


# ------------------------------------------------------- MCP streamable HTTP


def test_http_mcp_env_headers_cannot_exfiltrate_the_credential(
    credentialed_environ, monkeypatch
):
    """env_http_headers copies environment values into outbound headers, so a
    manifest naming a proxy variable would post the password to a third party."""
    from ollama_code.mcp_runtime import _http_headers

    monkeypatch.setenv("PLUGIN_TOKEN", "plugin-value")
    server = {
        "http_headers": {"X-Static": "literal"},
        "env_http_headers": {"X-Meta": "HTTP_PROXY", "X-Token": "PLUGIN_TOKEN"},
    }

    headers = _http_headers(server, {}, "")

    assert "s3cret" not in str(headers)
    assert headers["X-Meta"] == CLEAN
    assert headers["X-Static"] == "literal"
    assert headers["X-Token"] == "plugin-value", "non-proxy vars are unchanged"


def test_http_mcp_bearer_token_env_var_cannot_name_a_proxy_var(credentialed_environ):
    from ollama_code.mcp_runtime import _http_headers

    headers = _http_headers({"bearer_token_env_var": "HTTP_PROXY"}, {}, "")

    assert "s3cret" not in str(headers)
    assert headers["Authorization"] == f"Bearer {CLEAN}"


def test_http_mcp_stored_credentials_still_win(credentialed_environ):
    from ollama_code.mcp_runtime import _http_headers

    server = {
        "http_headers": {"X-Key": "from-manifest"},
        "env_http_headers": {"X-Key": "HTTP_PROXY"},
        "bearer_token_env_var": "HTTP_PROXY",
    }
    credentials = {"headers": {"X-Key": "from-store"}, "access_token": "stored"}

    headers = _http_headers(server, credentials, "")

    assert headers["X-Key"] == "from-store"
    assert headers["Authorization"] == "Bearer stored"
