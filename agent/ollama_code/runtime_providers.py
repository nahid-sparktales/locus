"""Supervisor-owned local model helpers; externally managed servers stay external."""
from __future__ import annotations

import asyncio
import ipaddress
import os
import shutil
from pathlib import Path
from urllib.parse import urlsplit

import requests


class RuntimeProviders:
    def __init__(self, runtime):
        self.runtime = runtime
        self.processes = {}
        self.lock = asyncio.Lock()

    @staticmethod
    def local_address(value):
        parsed = urlsplit(value)
        if parsed.scheme != 'http' or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in {'', '/'}:
            raise ValueError('Automatic Ollama startup requires a plain local HTTP address')
        host = parsed.hostname
        if host != 'localhost' and (not host or not ipaddress.ip_address(host).is_loopback):
            raise ValueError('Automatic Ollama startup requires a loopback address')
        port = parsed.port or 11434
        if not 1024 <= port <= 65535:
            raise ValueError('Ollama needs an unprivileged port')
        return f'http://127.0.0.1:{port}' if host == 'localhost' else f'http://[{host}]:{port}' if ':' in host else f'http://{host}:{port}'

    @staticmethod
    def healthy(address):
        try:
            with requests.Session() as client:
                client.trust_env = False
                return client.get(address + '/api/tags', timeout=2, allow_redirects=False).status_code == 200
        except requests.RequestException:
            return False

    async def ensure_ollama(self, value):
        address = self.local_address(value)
        async with self.lock:
            if await asyncio.to_thread(self.healthy, address):
                return {'ok': True, 'message': 'Ollama is running.', 'owned': address in self.processes}
            process = self.processes.get(address)
            if process is None or process.returncode is not None:
                candidates = [shutil.which('ollama'), '/opt/homebrew/bin/ollama', '/usr/local/bin/ollama', '/Applications/Ollama.app/Contents/Resources/ollama']
                executable = next((path for path in candidates if path and Path(path).is_file() and os.access(path, os.X_OK)), None)
                if not executable:
                    raise ValueError('Install Ollama on this runtime host, then retry.')
                from .proxy import sanitized_child_environment
                environment = sanitized_child_environment()
                environment.update(OLLAMA_HOST=address)
                process = await asyncio.create_subprocess_exec(executable, 'serve', env=environment,
                    stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL)
                self.processes[address] = process
                addresses = self.runtime.private.read().get('ollama_hosts', [])
                self.runtime.private.set('ollama_hosts', sorted(set(addresses + [address])))
            for _ in range(80):
                if process.returncode is not None:
                    raise ValueError('The runtime could not start Ollama. Inspect the host installation.')
                if await asyncio.to_thread(self.healthy, address):
                    return {'ok': True, 'message': 'The independent runtime started Ollama.', 'owned': True}
                await asyncio.sleep(.25)
            raise ValueError('Ollama did not become ready on the runtime host.')

    async def close(self):
        for process in self.processes.values():
            if process.returncode is None:
                process.terminate()
                try:
                    await asyncio.wait_for(process.wait(), timeout=3)
                except TimeoutError:
                    process.kill()
                    await process.wait()
