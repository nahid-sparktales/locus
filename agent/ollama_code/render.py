"""Rich rendering helpers and the streaming <think> filter."""
from __future__ import annotations

import re

from rich.console import Console
from rich.markup import escape
from rich.panel import Panel
from rich.text import Text

console = Console()

_THINK_RE = re.compile(r"<think(?:ing)?>.*?</think(?:ing)?>", re.DOTALL)
_THINK_UNCLOSED_RE = re.compile(r"<think(?:ing)?>.*", re.DOTALL)


def strip_think(text: str) -> str:
    """Remove think blocks from stored message content."""
    return _THINK_UNCLOSED_RE.sub("", _THINK_RE.sub("", text)).strip()


class ThinkFilter:
    """Split inline reasoning from visible output across arbitrary chunks."""

    OPEN_TAGS = {"<think>": "</think>", "<thinking>": "</thinking>"}

    def __init__(self) -> None:
        self._buf = ""
        self._in_think = False
        self._close_tag = "</think>"
        self._pending_thinking: list[str] = []
        self._all_thinking: list[str] = []
        #: Everything handed to the UI so far, so a stream that dies mid-way
        #: can still be persisted instead of vanishing from the transcript.
        self._emitted: list[str] = []

    def feed(self, token: str) -> str:
        self._buf += token
        out: list[str] = []
        while self._buf:
            if self._in_think:
                end = self._buf.find(self._close_tag)
                if end == -1:
                    # Surface all reasoning except a tail that may be the
                    # beginning of the closing tag.
                    keep = self._partial_suffix_len(self._close_tag)
                    emit_end = len(self._buf) - keep
                    self._record_thinking(self._buf[:emit_end])
                    self._buf = self._buf[emit_end:]
                    break
                self._record_thinking(self._buf[:end])
                self._buf = self._buf[end + len(self._close_tag):]
                self._in_think = False
            else:
                found = [
                    (self._buf.find(open_tag), open_tag, close_tag)
                    for open_tag, close_tag in self.OPEN_TAGS.items()
                    if self._buf.find(open_tag) >= 0
                ]
                if not found:
                    keep = max(self._partial_suffix_len(tag) for tag in self.OPEN_TAGS)
                    emit_end = len(self._buf) - keep
                    out.append(self._buf[:emit_end])
                    self._buf = self._buf[emit_end:]
                    break
                start, open_tag, close_tag = min(found, key=lambda item: item[0])
                out.append(self._buf[:start])
                self._buf = self._buf[start + len(open_tag):]
                self._in_think = True
                self._close_tag = close_tag
        text = "".join(out)
        if text:
            self._emitted.append(text)
        return text

    def flush(self) -> str:
        if self._in_think:
            self._record_thinking(self._buf)
            tail = ""
        else:
            tail = self._buf
        self._buf = ""
        if tail:
            self._emitted.append(tail)
        return tail

    def flush_all(self) -> str:
        """Everything emitted so far, including any un-flushed tail."""
        self.flush()
        return "".join(self._emitted)

    def take_thinking(self) -> str:
        """Return reasoning discovered since the previous call."""
        text = "".join(self._pending_thinking)
        self._pending_thinking = []
        return text

    @property
    def thinking(self) -> str:
        return "".join(self._all_thinking)

    def _record_thinking(self, text: str) -> None:
        if text:
            self._pending_thinking.append(text)
            self._all_thinking.append(text)

    def _partial_suffix_len(self, tag: str) -> int:
        for n in range(min(len(tag) - 1, len(self._buf)), 0, -1):
            if self._buf.endswith(tag[:n]):
                return n
        return 0


# ---------------------------------------------------------------------------
# print helpers


def print_banner(model: str, host: str, cwd: str, has_context: bool, session_path: str) -> None:
    ctx_line = "project context: OLLAMA.md loaded\n" if has_context else ""
    console.print(
        Panel.fit(
            f"[bold cyan]ollama-code[/bold cyan]\n"
            f"model: [green]{escape(model)}[/green]   host: {escape(host)}\n"
            f"cwd: {escape(cwd)}\n"
            f"{ctx_line}"
            f"session: {escape(session_path)}\n\n"
            "[dim]/help for commands · Ctrl+C interrupts · Ctrl+D exits[/dim]",
            border_style="cyan",
        )
    )


def print_error(message: str) -> None:
    console.print(Text(f"Error: {message}", style="red"))


def print_info(message: str) -> None:
    console.print(Text(message, style="green"))


def print_tool_call_compact(summary: str) -> None:
    console.print(Text(f"⚙ {summary}", style="cyan"))


def print_tool_result(result: str) -> None:
    lines = result.splitlines() or [""]
    shown = lines[:6]
    text = "\n".join(shown)
    if len(lines) > 6:
        text += f"\n… (+{len(lines) - 6} lines)"
    console.print(Text("⎿ " + text.replace("\n", "\n  "), style="dim"))


def print_todos(todos: list[dict[str, str]]) -> None:
    if not todos:
        console.print("[dim]No tasks. The model can create a plan with todo_write.[/dim]")
        return
    icons = {"pending": "☐", "in_progress": "◐", "completed": "☑"}
    styles = {"pending": "white", "in_progress": "yellow", "completed": "green"}
    lines = []
    for t in todos:
        status = t.get("status", "pending")
        icon = icons.get(status, "☐")
        style = styles.get(status, "white")
        lines.append(f"[{style}]{icon} {escape(t.get('content', ''))}[/{style}]")
    console.print(Panel("\n".join(lines), title="Tasks", border_style="blue", padding=(0, 1)))


def print_diff(detail: str) -> None:
    """Render a unified diff with per-line coloring."""
    for line in detail.splitlines():
        if line.startswith("@@"):
            console.print(Text(line, style="cyan"))
        elif line.startswith(("+++", "---")):
            console.print(Text(line, style="dim"))
        elif line.startswith("+"):
            console.print(Text(line, style="green"))
        elif line.startswith("-"):
            console.print(Text(line, style="red"))
        else:
            console.print(Text(line))


def show_permission_request(summary: str, detail: str) -> None:
    if detail:
        console.print(
            Panel(
                Text(detail[:4000]),
                title=f"[yellow]Permission needed:[/yellow] {escape(summary)}",
                border_style="yellow",
                padding=(0, 1),
            )
        )
    else:
        console.print(f"[yellow]Permission needed:[/yellow] {escape(summary)}")
