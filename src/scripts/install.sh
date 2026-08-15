#!/bin/bash
set -euo pipefail

# Parameters, passed in via the run step's `environment:` block per this orb's
# ORB_VAL_*/`environment:` convention (matching CircleCI-Labs/act-orb's own scripts,
# e.g. src/scripts/run-act.sh: never interpolate << parameters.x >> directly into a
# script body -- it's a config-compile-time substitution with no meaning to
# bash/shellcheck, and breaks on multi-line or special-character values):
#   ORB_VAL_BITRISE_VERSION  -- "latest" or a concrete version, e.g. "2.42.2"
#   ORB_VAL_BIN_DIR          -- directory this orb's own tooling (bitrise CLI, yq) lives in

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
  BITRISE_URL="https://github.com/bitrise-io/bitrise/releases/download/${BITRISE_VERSION_TAG}/bitrise-${OS}-${ARCH}"
  echo "Downloading Bitrise CLI ${BITRISE_VERSION_TAG} for ${OS}/${ARCH}:"
  echo "  ${BITRISE_URL}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${ORB_VAL_BIN_DIR}/bitrise" "${BITRISE_URL}"
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
if [[ -x "${ORB_VAL_BIN_DIR}/yq" ]] && [[ "$("${ORB_VAL_BIN_DIR}/yq" --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" == "${YQ_VERSION#v}" ]]; then
  echo "yq ${YQ_VERSION} already present at ${ORB_VAL_BIN_DIR}/yq (cache hit) -- skipping download."
else
  YQ_OS="$(echo "${OS}" | tr '[:upper:]' '[:lower:]')"
  YQ_URL="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_${YQ_OS}_${YQ_ARCH}"
  echo "Downloading yq ${YQ_VERSION} for ${YQ_OS}/${YQ_ARCH}:"
  echo "  ${YQ_URL}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${ORB_VAL_BIN_DIR}/yq" "${YQ_URL}"
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
