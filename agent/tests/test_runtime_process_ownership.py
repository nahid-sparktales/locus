"""Regression: an owned descendant must not keep a stopped worker's pipe open."""
import asyncio
import contextlib
import os
import signal
import sys
from types import SimpleNamespace

import pytest

from ollama_code.runstore import RunStore
from ollama_code.runtime import RuntimeSupervisor, Worker


@pytest.mark.skipif(os.name != "posix", reason="POSIX process groups")
def test_stop_worker_bounds_cleanup_of_owned_nested_child(tmp_path):
    async def scenario():
        app = SimpleNamespace(state=SimpleNamespace(service=SimpleNamespace(
            run_store=RunStore(tmp_path / "runs.sqlite3"))))
        runtime = RuntimeSupervisor(app, tmp_path / "private", port=1)
        marker = tmp_path / "child-ready"
        child = ("import os,signal,time,pathlib; "
                 "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                 f"pathlib.Path({str(marker)!r}).write_text(str(os.getpid())); "
                 "time.sleep(60)")
        parent = f"import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{child!r}]); time.sleep(60)"
        process = await asyncio.create_subprocess_exec(
            sys.executable, "-c", parent, start_new_session=True,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        worker = Worker("nested", process, 1, "fixture")
        worker.process_group = process.pid
        runtime.workers["nested"] = worker
        worker.log_task = asyncio.create_task(runtime._drain(worker))
        try:
            for _ in range(100):
                if marker.exists():
                    break
                await asyncio.sleep(.01)
            assert marker.exists(), "nested fixture did not start"
            await asyncio.wait_for(runtime.stop_worker("nested"), timeout=7)
            assert process.returncode is not None
            assert worker.log_task.done()
            # Idempotence must not signal a stale process id.
            await runtime.stop_worker("nested")
        finally:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            await process.wait()
            if not worker.log_task.done():
                worker.log_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await worker.log_task
    asyncio.run(scenario())
