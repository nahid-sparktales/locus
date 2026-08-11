"""Private managed Git worktrees for team tasks.

The source checkout is read while a private baseline is created, but its index,
branch, files, and HEAD are never changed.  Applying a task is a two-phase
``git apply --check`` / ``git apply`` operation and records the applied tree so
later rounds expose only their new delta.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .paths import APP_DIR

MAX_PATCH_BYTES = 128 * 1024 * 1024
TASKS_DIR = APP_DIR / "tasks"
_TASK_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class WorktreeError(RuntimeError):
    pass


@dataclass
class TaskCheckout:
    id: str
    workspace_root: str
    execution_path: str
    baseline_tree: str
    baseline_commit: str
    applied_tree: str | None = None
    state: str = "queued"

    @property
    def directory(self) -> Path:
        return Path(self.execution_path).parent

    @property
    def metadata_path(self) -> Path:
        return self.directory / "task.json"

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "workspace_root": self.workspace_root,
            "execution_path": self.execution_path,
            "baseline_tree": self.baseline_tree,
            "baseline_commit": self.baseline_commit,
            "applied_tree": self.applied_tree,
            "state": self.state,
        }

    def save(self) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        temporary = self.metadata_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.as_dict(), indent=2) + "\n", encoding="utf-8")
        temporary.replace(self.metadata_path)

    def capture_tree(self) -> str:
        base = self.applied_tree or self.baseline_tree
        checkout = Path(self.execution_path)
        descriptor, index_path = tempfile.mkstemp(prefix="locus-index-", dir=self.directory)
        os.close(descriptor)
        os.unlink(index_path)
        try:
            env = {**os.environ, "GIT_INDEX_FILE": index_path}
            _git(checkout, "read-tree", base, env=env)
            _git(checkout, "add", "-A", "--", ".", env=env)
            return _git(checkout, "write-tree", env=env).strip()
        finally:
            Path(index_path).unlink(missing_ok=True)

    def patch(self) -> tuple[str, str]:
        current_tree = self.capture_tree()
        base = self.applied_tree or self.baseline_tree
        patch = _git_bytes(
            Path(self.execution_path),
            "diff", "--binary", "--full-index", "--find-renames", base, current_tree, "--",
        )
        if len(patch) > MAX_PATCH_BYTES:
            raise WorktreeError("task patch exceeds the 128 MB safety limit")
        return patch.decode("utf-8", errors="surrogateescape"), current_tree

    def snapshot_commit(self) -> tuple[str, str]:
        """Create an immutable private commit for child worktrees.

        ``git commit-tree`` writes only an object: it never moves this
        checkout's HEAD, branch, index, or files.
        """
        current_tree = self.capture_tree()
        commit = _git(
            Path(self.execution_path),
            "-c", "user.name=Locus Parallel Baseline",
            "-c", "user.email=locus@localhost",
            "commit-tree", current_tree,
            "-p", self.baseline_commit,
            "-m", "Locus parallel writer baseline",
        ).strip()
        return commit, current_tree

    def integrate(self, child: TaskCheckout) -> dict[str, Any]:
        """Apply one child delta into this managed checkout atomically."""
        if Path(child.workspace_root).resolve() != Path(self.workspace_root).resolve():
            raise WorktreeError("parallel writer belongs to another workspace")
        patch_text, current_tree = child.patch()
        patch = patch_text.encode("utf-8", errors="surrogateescape")
        if not patch:
            return {"ok": True, "applied": False, "tree": current_tree, "paths": []}
        target = Path(self.execution_path)
        checked = _git_input(
            target, patch, "apply", "--check", "--binary", "--whitespace=nowarn"
        )
        if checked.returncode != 0:
            detail = checked.stderr.decode("utf-8", errors="replace").strip()
            raise WorktreeError(
                f"parallel writer changes conflict during deterministic integration: {detail}"
            )
        applied = _git_input(
            target, patch, "apply", "--binary", "--whitespace=nowarn"
        )
        if applied.returncode != 0:
            detail = applied.stderr.decode("utf-8", errors="replace").strip()
            raise WorktreeError(f"parallel writer changes were not integrated: {detail}")
        paths = _changed_paths(
            Path(child.execution_path), child.applied_tree or child.baseline_tree, current_tree
        )
        self.save()
        return {"ok": True, "applied": True, "tree": current_tree, "paths": paths}

    def apply(self) -> dict[str, Any]:
        patch_text, current_tree = self.patch()
        patch = patch_text.encode("utf-8", errors="surrogateescape")
        if not patch:
            return {"ok": True, "applied": False, "tree": current_tree, "paths": []}
        source = Path(self.workspace_root)
        # The first command is a complete dry run. No fallback strategy is
        # attempted: a collision leaves the source byte-for-byte untouched.
        checked = _git_input(source, patch, "apply", "--check", "--binary", "--whitespace=nowarn")
        if checked.returncode != 0:
            message = checked.stderr.decode("utf-8", errors="replace").strip()
            raise WorktreeError(f"task changes conflict with the workspace: {message}")
        applied = _git_input(source, patch, "apply", "--binary", "--whitespace=nowarn")
        if applied.returncode != 0:
            message = applied.stderr.decode("utf-8", errors="replace").strip()
            raise WorktreeError(f"task changes were not applied: {message}")
        paths = _changed_paths(Path(self.execution_path), self.applied_tree or self.baseline_tree, current_tree)
        self.applied_tree = current_tree
        self.save()
        return {"ok": True, "applied": True, "tree": current_tree, "paths": paths}


class TaskCheckoutStore:
    @staticmethod
    def create(workspace: str, task_id: str) -> TaskCheckout:
        if not _TASK_ID.fullmatch(task_id):
            raise WorktreeError("task id is invalid")
        source = Path(workspace).expanduser().resolve()
        root = Path(_git(source, "rev-parse", "--show-toplevel").strip()).resolve()
        if _dirty_submodules(root):
            raise WorktreeError(
                "dirty submodules require choosing their recorded commits or Use Current Folder"
            )
        task_dir = (TASKS_DIR / task_id).resolve()
        tasks_root = TASKS_DIR.resolve()
        if task_dir.parent != tasks_root:
            raise WorktreeError("task directory escaped the managed task root")
        checkout = task_dir / "checkout"
        if task_dir.exists():
            existing = TaskCheckoutStore.load(task_id)
            if existing is not None:
                return existing
            raise WorktreeError("managed task directory already exists")
        task_dir.mkdir(parents=True, exist_ok=False)
        try:
            _git(root, "worktree", "add", "--detach", str(checkout), "HEAD")
            _copy_source_state(root, checkout)
            _git(checkout, "add", "-A", "--", ".")
            _git(
                checkout,
                "-c", "user.name=Locus Task Baseline",
                "-c", "user.email=locus@localhost",
                "-c", "core.hooksPath=/dev/null",
                "commit", "--allow-empty", "-m", "Locus private task baseline",
            )
            baseline_commit = _git(checkout, "rev-parse", "HEAD").strip()
            baseline_tree = _git(checkout, "rev-parse", "HEAD^{tree}").strip()
            record = TaskCheckout(
                id=task_id,
                workspace_root=str(root),
                execution_path=str(checkout),
                baseline_tree=baseline_tree,
                baseline_commit=baseline_commit,
                state="queued",
            )
            record.save()
            return record
        except Exception:
            try:
                if checkout.exists():
                    _git(root, "worktree", "remove", "--force", str(checkout))
            except WorktreeError:
                pass
            shutil.rmtree(task_dir, ignore_errors=True)
            raise

    @staticmethod
    def replay(source: TaskCheckout, task_id: str) -> TaskCheckout:
        """Create a new checkout at another task's immutable private baseline."""
        if not _TASK_ID.fullmatch(task_id):
            raise WorktreeError("task id is invalid")
        root = Path(source.workspace_root).expanduser().resolve()
        task_dir = (TASKS_DIR / task_id).resolve()
        if task_dir.parent != TASKS_DIR.resolve() or task_dir.exists():
            raise WorktreeError("managed replay task already exists or escaped its root")
        checkout = task_dir / "checkout"
        task_dir.mkdir(parents=True, exist_ok=False)
        try:
            _git(root, "worktree", "add", "--detach", str(checkout), source.baseline_commit)
            observed_tree = _git(checkout, "rev-parse", "HEAD^{tree}").strip()
            if observed_tree != source.baseline_tree:
                raise WorktreeError("the original immutable baseline is no longer available")
            record = TaskCheckout(
                id=task_id,
                workspace_root=str(root),
                execution_path=str(checkout),
                baseline_tree=source.baseline_tree,
                baseline_commit=source.baseline_commit,
                state="queued",
            )
            record.save()
            return record
        except Exception:
            try:
                if checkout.exists():
                    _git(root, "worktree", "remove", "--force", str(checkout))
            except WorktreeError:
                pass
            shutil.rmtree(task_dir, ignore_errors=True)
            raise

    @staticmethod
    def fork(source: TaskCheckout, task_id: str) -> TaskCheckout:
        """Fork the source checkout's current state for one parallel writer."""
        if not _TASK_ID.fullmatch(task_id):
            raise WorktreeError("parallel writer task id is invalid")
        root = Path(source.workspace_root).expanduser().resolve()
        task_dir = (TASKS_DIR / task_id).resolve()
        if task_dir.parent != TASKS_DIR.resolve() or task_dir.exists():
            raise WorktreeError("parallel writer task already exists or escaped its root")
        baseline_commit, baseline_tree = source.snapshot_commit()
        checkout = task_dir / "checkout"
        task_dir.mkdir(parents=True, exist_ok=False)
        try:
            _git(root, "worktree", "add", "--detach", str(checkout), baseline_commit)
            observed_tree = _git(checkout, "rev-parse", "HEAD^{tree}").strip()
            if observed_tree != baseline_tree:
                raise WorktreeError("parallel writer baseline could not be reproduced")
            record = TaskCheckout(
                id=task_id,
                workspace_root=str(root),
                execution_path=str(checkout),
                baseline_tree=baseline_tree,
                baseline_commit=baseline_commit,
                state="running",
            )
            record.save()
            return record
        except Exception:
            try:
                if checkout.exists():
                    _git(root, "worktree", "remove", "--force", str(checkout))
            except WorktreeError:
                pass
            shutil.rmtree(task_dir, ignore_errors=True)
            raise

    @staticmethod
    def load(task_id: str) -> TaskCheckout | None:
        if not _TASK_ID.fullmatch(task_id):
            return None
        path = TASKS_DIR / task_id / "task.json"
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            record = TaskCheckout(
                id=str(value["id"]),
                workspace_root=str(value["workspace_root"]),
                execution_path=str(value["execution_path"]),
                baseline_tree=str(value["baseline_tree"]),
                baseline_commit=str(value["baseline_commit"]),
                applied_tree=str(value["applied_tree"]) if value.get("applied_tree") else None,
                state=str(value.get("state") or "queued"),
            )
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            return None
        expected = (TASKS_DIR / task_id).resolve()
        if record.directory.resolve() != expected or record.id != task_id:
            return None
        return record

    @staticmethod
    def cleanup(task_id: str) -> dict[str, Any]:
        """Remove one explicitly selected managed checkout, never workspace files."""
        if not _TASK_ID.fullmatch(task_id):
            raise WorktreeError("task id is invalid")
        record = TaskCheckoutStore.load(task_id)
        if record is None:
            raise WorktreeError("managed task checkout was not found")
        task_dir = (TASKS_DIR / task_id).resolve()
        if task_dir.parent != TASKS_DIR.resolve() or record.directory.resolve() != task_dir:
            raise WorktreeError("managed task checkout escaped its storage root")
        checkout = Path(record.execution_path).resolve()
        if checkout.parent != task_dir:
            raise WorktreeError("managed checkout path is invalid")
        workspace = Path(record.workspace_root).expanduser().resolve()
        if workspace.exists() and checkout.exists():
            try:
                _git(workspace, "worktree", "remove", "--force", str(checkout))
            except WorktreeError as exc:
                raise WorktreeError(f"could not detach the managed checkout: {exc}") from exc
        shutil.rmtree(task_dir)
        return {"ok": True, "task_id": task_id, "removed": True}


def _copy_source_state(source: Path, checkout: Path) -> None:
    paths = _git_bytes(
        source, "ls-files", "-z", "--cached", "--others", "--exclude-standard",
    ).split(b"\0")
    for raw in paths:
        if not raw:
            continue
        relative = raw.decode("utf-8", errors="surrogateescape")
        origin = source / relative
        target = checkout / relative
        if not origin.exists() and not origin.is_symlink():
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            else:
                target.unlink(missing_ok=True)
            continue
        # Gitlinks are reproduced at the recorded commit by `worktree add`;
        # dirty ones were rejected above, so copying a submodule directory
        # would only flatten it into ordinary files.
        if origin.is_dir() and not origin.is_symlink():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            target.unlink()
        if origin.is_symlink():
            target.symlink_to(os.readlink(origin))
        else:
            shutil.copy2(origin, target)


def _dirty_submodules(root: Path) -> bool:
    try:
        registered = _git(root, "submodule", "status", "--recursive").strip()
    except WorktreeError:
        return False
    if not registered:
        return False
    if any(line[:1] in {"+", "-", "U"} for line in registered.splitlines()):
        return True
    output = _git(
        root,
        "submodule", "foreach", "--recursive", "--quiet", "git status --porcelain",
    )
    return bool(output.strip())


def _changed_paths(checkout: Path, base: str, current: str) -> list[str]:
    raw = _git_bytes(checkout, "diff", "--name-only", "-z", base, current, "--")
    return [
        item.decode("utf-8", errors="replace")
        for item in raw.split(b"\0") if item
    ]


def _git(cwd: Path, *arguments: str, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise WorktreeError(message or f"git {' '.join(arguments)} failed")
    return result.stdout


def _git_bytes(cwd: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        capture_output=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        raise WorktreeError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def _git_input(cwd: Path, data: bytes, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        ["git", *arguments],
        cwd=cwd,
        input=data,
        capture_output=True,
        timeout=120,
        check=False,
    )


__all__ = ["TASKS_DIR", "TaskCheckout", "TaskCheckoutStore", "WorktreeError"]
