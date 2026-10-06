# Upgrade checklist

## Version 2 to version 3

Rename etag to expected_revision in lease mutation bodies. Change conflict
handling from HTTP 412 to HTTP 409. A stored version 2 export is imported once
through the migration command; validate_export accepts version 3 only.

## Workspace paths

Move a workspace with its host-side notebook directory. Opening a different
checkout path creates a separate scope until the operator explicitly migrates
the saved notes. Migration never merges two notebooks just because their folder
names are equal.
