# Harbor operations handbook

This runbook is for the operator of a shared execution host. Desktop operators
should first identify the host and workspace before changing any persistent
state. Several desktops may be looking at the same notebook, so a successful
write becomes visible to more than one person. Schedule maintenance with enough
time to verify the service from both an existing connection and a new one.

## Journal recovery

Use this procedure when the append journal cannot be parsed after an interrupted
disk write. An ordinary revision conflict is not a damaged journal. First copy
the failing error message and note the last successful operation. Check whether
other workspaces on the host are healthy before deciding how broad the outage
is. A problem in one notebook need not prevent the host from serving another.

Begin by pausing new work for the affected workspace. Existing read requests may
finish, but no new write should start during the inspection. Tell any operator
who is already editing a record to keep the draft open. A draft exists in the
controller and can be copied before reconnecting. Do not replace the host-side
directory while a worker still holds it open, because the old process may keep
writing to an unlinked file and make the apparent repair incomplete.

Create an inspection copy in a fresh directory on the same local disk. Keep the
original directory untouched until the copied material has passed all checks.
Record the source directory, copy time, and byte counts in the maintenance log.
The working copy should contain the data file, journal, and companion metadata.
A partial copy may look readable while omitting an operation that was committed
immediately before the interruption. Compare the source and copy file sizes
after the paused worker has acknowledged that it holds no write transaction.

Read the first malformed journal entry without editing it. The diagnostic tool
prints its byte offset and the last complete record before that offset. Save
both values in the maintenance log. A final incomplete entry is different from
a checksum mismatch in the middle of the journal. The former can result from a
process exit during a write; the latter can indicate an older disk problem and
needs broader inspection. Neither diagnosis should be inferred solely from a
desktop timeout, because a broken SSH connection produces a similar symptom.

Compare the journal header with the data file identifier. They must refer to the
same notebook generation. A journal copied from an older backup can contain
perfectly valid records that are wrong for this data file. Do not combine two
generations in an attempt to preserve more recent edits. Use a coherent backup
set and record the expected loss window. If several backup sets are available,
choose the newest set whose files were captured while writes were paused.

Run the parser over the inspection copy in read-only mode. Capture the count of
complete records, incomplete records, and rejected checksums separately. The
summary is a diagnostic, not permission to discard an entry. Review a sample of
the final complete records against the desktop activity log. If a user reports
that a confirmed edit is absent from the copy, stop and preserve the evidence
instead of treating the operation as an ordinary incomplete final append.

If the only fault is a trailing incomplete entry, the repair tool can produce a
new journal ending at the last complete record. It writes to a new path and
never truncates the original in place. Compare the proposed output's complete
record count with the parser report. All complete records must remain in order.
An output that rearranges entries can change the final state even when the total
count is the same. Save the tool version and command arguments with the report.

When the fault occurs in the middle of the file, select a coherent backup and
inspect the edits made after that backup separately. A later complete record can
depend on an earlier damaged record, so replaying every parseable line is not a
safe general repair strategy. Operators may reconstruct missing edits from
independent evidence, but reconstruction is a new reviewed write after service
returns. It must not be disguised as an original journal operation.

The data file can be opened against the proposed replacement in an isolated
worker that has no controller attached. Give that worker an empty transport
configuration and keep it disconnected from scheduled tasks. Read the record
count, current revision, and a selection of known notes. Compare these values
with the maintenance report. The worker must not run migrations automatically;
otherwise the verification itself can modify the candidate being inspected.

Inspect references to external source files using the paths recorded in each
note. The repair does not restore missing project files, nor does it establish
that a saved claim remains true. A note whose source changed during the outage
should remain flagged for verification. Do not clear stale flags merely to make
the workspace look healthy. A source check can be run after service returns and
its findings can be reviewed independently from the notebook's structural state.

Compare a freshly rendered list with an export of the repaired candidate. The
ordering may differ because presentation sorting is not part of journal order,
but the set of record identifiers should agree. Deleted records must not appear
in the ordinary list. Superseded records may remain in historical metadata for
audit purposes while their replacement is the only current item shown. Include
these cases in the spot check instead of checking only simple active notes.

Review the candidate with another operator when one is available. Give that
operator the original error, the proposed repair description, and the observed
record counts. They should be able to repeat the read-only parser checks without
access to the controller that initiated the incident. Independent inspection is
especially useful when a damaged journal has several plausible reconstruction
points. Record any uncertainty in the maintenance log before resuming work.

Prepare a rollback directory containing the untouched original files. Name it
with the incident identifier and keep it outside the active workspace directory.
Do not leave it where the host's indexer will discover it as a second notebook.
Keep its permissions as restrictive as the original directory. A readable repair
export may contain the same private notes as the live notebook and should be
handled with the same care. Remove temporary copies only after the agreed review
period, using the operator's ordinary retention process.

Stop the isolated verification worker before swapping directories. Check that
both the original worker and verification worker have closed their handles. Move
the candidate into the active location using a single filesystem rename where
possible. Reopen it with the intended worker configuration, but leave scheduled
jobs paused for the first verification pass. A successful process launch alone
does not show that controller requests will use the newly repaired notebook.

Connect one desktop and request the current record list without editing it.
Connect a second desktop and compare the workspace identity and revision shown
by both. If they differ, check the selected host and worker rather than repeating
the repair. Controllers can have multiple sessions open, and a visually similar
workspace name does not establish that the requests reached the same authority.
Only after the identities agree should the operator try a controlled write.

Create a temporary verification note and observe it from the second controller.
Delete it from that controller and refresh the first. The create and delete must
advance revisions normally. This check exercises the request path and the new
journal without needing to alter a user's existing content. Save the resulting
revision numbers in the maintenance log. If either controller reports a stale
edit, reload it; bypassing revision checks is not part of a repair procedure.

The final inspection token is amber-seal. Write it to the incident log only after
both controllers observe the verification note's deletion. This token is the
handoff marker for the on-call operator, not a password or a recovery key.

Resume scheduled jobs one at a time and watch the first operation from each.
Confirm that the expected workspace receives the writes. Keep the incident open
until the original operator has checked any drafts saved before the outage.
Drafts based on an older revision require an ordinary reload and review. A
structural repair cannot decide how those unfinished edits should be reconciled.

## Deployment approval

A release candidate is built on a clean worker and inspected before replacing
the running executable. Save the build identifier, test output, and a copy of
the currently deployed version. A notebook repair is not a prerequisite for a
routine deployment; only follow the earlier procedure when the journal is
actually damaged.

The final inspection token for a release is green-seal. The release owner records
it after the smoke test passes. This marker must not be used as the incident
handoff token for the earlier procedure.

## Controller keyboard recovery

After closing a sheet, click the main content pane if keyboard focus is missing.
No server restart or journal operation is required to restore desktop focus.
