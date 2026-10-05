# Verified Outpost recovery snapshot

Source commit: `4cce6ebfaa31f76cd7790967ad8ce7d7e2338deb` (initially clean). Audit gate committed separately before implementation. No original tracked renderer or artwork has been deleted by this recovery step.

Archive: `/Users/nahid/.codex/archives/agent-worlds/2026-10-05/locus-outpost-4cce6ebf/locus-outpost-source.tar.gz`

SHA-256: `d6694fb2258e5de2e85d8b0d4cf0a2865680d4dc9af9169c5554cc3bcb9297a3`

Size: 333,170,467 bytes. Contents: 1,239 tracked files from the source commit, including complete AgentWorldWeb, original two-world plugin, Locus native implementation/resources/tests, Python host source/tests, Tools, Docs, project/CI/marketplace configuration. Unrelated builtin skills and third-party native license bundles are excluded; this is a recovery source snapshot, not a redistributable whole-app release and not an import of Locus Git history.

The archive's sibling `manifest.json` lists all files with byte counts and SHA-256 hashes computed from `git show` at the source commit. `RESTORE.md` contains restoration instructions. `restoration-verification.txt` records the successful rehearsal.

Restoration rehearsal used a new disposable directory, verified every file hash against the commit-derived manifest, and ran the original package verifier successfully: two themes; digest `590da9c7cdd00ec9857dac7015fbdf4a37617dc7d8d0071fdaa4ae8b8c2931dc`; all 2,053 reserved/reported Meshy credits accounted for. Rehearsal path: `/var/folders/8s/h68vzwb10yg081d3vgblcx7c0000gn/T/locus-outpost-restoration-mie2eox1` (disposable; the archive is durable).

Restore into a new empty directory:

```sh
mkdir /tmp/locus-outpost-restored
shasum -a 256 /Users/nahid/.codex/archives/agent-worlds/2026-10-05/locus-outpost-4cce6ebf/locus-outpost-source.tar.gz
tar -xzf /Users/nahid/.codex/archives/agent-worlds/2026-10-05/locus-outpost-4cce6ebf/locus-outpost-source.tar.gz -C /tmp/locus-outpost-restored
```

Compare the archive hash with the recorded value, then verify each restored file against `manifest.json` before use. With the original Locus Python runtime dependencies and Pillow installed, `python Tools/VerifyAgentWorldPackage.py` revalidates the package offline. No generation request or private-generation-directory access is necessary.

Keep the archive outside active source/build inputs and release artifacts. It must survive acceptance and must not be deleted automatically. The existing in-tree implementation stays intact until the separately recorded extraction acceptance gates pass.
