# Roadmap / deferred design decisions

This file records the things a recent audit of the `cci-labs` ecosystem-bridge orb family
(2026-08) found worth doing to `bitrise-orb`, but that this orb deliberately does **not** do, and
why -- so the decision is visible in the repo instead of living only in a chat transcript or a PR
description that ages out. It also carries forward the reasoning behind a handful of scope/design
calls that already shipped, so a future contributor doesn't have to re-derive "why is it built
this way" from scratch.

None of the items below are secretly half-built. If you pick one up, treat this as the starting
brief, not a patch to apply.

## Deferred / not implemented

### 1. A wider default toolchain in `init-stack`'s profiles

**What it would do:** cover more of Bitrise's own Ubuntu/Android stack tooling by default --
things like `ripgrep`, `gh`, the AWS CLI, `gcloud`, or Nix, which all appear somewhere in
Bitrise's own stack tooling inventory.

**Why it's deferred:** the research behind `init-stack` read Bitrise's own machine-readable stack
manifest ([`bitrise-io/stacks`](https://github.com/bitrise-io/stacks), a JSON transcript refreshed
continuously against real stack VMs) and cross-referenced it against 20 real StepLib Steps' own
declared dependencies and Go source. `zstd`, a JDK+Android-SDK slice, Ruby+fastlane, and Node.js
are the only things any of those 20 Steps actually call -- ripgrep/gh/AWS CLI/gcloud/Nix/etc. all
appear in Bitrise's tools inventory but zero sampled first-party Step declares or calls any of
them. A tool nothing uses is not worth installing by default.

**What shipped instead:** an explicit `tools:` catalog override (`tools: "ripgrep,gh"` or pinned,
`ripgrep@14.1.1`) for the ad hoc case, checked against this orb's own pinned catalog so an
unrecognized name/version fails loudly instead of being silently skipped.

**If someone picks this up:** widen the sample past 20 Steps (or target a specific customer's real
Step list) before adding anything to a default profile -- the bar this orb held itself to was "a
real Step actually calls this," not "Bitrise's stack happens to include this."

### 2. Full-workflow (multi-Step, multi-tool-vendor) coverage in `android-toolchain`

**What it would do:** make `bitrise/android-toolchain` a complete, current mirror of Bitrise's own
hosted Android/Linux stack image, so any Step's toolchain assumption is satisfied without also
running `init-stack`.

**Why it's deferred:** the only pullable public image is `quay.io/bitriseio/android-20.04`, which
this orb's own research confirmed (directly against Quay's tag metadata) was last published
2024-01-08 -- a multi-year-stale snapshot, not a live mirror of bitrise.io's current hosted stack,
and it's amd64-only at 10+GB. Committing to that as *the* Android answer would mean shipping a
known-stale environment as this orb's default recommendation.

**What shipped instead:** `android-toolchain` remains a named, opt-in executor with its staleness
and size stated plainly, and `bitrise/machine` + `init-stack`'s pinned, freshly-verified subset
(see item 1) is the default recommendation instead -- current where the vendor image is stale, and
right-sized where the vendor image is oversized for what any sampled Step actually needs.

**If someone picks this up:** re-check Quay's tag metadata for a newer publish before doing
anything else -- this whole item goes away if Bitrise starts publishing current images again.

## Limitations reassessment (2026-08)

Four cross-cutting questions came up while auditing this orb against its `cci-labs` siblings.
Each was already answered somewhere in this orb's design; this section is where that reasoning
lives now, instead of being spread across README prose a user has to hunt for.

### Image caching economics

`bitrise/android-toolchain`'s `docker-layer-caching` (DLC) defaults to `true`, unlike
`bitrise/machine`'s own default of `false` -- because the two cases are economically different,
not because one default is "more correct." DLC is a **paid, plan-gated CircleCI feature** that
caches at the Docker *layer* level, so a small upstream tag bump often only re-pulls the top
layer instead of the whole image. Below roughly 50MB, a plain pull is already faster than the
cache round-trip, so DLC stays off by default everywhere in this orb except the one executor
whose image is 10+GB -- there, layer-level reuse is worth the round-trip. This orb doesn't
hand-roll its own `docker save`/`load` cache on top of DLC anywhere, because that would be
redundant with, and strictly worse than (all-or-nothing per exact tag vs. DLC's per-layer reuse),
a feature that already ships. See "A third, opt-in executor" in
[GETTING-STARTED.md](GETTING-STARTED.md#a-third-opt-in-executor-bitriseandroid-toolchain) for the
current user-facing guidance.

### Command-split decisions

`step` decomposes into five commands (`install` -> `map-env` -> `create-config` ->
`collect-outputs` -> `run-bitrise`) rather than one monolithic script, specifically so a
hand-rolled job chaining several Bitrise Steps that share on-disk/keychain state (see
["Chaining two Bitrise Steps"](GETTING-STARTED.md#chaining-two-bitrise-steps-that-share-machine-state)
in GETTING-STARTED.md) can skip the stages an earlier call in the same job already did
(`skip-install`/`skip-map-env`) instead of redoing them. The two ordering constraints that fall
out of this split are load-bearing, not incidental: `map-env` must run before `create-config`
(secrets resolve via `circleci env subst` against whatever `$BASH_ENV` holds *at that moment*,
and `map-env` is what populates `$BITRISE_DEPLOY_DIR`/etc.), and `collect-outputs` must run before
`run-bitrise` (it only *appends* an output-exporting Step to the not-yet-executed synthesized
config; nothing has run yet when it does). `init-stack`'s own resolve -> restore_cache -> install
-> save_cache shape deliberately mirrors `install.yml`'s for the same reason (a reference pattern
worth reusing), even though the two don't share code -- see "How it works" and "Stack bootstrap"
in [ARCHITECTURE.md](ARCHITECTURE.md) for the full mechanism.

### Workspace / parallelism fit

This orb's output-export mechanism (`$BASH_ENV`) is job-scoped, exactly like any other
`$BASH_ENV` export on CircleCI -- it doesn't cross a job boundary on its own, and no orb change
was built to make it do so. Passing a Step's output *value* to a downstream job is already fully
solved with zero orb changes: write it to a file, `persist_to_workspace` it, `attach_workspace`
downstream. **Branching which jobs *run*, based on an upstream job's runtime output, was
considered and explicitly not solved here** -- CircleCI has no native construct for a genuine
workflow-level conditional at all, orb or no orb; the closest real mechanism is a setup workflow
plus the `circleci/continuation` orb, and there is no lighter-weight substitute available today.
This orb doesn't invent one. See ["Passing data between jobs"](GETTING-STARTED.md#passing-data-between-jobs)
in GETTING-STARTED.md for the current worked examples of both mechanisms.

### Vendor-image layering

Checked directly against Bitrise's own stack manifest and Quay's tag metadata while researching
this orb: unlike the sibling `harness`/`bitbucket` orbs (where every plugin/pipe is already its
own purpose-built image, so there's nothing to layer) and unlike `buildkite` (where a current,
permissively-licensed vendor base image genuinely filled a real gap), this orb's only pullable
vendor image is `quay.io/bitriseio/android-20.04` -- amd64-only, 10+GB, and a snapshot last
published 2024-01-08, i.e. stale by design, not something worth adopting as this orb's default
layering strategy (see item 2 above). The default recommendation is `bitrise/machine` plus
`init-stack`'s pinned, checksum-verified, continuously-researched subset instead -- current where
the vendor image is stale, and scoped to what real Steps actually call rather than a whole stack
mirror. See ["A third, opt-in executor"](GETTING-STARTED.md#a-third-opt-in-executor-bitriseandroid-toolchain)
and ["Stack bootstrap"](ARCHITECTURE.md#stack-bootstrap) for the user-facing form of this decision.
