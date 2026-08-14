# Bitrise Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/bitrise-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/bitrise-orb)
[![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/bitrise.svg)](https://circleci.com/developer/orbs/orb/cci-labs/bitrise)
[![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/bitrise-orb/main/LICENSE)
[![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

This orb runs a single **[Bitrise Step](https://docs.bitrise.io/en/bitrise-ci/references/glossary#step)** as one step inside an otherwise-native CircleCI job, using Bitrise's own MIT-licensed [`bitrise` CLI](https://github.com/bitrise-io/bitrise) locally -- no bitrise.io account, app registration, or API token involved.

**Why:** Bitrise's StepLib has 400+ Steps, and a disproportionate number of the good ones are mobile-specific -- iOS code signing, Xcode archiving, fastlane, Android signing -- with no real CircleCI orb equivalent today. Teams migrating off Bitrise, or teams that just want to borrow one of those Steps, can run it as-is with this orb instead of reverse-engineering and rewriting it in shell.

**Scope, honestly:** this orb runs **one Step**, not a whole `bitrise.yml` workflow. It is not a Bitrise-workflow importer or a Pipelines equivalent. Everything that would normally be a *separate* Bitrise Step in your old workflow -- checkout, caching, artifact upload -- has a native CircleCI equivalent already (`checkout`, `save_cache`/`restore_cache`, `store_artifacts`) and this orb expects you to keep using those directly rather than running Bitrise's own versions of them (see "What doesn't work" below).

---

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.
- ✅ Created by engineers @ CircleCI
- ✅ Used by real CircleCI customers
- ❌ **not** officially supported by CircleCI support

---

## Features

- Run any Bitrise Step by StepLib id (`xcode-archive@5`), by git URL (`git::https://github.com/bitrise-io/steps-script.git@1.1.3`), or by local path (`path::./my-step`) -- the full reference grammar, passed through verbatim.
- **No version-resolution logic of our own.** Omit `@<version>` and Bitrise resolves latest, exactly as it would locally -- this orb never second-guesses that.
- **Step outputs come back under their verbatim vendor name** (`BITRISE_IPA_PATH` stays `BITRISE_IPA_PATH`), exported into `$BASH_ENV` so a plain native `run` step right after can read them -- no separate artifact-download step, no orb-specific output syntax to learn. Bitrise's own config-level output aliasing is available too, if you want to rename one.
- Step inputs are a flat YAML block resolved through CircleCI's built-in `circleci env subst`, so `$MY_SECRET` resolves at run time and secrets never have to enter your committed config.
- **No failure wrapping.** If a Step errors because a required input or credential is missing, the job fails with that Step's own stderr on the console, unmodified -- no retries, no swallowed exit codes, no extra validation layer guessing at what the Step needs.
- Two named executors (`bitrise/macos`, `bitrise/machine`) with **no default** -- see "Choosing an executor" below for why.

## Resources

- [cci-labs/bitrise on the CircleCI Orb Registry](https://circleci.com/developer/orbs/orb/cci-labs/bitrise) -- the auto-generated reference for every parameter this orb exposes, always up to date with the latest published version.
- [CircleCI Orbs documentation](https://circleci.com/docs/orbs/introduction-to-orbs/)
- [Bitrise Step Library](https://www.bitrise.io/integrations/steps) -- browse Steps and their inputs/outputs before referencing them here.

## Quick start

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

That's the whole thing -- five lines under the job invocation. For the most up-to-date parameter reference, visit [this orb's Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitrise#usage-examples). Two more complete, runnable examples:

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
          id: xcode-archive@5
          inputs: |
            project_path: MyApp.xcworkspace
            scheme: MyApp
            distribution_method: app-store
      - run:
          name: Use the .ipa Bitrise just built
          command: echo "xcode-archive produced $BITRISE_IPA_PATH"
      - store_artifacts:
          path: /tmp/bitrise-orb/deploy
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

## Choosing an executor

A Bitrise Step declares nothing machine-readable about needing macOS: `host_os_tags` in a Step's `step.yml` is documented by Bitrise as "currently unused," and `project_type_tags` (`ios`, `android`, `flutter`, ...) is search/filter metadata only, not enforced. So this orb never guesses -- you pick `bitrise/macos` or `bitrise/machine` explicitly on every `bitrise/step` job. Guessing wrong would mean either a confusing failure (an iOS Step on Linux) or roughly 10x the credit cost (an Android Step needlessly run on macOS).

If you're migrating an existing Bitrise workflow, the fastest way to translate is by the **Stack** it used to run on (Workflow Editor -> Stack, or `meta: bitrise.io: stack:` in an exported `bitrise.yml` -- this orb doesn't read or emit that key itself; it's a bitrise.io hosting concept with no local-CLI meaning, and your CircleCI executor choice *is* its replacement):

| Old Bitrise Stack (naming pattern) | Use this executor |
|---|---|
| `osx-xcode-*` (any macOS/Xcode stack) | `bitrise/macos` |
| `linux-docker-android-*` / any Linux stack | `bitrise/machine` |

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

Point `store_artifacts`/`store_test_results` at `deploy-dir` (default `/tmp/bitrise-orb/deploy`) in a later step to publish whatever the Step deposited there -- that's this orb's equivalent of `deploy-to-bitrise-io`.

## What doesn't work

A specific, identifiable slice of Bitrise Steps call back to bitrise.io's own hosted services with no substitution point -- these fail outside a real Bitrise build not because the CLI blocks them, but because *that Step's own code* calls a bitrise.io endpoint this orb has no account behind. Re-implement these against CircleCI's native equivalents instead of running the Bitrise Step:

| Doesn't work | Why | Use instead |
|---|---|---|
| **Virtual Device Testing** (Android/iOS) | Proxies to Firebase Test Lab under **Bitrise's own** Firebase license and build-slug identity, not yours. | A CircleCI-native device-testing integration, or Firebase Test Lab directly under your own GCP project. |
| **Deploy to Bitrise.io** | Authenticates against Bitrise's own Artifacts/Tests backend with a build-scoped `$BITRISE_BUILD_API_TOKEN` this orb never has. | `store_artifacts` / `store_test_results` on `$BITRISE_DEPLOY_DIR` (see above). |
| **Bitrise Build Cache** (Gradle/Bazel/Xcode remote cache) | A co-located, datacenter-local cache/proxy service gated behind a Bitrise workspace token. | Your build tool's own remote-cache config pointed at infrastructure you control, or plain CircleCI `save_cache`/`restore_cache`. |
| **Save/Restore Cache Steps** (and the dependency-manager-specific ones: Cocoapods, Gradle, SPM, ...) | The cache archive store is scoped to "your Bitrise project" and billed/retained per Bitrise plan -- it isn't something you can point at other infrastructure. | `save_cache`/`restore_cache` with the same keys/paths the dedicated Step would have used. |

By contrast, **iOS/Android code signing itself is not a hard blocker**: `xcode-archive`, `manage-ios-code-signing`, and the `fastlane` Step all expose an explicit "bring your own Apple/Google credentials" override (an App Store Connect API key, or `connection: off`) that talks directly to Apple/Google, sidestepping bitrise.io's backend entirely -- that's exactly the path the examples above use.

## Gotchas worth knowing before your first run

- **macOS requires Homebrew.** `bitrise setup` hard-requires it even in minimal mode. CircleCI's standard macOS executor images ship it, so this is low-risk, but it's the first thing to check if `install` fails on a custom image.
- **`bitrise run` auto-loads a file literally named `.bitrise.secrets.yml` from the working directory, with no flag needed.** If your repo happens to contain one, its values get silently picked up. This orb doesn't delete or otherwise touch that file -- it's a Bitrise CLI behavior, not this orb's.
- **This orb passes every Step input through verbatim and does not validate it (by design -- see "No failure wrapping" above).** A typo in an input name won't be caught by this orb; the Step's own error message is what you'll see, exactly as if you'd run `bitrise run` locally.
- **Bitrise's Go-toolkit Steps are compiled from source on first use per machine/version**, not shipped as prebuilt binaries -- expect the first run of a new Step+version to take a few seconds longer than subsequent cached runs.

## How to Contribute

Bug reports and feature requests are welcome via [Issues](https://github.com/CircleCI-Labs/bitrise-orb/issues). Pull requests are welcome via the usual GitHub flow.

## How to Publish An Update

1. Merge PRs using squash-merge with a [Conventional Commits](https://www.conventionalcommits.org/)-style message.
2. Check the current published version: `circleci orb info cci-labs/bitrise | grep "Latest"`.
3. Create a new GitHub Release with a new semver tag (`vX.Y.Z`).
4. Click "+ Auto-generate release notes."
5. Verify the semver bump you're about to publish actually matches what the generated notes describe (a breaking change needs a major bump, not a patch).
6. Click "Publish Release" -- pushing that `vX.Y.Z` tag is what satisfies this repo's production-publish gate.
