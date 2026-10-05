# Deletion-checkpoint protection and offline recovery

Locus keeps authenticated deletion history in the memory package and a monotonic
checkpoint in the macOS login Keychain. The bundled signed `LocusMemoryGuard`
helper owns Keychain access. An encrypted database restored without its newer
ledger cannot silently resurrect forgotten records. Restoring both old files
requires the newer ledger or an explicit acknowledgment of the missing history.

A checkpoint does **not** contain the missing deletion entries. Recovery may expose
records that had been forgotten after the restored backup. Prefer restoring the
newer ledger. Acknowledgment records the loss and advances the checkpoint; it does
not reconstruct history or certify that a restored record is safe to retain.

On other operating systems, or in an unenrolled source checkout without the signed
helper, status explicitly reports restore protection as unavailable. An enrolled
profile keeps a failing mirror capability until protection is restored: it never
falls back to unprotected memory or changes canonical ownership. The backend can
start and show the recovery state while memory operations remain unavailable.

## Keep an external checkpoint proof

Stop Locus before using the offline tool. Run it with the bundled Python/backend
or the Locus development environment. For a source CLI, set
`LOCUS_MEMORY_GUARD_HELPER` to the installed app's `Contents/Helpers/LocusMemoryGuard`.
The signature and helper identity are verified before use.

```sh
python -m ollama_code.memory_guard_recovery --app-dir "$PROFILE" status
python -m ollama_code.memory_guard_recovery --app-dir "$PROFILE" export-checkpoint --output "$BACKUP/memory-checkpoint.json"
```

The export contains opaque account/checkpoint metadata and an authentication tag,
not memory contents or keys. It is written with mode 0600 and never overwrites an
existing file. Keep the newest export **outside** the profile backup being restored.
Exports authenticate a checkpoint at export time; they do not prove no later
deletions occurred. Local enrollment markers can also have been restored, so they
are not sufficient proof of the lost latest Keychain generation.

## Preview and acknowledge

```sh
python -m ollama_code.memory_guard_recovery --app-dir "$PROFILE" preview --proof-file "$BACKUP/memory-checkpoint.json"
```

Preview authenticates the local ledger read-only and checks the external proof's
account, edition, partition, generation and MAC. It reports the known generation,
the next generation and whether recovery is possible. Without a surviving Keychain
checkpoint or a sufficiently new external proof, it does not guess a generation.

When the Keychain item is missing, first establish that the supplied proof is the
newest surviving external checkpoint. Then explicitly acknowledge that deletion
history may be lost:

```sh
python -m ollama_code.memory_guard_recovery --app-dir "$PROFILE" recover \
  --proof-file "$BACKUP/memory-checkpoint.json" --proof-is-latest \
  --acknowledge-lost-deletion-history --yes
```

If Keychain still contains a valid checkpoint, the proof argument and
`--proof-is-latest` are unnecessary; the same recovery command previews by default
and requires `--yes` plus the loss acknowledgment to apply. Recovery holds the
exclusive profile lease, checks for running Locus processes, preserves ownership,
and durably advances the ledger and Keychain strictly beyond the authenticated
known generation. It never runs cutover again.

Locked Keychains must be unlocked. Corrupt existing Keychain values, corrupt local
enrollment proofs, divergent external proofs, or an unverifiable latest generation
remain blocked. Restore the newer valid checkpoint/enrollment from external backup.
There is deliberately no delete-Keychain-item, reset-to-zero or force-replace option.
A proof older than authenticated local state is rejected.

The memory settings screen and `/api/memory/status` expose `restore_protection`.
When unavailable for an enrolled profile, counts are marked unavailable rather
than interpreted as an empty vault.

## Validation status

The original encrypted-cache and signed-helper implementation passed its focused
privacy suites and an isolated temporary-Keychain smoke check. Recovery CLI,
version-2 enrollment markers, unavailable-mirror behavior and the status UI were
added afterward. Their tests are written but execution and app builds are deferred
at the user's request to reduce RAM use. No live profile was enrolled or recovered.
