# Git Changes & Terminal

Review and ship Git changes, then run interactive project commands in the retained terminal.

## Changes

Changes reads the real Git working tree, including edits made outside Locus. Review staged and unstaged files, new files, deletions, renames, and binary changes.

* Stage, unstage, or discard a whole file.
* Stage, unstage, or discard individual hunks when the diff is complete and stable.
* Draft a commit message with the selected local model.
* Create or switch branches.
* Fetch, fast-forward-only pull, and push from the direct-download build.
* Publish a new branch on its first push.
* Open GitHub's compare page with the branch filled in; you own the final Create Pull Request action.

A changed hunk is relocated by content before application. If it can no longer be matched, Locus refreshes instead of guessing. Renames and truncated diffs keep whole-file controls only. Discard always confirms, and untracked files move to the Trash.

The App Store sandbox hides Git operations that require SSH keys or Keychain access.

## Files

Files browses all file types and generated folders, with incremental folder expansion, path search, and an explicit control for hidden files. Available previews depend on the file type. Add a file to context, insert an @ mention, reveal it in Finder, or copy its relative path.

Browsing a file does not automatically add it to model context or document knowledge. Use Context for the chat and Library's Document knowledge setting for persistent document indexing.

## Terminal and background services

Terminal owns a retained PTY, so interactive commands work normally. Agent-started dev servers, watchers, and workers should use managed background services; these appear separately, survive the task that created them, and do not occupy your terminal.

## Managed task changes

Team and isolated task checkouts are reviewed against their private baseline. Apply to Workspace performs a conflict check and leaves changes unstaged and uncommitted. Team-run review remains apply-all or discard-all; ordinary workspace diffs support hunk-level actions.
