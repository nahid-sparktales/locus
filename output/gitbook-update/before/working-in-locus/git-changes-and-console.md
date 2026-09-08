> For the complete documentation index, see [llms.txt](https://locus-3.gitbook.io/locus-docs/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://locus-3.gitbook.io/locus-docs/working-in-locus/git-changes-and-console.md).

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

Files searches the workspace index and previews common text formats. Hidden, generated, binary, and oversized files are skipped. Add a file to context, insert an @ mention, reveal it, or copy its relative path.

## Terminal and background services

Terminal owns a retained PTY, so interactive commands work normally. Agent-started dev servers, watchers, and workers should use managed background services; these appear separately, survive the task that created them, and do not occupy your terminal.

## Managed task changes

Team and isolated task checkouts are reviewed against their private baseline. Apply to Workspace performs a conflict check and leaves changes unstaged and uncommitted. Team-run review remains apply-all or discard-all; ordinary workspace diffs support hunk-level actions.
