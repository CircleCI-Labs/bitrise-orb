# Bitrise Orb (Unofficial) [![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/bitrise-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/bitrise-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/bitrise.svg)](https://circleci.com/developer/orbs/orb/cci-labs/bitrise) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/bitrise-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This orb runs a single **[Bitrise Step](https://docs.bitrise.io/en/bitrise-ci/references/glossary#step)** as one step inside an otherwise-native CircleCI job, using Bitrise's own MIT-licensed [`bitrise` CLI](https://github.com/bitrise-io/bitrise) locally -- no bitrise.io account, app registration, or API token involved.

**Why:** Bitrise's StepLib has 400+ Steps, and a disproportionate number of the good ones are mobile-specific -- iOS code signing, Xcode archiving, fastlane, Android signing -- with no real CircleCI orb equivalent today. Teams migrating off Bitrise, or teams that just want to borrow one of those Steps, can run it as-is with this orb instead of reverse-engineering and rewriting it in shell.

**Scope, honestly:** this orb runs **one Step**, not a whole `bitrise.yml` workflow. It is not a Bitrise-workflow importer or a Pipelines equivalent. Everything that would normally be a *separate* Bitrise Step in your old workflow -- checkout, caching, artifact upload -- has a native CircleCI equivalent already (`checkout`, `save_cache`/`restore_cache`, `store_artifacts`) and this orb expects you to keep using those directly rather than running Bitrise's own versions of them (see "What doesn't work" below).

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ✅ Used by real CircleCI customers
-   ❌ **not** officially supported by CircleCI support

---

## Features

- Run any Bitrise Step by StepLib id (`xcode-archive@6`), by git URL (`git::https://github.com/bitrise-io/steps-script.git@1.1.3`), or by local path (`path::./my-step`) -- the full reference grammar, passed through verbatim.
- **No version-resolution logic of our own.** Omit `@<version>` and Bitrise resolves latest, exactly as it would locally -- this orb never second-guesses that.
- **Step outputs come back under their verbatim vendor name** (`BITRISE_IPA_PATH` stays `BITRISE_IPA_PATH`), exported into `$BASH_ENV` so a plain native `run` step right after can read them -- no separate artifact-download step, no orb-specific output syntax to learn. Bitrise's own config-level output aliasing is available too, if you want to rename one.
- Step inputs are a flat YAML block resolved through CircleCI's built-in `circleci env subst`, so `$MY_SECRET` resolves at run time and secrets never have to enter your committed config.
- **No failure wrapping.** If a Step errors because a required input or credential is missing, the job fails with that Step's own stderr on the console, unmodified -- no retries, no swallowed exit codes, no extra validation layer guessing at what the Step needs.
- Two named executors (`bitrise/macos`, `bitrise/machine`) with **no default** -- see "Choosing an executor" below for why.
- **Smart defaults: this orb owns its own lifecycle.** `store_artifacts` against `deploy-dir` and `store_test_results` against `test-results-dir` both run automatically, with zero config -- see "The environment variable mapping" below. Each is a boolean you can turn off if you'd rather do it yourself.

## Resources

- [cci-labs/bitrise on the CircleCI Orb Registry](https://circleci.com/developer/orbs/orb/cci-labs/bitrise) -- the auto-generated reference for every parameter this orb exposes, always up to date with the latest published version.
- [CircleCI Orbs documentation](https://circleci.com/docs/orbs/introduction-to-orbs/)
- [Bitrise Step Library](https://www.bitrise.io/integrations/steps) -- browse Steps and their inputs/outputs before referencing them here.

## Quick start

If your Bitrise workflow's signing Step shows up with **empty inputs** in an exported `bitrise.yml` (`certificate-and-profile-installer@1: {}`, no `certificate_url` at all), that's expected: on Bitrise, those values live in your Bitrise app's **Code Signing** settings page in the bitrise.io web UI, not in the YAML, and get injected at build time. That page is what you're actually copying `certificate_url`/`certificate_passphrase` out of below.

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

That's the whole thing -- five lines under the job invocation. For the most up-to-date parameter reference, visit [this orb's Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitrise#usage-examples). Three more complete, runnable examples:

### Reading a Bitrise Step's output from a native step, in the same job

The single most important thing this orb does: interleave a Bitrise Step with plain CircleCI steps.

```yaml
version: 2.1
orbs:
  bitrise: cci-labs/bitrise@1.0.0
jobs:
  build-ios-app:
    executor: bitrise/macos
    steps:
      - checkout
      - bitrise/step:
          checkout: false
          id: xcode-archive@6
          inputs: |
            project_path: MyApp.xcworkspace
            scheme: MyApp
            distribution_method: app-store
      - run:
          name: Use the .ipa Bitrise just built
          command: echo "xcode-archive produced $BITRISE_IPA_PATH"
      # No manual store_artifacts needed here -- store-artifacts defaults to true, so
      # bitrise/step already published /tmp/bitrise-orb/deploy for you.
workflows:
  ios-release:
    jobs:
      - build-ios-app:
          context: ios-signing
```

### A second platform, on cheap Linux

```yaml
version: 2.1
orbs:
  bitrise: cci-labs/bitrise@1.0.0
workflows:
  android-release:
    jobs:
      - bitrise/step:
          executor: bitrise/machine
          id: sign-apk@2
          inputs: |
            android_app: app/build/outputs/apk/release/app-release-unsigned.apk
            keystore_url: $ANDROID_KEYSTORE_URL
            keystore_password: $ANDROID_KEYSTORE_PASSWORD
            keystore_alias: $ANDROID_KEYSTORE_ALIAS
            private_key_password: $ANDROID_KEY_PASSWORD
          context: android-signing
```

### Chaining two Bitrise Steps that share machine state

Steps that depend on each other's on-disk or keychain state -- code signing, then building with it -- must run in the **same job**, via repeated `bitrise/step` **command** calls with `checkout: false` (and `skip-install`/`skip-map-env` on the later ones), **not** as separate `bitrise/step` **jobs**. Two `bitrise/step` jobs are two independent, ephemeral machines with no shared state, unlike Steps inside one Bitrise Workflow, which always share a machine -- wiring a "cert install" job into an "archive" job as two separate workflow jobs will fail to find the signing identity, with no hint that job isolation is the cause.

```yaml
version: 2.1
orbs:
  bitrise: cci-labs/bitrise@1.0.0
jobs:
  build-signed-ios-app:
    executor: bitrise/macos
    steps:
      - checkout
      - bitrise/step:
          checkout: false
          store-artifacts: false
          store-test-results: false
          id: certificate-and-profile-installer@1
          inputs: |
            certificate_url: $IOS_CERTIFICATE_URL
            certificate_passphrase: $IOS_CERTIFICATE_PASSPHRASE
            provisioning_profile_url: $IOS_PROVISIONING_PROFILE_URL
      - bitrise/step:
          checkout: false
          skip-install: true
          skip-map-env: true
          id: xcode-archive@6
          inputs: |
            project_path: MyApp.xcworkspace
            scheme: MyApp
            distribution_method: app-store
          # store-artifacts/store-test-results default to true, so THIS call is the one
          # that actually publishes /tmp/bitrise-orb/deploy -- the first call above
          # disabled its own copy of the same default since nothing was built yet.
      - run:
          name: Use the .ipa Bitrise just built
          command: echo "xcode-archive produced $BITRISE_IPA_PATH"
workflows:
  ios-release:
    jobs:
      - build-signed-ios-app:
          context: ios-signing
```

Note also that **`bitrise/step` is both a job name and a command name** -- `src/jobs/step.yml` (used under a workflow's `jobs:`, as in the Quick Start above) and `src/commands/step.yml` (used inside an existing job's `steps:`, as in this example and the two above it) are different things that happen to share a name, distinguished only by where they appear in your config.

## Choosing an executor

A Bitrise Step declares nothing machine-readable about needing macOS: `host_os_tags` in a Step's `step.yml` is documented by Bitrise as "currently unused," and `project_type_tags` (`ios`, `android`, `flutter`, ...) is search/filter metadata only, not enforced. So this orb never guesses -- you pick `bitrise/macos` or `bitrise/machine` explicitly on every `bitrise/step` job. Guessing wrong would mean either a confusing failure (an iOS Step on Linux) or roughly 10x the credit cost (an Android Step needlessly run on macOS).

If you're migrating an existing Bitrise workflow, the fastest way to translate is by the **Stack** it used to run on (Workflow Editor -> Stack, or `meta: bitrise.io: stack:` in an exported `bitrise.yml` -- this orb doesn't read or emit that key itself; it's a bitrise.io hosting concept with no local-CLI meaning, and your CircleCI executor choice *is* its replacement):

| Old Bitrise Stack (naming pattern) | Use this executor |
|---|---|
| `osx-xcode-*` (any macOS/Xcode stack) | `bitrise/macos` |
| `linux-docker-android-*` / any Linux stack | `bitrise/machine` |
| `ubuntu-jammy-22.04-bitrise-*` / `ubuntu-noble-24.04-bitrise-*` (Bitrise's newer yearly-edition Linux stack naming) | `bitrise/machine` |

This table is a migration aid for humans reading their old Stack setting, not something this orb parses -- always cross-check against what the specific Step actually needs (its `type_tags`/`project_type_tags`, or just whether it shells out to `xcodebuild`/`security`).

## The environment variable mapping

`bitrise/step` exports these into `$BASH_ENV` before running the Step (via the `map-env` command), so Bitrise Steps that read the usual `BITRISE_*` build-metadata variables see sensible values with zero configuration. Add to or override any of them with the `extra-env` parameter.

| CircleCI | Bitrise |
|---|---|
| `CIRCLE_SHA1` | `BITRISE_GIT_COMMIT` |
| `CIRCLE_BRANCH` | `BITRISE_GIT_BRANCH` |
| `CIRCLE_TAG` | `BITRISE_GIT_TAG` |
| `CIRCLE_BUILD_NUM` | `BITRISE_BUILD_NUMBER` |
| `CIRCLE_PROJECT_REPONAME` | `BITRISE_APP_TITLE` |
| (job's working directory) | `BITRISE_SOURCE_DIR` |
| (the `deploy-dir` parameter, created for you) | `BITRISE_DEPLOY_DIR` |
| (the `test-results-dir` parameter, created for you) | `BITRISE_TEST_DEPLOY_DIR` |

**This orb owns its own lifecycle by default (Locked Decision: smart defaults).** `bitrise/step` automatically runs `store_artifacts` against `deploy-dir` (default `/tmp/bitrise-orb/deploy`) and `store_test_results` against `test-results-dir` (default `/tmp/bitrise-orb/test-results`) right after the Step -- that's this orb's equivalent of `deploy-to-bitrise-io`. You never need to write either step yourself. Set `store-artifacts: false` / `store-test-results: false` to disable either one (e.g. to call `store_artifacts` yourself with different options, or because you're chaining multiple `bitrise/step` calls in one job and only want the last one to publish -- see "Chaining two Bitrise Steps" above).

Bitrise documents `$BITRISE_DEPLOY_DIR` and `$BITRISE_TEST_DEPLOY_DIR` as two **distinct** directories -- deploy artifacts vs. JUnit-XML test results -- so this orb creates and exports both separately, and defaults `store_test_results` at the test-results one specifically. Only certain Steps (`android-unit-test`, `xcode-test`, and similar) actually populate `$BITRISE_TEST_DEPLOY_DIR`; running an arbitrary third-party Step through this orb may deposit nothing there, which is a silent no-op for `store_test_results`, not a failure.

Because the generated `store_artifacts`/`store_test_results` steps are templated from the exact same `deploy-dir`/`test-results-dir` orb parameters that get exported into `$BASH_ENV`, there's no path to type twice and no way for the two to drift apart -- override `deploy-dir` (or `test-results-dir`) once and both the export and the generated step move together. If you disable the defaults and write your own `store_artifacts`/`store_test_results` step instead, that step's own `path:` field still can't take a runtime environment-variable substitution (only a literal, compile-time-known path), so in that case only, you're back to typing the path yourself and keeping it in sync by hand.

## Interleaving native CircleCI steps around the Bitrise Step

The `bitrise/step` **job** (only when invoked from a workflow's `jobs:` list, not the `bitrise/step`
**command** inside another job's own `steps:`) accepts CircleCI's own built-in `pre-steps`/`post-steps`
arguments -- available on every 2.1+ job, not something this orb declares. Pass them at the call site:

```yaml
- bitrise/step:
    executor: bitrise/macos
    id: xcode-archive@6
    inputs: |
      project_path: MyApp.xcworkspace
      scheme: MyApp
    pre-steps:
      - run: echo "before checkout AND before the Bitrise Step"
    post-steps:
      - run: echo "after the Bitrise Step; its outputs are already in $BASH_ENV"
```

**One real platform caveat, verified while re-checking this orb's expansion order (`pre-steps`, job
steps, `post-steps`):** `pre-steps` run before **every** step in the job, including this job's own
internal `checkout` -- not just before the Bitrise Step. If a pre-step needs the repo checked out
first, either do that checkout yourself inside the pre-step, or use `checkout: false` on the job
plus an explicit `checkout` as the first entry of `pre-steps`, so you control exactly where it
lands relative to your other pre-steps:

```yaml
- bitrise/step:
    executor: bitrise/macos
    checkout: false
    id: xcode-archive@6
    inputs: |
      project_path: MyApp.xcworkspace
      scheme: MyApp
    pre-steps:
      - checkout
      - run: echo "runs after checkout, still before the Bitrise Step"
    post-steps:
      - store_artifacts:
          path: /tmp/bitrise-orb/deploy
```

Need several native steps and several Bitrise Steps interleaved in a specific order within one job
(not just "before all" / "after all")? Reach for the `bitrise/step` **command** in a hand-rolled job
instead -- see "Chaining two Bitrise Steps that share machine state" above -- since a command call is
just one entry in an ordinary `steps:` list and can sit anywhere in it.

## Outputs

By default, `bitrise/step` exports every output the Step's own `step.yml` **declares**, discovered via `stepman step-info` -- no maintained list, no guessing (see "Step outputs come back under their verbatim vendor name" above). That covers the overwhelming majority of Steps.

It does **not** cover a Step whose `step.yml` declares zero outputs but whose own code still calls `envman add` for one anyway -- which is exactly how Bitrise's own docs show passing a value between Steps from a `script` Step. Without an escape hatch, this does nothing on this orb, silently, with a green build:

```yaml
- bitrise/step:
    id: script@1
    inputs: |
      content: envman add --key APP_VERSION --value "$(cat VERSION)"
- run: echo "version is $APP_VERSION"    # empty -- script@1 declares no outputs
```

Use `extra-outputs` to name it explicitly -- a newline-separated list of environment variable **names** (no values), unioned with whatever the Step declares:

```yaml
- bitrise/step:
    id: script@1
    inputs: |
      content: envman add --key APP_VERSION --value "$(cat VERSION)"
    extra-outputs: |
      APP_VERSION
- run: echo "version is $APP_VERSION"    # now populated
```

`extra-outputs` entries are exported verbatim under their own name only -- they're not eligible for Bitrise's config-level output aliasing (the `outputs` parameter), since that mechanism only knows about a Step's *declared* outputs.

## What doesn't work

A specific, identifiable slice of Bitrise Steps call back to bitrise.io's own hosted services with no substitution point -- these fail outside a real Bitrise build not because the CLI blocks them, but because *that Step's own code* calls a bitrise.io endpoint this orb has no account behind. Re-implement these against CircleCI's native equivalents instead of running the Bitrise Step:

| Doesn't work | Why | Use instead |
|---|---|---|
| **Virtual Device Testing** (Android/iOS) | Proxies to Firebase Test Lab under **Bitrise's own** Firebase license and build-slug identity, not yours. | A CircleCI-native device-testing integration, or Firebase Test Lab directly under your own GCP project. |
| **Deploy to Bitrise.io** | Authenticates against Bitrise's own Artifacts/Tests backend with a build-scoped `$BITRISE_BUILD_API_TOKEN` this orb never has. | `store_artifacts` / `store_test_results` on `$BITRISE_DEPLOY_DIR` / `$BITRISE_TEST_DEPLOY_DIR` -- already automatic by default, see above. |
| **Bitrise Build Cache** (Gradle/Bazel/Xcode remote cache) | A co-located, datacenter-local cache/proxy service gated behind a Bitrise workspace token. | Your build tool's own remote-cache config pointed at infrastructure you control, or plain CircleCI `save_cache`/`restore_cache`. |
| **Save/Restore Cache Steps** (and the dependency-manager-specific ones: Cocoapods, Gradle, SPM, ...) | The cache archive store is scoped to "your Bitrise project" and billed/retained per Bitrise plan -- it isn't something you can point at other infrastructure. | `save_cache`/`restore_cache` with the same keys/paths the dedicated Step would have used. |
| **`register_test_devices` input on `xcode-archive`/`manage-ios-code-signing`** | Registers "the known test devices **on Bitrise** from team members" with the Apple Developer Portal -- that device roster lives in Bitrise's own account data, not exposed via an API this orb could substitute. | Register test devices directly in the Apple Developer portal, or via `fastlane`'s own `register_devices` action with your own Apple credentials. |
| **Unity license activation Step(s)** | Unity license *pools* are configured in Bitrise Workspace settings -- the pooling/allocation UX is bitrise.io-only, though the actual `Unity -serial ...` activation call itself goes straight to Unity (more a config-portability gap than a true hard blocker). | Manage your own Unity license/serial directly, outside Bitrise's pooling UI. |

By contrast, **iOS/Android code signing itself is not a hard blocker**: `xcode-archive`, `manage-ios-code-signing`, and the `fastlane` Step all expose an explicit "bring your own Apple/Google credentials" override (an App Store Connect API key, or `connection: off`) that talks directly to Apple/Google, sidestepping bitrise.io's backend entirely -- that's exactly the path the examples above use.

## Gotchas worth knowing before your first run

- **macOS requires Homebrew.** `bitrise setup` hard-requires it even in minimal mode. CircleCI's standard macOS executor images ship it, so this is low-risk, but it's the first thing to check if `install` fails on a custom image.
- **`bitrise run` auto-loads a file literally named `.bitrise.secrets.yml` from the working directory, with no flag needed.** If your repo happens to contain one, its values get silently picked up. This orb doesn't delete or otherwise touch that file -- it's a Bitrise CLI behavior, not this orb's.
- **This orb passes every Step input through verbatim and does not validate it (by design -- see "No failure wrapping" above).** A typo in an input name won't be caught by this orb; the Step's own error message is what you'll see, exactly as if you'd run `bitrise run` locally. It'll appear after a fair amount of orb-plumbing output (CLI install, cache restore, `bitrise setup`) -- look for the "Running Bitrise Step" step's own output specifically.
- **Bitrise's Go-toolkit Steps are compiled from source on first use per machine/version**, not shipped as prebuilt binaries -- expect the first run of a new Step+version to take a few seconds longer than subsequent cached runs.

## How to Contribute

Bug reports and feature requests are welcome via [Issues](https://github.com/CircleCI-Labs/bitrise-orb/issues). Pull requests are welcome via the usual GitHub flow.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's `<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb that can still pass `circleci orb validate` -- a false green with no other symptom. Run `scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack` workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a job parameter literally named `pre-steps` or `post-steps` outright -- this only surfaces under `orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If you're adding a new job parameter, don't pick either name.

## How to Publish An Update

1. Merge PRs using squash-merge with a [Conventional Commits](https://www.conventionalcommits.org/)-style message.
2. Check the current published version: `circleci orb info cci-labs/bitrise | grep "Latest"`.
3. Create a new GitHub Release with a new semver tag (`vX.Y.Z`).
4. Click "+ Auto-generate release notes."
5. Verify the semver bump you're about to publish actually matches what the generated notes describe (a breaking change needs a major bump, not a patch).
6. Click "Publish Release" -- pushing that `vX.Y.Z` tag is what satisfies this repo's production-publish gate.
