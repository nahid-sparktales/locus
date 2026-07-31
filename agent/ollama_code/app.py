"""Terminal CLI for ollama-code: interactive REPL rendering AgentCore events."""
from __future__ import annotations

import argparse
import sys
from typing import Any

from rich.live import Live
from rich.markdown import Markdown
from rich.markup import escape
from rich.panel import Panel
from rich.text import Text

from . import __version__
from .core import SLASH_COMMANDS, AgentCore
from .ollama import DEFAULT_HOST, OllamaError
from .paths import APP_DIR
from .render import (
    console,
    print_banner,
    print_diff,
    print_error,
    print_info,
    print_todos,
    print_tool_call_compact,
    print_tool_result,
    show_permission_request,
)
from .sessions import SessionStore

HISTORY_FILE = APP_DIR / "history"

HELP_TEXT = """[bold]Slash commands[/bold]
  /help                  show this help
  /model \\[name]        list installed models and switch (interactively or by name)
  /clear                 start a fresh conversation
  /compact               summarize older messages to free up context
  /init                  scan the project and write an OLLAMA.md context file
  /todos                 show the current task list
  /tools                 list the tools the agent can call
  /status                model, cwd, session, token usage  (alias: /cost)
  /sessions              list recent sessions
  /resume \\[n]          resume session n (default: most recent)
  /diff                  show the working-tree diff
  /retry                 regenerate the last response
  /permissions \\[reset] show or reset tool allowances
  /permissions mode M    ask | accept_edits | bypass
  /exit                  quit (Ctrl+D also works)

[bold]Keys[/bold]
  Enter        send            Alt+Enter   insert newline
  \\ at end of line  continue input  Ctrl+C      interrupt generation / clear line
  Ctrl+D       quit

[bold]Permissions[/bold]
  read_file, glob, grep, list_dir and todo_write always run automatically.
  Other tools ask first: y = allow once, a = always allow this tool, n = deny.
  Start with --dangerously-skip-permissions (-y) to auto-allow everything.
"""


class ExitREPL(Exception):
    """Raised to leave the REPL."""


class App:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.core = AgentCore(
            host=args.host,
            model=args.model or "",
            skip_permissions=bool(args.skip_permissions),
            cwd=args.cwd or None,
        )
        self.core.on_event(self._on_event)
        self._live: Live | None = None
        self._shown: list[str] = []
        self._thinking = False

        APP_DIR.mkdir(parents=True, exist_ok=True)
        self.psession: Any = None
        if sys.stdin.isatty():
            try:
                from prompt_toolkit import PromptSession
                from prompt_toolkit.completion import WordCompleter
                from prompt_toolkit.history import FileHistory
                from prompt_toolkit.key_binding import KeyBindings
            except ImportError:
                return
            kb = KeyBindings()

            @kb.add("escape", "enter")  # Alt+Enter -> newline
            def _newline(event: Any) -> None:
                event.current_buffer.insert_text("\n")

            @kb.add("enter")  # Enter -> submit
            def _accept(event: Any) -> None:
                event.current_buffer.validate_and_handle()

            self.psession = PromptSession(
                history=FileHistory(str(HISTORY_FILE)),
                key_bindings=kb,
                multiline=True,
                completer=WordCompleter(SLASH_COMMANDS, sentence=True),
                complete_while_typing=False,
                prompt_continuation="… ",
            )

    # --------------------------------------------------------- event rendering

    def _on_event(self, event: dict[str, Any]) -> None:
        etype = event.get("type")
        if etype == "message_start":
            self._shown = []
            self._thinking = False
            if console.is_terminal:
                self._live = Live(
                    Text("…", style="dim"),
                    console=console,
                    refresh_per_second=8,
                    vertical_overflow="visible",
                )
                self._live.start()
        elif etype == "thinking":
            if not self._thinking:
                self._thinking = True
                if self._live is None:
                    console.print("[dim]thinking…[/dim]")
        elif etype == "token":
            piece = str(event.get("text", ""))
            self._shown.append(piece)
            if self._live is not None:
                text = "".join(self._shown)
                self._live.update(Markdown(text) if text.strip() else Text("…", style="dim"))
            else:
                print(piece, end="", flush=True)
        elif etype == "message_end":
            if self._live is not None:
                text = "".join(self._shown)
                self._live.update(Markdown(text) if text.strip() else Text("…", style="dim"))
                self._live.stop()
                self._live = None
            else:
                print()
        elif etype == "tool_call_proposed":
            if event.get("auto"):
                print_tool_call_compact(str(event.get("summary", "")))
        elif etype == "permission_request":
            pass  # the decider renders the prompt synchronously
        elif etype == "tool_result":
            if event.get("tool") != "todo_write":  # todo panel renders via todo_update
                print_tool_result(str(event.get("result", "")))
        elif etype == "todo_update":
            print_todos(event.get("todos") or [])
        elif etype == "error":
            print_error(str(event.get("message", "")))
        elif etype == "session_started":
            reason = event.get("reason")
            if reason == "clear_chat":
                console.print("[dim]Started a fresh session.[/dim]")
        elif etype == "turn_done":
            reason = event.get("reason")
            if reason == "interrupted":
                console.print("\n[yellow]Interrupted (Ctrl+C). Session kept — you can continue typing.[/yellow]")
            elif reason == "max_iterations":
                console.print(
                    f"[yellow]Stopped after {self.core.max_iterations} tool iterations "
                    "(safety limit).[/yellow]"
                )

    # -------------------------------------------------------------- permission

    def _decider(self, tool_name: str, summary: str, detail: str, request_id: str) -> str:
        if detail and ("@@" in detail or detail.startswith(("---", "+++", "+"))):
            console.print(f"[yellow]Permission needed:[/yellow] {escape(summary)}")
            print_diff(detail[:4000])
        else:
            show_permission_request(summary, detail)
        always_label = f"always allow {tool_name}"
        console.print(
            "[bold]Allow?[/bold]  \\[y] yes, once   \\[n] no   "
            f"\\[a] {escape(always_label)}   ",
            end="",
        )
        try:
            choice = input().strip().lower()
        except (EOFError, KeyboardInterrupt):
            console.print("[dim](no)[/dim]")
            return "deny"
        if choice in ("y", "yes"):
            return "once"
        if choice in ("a", "always") or (choice in ("b", "bash") and tool_name == "bash"):
            console.print(f"[dim]{escape(tool_name)} allowed for the rest of this session.[/dim]")
            return "always"
        return "deny"

    # ------------------------------------------------------------------- setup

    def startup_checks(self) -> None:
        """Verify Ollama is reachable and pick a model. SystemExit on failure."""
        try:
            self.core.client.check()
        except OllamaError as e:
            console.print(
                Panel(
                    f"[red]Cannot reach Ollama at {escape(self.core.host)}.[/red]\n\n"
                    "Start it in another terminal with:\n\n  [bold]ollama serve[/bold]\n",
                    title="Ollama not running",
                    border_style="red",
                )
            )
            raise SystemExit(1) from e
        try:
            warning = self.core.ensure_model()
        except OllamaError as e:
            if "no models" in str(e):
                console.print(
                    Panel(
                        "[red]No Ollama models are installed.[/red]\n\n"
                        "Install one first, for example:\n\n  [bold]ollama pull qwen3:8b[/bold]\n",
                        title="No models",
                        border_style="red",
                    )
                )
            else:
                print_error(str(e))
            raise SystemExit(1) from e
        if warning:
            console.print(f"[yellow]Warning:[/yellow] {escape(warning)}")
        if self.core.model and not self.core.client.supports_tools(self.core.model):
            console.print(
                f"[yellow]Warning:[/yellow] {escape(self.core.model)} may not support tool "
                "calling; the agent cannot edit files with it."
            )
        self.core.messages = [self.core.system_message()]

    # -------------------------------------------------------------------- REPL

    def read_input(self) -> str | None:
        """Read one user input. None means Ctrl+D (quit)."""
        prompt_fn = self.psession.prompt if self.psession is not None else input
        try:
            text = prompt_fn("❯ ")
        except KeyboardInterrupt:
            return ""
        except EOFError:
            return None
        while text.endswith("\\"):
            text = text[:-1] + "\n"
            try:
                text += prompt_fn("… ")
            except KeyboardInterrupt:
                return ""
            except EOFError:
                return None
        return text

    def repl(self) -> None:
        while True:
            user = self.read_input()
            if user is None:
                console.print("[dim]Goodbye.[/dim]")
                return
            text = user.strip()
            if not text:
                continue
            try:
                if text.startswith("/"):
                    self.handle_slash(text)
                else:
                    self.core.run_turn(text, self._decider)
            except ExitREPL:
                console.print("[dim]Goodbye.[/dim]")
                return
            except KeyboardInterrupt:
                console.print("\n[yellow]Interrupted.[/yellow]")
            except Exception as e:  # noqa: BLE001 - never crash the REPL
                print_error(f"unexpected error: {e}")

    # ----------------------------------------------------------- slash commands

    def handle_slash(self, text: str) -> None:
        parts = text.strip().split(maxsplit=1)
        cmd = parts[0].lower()
        arg = parts[1] if len(parts) > 1 else ""
        if cmd == "/help":
            console.print(HELP_TEXT)
            return
        if cmd == "/model":
            self.cmd_model_interactive(arg)
            return
        result = self.core.handle_slash(text, self._decider)
        if result.get("command") == "exit":
            raise ExitREPL
        self._render_slash_result(result)

    def _render_slash_result(self, result: dict[str, Any]) -> None:
        cmd = result.get("command")
        data = result.get("data") or {}
        text = str(result.get("text") or "")
        if result.get("error"):
            if text:
                print_error(text)
            return
        if cmd == "todos":
            print_todos(data.get("todos") or [])
        elif cmd == "diff":
            if text.strip() in ("", "(no output)"):
                console.print("[dim]No changes in the working tree.[/dim]")
            else:
                print_diff(text)
        elif cmd == "status":
            lines = [
                f"model: {data.get('model')}",
                f"host: {data.get('host')}",
                f"cwd: {data.get('cwd')}",
                f"session file: {data.get('session')}",
                f"messages in context: {data.get('messages')} (~{data.get('approx_tokens')} tokens"
                + (f" of {data.get('context_limit')}" if data.get("context_limit") else "") + ")",
                f"tokens used (from Ollama): {data.get('prompt_tokens')} prompt / "
                f"{data.get('completion_tokens')} completion",
                f"permission mode: {(data.get('permissions') or {}).get('mode')}",
                f"max tool iterations: {data.get('max_iterations')}",
            ]
            console.print(Panel("\n".join(lines), title="Status", border_style="blue", padding=(0, 1)))
        elif cmd == "sessions":
            sessions = data.get("sessions") or []
            if not sessions:
                console.print("[dim]No saved sessions yet.[/dim]")
            else:
                console.print("[bold]Recent sessions[/bold] (use /resume <n>):")
                for i, s in enumerate(sessions, 1):
                    pin = "📌 " if s.get("pinned") else ""
                    title = s.get("title") or s.get("name", "")
                    console.print(f"  {i}. {pin}{escape(str(title))}\n"
                                  f"     [dim]{escape(str(s.get('preview', '')))}[/dim]")
        elif cmd in ("permissions", "tools"):
            console.print(Panel(Text(text), title=str(cmd).title(), border_style="blue", padding=(0, 1)))
        elif text:
            print_info(text)

    def cmd_model_interactive(self, arg: str) -> None:
        if arg:
            self._render_slash_result(self.core.handle_slash(f"/model {arg}"))
            return
        try:
            models = self.core.client.list_models()
        except OllamaError as e:
            print_error(str(e))
            return
        names = [m.get("name") for m in models if m.get("name")]
        if not names:
            print_error("no models installed — run: ollama pull qwen3:8b")
            return
        sizes = {m.get("name"): (m.get("size") or 0) for m in models}
        console.print("[bold]Installed models:[/bold]")
        for i, n in enumerate(names, 1):
            gb = sizes.get(n, 0) / 1_000_000_000
            marker = " [green](current)[/green]" if n == self.core.model else ""
            size = f" [dim]({gb:.1f} GB)[/dim]" if gb else ""
            console.print(f"  {i}. {escape(n)}{size}{marker}")
        console.print("Enter a number to switch (blank to cancel): ", end="")
        try:
            choice = input().strip()
        except (EOFError, KeyboardInterrupt):
            console.print()
            return
        if not choice:
            return
        try:
            idx = int(choice)
        except ValueError:
            print_error("not a number.")
            return
        if 1 <= idx <= len(names):
            self.core.set_model(names[idx - 1])
            print_info(f"Switched to model {names[idx - 1]} (saved as default).")
        else:
            print_error("out of range.")

    def resume_latest(self) -> None:
        files = SessionStore.list_sessions()
        if not files:
            console.print("[dim]No previous sessions to continue.[/dim]")
            return
        result = self.core.resume_session(files[0].stem)
        print_info(str(result.get("text", "")))


# ----------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="ollama-code",
        description="A Claude Code-style AI coding agent powered by local Ollama models.",
    )
    parser.add_argument("--model", "-m", help="Ollama model to use (default: config default or first installed).")
    parser.add_argument("--host", help=f"Ollama host URL (default: {DEFAULT_HOST}).")
    parser.add_argument("--cwd", help="Working directory for the agent (default: current directory).")
    parser.add_argument("--print", "-p", dest="print_prompt", metavar="PROMPT",
                        help="Run one prompt non-interactively, print the answer, and exit.")
    parser.add_argument("--continue", "-c", dest="continue_session", action="store_true",
                        help="Resume the most recent session.")
    parser.add_argument("--dangerously-skip-permissions", "--yes", "-y", dest="skip_permissions",
                        action="store_true", help="Auto-allow every tool call. Use with care.")
    parser.add_argument("--serve", action="store_true",
                        help="Run the REST/WebSocket server instead of the REPL.")
    parser.add_argument("--port", type=int, default=8791, help="Port for --serve (default: 8791).")
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    args = parser.parse_args(argv)

    if args.serve:
        from .server import main as serve_main

        serve_argv = ["--port", str(args.port)]
        if args.model:
            serve_argv += ["--model", args.model]
        if args.cwd:
            serve_argv += ["--cwd", args.cwd]
        if args.skip_permissions:
            serve_argv.append("--dangerously-skip-permissions")
        serve_main(serve_argv)
        return 0

    app = App(args)
    try:
        app.startup_checks()
    except SystemExit as e:
        return int(e.code or 0)
    if args.continue_session:
        app.resume_latest()
    if args.print_prompt is not None:
        app.core.run_turn(args.print_prompt, app._decider)
        return 0
    core = app.core
    print_banner(core.model, core.host, core.cwd, bool(core.project_context), str(core.session.path))
    app.repl()
    return 0
