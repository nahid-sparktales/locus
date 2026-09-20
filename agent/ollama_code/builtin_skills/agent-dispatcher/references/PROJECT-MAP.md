# Local project map

The optional `scripts/project_map.py` helper records source-linked facts, never permissions
or instructions. PACK is this bundle's absolute path and PROJECT is the chat workspace.
Use the actual permitted terminal tools, quote paths individually, and do not interpolate
request text into shell code. No model, network call, or background service is involved.

```text
python3 -B PACK/scripts/project_map.py --pack PACK --project PROJECT show --json
```

`show` is read-only. Only when the user explicitly requests a map build or refresh, and
the active Locus mode permits workspace writes, replace `show` with `build` or `refresh`.
Those operations write `.agent-dispatcher/project-map.json` in PROJECT. They never execute
discovered project commands. Source hashes establish freshness; changed facts are withheld.
If Python or the terminal is unavailable, inspect relevant files directly and describe gaps.
