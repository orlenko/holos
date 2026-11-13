# Shared quality tooling

This repository records its gates for the shared runner from
[orlenko/software-quality](https://github.com/orlenko/software-quality) in `.quality/config.json` and pins the runner in
`.quality/lock.json`. This is a partial setup that inspects and does not execute. The rules in `AGENTS.md`
"Pull requests" and "Review and tests" decide every merge, and a result from this runner neither replaces nor waives
any of them.

## Stages

| Stage | State |
|---|---|
| Configured | Yes: config and lock in this repository, read by the runner from the accepted base commit only. |
| Installed | Per machine, outside this repository. Nothing here installs it. |
| Executed | `doctor` only. `check` runs no target commands, because `trusted_local` is false. |
| Verified adoption | No. See "Gaps". |

`doctor` exits 2 because check and review evidence is missing. Exit 2 also covers bad config, pins or runtime, so a
valid run is one whose `report.json` shows the expected config and lock digests, passing inspection and artifact
stages, and the missing checks and reviews marked incomplete.

## Running it

The pin in `.quality/lock.json` names a source commit and an artifact digest. Get the artifact bytes from the toolkit
maintainer, compare the digest, and take `quality_launch.py` and `quality_trust.py` from that source commit. Use a
Python 3.11 or newer interpreter where `os.waitid` exists; Apple's `/usr/bin/python3` does not qualify. Keep the
bootstrap files, cache and state in separate folders outside this repository, and keep the reports private.

```sh
PYTHON -I -S BOOTSTRAP/quality_launch.py install --artifact CORE_PYZ \
  --source LOCK_SOURCE --sha256 LOCK_ARTIFACT_SHA256 --cache CACHE
PYTHON -I -S BOOTSTRAP/quality_launch.py doctor --repo REPO --base FULL_BASE --head FULL_HEAD \
  --identity orlenko/holos --cache CACHE --state STATE
```

Do not add `--execute-trusted`, and do not write review attestations. There is no launcher, hook, workflow or registered
command in this repository, because head-side code must not choose the tool that checks it.

## Effects and threats

`doctor` reads Git objects, writes a report under the state folder, and runs no code from this repository. It sends
nothing over the network.

The listed checks are requirements with execution disabled, for these reasons:

- `full-test-suite` needs longer than the runner's 600-second limit. It compiles from nothing in a Git-free snapshot,
  and takes 8 to 10 minutes even with an existing build folder.
- Some tests write defaults domains into the real macOS preferences of whoever runs them, so `owner-approved-wrapper`
  would be false. A fresh `HOME` does not isolate that store.
- `doc-citations` reads the real Git index, which a snapshot does not have. A synthetic index does not count.

Both review routes are hosted models reading public source. The `enforced` and `tracked-source` boundary fields state
what a future attestation has to show. Neither route shows them today, so the review stage stays incomplete. Private
recordings and user data stay out of every route, as `AGENTS.md` "Privacy" requires.

## Gaps

The runner's schema cannot express these, and leaving them out of the config waives none of them:

- Moves-only evidence for refactor PRs, and the other PR rules in `AGENTS.md` "Pull requests".
- Privacy review of public changes, by hand.
- Product and accessibility checks in the real app, in `docs/manual-testing.md` and `docs/dictation-validation.md`.
- Release evidence, in `docs/release.md`.

These stand between this setup and verified adoption:

- Tests need isolated preferences before they can run under a wrapper.
- The test suite needs a route that fits the time limit without running a subset.
- Review routes need an enforced boundary and durable, exact-commit evidence.
