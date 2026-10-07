# Snapshot exports

The Export command writes a version 3 JSON snapshot to a path chosen by the
operator. The file is readable without a running host. Import is an explicit
operation; copying an export beside a notebook does not merge its records.

## Recovery

Verify the snapshot version before importing. Inspect the record count and
workspace identity before applying changes to a live notebook.
