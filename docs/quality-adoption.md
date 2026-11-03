# Shared quality tooling

This repository records its gates for the shared runner from
[orlenko/software-quality](https://github.com/orlenko/software-quality) in `.quality/config.json` and pins the runner in
`.quality/lock.json`. This is a partial setup that inspects and does not execute. The gates in `AGENTS.md`
"Pull requests" still decide every merge, and a result from this runner neither replaces nor waives any of them.

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

## Review procedure for features

This repository adopts the manual
[review workflow v0.2](https://github.com/orlenko/software-quality/blob/36b0b858b293e14af726e0adf58af476334ccd5d/docs/review-workflow.md)
and its [role instructions](https://github.com/orlenko/software-quality/blob/36b0b858b293e14af726e0adf58af476334ccd5d/docs/review-roles.md),
pinned to source `36b0b858b293e14af726e0adf58af476334ccd5d`. This pin is for those documents only. The runner's pin stays
in `.quality/lock.json`, and nothing here runs automatically. The stricter rule wins wherever this and `AGENTS.md` differ.

For a substantial feature:

1. Before coding, write the user problem, acceptance, smallest alternative, data effects, failure behavior and test
   plan, split into working increments. About 500 changed lines per PR is the aim. It is guidance, and the limit in
   `AGENTS.md` "Pull requests" stays.
2. Get a skeptical design review in a separate context, and pick the lenses below. Record the responses.
3. After coding, get a general bug review in a fresh context that starts from the diff, not from the author's reasoning,
   plus each selected lens in its own context with its own report.
4. Someone other than the author and the report writers reconciles the reports, keeping each finding's original ID, and
   orders the fixes. A valid blocker stays blocking until it is fixed and re-reviewed.
5. Run every gate in `AGENTS.md` "Pull requests" on the final commit, and keep the record in the PR.

Small changes inside a settled design skip step 1 and step 2, and keep the code reviews and all gates.

| Lens | Applies when a change touches | Route today |
|---|---|---|
| Security and privacy | Permissions, user data, logs, Accessibility, the network | Separate agent context |
| Data integrity | Anything in `<id>.holos`, the stores, locks, formats | Separate agent context |
| Reliability and performance | The main actor, background jobs, cancellation, recording | Separate agent context |
| Product and accessibility | A changed workflow or output, keyboard, VoiceOver | Separate agent context, then the owner in the real app |

Other routes: the design review and adjudication use a separate agent context or a peer session. The general bug review is
the local astra review. GitHub Codex stays a separate required gate and does not count as one of the lenses.

The repository owner decides disputed findings.

Limits of these routes:

- A separate agent context is a fresh conversation on the same account. It does not prove independence, and it enforces no
  permission boundary. The agent writing a change cannot adjudicate it.
- No lens runs automatically, and nothing attests that one ran. A selected lens that did not run is a missing review.
- This process has not yet been walked through on a real feature in this repository.
