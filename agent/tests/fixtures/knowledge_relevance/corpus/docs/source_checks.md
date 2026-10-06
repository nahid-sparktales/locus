# Source verification

A saved note can carry fingerprints of the files used to establish it. The
source checker compares those fingerprints with current file bytes.

## Changed or missing files

A changed file or a missing file marks the note stale. Search excludes stale
notes until somebody verifies the claim against the current source. A source
check does not prove the note false, and it does not delete the note.

## Rechecking

After reviewing the new source, use Recheck after verification. The request
includes the note's expected revision. A concurrent edit yields a conflict and
requires a reload; the checker must not overwrite someone else's update.

## Scope

Only file-backed workspace notes are rechecked. Personal preferences, retired
duplicates, and procedures use their own review paths.
