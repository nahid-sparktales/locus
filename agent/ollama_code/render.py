"""Rich rendering helpers and the streaming <think> filter."""
from __future__ import annotations

from rich.console import Console
from rich.markup import escape
from rich.panel import Panel
from rich.text import Text

console = Console()

def strip_think(text: str) -> str:
    """Remove legacy reasoning, preserving Markdown code and escaped examples."""
    scanner = ThinkFilter()
    return (scanner.feed(text) + scanner.flush()).strip()


class ThinkFilter:
    """Split legacy reasoning without interpreting tags inside literal Markdown.

    Delimiter runs and partial tags are retained across token boundaries. This is
    deliberately conservative for an unfinished code span: losing answer text is
    worse than displaying a tag example whose closing backtick never arrived.
    """

    OPEN_TAGS = {"<think>": "</think>", "<thinking>": "</thinking>"}

    def __init__(self) -> None:
        self._buf = ""
        self._in_think = False
        self._close_tag = "</think>"
        self._fence: tuple[str, int] | None = None
        self._inline_ticks = 0
        self._escaped = False
        self._line_prefix = True
        self._indent = 0
        self._indented_line = False
        self._pending_thinking: list[str] = []
        self._all_thinking: list[str] = []
        self._emitted: list[str] = []

    def _visible(self, value: str, out: list[str]) -> None:
        out.append(value)
        for char in value:
            if char == "\n":
                self._line_prefix = True
                self._indent = 0
                self._indented_line = False
            elif self._line_prefix and char in " \t":
                self._indent += 4 if char == "\t" else 1
                self._indented_line = self._indent >= 4
            else:
                self._line_prefix = False

    def feed(self, token: str) -> str:
        self._buf += token
        return self._scan(final=False)

    def _scan(self, *, final: bool) -> str:
        out: list[str] = []
        cursor = 0
        data = self._buf
        while cursor < len(data):
            if self._in_think:
                end = data.find(self._close_tag, cursor)
                if end < 0:
                    keep = 0 if final else self._partial_suffix_len(data[cursor:], self._close_tag)
                    limit = len(data) - keep
                    self._record_thinking(data[cursor:limit])
                    cursor = limit
                    break
                self._record_thinking(data[cursor:end])
                cursor = end + len(self._close_tag)
                self._in_think = False
                continue

            char = data[cursor]
            # A fenced block ends only on its own delimiter line. Retain a
            # possible closing line until its trailing whitespace is known.
            if self._fence is not None:
                marker, width = self._fence
                if self._line_prefix and self._indent <= 3 and char == marker:
                    end = cursor
                    while end < len(data) and data[end] == marker:
                        end += 1
                    if end == len(data) and not final:
                        break
                    if end - cursor >= width:
                        newline = data.find("\n", end)
                        if newline < 0 and not final:
                            break
                        limit = newline if newline >= 0 else len(data)
                        if not data[end:limit].strip():
                            self._fence = None
                        self._visible(data[cursor:limit], out)
                        cursor = limit
                        continue
                self._visible(char, out)
                cursor += 1
                continue

            if self._inline_ticks:
                if char == "`":
                    end = cursor
                    while end < len(data) and data[end] == "`":
                        end += 1
                    if end == len(data) and not final:
                        break
                    if end - cursor == self._inline_ticks:
                        self._inline_ticks = 0
                    self._visible(data[cursor:end], out)
                    cursor = end
                else:
                    self._visible(char, out)
                    cursor += 1
                continue

            if self._escaped or self._indented_line:
                self._escaped = False
                self._visible(char, out)
                cursor += 1
                continue
            if char == "\\":
                self._escaped = True
            elif char in "`~":
                end = cursor
                while end < len(data) and data[end] == char:
                    end += 1
                if end == len(data) and not final:
                    break
                width = end - cursor
                if self._line_prefix and self._indent <= 3 and width >= 3:
                    self._fence = (char, width)
                elif char == "`":
                    self._inline_ticks = width
                self._visible(data[cursor:end], out)
                cursor = end
                continue
            elif char == "<":
                opened = next((tag for tag in self.OPEN_TAGS if data.startswith(tag, cursor)), None)
                if opened is not None:
                    self._in_think = True
                    self._close_tag = self.OPEN_TAGS[opened]
                    cursor += len(opened)
                    continue
                if not final and len(data) - cursor < 10 and any(tag.startswith(data[cursor:]) for tag in self.OPEN_TAGS):
                    break
            self._visible(char, out)
            cursor += 1
        self._buf = data[cursor:]
        text = "".join(out)
        if text:
            self._emitted.append(text)
        return text

    def flush(self) -> str:
        return self._scan(final=True)

    def flush_all(self) -> str:
        """Everything emitted so far, including any un-flushed tail."""
        self.flush()
        return "".join(self._emitted)

    def take_thinking(self) -> str:
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

    @staticmethod
    def _partial_suffix_len(text: str, tag: str) -> int:
        for size in range(min(len(tag) - 1, len(text)), 0, -1):
            if text.endswith(tag[:size]):
                return size
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
