"""Harness for the manual live-model smoke tests in this directory.

These scripts drive a real model through the real WebSocket protocol, which is
the one thing the in-process suite cannot do. They are not collected by pytest.

The harness exists because the scripts used to connect to
``ws://localhost:8791``, which is the default port a development agent listens
on — so running one drove the developer's own agent against whatever project it
had open, with their real model, answering every permission prompt with
"always". Each run now starts its own server, on its own port, against a
throwaway agent home and a throwaway working directory.
"""
from __future__ import annotations

import argparse
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from contextlib import contextmanager
from pathlib import Path

#: The agent home these scripts must never run against.
REAL_APP_DIR = Path.home() / ".ollama-code"

AGENT_DIR = Path(__file__).resolve().parent.parent.parent


def parse_args(description: str) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--model",
        default=os.environ.get("OLLAMA_CODE_LIVE_MODEL", ""),
        help="model to run against (or set OLLAMA_CODE_LIVE_MODEL). Required: "
             "a live test must not guess which model it is spending time on.",
    )
    args = parser.parse_args()
    if not args.model:
        raise SystemExit(
            "no model given: pass --model NAME or set OLLAMA_CODE_LIVE_MODEL.\n"
            "`ollama list` shows what is installed."
        )
    return args


def _agent_home() -> Path:
    """A throwaway agent home, refusing anything that overlaps the real one."""
    configured = os.environ.get("OLLAMA_CODE_HOME", "").strip()
    if not configured:
        return Path(tempfile.mkdtemp(prefix="ollama-code-live-home-"))
    home = Path(configured).expanduser().resolve()
    real = REAL_APP_DIR.resolve()
    if home == real or home in real.parents or real in home.parents:
        raise SystemExit(
            f"OLLAMA_CODE_HOME ({home}) overlaps the real agent home ({real}).\n"
            "These scripts write config, permissions and transcripts. Point it "
            "somewhere disposable or unset it to get a temp directory."
        )
    home.mkdir(parents=True, exist_ok=True)
    return home


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


@contextmanager
def live_server(model: str):
    """Run a private agent server; yields (base_url, ws_url, workdir)."""
    home = _agent_home()
    workdir = Path(tempfile.mkdtemp(prefix="ollama-code-live-cwd-"))
    port = _free_port()
    env = {**os.environ, "OLLAMA_CODE_HOME": str(home)}
    # No LOCUS_AGENT_TOKEN: the server only demands one for a non-loopback bind,
    # and leaving it unset keeps these scripts free of header plumbing.
    env.pop("LOCUS_AGENT_TOKEN", None)
    proc = subprocess.Popen(
        [
            sys.executable, "-m", "ollama_code.server",
            "--port", str(port),
            "--host", "127.0.0.1",
            "--cwd", str(workdir),
            "--model", model,
        ],
        cwd=str(AGENT_DIR),
        env=env,
    )
    base_url = f"http://127.0.0.1:{port}"
    try:
        deadline = time.time() + 60
        while True:
            if proc.poll() is not None:
                raise SystemExit(f"agent server exited early with {proc.returncode}")
            try:
                with urllib.request.urlopen(f"{base_url}/api/health", timeout=2):
                    break
            except (urllib.error.URLError, OSError) as error:
                if time.time() > deadline:
                    raise SystemExit(
                        f"agent server did not become ready in 60s: {error}"
                    ) from error
                time.sleep(0.25)
        print(f"live server on {port} | home {home} | cwd {workdir} | model {model}")
        yield base_url, f"ws://127.0.0.1:{port}/ws/chat", workdir
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
