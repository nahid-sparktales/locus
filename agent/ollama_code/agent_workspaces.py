"""Allocate new saved-agent chat folders without moving existing conversations."""
from __future__ import annotations

import os
import sys
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .worktrees import TaskCheckout, TaskCheckoutStore, WorktreeError, is_git_workspace


def agent_homes_root() -> Path:
    override = os.environ.get("LOCUS_AGENT_HOMES_ROOT", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "Locus" / "AgentHomes"
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    return data / "locus" / "AgentHomes"


def validate_agent_home(workspace: Path, profile_id: str | None) -> None:
    try:
        profile_id = str(uuid.UUID(profile_id))
    except (ValueError, AttributeError, TypeError) as exc:
        raise ValueError("agent_home requires an agent_profile_id UUID") from exc
    expected = agent_homes_root().resolve() / profile_id / "Workspace"
    if expected.resolve() != expected or workspace != expected:
        raise ValueError("agent_home must identify this profile's managed home workspace")


def _child_directory(parent: Path, name: str, *, exclusive: bool = False) -> tuple[Path, bool]:
    directory = parent / name
    # Existing user directories are allowed, but never follow a link to create
    # a task/output directory somewhere other than the selected workspace.
    if directory.parent != parent or directory.is_symlink() or directory.resolve() != directory:
        raise ValueError("The task or output directory must not redirect to another folder")
    try:
        directory.mkdir(exist_ok=False)
        return directory, True
    except FileExistsError:
        if exclusive or not directory.is_dir():
            raise ValueError("The task or output directory already exists") from None
        return directory, False


@dataclass
class AgentChatWorkspace:
    workspace_root: Path
    execution_path: Path
    environment: dict[str, str]
    output_directory: Path | None = None
    task: TaskCheckout | None = None
    # Only directories created in this allocation are ever eligible for cleanup.
    _created_directories: list[Path] = field(default_factory=list)

    @classmethod
    def create(
        cls, workspace: Path, session_id: str, *, policy: str | None, agent_home: bool,
    ) -> AgentChatWorkspace:
        if policy is not None and (not isinstance(policy, str) or policy not in {"automatic", "local", "worktree"}):
            raise ValueError("execution_environment must be automatic, local, or worktree")
        value = cls(workspace, workspace, {"type": "local", "isolation": "local"})
        if policy is None and not agent_home:
            return value
        value.environment["execution_policy"] = policy or "local"
        try:
            if agent_home:
                if policy == "worktree":
                    raise ValueError("Agent homes use a separate task folder; choose automatic or local")
                tasks, created = _child_directory(workspace, "Tasks")
                if created:
                    value._created_directories.append(tasks)
                value.execution_path, _ = _child_directory(tasks, session_id, exclusive=True)
                value._created_directories.append(value.execution_path)
                output, _ = _child_directory(value.execution_path, "Outputs", exclusive=True)
                value._created_directories.append(output)
                value.environment.update(isolation="agent_task_folder", agent_home="true")
            else:
                use_worktree = policy == "worktree" or (
                    policy == "automatic" and is_git_workspace(str(workspace))
                )
                if use_worktree:
                    if policy == "worktree" and not is_git_workspace(str(workspace)):
                        raise ValueError("worktree chats require a Git repository")
                    value.task = TaskCheckoutStore.create(
                        str(workspace), session_id, session_id=session_id, reuse_existing=False,
                    )
                    value.workspace_root = Path(value.task.workspace_root)
                    value.execution_path = Path(value.task.execution_path)
                    if value.workspace_root != workspace:
                        # A map may represent a repository subfolder. Keep that
                        # association while execution and permissions use the
                        # managed checkout's canonical repository root.
                        value.environment["source_workspace"] = str(workspace)
                    value.environment.update(
                        type="worktree", isolation="managed_worktree", worktree_id=value.task.id,
                        starting_ref=value.task.starting_ref,
                    )
                outputs, created = _child_directory(value.execution_path, "Outputs")
                if created:
                    value._created_directories.append(outputs)
                output, _ = _child_directory(outputs, session_id, exclusive=True)
                value._created_directories.append(output)
            value.output_directory = output
            value.environment["output_directory"] = str(output)
            return value
        except Exception:
            value.cleanup()
            raise

    def metadata(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "workspace_root": str(self.workspace_root),
            "execution_path": str(self.execution_path),
            "environment": self.environment,
        }
        if self.output_directory is not None:
            value["output_directory"] = str(self.output_directory)
        if self.task is not None:
            value["task"] = self.task.as_dict()
        return value

    def cleanup(self) -> None:
        # These folders were empty at allocation. rmdir refuses to erase files
        # that another process may have added before a failed save completes.
        for directory in reversed(self._created_directories):
            try:
                directory.rmdir()
            except OSError:
                pass
        if self.task is not None:
            try:
                TaskCheckoutStore.cleanup(self.task.id)
            except (OSError, WorktreeError):
                # A failed detach must not fall back to deleting repository files.
                pass


def home_session_workspace(metadata: dict[str, Any], session_id: str) -> tuple[Path, Path] | None:
    """Resolve a recorded home task for resume without allocating or moving it."""
    environment = metadata.get("environment")
    if not isinstance(environment, dict) or environment.get("isolation") != "agent_task_folder":
        return None
    workspace = Path(str(metadata.get("workspace_root") or "")).expanduser().resolve()
    validate_agent_home(workspace, metadata.get("agent_profile_id"))
    execution = workspace / "Tasks" / session_id
    if execution.resolve() != execution or str(execution) != metadata.get("execution_path"):
        raise ValueError("The saved chat task folder does not belong to this agent home")
    if not execution.is_dir():
        raise ValueError("The saved chat task folder is unavailable")
    return workspace, execution


def local_session_workspace(metadata: dict[str, Any]) -> tuple[Path, Path] | None:
    """Use an explicitly saved local location instead of an older transcript header."""
    environment = metadata.get("environment")
    if isinstance(environment, dict) and (
        environment.get("type") == "worktree"
        or environment.get("isolation") in {"managed_worktree", "agent_task_folder"}
    ):
        return None
    if "workspace_root" not in metadata and "execution_path" not in metadata:
        return None
    root_value = metadata.get("workspace_root", metadata.get("execution_path"))
    execution_value = metadata.get("execution_path", root_value)
    if any(not isinstance(value, str) or not value or "\0" in value
           for value in (root_value, execution_value)):
        raise ValueError("The saved chat workspace location is invalid")
    try:
        root, execution = Path(root_value).expanduser(), Path(execution_value).expanduser()
        if not root.is_absolute() or not execution.is_absolute():
            raise ValueError("The saved chat workspace location must be absolute")
        root, execution = root.resolve(), execution.resolve()
        if not execution.is_relative_to(root):
            raise ValueError("The saved chat execution folder is outside its workspace")
        if not root.is_dir() or not execution.is_dir():
            raise ValueError("The saved chat workspace is unavailable; choose its folder again")
        return root, execution
    except (OSError, RuntimeError) as exc:
        raise ValueError("The saved chat workspace is unavailable; choose its folder again") from exc
