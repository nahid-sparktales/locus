"""Product account/login adapter over the canonical SSH transport."""
from locus_runtime.remote import RemoteRuntimes as _RemoteRuntimes
from locus_runtime.remote import ssh_arguments

__all__ = ["RemoteRuntimes", "ssh_arguments"]


class RemoteRuntimes(_RemoteRuntimes):
    def __init__(self, runtime):
        super().__init__(getattr(runtime, "store", None), getattr(runtime, "private", None), getattr(runtime, "root", None))

    def login(self, key, account_id, method, provider="chatgpt"):
        if provider == "claude_plan":
            from urllib.parse import parse_qs, urlsplit
            status = self.request(key, "GET", "/api/runtime")
            if not status.get("capabilities", {}).get("remote_claude_plan"):
                raise ValueError("This host does not advertise Claude plan support. Update and enable its runtime first.")
            result = self.request(key, "POST", "/api/claude/login/start", {"account_id": account_id})
            callback = parse_qs(urlsplit(result.get("auth_url", "")).query).get("redirect_uri", [""])[0]
            address = urlsplit(callback)
            if address.hostname in {"localhost", "127.0.0.1"} and address.port and address.port >= 1024:
                self.forward_callback(key, address.port, failure="The Claude login callback port is unavailable on this Mac.")
            return result
        if provider != "chatgpt":
            raise ValueError("Unsupported subscription provider")
        if method == "browser":
            self.forward_callback(key, 1455, failure="Browser login needs local port 1455 available for its SSH tunnel")
        elif method != "device_code":
            raise ValueError("Choose device_code or browser login")
        return self.request(key, "POST", "/api/chatgpt/login/start", {"account_id": account_id, "method": method})
