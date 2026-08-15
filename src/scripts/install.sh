#!/bin/bash
set -euo pipefail

# Parameters, passed in via the run step's `environment:` block per this orb's
# ORB_VAL_*/`environment:` convention (matching CircleCI-Labs/act-orb's own scripts,
# e.g. src/scripts/run-act.sh: never interpolate << parameters.x >> directly into a
# script body -- it's a config-compile-time substitution with no meaning to
# bash/shellcheck, and breaks on multi-line or special-character values):
#   ORB_VAL_BITRISE_VERSION  -- "latest" or a concrete version, e.g. "2.42.2"
#   ORB_VAL_BIN_DIR          -- directory this orb's own tooling (bitrise CLI, yq) lives in
#   ORB_VAL_VERIFY_CHECKSUMS -- boolean-as-string (see map-env.sh's orb_bool_is_true note);
#                               never disable outside local debugging of this orb itself
#
# SECURITY (security review, Finding #8 -- MEDIUM): both binaries this script downloads
# used to be curl'd straight into place with NO checksum or signature verification --
# the only runtime binary downloads in this orb family with that gap. Fixed here, with a
# different integrity mechanism per binary because their release cadence differs:
#   - the Bitrise CLI can float to "latest", so there's no one checksum to vendor ahead
#     of time -- instead, fetch the SAME GitHub release's own published "checksums.txt"
#     (over HTTPS, from the exact resolved tag) and verify the download against THAT,
#     same-origin, before it's ever chmod +x'd or executed.
#   - yq is pinned to one fixed version already (YQ_VERSION below), so its four
#     (os, arch) checksums are vendored directly, computed from and cross-checked
#     against yq's own multi-algorithm "checksums" release artifact.
# Neither path is "curl | bash" -- both fully download to disk, verify, THEN execute.

orb_bool_is_true() {
  case "${1:-}" in
    1 | true | True | TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

# macOS has no `sha256sum` by default (verified against a real CircleCI macOS job --
# this is not a hypothetical) -- fall back to BSD `shasum -a 256`, which Linux also
# carries via perl's Digest::SHA, so this works on both without a branch on `uname`.
sha256_of() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_sha256() {
  # $1 = file, $2 = expected sha256, $3 = human label for messages
  local file="$1" expected="$2" label="$3" actual
  if ! orb_bool_is_true "${ORB_VAL_VERIFY_CHECKSUMS:-1}"; then
    echo "WARNING: verify-checksums is false -- skipping checksum verification for ${label}. Never disable this outside local debugging of this orb itself." >&2
    return 0
  fi
  actual="$(sha256_of "${file}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "bitrise-orb: checksum mismatch for ${label} -- refusing to use this download." >&2
    echo "  expected: ${expected}" >&2
    echo "  got:      ${actual}" >&2
    rm -f "${file}"
    exit 1
  fi
  echo "Checksum OK for ${label}."
}

mkdir -p "${ORB_VAL_BIN_DIR}"

OS="$(uname -s)"
ARCH_RAW="$(uname -m)"

case "${ARCH_RAW}" in
  x86_64)
    ARCH="x86_64"
    YQ_ARCH="amd64"
    ;;
  arm64 | aarch64)
    ARCH="arm64"
    YQ_ARCH="arm64"
    ;;
  *)
    echo "bitrise-orb: unsupported architecture '${ARCH_RAW}'." >&2
    exit 1
    ;;
esac

if [[ "${OS}" == "Linux" && "${ARCH}" == "arm64" ]]; then
  # bitrise-io/bitrise's GitHub releases only publish a Linux x86_64 asset -- there is no
  # Linux arm64 build (confirmed against the release asset list at
  # https://github.com/bitrise-io/bitrise/releases). Fail loudly and clearly here rather
  # than let a confusing 404 surface deep inside curl below.
  echo "bitrise-orb: no Linux arm64 build of the Bitrise CLI is published." >&2
  echo "Use an x86_64/amd64 resource class with the bitrise/machine executor." >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "bitrise-orb: this orb requires 'jq' on PATH (used to parse stepman's JSON output)." >&2
  echo "jq ships preinstalled on CircleCI's cimg/* and machine images; install it first if you're on a custom image." >&2
  exit 1
fi

BITRISE_VERSION_TAG="$(cat /tmp/.bitrise-orb-version)"
if [[ "${BITRISE_VERSION_TAG}" != v* ]]; then
  BITRISE_VERSION_TAG="v${BITRISE_VERSION_TAG}"
fi

# SECURITY/CORRECTNESS (shell-correctness review, Finding #5): compare versions EXACTLY,
# not with a substring test. `grep -qF` is a substring match -- "2.4.0" matches inside
# "12.4.0", so a stale/fallback-restored cache (install.yml's restore_cache declares a
# checksum-less fallback key that can restore a *different* resolved version's binaries
# on an exact-key miss) could silently be accepted as a match for the version actually
# requested. Extract the dotted version number and compare with "==" instead.
bitrise_installed_version() {
  "${ORB_VAL_BIN_DIR}/bitrise" --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

if [[ -x "${ORB_VAL_BIN_DIR}/bitrise" ]] && [[ "$(bitrise_installed_version)" == "${BITRISE_VERSION_TAG#v}" ]]; then
  echo "bitrise CLI ${BITRISE_VERSION_TAG} already present at ${ORB_VAL_BIN_DIR}/bitrise (cache hit) -- skipping download."
else
  BITRISE_ASSET="bitrise-${OS}-${ARCH}"
  BITRISE_URL="https://github.com/bitrise-io/bitrise/releases/download/${BITRISE_VERSION_TAG}/${BITRISE_ASSET}"
  echo "Downloading Bitrise CLI ${BITRISE_VERSION_TAG} for ${OS}/${ARCH}:"
  echo "  ${BITRISE_URL}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${ORB_VAL_BIN_DIR}/bitrise" "${BITRISE_URL}"

  if orb_bool_is_true "${ORB_VAL_VERIFY_CHECKSUMS:-1}"; then
    # Same-origin verification against the EXACT resolved release's own published
    # checksums.txt (bitrise-io/bitrise publishes one per release) -- this covers
    # "latest" too, since it verifies against whatever tag was actually resolved above,
    # not a checksum vendored ahead of time for a version we can't predict.
    BITRISE_CHECKSUMS_URL="https://github.com/bitrise-io/bitrise/releases/download/${BITRISE_VERSION_TAG}/checksums.txt"
    BITRISE_CHECKSUMS_FILE="$(mktemp)"
    echo "Fetching ${BITRISE_VERSION_TAG}'s own checksums.txt to verify the download against:"
    echo "  ${BITRISE_CHECKSUMS_URL}"
    curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
      --output "${BITRISE_CHECKSUMS_FILE}" "${BITRISE_CHECKSUMS_URL}"
    BITRISE_EXPECTED_SHA256="$(grep -E "  ${BITRISE_ASSET}\$" "${BITRISE_CHECKSUMS_FILE}" | awk '{print $1}' | head -1)"
    rm -f "${BITRISE_CHECKSUMS_FILE}"
    if [[ -z "${BITRISE_EXPECTED_SHA256}" ]]; then
      echo "bitrise-orb: could not find an entry for '${BITRISE_ASSET}' in ${BITRISE_VERSION_TAG}'s checksums.txt -- refusing to use an unverified download." >&2
      rm -f "${ORB_VAL_BIN_DIR}/bitrise"
      exit 1
    fi
    verify_sha256 "${ORB_VAL_BIN_DIR}/bitrise" "${BITRISE_EXPECTED_SHA256}" "Bitrise CLI ${BITRISE_VERSION_TAG} (${BITRISE_ASSET})"
  else
    echo "WARNING: verify-checksums is false -- skipping checksum verification for the Bitrise CLI download. Never disable this outside local debugging of this orb itself." >&2
  fi
  chmod +x "${ORB_VAL_BIN_DIR}/bitrise"
fi

# yq (mikefarah/yq, the Go implementation -- deliberately NOT whatever a distro's own
# `apt install yq`/`pip install yq` resolves to, which on several Linux distros is an
# unrelated Python/jq-wrapper with a different CLI grammar) is this orb's YAML-aware
# transform for turning a user's flat "key: value" Step-input block into Bitrise's
# list-of-single-key-maps `inputs:` shape, and for injecting the output-collector Step
# (see scripts/create-config.sh and scripts/collect-outputs.sh). It is curl-installed the
# same way the bitrise CLI itself is above, for the same reason: one portable static
# binary, no package-manager-name ambiguity between macOS and Linux.
#
# NOTE: this dependency's pinned version/release-asset naming is this orb's own addition,
# not something covered by this project's spike report. Reviewers should sanity-check the
# version below is still current, and that https://github.com/mikefarah/yq/releases still
# publishes assets under this yq_<os>_<arch> naming, before the first real release of
# this orb.
YQ_VERSION="v4.44.3"

# Vendored sha256 checksums for yq's own (os, arch) binaries at the exact pinned
# YQ_VERSION above -- computed directly from the downloaded binaries and cross-checked
# against yq's own published multi-algorithm "checksums" release artifact (its SHA-256
# column, per its sibling "checksums_hashes_order" file) while authoring this fix.
# Because YQ_VERSION is a fixed pin (not "latest"), these can be vendored ahead of time
# rather than fetched per run -- update this table (and re-verify) whenever YQ_VERSION
# is bumped.
yq_expected_sha256() {
  # Keyed by the FULL asset filename ("yq_<os>_<arch>", matching YQ_ASSET below) --
  # verified locally that this matters: an earlier version of this table was keyed
  # without the "yq_" prefix and silently never matched, which turned every "verified"
  # install into a hard failure instead (fail-closed, but for the wrong reason -- caught
  # by this orb's own real CI run, not by local testing on a mismatched (os, arch)).
  case "$1" in
    yq_linux_amd64) echo "a2c097180dd884a8d50c956ee16a9cec070f30a7947cf4ebf87d5f36213e9ed7" ;;
    yq_linux_arm64) echo "0e7e1524f68d91b3ff9b089872d185940ab0fa020a5a9052046ef10547023156" ;;
    yq_darwin_amd64) echo "216ddfa03e7ba0e5aba00b236ec78324b5bfc49b610db254fe92310878baea20" ;;
    yq_darwin_arm64) echo "559a594ef7a6ebc5b81a67b7717fb3accedd266d8fa7d8352da7fec9e463f48b" ;;
    *) echo "" ;;
  esac
}

if [[ -x "${ORB_VAL_BIN_DIR}/yq" ]] && [[ "$("${ORB_VAL_BIN_DIR}/yq" --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" == "${YQ_VERSION#v}" ]]; then
  echo "yq ${YQ_VERSION} already present at ${ORB_VAL_BIN_DIR}/yq (cache hit) -- skipping download."
else
  YQ_OS="$(echo "${OS}" | tr '[:upper:]' '[:lower:]')"
  YQ_ASSET="yq_${YQ_OS}_${YQ_ARCH}"
  YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_ASSET}"
  echo "Downloading yq ${YQ_VERSION} for ${YQ_OS}/${YQ_ARCH}:"
  echo "  ${YQ_URL}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${ORB_VAL_BIN_DIR}/yq" "${YQ_URL}"

  YQ_EXPECTED_SHA256="$(yq_expected_sha256 "${YQ_ASSET}")"
  if [[ -z "${YQ_EXPECTED_SHA256}" ]]; then
    echo "bitrise-orb: no vendored checksum for '${YQ_ASSET}' at ${YQ_VERSION} -- refusing to use an unverified download." >&2
    rm -f "${ORB_VAL_BIN_DIR}/yq"
    exit 1
  fi
  verify_sha256 "${ORB_VAL_BIN_DIR}/yq" "${YQ_EXPECTED_SHA256}" "yq ${YQ_VERSION} (${YQ_ASSET})"
  chmod +x "${ORB_VAL_BIN_DIR}/yq"
fi

# Neither envman nor stepman are added to PATH by `bitrise setup` itself -- verified
# hands-on while building this orb (a fresh $HOME, running only `bitrise setup --ci
# --minimal`, installs them at "$HOME/.bitrise/tools/{stepman,envman}" but does not
# touch $PATH itself). `bitrise run` resolves their absolute paths internally for a
# Step's own subprocess, but this orb also calls `stepman` directly (see
# collect-outputs.sh) to discover a Step's declared output keys, so both this orb's own
# bin-dir and stepman/envman's install dir need to be on PATH for every later step.
#
# SECURITY (shell-correctness review, Finding #4): ORB_VAL_BIN_DIR is spliced into a
# double-quoted string written into $BASH_ENV, which every later step sources -- unlike
# every other value written to $BASH_ENV in this orb's scripts, this line was missing
# the `printf '%q'` escaping, so a bin-dir containing a double quote (or, maliciously, a
# `"; some-command; a="`) would break out of the string and inject a command into every
# subsequent step. Escape only the untrusted segment; leave $HOME/$PATH deferred to
# sourcing time, exactly as intended.
{
  printf 'export PATH=%s:$HOME/.bitrise/tools:$PATH\n' "$(printf '%q' "${ORB_VAL_BIN_DIR}")"
} >> "$BASH_ENV"
export PATH="${ORB_VAL_BIN_DIR}:$HOME/.bitrise/tools:$PATH"

if [[ "${OS}" == "Linux" ]]; then
  # UNVERIFIED, defensive: while building this orb, a bare ubuntu:22.04 Docker container
  # (not a CircleCI machine-executor image) failed Step activation with
  # `exec: "rsync": executable file not found in $PATH`, because stepman shells out to
  # rsync when copying an activated Step's files into place, and rsync is not bundled
  # with bitrise/envman/stepman. Whether CircleCI's own machine-executor Ubuntu images
  # ship rsync by default was NOT verified against a real CircleCI job in this sandbox --
  # install it defensively and cheaply here rather than risk failing deep inside
  # stepman's own activation logic later. Re-check this against a real
  # bitrise/machine job and drop it if CircleCI's images already ship rsync.
  if ! command -v rsync > /dev/null 2>&1; then
    echo "Installing rsync (required by stepman to activate Bitrise Steps)..."
    if [[ "${EUID}" == 0 ]]; then
      SUDO_CMD=""
    else
      SUDO_CMD="sudo"
    fi
    ${SUDO_CMD} apt-get update -qq
    ${SUDO_CMD} apt-get install -y -qq rsync
  fi
fi

# `bitrise setup --ci --minimal` is fast and safe to run unconditionally even on a full
# cache hit -- verified hands-on while building this orb: it writes ~/.bitrise/config.json
# with the setup CLI version and short-circuits on a version match (a warm-cache rerun
# completed in well under a second locally, vs. several seconds for the tool checks on a
# cold ~/.bitrise).
echo "Running 'bitrise setup --ci --minimal'..."
"${ORB_VAL_BIN_DIR}/bitrise" setup --ci --minimal

echo "Installed versions:"
"${ORB_VAL_BIN_DIR}/bitrise" --version
"${ORB_VAL_BIN_DIR}/yq" --version
