"""Process characterization through the Locus adapter, with harmless workers."""
import asyncio
import contextlib
import socket
import sys
from types import SimpleNamespace

import pytest
import requests

from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor, Worker


def supervisor(tmp_path):
    app = SimpleNamespace(state=SimpleNamespace(service=SimpleNamespace(
        run_store=RunStore(tmp_path / "runs.sqlite3"))))
    return RuntimeSupervisor(app, tmp_path / "private", port=1)


def test_worker_output_is_drained_without_publishing_provider_secrets(tmp_path):
    async def scenario():
        runtime = supervisor(tmp_path)
        runtime.store.save_worker("output", str(tmp_path))
        # Exceed ordinary OS pipe capacity on both streams. Finishing the child
        # requires a reader; the bytes must never enter the public event store.
        script = ("import sys; "
                  "sys.stdout.write('provider-secret-fixture' * 200000); "
                  "sys.stdout.flush(); "
                  "sys.stderr.write('private-stderr-fixture' * 200000); "
                  "sys.stderr.flush()")
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", script,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        worker = Worker("output", process, 1, "fixture")
        runtime.workers["output"] = worker
        worker.log_task = asyncio.create_task(runtime._drain(worker))
        try:
            await asyncio.wait_for(process.wait(), timeout=10)
            await asyncio.wait_for(worker.log_task, timeout=2)
            assert process.returncode == 0
            assert runtime.store.events("output") == []
            await runtime.stop_worker("output")
            await runtime.stop_worker("output")
            await runtime.close()
            await runtime.close()
            assert not runtime.workers
        finally:
            if process.returncode is None:
                process.kill()
            await process.wait()
            if not worker.log_task.done():
                worker.log_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker.log_task
    asyncio.run(scenario())


@pytest.mark.parametrize("occupied_port", [False, True], ids=["startup-exit", "occupied-port"])
def test_failed_worker_start_cleans_only_its_owned_process(tmp_path, monkeypatch, occupied_port):
    async def scenario():
        runtime = supervisor(tmp_path)
        created = []
        original_spawn = asyncio.create_subprocess_exec
        # This listener belongs to the test host, not the runtime. A failing
        # worker must not probe for/terminate the process owning an occupied port.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            script = ("import socket; s=socket.socket(); "
                      f"s.bind(('127.0.0.1', {port}))") if occupied_port else "raise SystemExit(17)"

            async def fixture_spawn(*_command, **options):
                process = await original_spawn(sys.executable, "-c", script, **options)
                created.append(process)
                return process

            async def unavailable(*_args, **_kwargs):
                raise requests.ConnectionError("Fixture has no authenticated worker service")

            monkeypatch.setattr(asyncio, "create_subprocess_exec", fixture_spawn)
            monkeypatch.setattr(runtime, "request", unavailable)
            try:
                with pytest.raises(RuntimeError, match="exited during startup"):
                    await asyncio.wait_for(runtime.ensure_worker("failed", str(tmp_path)), timeout=10)
                assert len(created) == 1
                assert created[0].returncode is not None
                assert not runtime.workers
                await runtime.stop_worker("failed")
                await runtime.close()
                await runtime.close()
                # Verify the unrelated listener remains reachable after failure.
                with socket.create_connection(("127.0.0.1", port), timeout=2):
                    pass
                assert runtime.store.events("failed") == []
            finally:
                for process in created:
                    if process.returncode is None:
                        process.kill()
                    await process.wait()
    asyncio.run(scenario())


def test_cancel_during_worker_readiness_reaps_child_and_preserves_queued_work(tmp_path, monkeypatch):
    async def scenario():
        runtime = supervisor(tmp_path)
        runtime.store.enqueue("starting", {"type": "user_message", "request_id": "queued", "text": "fixture"})
        created = []
        entered_readiness = asyncio.Event()
        original_spawn = asyncio.create_subprocess_exec

        async def fixture_spawn(*_command, **options):
            process = await original_spawn(sys.executable, "-c", "import time; time.sleep(60)", **options)
            created.append(process)
            return process

        async def wait_for_readiness(*_args, **_kwargs):
            entered_readiness.set()
            await asyncio.Future()

        monkeypatch.setattr(asyncio, "create_subprocess_exec", fixture_spawn)
        monkeypatch.setattr(runtime, "request", wait_for_readiness)
        launching = asyncio.create_task(runtime.ensure_worker("starting", str(tmp_path)))
        try:
            await asyncio.wait_for(entered_readiness.wait(), timeout=5)
            launching.cancel()
            with pytest.raises(asyncio.CancelledError):
                await asyncio.wait_for(launching, timeout=10)
            assert len(created) == 1 and created[0].returncode is not None
            assert not runtime.workers
            assert [row["id"] for row in runtime.store.commands("starting")] == ["queued"]
            assert runtime.store.commands("starting", "sent") == []
            await runtime.close()
            await runtime.close()
        finally:
            if not launching.done():
                launching.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await launching
            for process in created:
                if process.returncode is None:
                    process.kill()
                await process.wait()
    asyncio.run(scenario())
