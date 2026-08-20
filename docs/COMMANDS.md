# Commands and Job Reference

| Name | Kind | What it does |
|---|---|---|
| `step` | command, job | The aggregate most users want: install -> map-env -> create-config -> collect-outputs -> run-bitrise -> store_artifacts/store_test_results, in order. |
| `install` | command | Resolves and installs the Bitrise CLI + `yq`, checksum-verified, cached by resolved version. |
| `map-env` | command | Exports the CircleCI -> Bitrise variable mapping into `$BASH_ENV`; creates `deploy-dir`/`test-results-dir`. |
| `create-config` | command | Synthesizes the throwaway `bitrise.yml` for exactly one Step, resolving `$SECRET`-style references via `circleci env subst`. |
| `collect-outputs` | command | Discovers the Step's declared outputs (`stepman step-info`) and appends an output-exporting Step to the not-yet-executed config. |
| `run-bitrise` | command | `bitrise run`s the synthesized config: the actual execution point for both the target Step and the appended output exporter. |
| `init-stack` | command | **Standalone, opt-in.** Bootstraps the pinned subset of Bitrise's stack toolchain a Step needs (`profile`) plus any ad hoc `tools`, cached and checksum-verified. See [Stack bootstrap](ARCHITECTURE.md#stack-bootstrap). Not part of the `step` aggregate; compose it yourself, e.g. via `pre-steps`. |

**Reach for the granular commands instead of the `step` aggregate when:** you're chaining two or more Bitrise Steps that must share on-disk/keychain state in one job (see [Chaining two Bitrise Steps](GETTING-STARTED.md#chaining-two-bitrise-steps-that-share-machine-state); `skip-install`/`skip-map-env` on the later calls avoid redundant work), or when you want native CircleCI steps interleaved at a point finer than `pre-steps`/`post-steps` allow.

## `step` (command and job) parameters

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `executor` *(job only)* | executor | *(required)* | `bitrise/macos` or `bitrise/machine`, no default; see [Choosing an executor](GETTING-STARTED.md#choosing-an-executor). |
| `checkout` | boolean | `true` | Check out the project first. |
| `id` | string | *(required)* | The Step reference (`<id>@<version>`, `git::<url>@<ref>`, or `path::<local-path>`). |
| `inputs` | string | `""` | Flat `key: value` block of the Step's inputs; `$SECRET` resolved via `circleci env subst`. |
| `outputs` | string | `""` | Flat `ORIGINAL_KEY: alias` block for Bitrise's own output-aliasing. Leave empty to export verbatim vendor names. |
| `extra-outputs` | string | `""` | Newline-separated env var **names** to export in addition to the Step's declared outputs, for Steps that call `envman add` without declaring an output in `step.yml`. |
| `step-lib-source` | string | Bitrise's official StepLib URL | Where to resolve `id` against when it has no explicit source prefix. |
| `bitrise-version` | string | `"latest"` | Bitrise CLI version to install. |
| `bin-dir` | string | `/tmp/bitrise-orb/bin` | Install directory for the CLI + `yq`. |
| `cache-key-prefix` | string | `"v1"` | Prefix on every cache key this orb writes; bump to force a clean cache. |
| `verify-checksums` | boolean | `true` | Checksum-verify the Bitrise CLI + `yq` downloads before use. Never disable outside local debugging of this orb itself. |
| `deploy-dir` | string | `/tmp/bitrise-orb/deploy` | Exported as `$BITRISE_DEPLOY_DIR`; also what `store-artifacts` publishes. |
| `store-artifacts` | boolean | `true` | Auto-run `store_artifacts` against `deploy-dir` after the Step. |
| `test-results-dir` | string | `/tmp/bitrise-orb/test-results` | Exported as `$BITRISE_TEST_DEPLOY_DIR`; also what `store-test-results` publishes. |
| `store-test-results` | boolean | `true` | Auto-run `store_test_results` against `test-results-dir` after the Step. |
| `extra-env` | string | `""` | Extra/override `NAME: value` pairs, applied after the built-in mapping (these win). |
| `skip-default-env-mapping` | boolean | `false` | Skip the built-in CircleCI -> Bitrise mapping entirely. |
| `config-path` | string | `.bitrise-orb.generated.yml` | Where the synthesized `bitrise.yml` is written. |
| `workflow-name` | string | `"orb-step"` | Name of the workflow inside the synthesized config. |
| `skip-install` | boolean | `false` | Skip installing the CLI (an earlier call in this job already did). |
| `skip-map-env` | boolean | `false` | Skip exporting the env mapping (an earlier call in this job already did). |
| `skip-collect-outputs` | boolean | `false` | Skip discovering/exporting the Step's outputs. |
| `debug-dump-config` | boolean | `false` | Print the fully-resolved synthesized `bitrise.yml` to the console (security review, Finding #3: may contain resolved secrets). Off by default; local debugging of this orb only. |

Individual commands (`install`, `map-env`, `create-config`, `collect-outputs`, `run-bitrise`) expose the matching subset of these same parameters, under the same names. See each command's own description on the [Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/bitrise) for the exhaustive, always-current list.

## `init-stack` parameters

Standalone, not part of `step`'s parameter set above. See [Stack bootstrap](ARCHITECTURE.md#stack-bootstrap) for the full picture.

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `profile` | enum | `"none"` | `none` \| `android-build` \| `fastlane` \| `js-mobile`. |
| `tools` | string | `""` | Comma-separated `name@version` catalog additions (currently: `ripgrep`, `gh`); unrecognized names/versions fail loudly. |
| `install-zstd` | boolean | `true` | Install `zstd` regardless of `profile` (a hard dependency of current-gen Bitrise cache Steps). |
| `jdk-version` | string | `"17"` | `android-build` only. |
| `android-platform` | string | `"35"` | `android-build` only. |
| `android-build-tools` | string | `"35.0.0"` | `android-build` only. |
| `android-sdk-root` | string | `/tmp/bitrise-orb/android-sdk` | `android-build` only; exported as `$ANDROID_HOME`/`$ANDROID_SDK_ROOT`. |
| `fastlane-version` | string | `"2.236.1"` | `fastlane` only; freely overridable (RubyGems verifies it, not this orb). |
| `gem-home` | string | `/tmp/bitrise-orb/gems` | `fastlane` only; exported as `$GEM_HOME`/`$GEM_PATH`. |
| `node-version` | string | `"22.22.0"` | `js-mobile` only; **not** freely overridable, must match this orb's vendored checksum. |
| `node-root` | string | `/tmp/bitrise-orb/node` | `js-mobile` only. |
| `stack-bin-dir` | string | `/tmp/bitrise-orb/stack-bin` | Where `tools` catalog binaries land. |
| `cache-key-prefix` | string | `"v1"` | Same convention as `step`'s. |
| `verify-checksums` | boolean | `true` | Checksum-verify every direct download (apt/gem/`sdkmanager` installs verify themselves already; see [Stack bootstrap](ARCHITECTURE.md#stack-bootstrap)'s integrity table). |

## Worked example: composing the granular commands by hand

The same two chained Steps from [Chaining two Bitrise Steps](GETTING-STARTED.md#chaining-two-bitrise-steps-that-share-machine-state), but built entirely from the individual commands instead of `step`, to show the exact order that has to hold (`map-env` before `create-config`; `collect-outputs` before `run-bitrise`):

```yaml
version: 2.1
orbs:
  bitrise: cci-labs/bitrise@1.0.0
jobs:
  build-signed-ios-app:
    executor: bitrise/macos
    steps:
      - checkout
      - bitrise/install
      - bitrise/map-env
      - bitrise/create-config:
          id: certificate-and-profile-installer@1
          inputs: |
            certificate_url: $IOS_CERTIFICATE_URL
            certificate_passphrase: $IOS_CERTIFICATE_PASSPHRASE
      - bitrise/collect-outputs:
          id: certificate-and-profile-installer@1
      - bitrise/run-bitrise
workflows:
  ios-release:
    jobs:
      - build-signed-ios-app:
          context: ios-signing
```
