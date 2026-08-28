## What this changes

<!-- What behaviour differs after this, and why. Not a list of files. -->

## How you verified it

<!-- What you actually ran. `xcodebuild test -only-testing:LocusTests` and
`agent/.venv/bin/python3 -m pytest -q` at minimum for anything non-trivial.
Say if you exercised it in the running app. -->

## Checklist

- [ ] Commits are signed off (`git commit -s`) — see [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] Swift and Python suites pass
- [ ] New state/routes follow [the ownership boundaries](../Docs/Architecture.md),
      or the PR explains why the boundary should change
- [ ] The advisory `Tools/ReviewabilityReport.py` signals were reviewed; large
      files or diffs are intentional and independently understandable
- [ ] New feature state/actions were kept out of `AppModel`, and new API
      handlers were kept out of `server.py`
- [ ] `xcodegen generate` run if `project.yml` or the file layout changed, and the
      regenerated `Locus.xcodeproj/project.pbxproj` is committed
- [ ] No credential, key, token, or absolute local path added — including in a
      test fixture or a comment
- [ ] A new Python dependency is pinned in `agent/requirements-runtime.lock` and
      listed in `Locus/Resources/ThirdPartyNotices.md`
- [ ] User-visible changes have a `CHANGELOG.md` entry
- [ ] Docs and UI strings still describe what the code now does
