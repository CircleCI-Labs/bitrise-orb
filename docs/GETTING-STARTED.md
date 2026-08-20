# Getting Started

## Scope: one Step per call, not a whole `bitrise.yml`

This orb runs **one Step**, not a whole `bitrise.yml` workflow. It is not a Bitrise-workflow importer or a Pipelines equivalent. Everything that would normally be a *separate* Bitrise Step in your old workflow (checkout, caching, artifact upload) has a native CircleCI equivalent already (`checkout`, `save_cache`/`restore_cache`, `store_artifacts`), and this orb expects you to keep using those directly rather than running Bitrise's own versions of them (see [Limits](LIMITS.md)).

## Capabilities

- Run any Bitrise Step by StepLib id (`xcode-archive@6`), by git URL (`git::https://github.com/bitrise-io/steps-script.git@1.1.3`), or by local path (`path::./my-step`): the full reference grammar, passed through verbatim.
- **No version-resolution logic of our own.** Omit `@<version>` and Bitrise resolves latest, exactly as it would locally. This orb never second-guesses that.
- **Step outputs come back under their verbatim vendor name** (`BITRISE_IPA_PATH` stays `BITRISE_IPA_PATH`), exported into `$BASH_ENV` so a plain native `run` step right after can read them. There's no separate artifact-download step and no orb-specific output syntax to learn. Bitrise's own config-level output aliasing is available too, if you want to rename one.
- Step inputs are a flat YAML block resolved through CircleCI's built-in `circleci env subst`, so `$MY_SECRET` resolves at run time and secrets never have to enter your committed config.
- **No failure wrapping.** If a Step errors because a required input or credential is missing, the job fails with that Step's own stderr on the console, unmodified. There are no retries, no swallowed exit codes, and no extra validation layer guessing at what the Step needs.
- Two named executors (`bitrise/macos`, `bitrise/machine`) with **no default**; see [Choosing an executor](#choosing-an-executor) below for why.
- **Smart defaults: this orb owns its own lifecycle.** `store_artifacts` against `deploy-dir` and `store_test_results` against `test-results-dir` both run automatically, with zero config; see [The environment variable mapping](ARCHITECTURE.md#the-environment-variable-mapping). Each is a boolean you can turn off if you'd rather do it yourself.
- **`bitrise/init-stack` bootstraps just the pinned slice of Bitrise's own Ubuntu/Android stack a Step actually needs** (Android build/sign, fastlane, Node.js), cached, checksum-verified, and entirely opt-in. See [Stack bootstrap](ARCHITECTURE.md#stack-bootstrap).

## More quick-start examples

The [README](../README.md#quick-start) has the minimal example. Here are three more complete, runnable ones.

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
      # No manual store_artifacts needed here: store-artifacts defaults to true, so
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

Steps that depend on each other's on-disk or keychain state (code signing, then building with it) must run in the **same job**, via repeated `bitrise/step` **command** calls with `checkout: false` (and `skip-install`/`skip-map-env` on the later ones), **not** as separate `bitrise/step` **jobs**. Two `bitrise/step` jobs are two independent, ephemeral machines with no shared state, unlike Steps inside one Bitrise Workflow, which always share a machine. Wiring a "cert install" job into an "archive" job as two separate workflow jobs will fail to find the signing identity, with no hint that job isolation is the cause.

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
          # that actually publishes /tmp/bitrise-orb/deploy: the first call above
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

Note also that **`bitrise/step` is both a job name and a command name**: `src/jobs/step.yml` (used under a workflow's `jobs:`, as in the Quick Start) and `src/commands/step.yml` (used inside an existing job's `steps:`, as in this example and the two above it) are different things that happen to share a name, distinguished only by where they appear in your config.

## Choosing an executor

A Bitrise Step declares nothing machine-readable about needing macOS: `host_os_tags` in a Step's `step.yml` is documented by Bitrise as "currently unused," and `project_type_tags` (`ios`, `android`, `flutter`, ...) is search/filter metadata only, not enforced. So this orb never guesses; you pick `bitrise/macos` or `bitrise/machine` explicitly on every `bitrise/step` job. Guessing wrong would mean either a confusing failure (an iOS Step on Linux) or roughly 10x the credit cost (an Android Step needlessly run on macOS).

If you're migrating an existing Bitrise workflow, the fastest way to translate is by the **Stack** it used to run on (Workflow Editor -> Stack, or `meta: bitrise.io: stack:` in an exported `bitrise.yml`; this orb doesn't read or emit that key itself, since it's a bitrise.io hosting concept with no local-CLI meaning, and your CircleCI executor choice *is* its replacement):

| Old Bitrise Stack (naming pattern) | Use this executor |
|---|---|
| `osx-xcode-*` (any macOS/Xcode stack) | `bitrise/macos` |
| `linux-docker-android-*` / any Linux stack | `bitrise/machine` |
| `ubuntu-jammy-22.04-bitrise-*` / `ubuntu-noble-24.04-bitrise-*` (Bitrise's newer yearly-edition Linux stack naming) | `bitrise/machine` |

This table is a migration aid for humans reading their old Stack setting, not something this orb parses. Always cross-check against what the specific Step actually needs (its `type_tags`/`project_type_tags`, or just whether it shells out to `xcodebuild`/`security`).

### A third, opt-in executor: `bitrise/android-toolchain`

`bitrise/machine` installs whatever a Step needs itself (this orb's own `install` command handles the Bitrise CLI; anything an Android Step needs beyond that, such as an SDK, an NDK, or a specific Ruby, is on you, same as it would be on a bare Bitrise Linux stack without the toolchain preinstalled). If you'd rather start from Bitrise's own published Android/Linux image instead, `bitrise/android-toolchain` is a `docker` executor defaulting to `quay.io/bitriseio/android-20.04:latest`.

**Use this only if you know why:** it's a 10+GB image, amd64-only, and, verified directly against Quay's tag metadata while building this orb, a snapshot last published 2024-01-08, not a live mirror of bitrise.io's current hosted stack. Check the tools actually inside it before trusting it (see the executor's own description). For most Steps, `bitrise/machine` plus this orb's own `init-stack` command ([Stack bootstrap](ARCHITECTURE.md#stack-bootstrap)) is the safer default; reach for this one specifically when a Step assumes a real Android toolchain is already on `PATH` and you've confirmed this image's versions are close enough to what you need.

**Caching the image, and what it costs:** `docker-layer-caching` (DLC) on this executor defaults to `true`, unlike `bitrise/machine`'s own default of `false`; see [`docs/ROADMAP.md`](ROADMAP.md)'s "Image caching economics" for why the two executors default differently.

## Interleaving native CircleCI steps around the Bitrise Step

The `bitrise/step` **job** (only when invoked from a workflow's `jobs:` list, not the `bitrise/step` **command** inside another job's own `steps:`) accepts CircleCI's own built-in `pre-steps`/`post-steps` arguments, available on every 2.1+ job, not something this orb declares. Pass them at the call site:

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

**One real platform caveat, verified while re-checking this orb's expansion order (`pre-steps`, job steps, `post-steps`):** `pre-steps` run before **every** step in the job, including this job's own internal `checkout`, not just before the Bitrise Step. If a pre-step needs the repo checked out first, either do that checkout yourself inside the pre-step, or use `checkout: false` on the job plus an explicit `checkout` as the first entry of `pre-steps`, so you control exactly where it lands relative to your other pre-steps:

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

Need several native steps and several Bitrise Steps interleaved in a specific order within one job (not just "before all" / "after all")? Reach for the `bitrise/step` **command** in a hand-rolled job instead; see [Chaining two Bitrise Steps that share machine state](#chaining-two-bitrise-steps-that-share-machine-state) above, since a command call is just one entry in an ordinary `steps:` list and can sit anywhere in it.

## Outputs

By default, `bitrise/step` exports every output the Step's own `step.yml` **declares**, discovered via `stepman step-info`: no maintained list, no guessing (see "Step outputs come back under their verbatim vendor name" in [Capabilities](#capabilities)). That covers the overwhelming majority of Steps.

It does **not** cover a Step whose `step.yml` declares zero outputs but whose own code still calls `envman add` for one anyway, which is exactly how Bitrise's own docs show passing a value between Steps from a `script` Step. Without an escape hatch, this does nothing on this orb, silently, with a green build:

```yaml
- bitrise/step:
    id: script@1
    inputs: |
      content: envman add --key APP_VERSION --value "$(cat VERSION)"
- run: echo "version is $APP_VERSION"    # empty: script@1 declares no outputs
```

Use `extra-outputs` to name it explicitly: a newline-separated list of environment variable **names** (no values), unioned with whatever the Step declares:

```yaml
- bitrise/step:
    id: script@1
    inputs: |
      content: envman add --key APP_VERSION --value "$(cat VERSION)"
    extra-outputs: |
      APP_VERSION
- run: echo "version is $APP_VERSION"    # now populated
```

`extra-outputs` entries are exported verbatim under their own name only. They're not eligible for Bitrise's config-level output aliasing (the `outputs` parameter), since that mechanism only knows about a Step's *declared* outputs.

**Treat every Step output as public log content.** This orb never masks an output value; it exports whatever the Step produced straight into `$BASH_ENV`, unredacted, and any later step that echoes it (directly, or indirectly via its own error output) puts it on the console exactly like any other unmasked variable. CircleCI's log masking only ever catches an *exact-match* registered secret; a Step output that's a derived value, a URL with embedded credentials, or a value composed from a secret plus other text is not something masking will catch. If a Step's output could be sensitive, don't assume this orb (or CircleCI) hides it for you.

**This orb also refuses to let a Step's output (declared, or named via `extra-outputs`) overwrite a reserved shell variable**: `PATH`, `BASH_ENV`, `IFS`, `LD_PRELOAD`, and about a dozen others. Without that guard, a Step (or a malicious/compromised one reached via `git::`/`path::`) that called `envman add --key PATH --value "/tmp/evil:$PATH"` could poison every *later* native step in the job, not just its own. This orb's whole point is running someone else's Step code, so this is refused outright rather than exported.

## Passing data between jobs

`bitrise/step`'s output-export mechanism above is job-scoped, not workflow-scoped, exactly like any other `$BASH_ENV` export in CircleCI: it doesn't cross a job boundary on its own. Two real needs, two different real answers:

- **Passing a Step's output value to a downstream job:** write it to a file, then `persist_to_workspace` that file in the job that produced it and `attach_workspace` in the job that needs it. This works today, with zero orb changes:
  ```yaml
  - run: echo "$BITRISE_IPA_PATH" > /tmp/workspace/ipa-path.txt
  - persist_to_workspace:
      root: /tmp/workspace
      paths: [ipa-path.txt]
  # ...in the downstream job:
  - attach_workspace: { at: /tmp/workspace }
  - run: export IPA_PATH="$(cat /tmp/workspace/ipa-path.txt)"
  ```
- **Branching which jobs run, based on an upstream job's output** (a genuinely harder ask: conditional workflow logic driven by runtime data): CircleCI has no native construct for this. The closest real mechanism is a setup workflow plus the `circleci/continuation` orb, where an early job computes a value and calls `continuation/continue` with a config whose `workflows:` block is shaped by that value. There is no simpler answer available today; don't expect a lighter-weight substitute. See [`docs/ROADMAP.md`](ROADMAP.md)'s "Workspace / parallelism fit" for why this wasn't built as an orb feature.
