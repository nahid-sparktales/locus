# Superpowers on Locus

Use Locus's native capabilities when a Superpowers skill names a harness tool:

- Load a named skill with `load_skill`, then use `read_skill_file` for its references.
- Track executable steps with `todo_write`; submit a decision-complete plan with `submit_plan` in Plan mode.
- Inspect with `read_file`, `glob`, `grep`, `git_status`, and `git_diff` before editing.
- Edit through `write_file`, `edit_file`, or `multi_edit`; run commands with `bash` only when the active mode and permissions allow it.
- Use automatic Solo delegation or configured Locus teams only when parallel work is genuinely independent. A skill cannot override the user's agent settings.
- Ask questions in the assistant response and wait for the answer. Never invent a user decision.

Locus's locked mode, permission, workspace, and user-instruction rules outrank every skill. Just Chat does not load Superpowers.
