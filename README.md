# Bitrise Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/bitrise-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/bitrise-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/bitrise.svg)](https://circleci.com/developer/orbs/orb/cci-labs/bitrise) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/bitrise-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This orb runs a single **[Bitrise Step](https://docs.bitrise.io/en/bitrise-ci/references/glossary#step)** as one step inside an otherwise-native CircleCI job, using Bitrise's own MIT-licensed [`bitrise` CLI](https://github.com/bitrise-io/bitrise) locally: no bitrise.io account, app registration, or API token involved. It runs **one Step per call**, not a whole `bitrise.yml` workflow.

**Why:** Bitrise's StepLib has 400+ Steps, and a disproportionate number of the good ones are mobile-specific (iOS code signing, Xcode archiving, fastlane, Android signing) with no real CircleCI orb equivalent today. Teams migrating off Bitrise, or teams that just want to borrow one of those Steps, can run it as-is with this orb instead of reverse-engineering and rewriting it in shell.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ⚠️ **Android signing is genuinely proven; iOS signing is proven only partway, honestly.**
    `test-sign-apk` runs unconditionally (no context, no credentials) against a committed,
    non-secret debug keystore (the same alias/password every Android dev tool ships by
    default) and a freshly-built unsigned APK fixture, then requires `apksigner verify`
    AND `jarsigner -verify` to both confirm the output is really signed and attribute it
    to that fixture's own certificate, not just a 0 exit code. `test-certificate-and-
    profile-installer` also runs unconditionally, against a throwaway self-signed
    certificate generated fresh with `openssl` every run, and verifies via `security
    find-certificate` that the Step really downloaded, decrypted, and imported it into a
    real macOS keychain, proving this orb's input-mapping and Step-invocation for the
    certificate half of that Step is real, working code. It does **not** prove a
    provisioning-profile install (none is exercised: a real one needs an Apple Developer
    account this project doesn't have and won't fabricate) or that Xcode would ever trust
    a self-signed, non-Apple-issued certificate. See both jobs' own comments in
    `.circleci/test-deploy.yml` for the exact boundary. Everything else in this repo (the
    plumbing: parameter handling, output export, the stack bootstrap, every
    security-regression test) runs green, unauthenticated, on every commit too.
-   ❌ **not** officially supported by CircleCI support

---

## Contents

- [Architecture](docs/ARCHITECTURE.md): how it works, the command pipeline, the stack-bootstrap mechanism
- [Getting Started](docs/GETTING-STARTED.md): fuller walkthrough, executor choices, more examples
- [Commands](docs/COMMANDS.md): the complete command/job/parameter reference
- [Migrating from Bitrise](docs/MIGRATING.md): mapping a real `bitrise.yml` onto this orb
- [Limits](docs/LIMITS.md): what doesn't work, and gotchas worth knowing first
- [Roadmap](docs/ROADMAP.md): items deliberately scoped out, with the reasoning kept

## Quick start

If your Bitrise workflow's signing Step shows up with **empty inputs** in an exported `bitrise.yml` (`certificate-and-profile-installer@1: {}`, no `certificate_url` at all), that's expected: on Bitrise those values live in your Bitrise app's **Code Signing** settings page in the bitrise.io web UI, not in the YAML, and get injected at build time. That page is what you're actually copying `certificate_url`/`certificate_passphrase` out of below.

```yaml
version: 2.1
orbs:
  bitrise: cci-labs/bitrise@1.0.0
workflows:
  ios-code-signing:
    jobs:
      - bitrise/step:
          executor: bitrise/macos
          id: certificate-and-profile-installer@1
          inputs: |
            certificate_url: $IOS_CERTIFICATE_URL
            certificate_passphrase: $IOS_CERTIFICATE_PASSPHRASE
```

That's the whole thing: five lines under the job invocation. See [Getting Started](docs/GETTING-STARTED.md) for three more complete, runnable examples (including reading a Step's output from a native step in the same job), and the [Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitrise#usage-examples) for the most up-to-date parameter reference.

## Commands and jobs

| Name | Kind | What it does |
|---|---|---|
| `step` | command, job | The aggregate most users want: install, map env, synthesize config, collect outputs, run, publish artifacts/results. |
| `install` | command | Resolves and installs the Bitrise CLI + `yq`, checksum-verified, cached. |
| `map-env` | command | Exports the CircleCI to Bitrise variable mapping into `$BASH_ENV`. |
| `create-config` | command | Synthesizes the throwaway `bitrise.yml` for exactly one Step. |
| `collect-outputs` | command | Discovers and prepares export of the Step's declared outputs. |
| `run-bitrise` | command | Runs the synthesized config; the actual execution point. |
| `init-stack` | command | Standalone, opt-in: bootstraps a pinned Android/fastlane/Node toolchain slice. |

Full parameter tables for every command and job are in [docs/COMMANDS.md](docs/COMMANDS.md).

## Limits, in brief

- A specific slice of Bitrise Steps call back to bitrise.io's own hosted services (Virtual Device Testing, Deploy to Bitrise.io, Bitrise Build Cache, the Save/Restore Cache Steps) and have no substitution point; use CircleCI's native equivalents instead.
- This orb runs a Step natively, with no container boundary: treat it as exactly as trusting as running that Step's code directly in your job.
- The synthesized `bitrise.yml` contains every resolved input/output value, including secrets, once written; scope any broad artifact/workspace glob to exclude it.
- iOS/Android code signing itself is **not** a hard blocker: bring your own Apple/Google credentials and it works.

Full detail, plus first-run gotchas, in [docs/LIMITS.md](docs/LIMITS.md).

## Resources

- [cci-labs/bitrise on the CircleCI Orb Registry](https://circleci.com/developer/orbs/orb/cci-labs/bitrise): the auto-generated reference for every parameter this orb exposes, always up to date with the latest published version.
- [CircleCI Orbs documentation](https://circleci.com/docs/orbs/introduction-to-orbs/)
- [Bitrise Step Library](https://www.bitrise.io/integrations/steps): browse Steps and their inputs/outputs before referencing them here.

## How to Contribute

Bug reports and feature requests are welcome via [Issues](https://github.com/CircleCI-Labs/bitrise-orb/issues). Pull requests are welcome via the usual GitHub flow. See [`docs/ROADMAP.md`](docs/ROADMAP.md) for items deliberately scoped out of past passes, with the reasoning recorded rather than lost.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's `<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb that can still pass `circleci orb validate`: a false green with no other symptom. Run `scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack` workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a job parameter literally named `pre-steps` or `post-steps` outright; this only surfaces under `orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If you're adding a new job parameter, don't pick either name.

## How to Publish An Update

1. Merge PRs using squash-merge with a [Conventional Commits](https://www.conventionalcommits.org/)-style message.
2. Check the current published version: `circleci orb info cci-labs/bitrise | grep "Latest"`.
3. Create a new GitHub Release with a new semver tag (`vX.Y.Z`).
4. Click "+ Auto-generate release notes."
5. Verify the semver bump you're about to publish actually matches what the generated notes describe (a breaking change needs a major bump, not a patch).
6. Click "Publish Release": pushing that `vX.Y.Z` tag is what satisfies this repo's production-publish gate.
