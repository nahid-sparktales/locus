import json
import os
import sys
import tempfile
import socket
import subprocess
import time
from pathlib import Path
from types import SimpleNamespace

base = Path(tempfile.mkdtemp(prefix="locus-panel-audit-"))
os.environ["OLLAMA_CODE_HOME"] = str(base / "home")
repo = Path(__file__).resolve().parents[3]
sys.path[:0] = [str(repo / "agent"), str(repo / "agent/tests")]
from test_extensions import _panel_plugin, _marketplace
from ollama_code.api.extensions import call_extension_plugin_panel_tool
from ollama_code.extensions import ExtensionManager
from ollama_code.mcp_runtime import MCPManager

original, selected = base / "original", base / "selected"
original.mkdir()
selected.mkdir()
(original / "project.txt").write_text("ORIGINAL PROJECT DATA")
(selected / "project.txt").write_text("SELECTED PROJECT PRIVATE DATA")
if "--selected-original" in sys.argv:
    selected = original
market = base / "market"
server_config = {
    "command": "${LOCUS_PYTHON}", "args": ["-B", "${PLUGIN_ROOT}/server.py"],
    "cwd": "${LOCUS_WORKSPACE}", "env": {"PROJECT": "${LOCUS_WORKSPACE}"},
    "share_workspace_root": True, "protocol_mode": "legacy",
}
port = None
if "--http" in sys.argv:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    server_config = {"url": f"http://127.0.0.1:{port}/mcp", "share_workspace_root": True, "protocol_mode": "legacy"}
plugin = _panel_plugin(market / "plugins/fixture", server=server_config)
(plugin / "server.py").write_text('''
import json, os
from pathlib import Path
from mcp.server import MCPServer
from mcp.server.mcpserver import Context
server = MCPServer("workspace-probe")
@server.tool(structured_output=False)
async def status(ctx: Context) -> str:
    roots = await ctx.request_context.session.list_roots()
    return json.dumps({"meta": ctx.request_context.meta, "cwd": os.getcwd(),
        "env_project": os.getenv("PROJECT"), "roots": [str(r.uri) for r in roots.roots],
        "read_relative": Path("project.txt").read_text()})
server.run("stdio")
''')
process = None
if port:
    file = plugin / "server.py"
    file.write_text(file.read_text().replace('server.run("stdio")', f'server.run("streamable-http", host="127.0.0.1", port={port})'))
    process = subprocess.Popen([sys.executable, "-B", str(file)], cwd=selected, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                break
        except OSError:
            time.sleep(0.1)
_marketplace(market, plugin)
manager = ExtensionManager(str(selected), root=base / "state")
source = manager.add_marketplace(str(market))
inspection = manager.inspect_catalog_plugin(source["id"], "fixture")
installed = manager.install_plugin(source["id"], "fixture", scope="workspace", workspace=str(original), expected_digest=inspection["digest"])
runtime = MCPManager(manager)
service = SimpleNamespace(core=SimpleNamespace(cwd=str(selected), extensions=manager, mcp=runtime))
request = {"plugin_id": installed["id"], "tool": "status", "arguments": {},
           "workspace": str(original), "panel_id": "workflows", "digest": installed["digest"]}
try:
    print(json.dumps({"original": str(original), "selected": str(selected),
        "active_in_selected": manager.mcp_servers()[0]["active"],
        "response": call_extension_plugin_panel_tool(service, request)}, indent=2))
finally:
    runtime.close()
    if process:
        process.terminate()
        process.wait(timeout=10)
