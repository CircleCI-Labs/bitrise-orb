#!/bin/bash
set -euo pipefail

# Resolves the ORB_VAL_BITRISE_VERSION parameter ("latest" or a concrete version) to a
# single concrete version string, and writes it to a throwaway file. This file -- not the
# raw "latest" parameter -- is what the install command's restore_cache/save_cache steps
# checksum, so a moving "latest" target still gets a stable, correct cache key. This is
# the exact same "resolve then checksum the resolved value" pattern verified in the
# act-orb-conventions spec (act-binary-cache.sh / /tmp/.act-version), applied here to the
# Bitrise CLI's own version instead of a Step's version (this orb never resolves a Step's
# own version -- see Locked Decision #4 -- this script is purely about our own tooling).

VERSION_FILE="/tmp/.bitrise-orb-version"

if [[ "${ORB_VAL_BITRISE_VERSION}" == "latest" ]]; then
  echo "Resolving the latest Bitrise CLI release from GitHub..."
  LATEST_TAG="$(curl --fail --silent --show-error --retry 3 --retry-all-errors \
    https://api.github.com/repos/bitrise-io/bitrise/releases/latest | jq -r '.tag_name')"
  if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "null" ]]; then
    echo "bitrise-orb: could not resolve the latest Bitrise CLI version from the GitHub API." >&2
    exit 1
  fi
  echo "${LATEST_TAG}" >"${VERSION_FILE}"
else
  echo "${ORB_VAL_BITRISE_VERSION}" >"${VERSION_FILE}"
fi

echo "Resolved Bitrise CLI version: $(cat "${VERSION_FILE}")"
