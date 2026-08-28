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
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .paths import APP_DIR

MAX_PATCH_BYTES = 128 * 1024 * 1024
TASKS_DIR = APP_DIR / "tasks"
_TASK_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class WorktreeError(RuntimeError):
    pass


def is_git_workspace(workspace: str) -> bool:
    result = subprocess.run(
        ["git", "rev-parse", "--is-inside-work-tree"],
        cwd=workspace,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
        check=False,
    )
    return result.returncode == 0


@dataclass
class TaskCheckout:
    id: str
    workspace_root: str
    execution_path: str
    baseline_tree: str
    baseline_commit: str
    applied_tree: str | None = None
    state: str = "queued"
    session_id: str | None = None
    starting_ref: str = "HEAD"
    snapshot_oid: str | None = None
    branch: str | None = None
    pinned: bool = False
    permanent: bool = False
    updated_at: float = 0
    landing_destination: str | None = None
    landing_tree: str | None = None
    landing_commit: str | None = None
    landing_source_tree: str | None = None
    landing_check_run_id: str | None = None
    landing_checks_passed: bool | None = None
    landing_override: bool = False
    landed_at: float | None = None

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
            "session_id": self.session_id,
            "starting_ref": self.starting_ref,
            "snapshot_oid": self.snapshot_oid,
            "branch": self.branch,
            "pinned": self.pinned,
            "permanent": self.permanent,
            "updated_at": self.updated_at,
            "landing_destination": self.landing_destination,
            "landing_tree": self.landing_tree,
            "landing_commit": self.landing_commit,
            "landing_source_tree": self.landing_source_tree,
            "landing_check_run_id": self.landing_check_run_id,
            "landing_checks_passed": self.landing_checks_passed,
            "landing_override": self.landing_override,
            "landed_at": self.landed_at,
        }

    def save(self) -> None:
        self.updated_at = time.time()
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

    def snapshot(self) -> str:
        """Anchor the checkout's current state before its files are removed."""
        commit, _ = self.snapshot_commit()
        _git(
            Path(self.workspace_root),
            "update-ref", f"refs/locus/worktrees/{self.id}/snapshot", commit,
        )
        self.snapshot_oid = commit
        self.state = "snapshotted"
        self.save()
        return commit

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
        paths = _changed_paths(
            Path(self.execution_path), self.applied_tree or self.baseline_tree, current_tree
        )
        # The first command is a complete dry run. No fallback strategy is
        # attempted: a collision leaves the source byte-for-byte untouched.
        checked = _git_input(source, patch, "apply", "--check", "--binary", "--whitespace=nowarn")
        if checked.returncode != 0:
            message = checked.stderr.decode("utf-8", errors="replace").strip()
            affected = ", ".join(paths[:20])
            suffix = f" Affected paths: {affected}." if affected else ""
            raise WorktreeError(
                f"task changes conflict with the workspace: {message}.{suffix}".rstrip(".")
            )
        applied = _git_input(source, patch, "apply", "--binary", "--whitespace=nowarn")
        if applied.returncode != 0:
            message = applied.stderr.decode("utf-8", errors="replace").strip()
            raise WorktreeError(f"task changes were not applied: {message}")
        self.applied_tree = current_tree
        self.landing_destination = "local"
        self.landing_tree = current_tree
        self.landed_at = time.time()
        self.save()
        return {"ok": True, "applied": True, "tree": current_tree, "paths": paths}

    def landing_preflight(self) -> dict[str, Any]:
        """Describe the next complete delta and test Local application without mutation."""
        patch_text, current_tree = self.patch()
        patch = patch_text.encode("utf-8", errors="surrogateescape")
        base = self.applied_tree or self.baseline_tree
        paths = _changed_paths(Path(self.execution_path), base, current_tree)
        conflict = ""
        can_apply = True
        if patch:
            checked = _git_input(
                Path(self.workspace_root), patch, "apply", "--check", "--binary",
                "--whitespace=nowarn",
            )
            can_apply = checked.returncode == 0
            if not can_apply:
                conflict = checked.stderr.decode("utf-8", errors="replace").strip()[:8_000]
        return {
            "ok": True,
            "tree": current_tree,
            "base_tree": base,
            "paths": paths,
            "patch_bytes": len(patch),
            "can_apply_local": can_apply,
            "conflict": conflict,
            "branch": self.branch,
            "landing_destination": self.landing_destination,
            "landing_tree": self.landing_tree,
            "landing_commit": self.landing_commit,
            "landed_at": self.landed_at,
        }

    def land_branch(self, branch: str, message: str) -> dict[str, Any]:
        """Create/reuse a branch and commit the complete baseline-relative delta."""
        name = branch.strip()
        commit_message = message.strip()
        if not name or len(name) > 240:
            raise WorktreeError("branch name is invalid")
        if not commit_message or len(commit_message) > 10_000:
            raise WorktreeError("commit message is invalid")
        checkout = Path(self.execution_path)
        _git(checkout, "check-ref-format", "--branch", name)
        if self.branch and self.branch != name:
            raise WorktreeError(f"the worktree is already on branch {self.branch}")
        if not self.branch:
            _git(checkout, "switch", "-c", name)
            self.branch = name
            self.save()
        _, current_tree = self.patch()
        _git(checkout, "add", "-A", "--", ".")
        try:
            _git(checkout, "commit", "-m", commit_message)
        except WorktreeError:
            # Intentionally retain the branch and staged index for inspection/retry.
            self.save()
            raise
        commit = _git(checkout, "rev-parse", "HEAD").strip()
        # Future reviews are incremental from this successful landing. The
        # committed work remains in the checkout and its branch; only new
        # chat-produced changes invalidate checks and become landable.
        self.applied_tree = current_tree
        self.landing_destination = "branch"
        self.landing_tree = current_tree
        self.landing_commit = commit
        self.landed_at = time.time()
        self.save()
        return {
            "ok": True, "destination": "branch", "tree": current_tree,
            "branch": name, "commit": commit, "landed_at": self.landed_at,
        }


class TaskCheckoutStore:
    @staticmethod
    def create(
        workspace: str,
        task_id: str,
        *,
        base_ref: str = "HEAD",
        session_id: str | None = None,
    ) -> TaskCheckout:
        if not _TASK_ID.fullmatch(task_id):
            raise WorktreeError("task id is invalid")
        source = Path(workspace).expanduser().resolve()
        root = Path(_git(source, "rev-parse", "--show-toplevel").strip()).resolve()
        selected_ref = base_ref.strip() or "HEAD"
        selected_commit = _git(
            root, "rev-parse", "--verify", f"{selected_ref}^{{commit}}"
        ).strip()
        source_head = _git(root, "rev-parse", "HEAD").strip()
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
            _git(root, "worktree", "add", "--detach", str(checkout), selected_commit)
            if selected_commit == source_head:
                _copy_source_state(root, checkout)
            _copy_worktree_includes(root, checkout)
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
                session_id=session_id,
                starting_ref=selected_ref,
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
                session_id=str(value["session_id"]) if value.get("session_id") else None,
                starting_ref=str(value.get("starting_ref") or "HEAD"),
                snapshot_oid=str(value["snapshot_oid"]) if value.get("snapshot_oid") else None,
                branch=str(value["branch"]) if value.get("branch") else None,
                pinned=bool(value.get("pinned", False)),
                permanent=bool(value.get("permanent", False)),
                updated_at=float(value.get("updated_at") or 0),
                landing_destination=str(value["landing_destination"])
                if value.get("landing_destination") else None,
                landing_tree=str(value["landing_tree"])
                if value.get("landing_tree") else None,
                landing_commit=str(value["landing_commit"])
                if value.get("landing_commit") else None,
                landing_source_tree=str(value["landing_source_tree"])
                if value.get("landing_source_tree") else None,
                landing_check_run_id=str(value["landing_check_run_id"])
                if value.get("landing_check_run_id") else None,
                landing_checks_passed=bool(value["landing_checks_passed"])
                if value.get("landing_checks_passed") is not None else None,
                landing_override=bool(value.get("landing_override", False)),
                landed_at=float(value["landed_at"]) if value.get("landed_at") else None,
            )
        except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
            return None
        expected = (TASKS_DIR / task_id).resolve()
        if record.directory.resolve() != expected or record.id != task_id:
            return None
        return record

    @staticmethod
    def snapshot_and_remove(task_id: str) -> dict[str, Any]:
        """Save a restorable Git object, then remove only the managed checkout."""
        record = TaskCheckoutStore.load(task_id)
        if record is None:
            raise WorktreeError("managed task checkout was not found")
        checkout = Path(record.execution_path)
        if not checkout.exists():
            return {"ok": True, "task": record.as_dict(), "removed": False}
        snapshot = record.snapshot()
        _git(
            Path(record.workspace_root),
            "worktree", "remove", "--force", str(checkout),
        )
        record.state = "snapshotted"
        record.save()
        return {
            "ok": True,
            "task": record.as_dict(),
            "removed": True,
            "snapshot_oid": snapshot,
        }

    @staticmethod
    def restore(task_id: str) -> TaskCheckout:
        """Restore a snapshotted checkout at its original managed path."""
        record = TaskCheckoutStore.load(task_id)
        if record is None:
            raise WorktreeError("managed task checkout was not found")
        checkout = Path(record.execution_path)
        if checkout.exists():
            return record
        target = record.snapshot_oid or record.baseline_commit
        if not target:
            raise WorktreeError("managed checkout has no restorable snapshot")
        _git(
            Path(record.workspace_root),
            "worktree", "add", "--detach", str(checkout), target,
        )
        record.state = "queued"
        record.save()
        return record

    @staticmethod
    def refresh_from_workspace(task_id: str) -> TaskCheckout:
        """Return a handed-off chat to its same worktree using Local as baseline."""
        record = TaskCheckoutStore.load(task_id)
        if record is None:
            raise WorktreeError("managed task checkout was not found")
        root = Path(record.workspace_root).expanduser().resolve()
        checkout = Path(record.execution_path)
        if checkout.exists():
            _git(root, "worktree", "remove", "--force", str(checkout))
        _git(root, "worktree", "add", "--detach", str(checkout), "HEAD")
        _copy_source_state(root, checkout)
        _copy_worktree_includes(root, checkout)
        _git(checkout, "add", "-A", "--", ".")
        _git(
            checkout,
            "-c", "user.name=Locus Chat Baseline",
            "-c", "user.email=locus@localhost",
            "-c", "core.hooksPath=/dev/null",
            "commit", "--allow-empty", "-m", "Locus private chat baseline",
        )
        record.baseline_commit = _git(checkout, "rev-parse", "HEAD").strip()
        record.baseline_tree = _git(checkout, "rev-parse", "HEAD^{tree}").strip()
        record.applied_tree = None
        record.snapshot_oid = None
        record.branch = None
        record.starting_ref = "HEAD"
        record.state = "queued"
        record.save()
        return record

    @staticmethod
    def create_branch(task_id: str, branch: str) -> TaskCheckout:
        record = TaskCheckoutStore.load(task_id)
        if record is None:
            raise WorktreeError("managed task checkout was not found")
        name = branch.strip()
        if not name or len(name) > 240:
            raise WorktreeError("branch name is invalid")
        _git(Path(record.execution_path), "check-ref-format", "--branch", name)
        _git(Path(record.execution_path), "switch", "-c", name)
        record.branch = name
        record.save()
        return record

    @staticmethod
    def prune(limit: int = 15, *, protected_ids: set[str] | None = None) -> list[str]:
        """Snapshot old disposable checkouts while retaining their chat records."""
        bounded = max(int(limit), 0)
        protected = protected_ids or set()
        records = []
        if TASKS_DIR.exists():
            for metadata in TASKS_DIR.glob("*/task.json"):
                record = TaskCheckoutStore.load(metadata.parent.name)
                if record is not None:
                    records.append(record)
        live = [record for record in records if Path(record.execution_path).exists()]
        live.sort(key=lambda record: record.updated_at, reverse=True)
        removed: list[str] = []
        for record in live[bounded:]:
            if record.id in protected or record.pinned or record.permanent:
                continue
            if record.state in {"running", "waiting_permission", "waiting_computer"}:
                continue
            try:
                patch, _ = record.patch()
            except WorktreeError:
                # An unreadable checkout is not safe to remove automatically.
                continue
            if patch:
                # Chat-produced changes remain addressable until the user
                # applies, snapshots explicitly, or cleans up the checkout.
                continue
            TaskCheckoutStore.snapshot_and_remove(record.id)
            removed.append(record.id)
        return removed

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
        try:
            _git(workspace, "update-ref", "-d", f"refs/locus/worktrees/{task_id}/snapshot")
        except WorktreeError:
            pass
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


def _copy_worktree_includes(source: Path, checkout: Path) -> None:
    """Copy only ignored files selected by Codex-compatible include patterns."""
    include_file = source / ".worktreeinclude"
    patterns: list[str] = ["AGENTS.override.md"]
    try:
        patterns.extend(
            line.strip() for line in include_file.read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        )
    except OSError:
        pass
    if not patterns:
        return
    ignored = set(
        item for item in _git_bytes(
            source, "ls-files", "-z", "--others", "--ignored", "--exclude-standard",
        ).split(b"\0") if item
    )
    if not ignored:
        return
    descriptor, pattern_path = tempfile.mkstemp(prefix="locus-worktreeinclude-")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write("\n".join(patterns) + "\n")
        selected = set(
            item for item in _git_bytes(
                source, "ls-files", "-z", "--others", "--ignored",
                f"--exclude-from={pattern_path}",
            ).split(b"\0") if item
        )
    finally:
        Path(pattern_path).unlink(missing_ok=True)
    for raw in sorted(ignored & selected):
        relative = raw.decode("utf-8", errors="surrogateescape")
        origin = source / relative
        target = checkout / relative
        if origin.is_symlink() or not origin.is_file() or target.exists() or target.is_symlink():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
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


__all__ = [
    "TASKS_DIR",
    "TaskCheckout",
    "TaskCheckoutStore",
    "WorktreeError",
    "is_git_workspace",
]
