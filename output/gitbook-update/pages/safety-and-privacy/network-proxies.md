# Network Proxies

Route V2 traffic through named proxy profiles with strict tunnel and health-ranked failover.

Open Settings → Network or the Proxies inspector.

Locus supports direct, macOS system, HTTP/HTTPS, and SOCKS5 routes. Manual routes can cover app requests, hosted models, agent web traffic, Browser, downloads, Git, Terminal, and MCP. SOCKS5 uses remote DNS.

## Profiles and assignment

Create named profiles, then assign them by traffic class, workspace, or provider. A more specific assignment wins over the general route. Health checks report latency and the externally observed exit address.

Automatic failover checks the pool every minute and chooses the fastest healthy standby. **Strict tunnel** ignores custom bypass entries and blocks external traffic when no configured route is available. Locus never silently falls back to a direct external connection.

Loopback, the app-to-agent connection, and the configured Ollama host remain direct.

## System proxy caveats

The agent receives a snapshot of macOS proxy settings when it starts. Restart it after system changes. PAC files cannot be translated into the environment used by all agent libraries, so choose a manual Locus profile when the network requires the tunnel.

The MCP OAuth browser follows macOS system networking. Configure the system proxy as well when only the proxy can reach the sign-in page.

## Authentication and child processes

Manual profiles support Basic authentication. Proxy secrets are withheld from shell commands, Terminal children, Git, stdio MCP servers, and Ollama processes started by Locus. Those children can receive the proxy address without the password and may report HTTP 407 by design.

Custom bypass values accept hostnames, IP addresses, and suffixes such as `.example.com`; CIDR is not supported.
