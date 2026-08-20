# Migrating from Bitrise

## Mapping your existing config

If you're migrating a real `bitrise.yml`, here's the same Step, side by side. This is Android signing exactly as it would appear inside a Bitrise workflow's `steps:` list, Bitrise's own list-of-single-key-maps shape:

```yaml
# bitrise.yml (Bitrise)
workflows:
  primary:
    steps:
    - sign-apk@2:
        inputs:
        - android_app: app/build/outputs/apk/release/app-release-unsigned.apk
        - keystore_url: $BITRISEIO_ANDROID_KEYSTORE_URL
        - keystore_password: $BITRISEIO_ANDROID_KEYSTORE_PASSWORD
        - keystore_alias: $BITRISEIO_ANDROID_KEYSTORE_ALIAS
        - private_key_password: $BITRISEIO_ANDROID_KEY_PASSWORD
```

```yaml
# .circleci/config.yml (this orb)
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

What actually changed, concept by concept:

- **A Bitrise "Step" becomes a `bitrise/step` command (inline, among native steps) or job (standalone, in a workflow's `jobs:` list).** There's no separate CircleCI vocabulary for it; it's just this orb's one unit of work. The `<step-id>@<version>` reference (`sign-apk@2`) passes through to the `id` parameter completely unchanged. This orb does no version resolution of its own, so anything that resolves for `bitrise run` locally resolves here too.
- **Step `inputs` go from a list-of-single-key-maps to a flat `key: value` block.** This orb's `create-config` command converts your flat block back into Bitrise's own list shape internally when it synthesizes the throwaway `bitrise.yml`. You're not fighting Bitrise's format; you're just not required to type its extra list/map ceremony by hand.
- **Where the vendor's env vars come from is the biggest mental shift.** On Bitrise, `$BITRISEIO_ANDROID_KEYSTORE_URL` lives in your Bitrise app's **Secrets** or the Workflow Editor's **Env Vars** tab in the bitrise.io web UI, injected at build time by Bitrise's own backend. It's not really "in" the `bitrise.yml` you're reading, even though the YAML references it by name. On CircleCI there's no separate backend injecting anything: put the real secret value in a CircleCI **context** or **project environment variable**, reference it with a plain `$MY_VAR` inside `inputs:`, and this orb's `create-config` resolves it via `circleci env subst` at the moment it writes the synthesized config. The secret's value never touches your committed `.circleci/config.yml`, the same security property Bitrise's own Secrets give you, achieved by a different mechanism.
- **What Bitrise's platform does for you that CircleCI does natively instead:** the Step's own outputs (`$BITRISE_SIGNED_APK_PATH`) land in `$BASH_ENV` automatically (see [Outputs](GETTING-STARTED.md#outputs)) instead of Bitrise's `$BITRISE_DEPLOY_DIR`-plus-`deploy-to-bitrise-io` combo; this orb's `store-artifacts`/`store-test-results` defaults are the direct equivalent, already wired up with zero extra config (see [The environment variable mapping](ARCHITECTURE.md#the-environment-variable-mapping)); and StepLib's own Step caching (git-cloning each Step's code) has no equivalent to port, because this orb's `install` command already caches the CLI + StepLib state that makes Step resolution fast on repeat runs.
- **What has no equivalent and needs a real decision on your part:** picking an executor. Bitrise's own **Stack** setting picked the OS for you; this orb never guesses (see [Choosing an executor](GETTING-STARTED.md#choosing-an-executor)). Translate your old Stack name into `bitrise/macos` or `bitrise/machine` explicitly.
