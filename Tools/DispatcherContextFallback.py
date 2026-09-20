"""Locus-owned fallback injected into the exported context helper.

Fail closed around ignore/VCS rules instead of approximating their semantics.
"""


def _portable_enumerate(project, diagnostics, max_files, max_list_bytes, skip):
    import os
    import time
    from pathlib import Path

    guards = {".gitignore", ".ignore", ".rgignore", ".git", ".hg", ".svn"}
    diagnostics.append("Git/ripgrep enumeration unavailable; using bounded portable enumeration.")
    guarded = "Portable enumeration skipped ignore or version-control rules; results are partial. Git or ripgrep is needed for those files."
    for ancestor in (project, *project.parents):
        if any((ancestor / name).exists() or (ancestor / name).is_symlink() for name in guards):
            diagnostics.append(guarded)
            return []
    paths, pending = [], [project]
    visited = listed_bytes = 0
    deadline = time.monotonic() + 10
    while pending:
        directory = pending.pop()
        entries = []
        try:
            with os.scandir(directory) as stream:
                for entry in stream:
                    visited += 1
                    listed_bytes += len(os.fsencode(entry.name)) + 1
                    if (visited > max_files or listed_bytes > max_list_bytes
                            or time.monotonic() >= deadline):
                        diagnostics.append("Portable enumeration reached its entry, byte or time limit; results are partial.")
                        # Do not use this incomplete directory: an unseen ignore
                        # file could protect entries already encountered here.
                        return sorted(paths)
                    entries.append(entry)
        except OSError:
            diagnostics.append("Portable enumeration could not inspect a directory; results are partial.")
            continue
        if any(entry.name.casefold() in guards for entry in entries):
            diagnostics.append(guarded)
            continue
        directories = []
        for entry in sorted(entries, key=lambda item: item.name):
            relative = Path(entry.path).relative_to(project).as_posix()
            if any(ord(character) < 32 or ord(character) == 127 for character in relative) or skip(relative):
                continue
            try:
                if entry.is_symlink():
                    continue
                if entry.is_dir(follow_symlinks=False):
                    directories.append(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    paths.append(relative)
            except OSError:
                diagnostics.append("Portable enumeration could not inspect an entry; results are partial.")
        pending.extend(reversed(directories))
    return sorted(paths)
