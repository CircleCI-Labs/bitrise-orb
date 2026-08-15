#!/bin/bash
set -euo pipefail

# Parameters, via `environment:` (see install.sh for why this indirection exists):
#   ORB_VAL_PROFILE              -- "none" | "android-build" | "fastlane" | "js-mobile"
#   ORB_VAL_TOOLS                -- comma-separated "name" or "name@version" overrides/additions
#   ORB_VAL_INSTALL_ZSTD         -- boolean-as-string ("1"/"0" or "true"/"false" -- see map-env.sh)
#   ORB_VAL_JDK_VERSION
#   ORB_VAL_ANDROID_PLATFORM
#   ORB_VAL_ANDROID_BUILD_TOOLS
#   ORB_VAL_NODE_VERSION
#   ORB_VAL_FASTLANE_VERSION
#
# Resolves `profile` + `tools` into a single, deterministic PLAN FILE that:
#   1. Is what install-stack.sh's restore_cache/save_cache keys checksum -- the same
#      "resolve then checksum the resolved value" pattern install.yml already uses for
#      the Bitrise CLI's own "latest" (see resolve-bitrise-version.sh) -- so the cache key
#      changes exactly when the actual resolved install work changes.
#   2. Is where an unrecognized tool name/version in `tools` is refused, loudly, BEFORE
#      any cache restore or download happens -- per this project's stacks-research brief:
#      "an unrecognized tool name in tools fails the step rather than being ignored."
#
# NOTE ON DUPLICATION: the "name -> pinned version" table below is intentionally
# duplicated in install-stack.sh's own (name, version, checksum) catalog. Each script
# named via this orb's own include-and-pack mechanism is packed as an independent,
# self-contained command body -- there is no shared file on disk at job runtime for the
# two to source from a common place. If you add or bump a catalog tool, update BOTH
# tables; install-stack.sh's copy carries the actual checksums and is the authoritative
# source for "what's really pinned" -- this copy exists only so an unknown/unsupported
# request is refused here, before any network call, rather than partway through
# install-stack.sh.

orb_bool_is_true() {
  case "${1:-}" in
    1 | true | True | TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

case "${ORB_VAL_PROFILE}" in
  none | android-build | fastlane | js-mobile) ;;
  *)
    echo "bitrise-orb: unknown init-stack profile '${ORB_VAL_PROFILE}' -- must be one of: none, android-build, fastlane, js-mobile." >&2
    exit 1
    ;;
esac

catalog_pinned_version() {
  case "$1" in
    ripgrep) echo "14.1.1" ;;
    gh) echo "2.86.0" ;;
    *) echo "" ;;
  esac
}

PLAN_FILE="/tmp/.bitrise-orb-stack-plan"
: > "${PLAN_FILE}"
{
  echo "profile=${ORB_VAL_PROFILE}"
  if orb_bool_is_true "${ORB_VAL_INSTALL_ZSTD:-}"; then
    echo "install-zstd=1"
  else
    echo "install-zstd=0"
  fi
} >> "${PLAN_FILE}"

case "${ORB_VAL_PROFILE}" in
  android-build)
    {
      echo "jdk-version=${ORB_VAL_JDK_VERSION}"
      echo "android-platform=${ORB_VAL_ANDROID_PLATFORM}"
      echo "android-build-tools=${ORB_VAL_ANDROID_BUILD_TOOLS}"
    } >> "${PLAN_FILE}"
    ;;
  fastlane)
    echo "fastlane-version=${ORB_VAL_FASTLANE_VERSION}" >> "${PLAN_FILE}"
    ;;
  js-mobile)
    echo "node-version=${ORB_VAL_NODE_VERSION}" >> "${PLAN_FILE}"
    ;;
esac

RESOLVED_TOOLS=()
if [[ -n "${ORB_VAL_TOOLS// /}" ]]; then
  IFS=',' read -ra RAW_TOOLS <<< "${ORB_VAL_TOOLS}"
  for RAW in "${RAW_TOOLS[@]}"; do
    ENTRY="${RAW// /}"
    [[ -z "${ENTRY}" ]] && continue
    NAME="${ENTRY%%@*}"
    if [[ "${ENTRY}" == *@* ]]; then
      REQUESTED_VERSION="${ENTRY#*@}"
    else
      REQUESTED_VERSION=""
    fi
    PINNED_VERSION="$(catalog_pinned_version "${NAME}")"
    if [[ -z "${PINNED_VERSION}" ]]; then
      echo "bitrise-orb: unknown 'tools' entry '${ENTRY}' -- '${NAME}' is not in this orb's pinned catalog (currently: ripgrep, gh)." >&2
      echo "This command refuses to install a tool it hasn't vendored a checksum for, rather than silently skipping it. Open a PR against src/scripts/install-stack.sh to add it." >&2
      exit 1
    fi
    if [[ -n "${REQUESTED_VERSION}" && "${REQUESTED_VERSION}" != "${PINNED_VERSION}" ]]; then
      echo "bitrise-orb: unsupported version '${REQUESTED_VERSION}' for tool '${NAME}' -- this orb only vendors a checksum for ${NAME}@${PINNED_VERSION}." >&2
      echo "Omit the version to use the pinned one, or open a PR against src/scripts/install-stack.sh to add a checksum for ${REQUESTED_VERSION}." >&2
      exit 1
    fi
    RESOLVED_TOOLS+=("${NAME}@${PINNED_VERSION}")
  done
fi

if [[ "${#RESOLVED_TOOLS[@]}" -gt 0 ]]; then
  # Sorted so the plan file (and therefore the cache key) is deterministic regardless of
  # the order the user listed tools in.
  while IFS= read -r line; do
    [[ -n "${line}" ]] && echo "tool=${line}" >> "${PLAN_FILE}"
  done < <(printf '%s\n' "${RESOLVED_TOOLS[@]}" | sort -u)
fi

echo "Resolved init-stack plan (this is what the cache key below is checksummed against):"
cat "${PLAN_FILE}"
