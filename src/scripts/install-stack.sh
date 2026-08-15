#!/bin/bash
set -euo pipefail

# Parameters, via `environment:` (see install.sh for why this indirection exists):
#   ORB_VAL_PROFILE               -- "none" | "android-build" | "fastlane" | "js-mobile"
#   ORB_VAL_INSTALL_ZSTD          -- boolean-as-string (see map-env.sh's orb_bool_is_true note)
#   ORB_VAL_VERIFY_CHECKSUMS      -- boolean-as-string; never disable outside local debugging
#   ORB_VAL_JDK_VERSION           -- e.g. "17" (apt package "openjdk-<N>-jdk-headless")
#   ORB_VAL_ANDROID_PLATFORM      -- e.g. "35"
#   ORB_VAL_ANDROID_BUILD_TOOLS   -- e.g. "35.0.0"
#   ORB_VAL_ANDROID_SDK_ROOT      -- directory exported as $ANDROID_HOME/$ANDROID_SDK_ROOT
#   ORB_VAL_FASTLANE_VERSION      -- e.g. "2.236.1"
#   ORB_VAL_GEM_HOME              -- directory exported as $GEM_HOME for the fastlane gem
#   ORB_VAL_NODE_VERSION          -- must equal NODE_PINNED_VERSION below (see that constant)
#   ORB_VAL_NODE_ROOT             -- directory the Node.js tarball is extracted into
#   ORB_VAL_STACK_BIN_DIR         -- directory `tools` catalog binaries (ripgrep, gh) go into
#
# resolve-stack-plan.sh has already validated `profile` and every `tools` entry, and left
# its resolved plan at /tmp/.bitrise-orb-stack-plan (also this command's cache-key input).
# This script does the actual work: OS/arch capability checks (fail loudly, naming the
# tool and the reason, before any network call -- never a bare download-then-404), then
# per-profile installs, each idempotent against a warm cache and each direct-download
# artifact checksum-verified against the pinned table below before it is ever unpacked
# or executed.
#
# INTEGRITY MODEL, deliberately different per install path (this project's stacks
# research, "Pinning and integrity"):
#   - apt packages (JDK, Ruby, build-essential, zstd, unzip)  -> APT's own signed Release
#     files are the integrity mechanism; no separate checksum needed, and the exact
#     version is whatever the machine image's Ubuntu release carries (NOT vendor-pinned
#     by this orb -- see the fastlane/JDK sections below).
#   - the fastlane GEM                                        -> RubyGems' own checksum
#     protocol is the integrity mechanism; no separate checksum needed, so
#     `fastlane-version` is freely overridable.
#   - Android SDK packages installed BY sdkmanager (platform-tools, platforms,
#     build-tools) -> sdkmanager verifies these against Google's own signed repository
#     manifest; no separate checksum needed, so `android-platform`/`android-build-tools`
#     are freely overridable.
#   - the Android cmdline-tools BOOTSTRAP zip, and the Node.js tarball -> fetched by a
#     bare `curl`, with NOTHING else verifying them, so THIS script vendors a checksum for
#     each and refuses to unpack/execute on a mismatch. Because that checksum is pinned to
#     one exact version, `node-version` is NOT freely overridable -- see NODE_PINNED_VERSION.
#
# CATALOG SOURCES (fetched 2026-08-15; re-verify before bumping any of these):
#   - Android cmdline-tools: dl.google.com/android/repository/repository2-3.xml (Google's
#     own package manifest; sha1 is the checksum type Google itself publishes there)
#   - Node.js: nodejs.org/dist/v<version>/SHASUMS256.txt (Node's own release manifest)
#   - ripgrep: each GitHub release's own published "<asset>.sha256" sidecar file
#   - gh (GitHub CLI): the release's own published "gh_<version>_checksums.txt"
# See resolve-stack-plan.sh's NOTE for why the tool-name/pinned-version list is duplicated
# there rather than shared with this file.

orb_bool_is_true() {
  case "${1:-}" in
    1 | true | True | TRUE) return 0 ;;
    *) return 1 ;;
  esac
}

OS="$(uname -s)"
ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
  x86_64) ARCH="x86_64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *) ARCH="${ARCH_RAW}" ;;
esac
case "${OS}" in
  Linux) GOOS="linux" ;;
  Darwin) GOOS="darwin" ;;
  *) GOOS="" ;;
esac
OS_ARCH_KEY="${GOOS}-${ARCH}"

APT_UPDATED=0
apt_install() {
  local sudo_cmd=""
  [[ "${EUID}" != 0 ]] && sudo_cmd="sudo"
  if [[ "${APT_UPDATED}" -eq 0 ]]; then
    ${sudo_cmd} apt-get update -qq
    APT_UPDATED=1
  fi
  ${sudo_cmd} apt-get install -y -qq "$@"
}

# Download $1 to $2, then verify it against the expected checksum $3 using algorithm $4
# ("sha256" or "sha1") before returning -- fails closed (removes the partial download and
# exits non-zero) on any mismatch. $5 is a human label used only in messages.
download_and_verify() {
  local url="$1" dest="$2" expected="$3" algo="$4" label="$5"
  echo "Downloading ${label}:"
  echo "  ${url}"
  curl --proto '=https' --tlsv1.2 --fail --silent --show-error --location --retry 3 \
    --output "${dest}" "${url}"
  if orb_bool_is_true "${ORB_VAL_VERIFY_CHECKSUMS:-1}"; then
    local actual=""
    case "${algo}" in
      sha256) actual="$(sha256sum "${dest}" | awk '{print $1}')" ;;
      sha1) actual="$(sha1sum "${dest}" | awk '{print $1}')" ;;
      *)
        echo "bitrise-orb: internal error -- unknown checksum algorithm '${algo}' for ${label}." >&2
        exit 1
        ;;
    esac
    if [[ "${actual}" != "${expected}" ]]; then
      echo "bitrise-orb: checksum mismatch for ${label} -- refusing to use this download." >&2
      echo "  expected (${algo}): ${expected}" >&2
      echo "  got (${algo}):      ${actual}" >&2
      echo "  url: ${url}" >&2
      rm -f "${dest}"
      exit 1
    fi
    echo "Checksum OK (${algo}) for ${label}."
  else
    echo "WARNING: verify-checksums is false -- skipping checksum verification for ${label}. Never disable this outside local debugging of this orb itself." >&2
  fi
}

# --- zstd: a hard, confirmed dependency of current-generation Bitrise cache Steps
# (bitrise-step-restore-cache/save-cache both declare it in their own step.yml `deps:`) --
# on by default regardless of `profile`, since it's cheap and nothing depending on it
# should silently break. See this project's stacks research, ranked item #4.
maybe_install_zstd() {
  if ! orb_bool_is_true "${ORB_VAL_INSTALL_ZSTD:-1}"; then
    echo "install-zstd is false -- skipping. Current-generation Bitrise cache Steps require zstd; only skip this if you know the target Step doesn't use them."
    return
  fi
  if command -v zstd > /dev/null 2>&1; then
    echo "zstd already present ($(zstd --version 2>&1 | head -1)) -- skipping."
    return
  fi
  case "${OS}" in
    Linux)
      echo "Installing zstd (apt)..."
      apt_install zstd
      ;;
    Darwin)
      if command -v brew > /dev/null 2>&1; then
        echo "Installing zstd (Homebrew)..."
        brew install zstd
      else
        echo "bitrise-orb: cannot install zstd -- this is not Linux (no apt) and no Homebrew was found on this macOS executor." >&2
        echo "CircleCI's standard macOS executor images ship Homebrew; if you're on a custom image, install zstd yourself first, or set install-zstd: false if you know the target Step doesn't need it." >&2
        exit 1
      fi
      ;;
    *)
      echo "bitrise-orb: cannot install zstd -- unsupported OS '${OS}' (this command only knows apt on Linux and Homebrew on macOS)." >&2
      exit 1
      ;;
  esac
}

# =====================================================================================
# profile: android-build -- OpenJDK (apt) + Android SDK platform-tools/build-tools/one
# platform (cmdline-tools bootstrap zip, checksum-verified; everything sdkmanager itself
# fetches after that is verified by sdkmanager against Google's own signed manifest).
# Deliberately excludes the emulator and NDK -- neither is a dependency of the
# android-build/android-lint/android-unit-test/sign-apk Step cluster this profile targets
# (this project's stacks research, ranked item #1); use the bitrise/android-toolchain
# executor's full vendor image instead if a Step genuinely needs those.
# =====================================================================================
ANDROID_CMDLINE_TOOLS_REV="15859902"
ANDROID_CMDLINE_TOOLS_ZIP="commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_REV}_latest.zip"
ANDROID_CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/${ANDROID_CMDLINE_TOOLS_ZIP}"
ANDROID_CMDLINE_TOOLS_SHA1="040d3996a65543d22ec4bf73e4c37aa37a8d4af4"

install_android_build() {
  if [[ "${OS}" != "Linux" || "${ARCH}" != "x86_64" ]]; then
    echo "bitrise-orb: init-stack's 'android-build' profile cannot run here (got OS='${OS}' ARCH='${ARCH_RAW}')." >&2
    echo "It needs Linux/x86_64: the JDK install goes through apt (Linux-only), and this orb only vendors a checksum for the Linux x86_64 Android cmdline-tools bootstrap archive." >&2
    echo "This orb's bitrise/machine executor already requires an x86_64/amd64 resource class for the same reason the Bitrise CLI itself has no Linux arm64 build -- see that executor's own description." >&2
    exit 1
  fi

  echo "Installing OpenJDK ${ORB_VAL_JDK_VERSION} (openjdk-${ORB_VAL_JDK_VERSION}-jdk-headless via apt; version is whatever this image's Ubuntu release carries, not vendor-pinned by this orb -- apt's own signed Release files are the integrity mechanism)..."
  if dpkg -s "openjdk-${ORB_VAL_JDK_VERSION}-jdk-headless" > /dev/null 2>&1; then
    echo "openjdk-${ORB_VAL_JDK_VERSION}-jdk-headless already installed -- skipping."
  else
    apt_install "openjdk-${ORB_VAL_JDK_VERSION}-jdk-headless"
  fi

  local sdk_root="${ORB_VAL_ANDROID_SDK_ROOT}"
  mkdir -p "${sdk_root}"

  if [[ -x "${sdk_root}/platform-tools/adb" ]] &&
    [[ -d "${sdk_root}/platforms/android-${ORB_VAL_ANDROID_PLATFORM}" ]] &&
    [[ -d "${sdk_root}/build-tools/${ORB_VAL_ANDROID_BUILD_TOOLS}" ]]; then
    echo "platform-tools + platforms;android-${ORB_VAL_ANDROID_PLATFORM} + build-tools;${ORB_VAL_ANDROID_BUILD_TOOLS} already present at ${sdk_root} (cache hit) -- skipping the SDK bootstrap entirely."
  else
    if ! command -v unzip > /dev/null 2>&1; then
      apt_install unzip
    fi
    local zip_path="/tmp/bitrise-orb-cmdline-tools.zip"
    download_and_verify \
      "${ANDROID_CMDLINE_TOOLS_URL}" "${zip_path}" "${ANDROID_CMDLINE_TOOLS_SHA1}" sha1 \
      "Android cmdline-tools ${ANDROID_CMDLINE_TOOLS_REV} (Linux)"

    rm -rf "${sdk_root}/cmdline-tools"
    mkdir -p "${sdk_root}/cmdline-tools/_extract"
    unzip -q "${zip_path}" -d "${sdk_root}/cmdline-tools/_extract"
    mv "${sdk_root}/cmdline-tools/_extract/cmdline-tools" "${sdk_root}/cmdline-tools/latest"
    rm -rf "${sdk_root}/cmdline-tools/_extract" "${zip_path}"

    local sdkmanager="${sdk_root}/cmdline-tools/latest/bin/sdkmanager"
    echo "Accepting Android SDK licenses non-interactively (bitrise --ci run's own equivalent of the interactive prompt this replaces)..."
    set +o pipefail # `yes` legitimately gets SIGPIPE'd once sdkmanager stops reading; that
    # must not be mistaken for sdkmanager's own exit status below.
    yes | "${sdkmanager}" --sdk_root="${sdk_root}" --licenses > /dev/null 2>&1
    set -o pipefail

    echo "Installing platform-tools, platforms;android-${ORB_VAL_ANDROID_PLATFORM}, build-tools;${ORB_VAL_ANDROID_BUILD_TOOLS} (sdkmanager verifies these itself against Google's signed repository manifest)..."
    "${sdkmanager}" --sdk_root="${sdk_root}" \
      "platform-tools" \
      "platforms;android-${ORB_VAL_ANDROID_PLATFORM}" \
      "build-tools;${ORB_VAL_ANDROID_BUILD_TOOLS}"
  fi

  {
    printf 'export ANDROID_HOME=%s\n' "$(printf '%q' "${sdk_root}")"
    printf 'export ANDROID_SDK_ROOT=%s\n' "$(printf '%q' "${sdk_root}")"
    printf 'export PATH=%s:%s:$PATH\n' \
      "$(printf '%q' "${sdk_root}/platform-tools")" \
      "$(printf '%q' "${sdk_root}/build-tools/${ORB_VAL_ANDROID_BUILD_TOOLS}")"
  } >> "$BASH_ENV"
}

# =====================================================================================
# profile: fastlane -- Ruby (apt) + the fastlane gem. Blocks the steps-fastlane Step
# cluster (this project's stacks research, ranked item #2).
# =====================================================================================
install_fastlane() {
  if [[ "${OS}" != "Linux" ]]; then
    echo "bitrise-orb: init-stack's 'fastlane' profile cannot run here (got OS='${OS}') -- it installs Ruby via apt, which only exists on Linux." >&2
    echo "On CircleCI's macOS executor, Ruby already ships with the system/Xcode toolchain (or install your own via Homebrew) -- 'gem install fastlane -v ${ORB_VAL_FASTLANE_VERSION}' directly is the macOS equivalent of this profile; this orb doesn't automate it there." >&2
    exit 1
  fi

  echo "Installing Ruby (ruby-full via apt; version is whatever this image's Ubuntu release carries, not vendor-pinned by this orb) + build-essential (native gem extensions)..."
  if dpkg -s ruby-full > /dev/null 2>&1 && dpkg -s build-essential > /dev/null 2>&1; then
    echo "ruby-full and build-essential already installed -- skipping."
  else
    apt_install ruby-full build-essential
  fi

  local gem_home="${ORB_VAL_GEM_HOME}"
  mkdir -p "${gem_home}"

  installed_fastlane_version() {
    GEM_HOME="${gem_home}" "${gem_home}/bin/fastlane" --version 2> /dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
  }
  if [[ -x "${gem_home}/bin/fastlane" ]] && [[ "$(installed_fastlane_version)" == "${ORB_VAL_FASTLANE_VERSION}" ]]; then
    echo "fastlane ${ORB_VAL_FASTLANE_VERSION} already present at ${gem_home} (cache hit) -- skipping gem install."
  else
    echo "Installing fastlane gem ${ORB_VAL_FASTLANE_VERSION} (GEM_HOME=${gem_home}; RubyGems' own checksum protocol is the integrity mechanism here, so fastlane-version is freely overridable, unlike node-version below)..."
    GEM_HOME="${gem_home}" GEM_PATH="${gem_home}" gem install fastlane -v "${ORB_VAL_FASTLANE_VERSION}" --no-document
  fi

  {
    printf 'export GEM_HOME=%s\n' "$(printf '%q' "${gem_home}")"
    printf 'export GEM_PATH=%s\n' "$(printf '%q' "${gem_home}")"
    printf 'export PATH=%s:$PATH\n' "$(printf '%q' "${gem_home}/bin")"
  } >> "$BASH_ENV"
}

# =====================================================================================
# profile: js-mobile -- Node.js (direct tarball, checksum-verified) + npm/Yarn/corepack.
# Blocks the steps-npm/steps-yarn Step cluster (ranked item #3). Works on both Linux and
# macOS -- Node.js publishes, and this orb vendors checksums for, both, unlike the
# apt-based android-build/fastlane profiles above.
# =====================================================================================
NODE_PINNED_VERSION="22.22.0"
node_sha256() {
  case "$1" in
    linux-x86_64) echo "9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37" ;;
    linux-arm64) echo "1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f" ;;
    darwin-x86_64) echo "5ea50c9d6dea3dfa3abb66b2656f7a4e1c8cef23432b558d45fb538c7b5dedce" ;;
    darwin-arm64) echo "5ed4db0fcf1eaf84d91ad12462631d73bf4576c1377e192d222e48026a902640" ;;
    *) echo "" ;;
  esac
}
node_archive_ext() {
  case "$1" in
    linux-*) echo "tar.xz" ;;
    darwin-*) echo "tar.gz" ;;
    *) echo "" ;;
  esac
}
node_platform_tag() {
  case "$1" in
    linux-x86_64) echo "linux-x64" ;;
    linux-arm64) echo "linux-arm64" ;;
    darwin-x86_64) echo "darwin-x64" ;;
    darwin-arm64) echo "darwin-arm64" ;;
    *) echo "" ;;
  esac
}

install_js_mobile() {
  if [[ "${ORB_VAL_NODE_VERSION}" != "${NODE_PINNED_VERSION}" ]]; then
    echo "bitrise-orb: unsupported node-version '${ORB_VAL_NODE_VERSION}' -- this orb only vendors a checksum for Node.js ${NODE_PINNED_VERSION} (fetched via a bare curl, with nothing else to verify it against)." >&2
    echo "Use the default, or open a PR against src/scripts/install-stack.sh to add checksums for ${ORB_VAL_NODE_VERSION} from nodejs.org/dist/v${ORB_VAL_NODE_VERSION}/SHASUMS256.txt." >&2
    exit 1
  fi

  local platform_tag sha256
  platform_tag="$(node_platform_tag "${OS_ARCH_KEY}")"
  sha256="$(node_sha256 "${OS_ARCH_KEY}")"
  if [[ -z "${platform_tag}" || -z "${sha256}" ]]; then
    echo "bitrise-orb: init-stack's 'js-mobile' profile has no pinned Node.js build for OS='${OS}' ARCH='${ARCH_RAW}' -- this orb vendors checksums only for linux/darwin on x86_64/arm64." >&2
    exit 1
  fi

  local node_root="${ORB_VAL_NODE_ROOT}"
  mkdir -p "${node_root}"

  if [[ -x "${node_root}/bin/node" ]] && [[ "$("${node_root}/bin/node" --version 2> /dev/null)" == "v${ORB_VAL_NODE_VERSION}" ]]; then
    echo "Node.js ${ORB_VAL_NODE_VERSION} already present at ${node_root} (cache hit) -- skipping download."
  else
    local ext filename url archive_path
    ext="$(node_archive_ext "${OS_ARCH_KEY}")"
    filename="node-v${ORB_VAL_NODE_VERSION}-${platform_tag}.${ext}"
    url="https://nodejs.org/dist/v${ORB_VAL_NODE_VERSION}/${filename}"
    archive_path="/tmp/bitrise-orb-${filename}"
    download_and_verify "${url}" "${archive_path}" "${sha256}" sha256 "Node.js ${ORB_VAL_NODE_VERSION} (${platform_tag})"

    rm -rf "${node_root}"
    mkdir -p "${node_root}"
    tar -xf "${archive_path}" -C "${node_root}" --strip-components=1
    rm -f "${archive_path}"
  fi

  {
    printf 'export PATH=%s:$PATH\n' "$(printf '%q' "${node_root}/bin")"
  } >> "$BASH_ENV"
  export PATH="${node_root}/bin:${PATH}"

  echo "Enabling corepack (bundled with Node >=16.9; manages Yarn/pnpm on demand without a separate install)..."
  "${node_root}/bin/corepack" enable || echo "WARNING: 'corepack enable' failed -- continuing; npm itself is still fully usable." >&2
}

# =====================================================================================
# `tools` catalog -- name@version overrides/additions beyond `profile`, already validated
# by resolve-stack-plan.sh and left in its plan file as "tool=name@version" lines.
# =====================================================================================
ripgrep_asset() {
  case "$1" in
    linux-x86_64) echo "ripgrep-14.1.1-x86_64-unknown-linux-musl.tar.gz" ;;
    linux-arm64) echo "ripgrep-14.1.1-aarch64-unknown-linux-gnu.tar.gz" ;;
    darwin-x86_64) echo "ripgrep-14.1.1-x86_64-apple-darwin.tar.gz" ;;
    darwin-arm64) echo "ripgrep-14.1.1-aarch64-apple-darwin.tar.gz" ;;
    *) echo "" ;;
  esac
}
ripgrep_sha256() {
  case "$1" in
    linux-x86_64) echo "4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e" ;;
    linux-arm64) echo "c827481c4ff4ea10c9dc7a4022c8de5db34a5737cb74484d62eb94a95841ab2f" ;;
    darwin-x86_64) echo "fc87e78f7cb3fea12d69072e7ef3b21509754717b746368fd40d88963630e2b3" ;;
    darwin-arm64) echo "24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be" ;;
    *) echo "" ;;
  esac
}
gh_asset() {
  case "$1" in
    linux-x86_64) echo "gh_2.86.0_linux_amd64.tar.gz" ;;
    linux-arm64) echo "gh_2.86.0_linux_arm64.tar.gz" ;;
    darwin-x86_64) echo "gh_2.86.0_macOS_amd64.zip" ;;
    darwin-arm64) echo "gh_2.86.0_macOS_arm64.zip" ;;
    *) echo "" ;;
  esac
}
gh_sha256() {
  case "$1" in
    linux-x86_64) echo "f3b08bd6a28420cc2229b0a1a687fa25f2b838d3f04b297414c1041ca68103c7" ;;
    linux-arm64) echo "83cf7a7962ea9dfcc2c123666695792916a87af32cba5f1f6e585db08fa57547" ;;
    darwin-x86_64) echo "ced7094d05702eb54a63542abd8a1dc570b7e5ae94951844eb1626ba74bc2c60" ;;
    darwin-arm64) echo "bde753978a352c5ae6c4abec47334d516e82807af20c9dbbd45507a5a0aedaaa" ;;
    *) echo "" ;;
  esac
}

install_ripgrep() {
  local version="$1" asset sha bin_dir
  asset="$(ripgrep_asset "${OS_ARCH_KEY}")"
  sha="$(ripgrep_sha256 "${OS_ARCH_KEY}")"
  if [[ -z "${asset}" ]]; then
    echo "bitrise-orb: 'tools: ripgrep' cannot install here -- no pinned build for OS='${OS}' ARCH='${ARCH_RAW}'." >&2
    exit 1
  fi
  bin_dir="${ORB_VAL_STACK_BIN_DIR}"
  mkdir -p "${bin_dir}"
  if [[ -x "${bin_dir}/rg" ]] && [[ "$("${bin_dir}/rg" --version 2> /dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" == "${version}" ]]; then
    echo "ripgrep ${version} already present at ${bin_dir}/rg (cache hit) -- skipping."
    return
  fi
  local url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${asset}"
  local archive_path="/tmp/bitrise-orb-${asset}"
  download_and_verify "${url}" "${archive_path}" "${sha}" sha256 "ripgrep ${version} (${OS_ARCH_KEY})"
  local extract_dir="/tmp/bitrise-orb-rg-extract"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  tar -xf "${archive_path}" -C "${extract_dir}"
  find "${extract_dir}" -type f -name rg -exec cp {} "${bin_dir}/rg" \;
  chmod +x "${bin_dir}/rg"
  rm -rf "${extract_dir}" "${archive_path}"
}

install_gh() {
  local version="$1" asset sha bin_dir
  asset="$(gh_asset "${OS_ARCH_KEY}")"
  sha="$(gh_sha256 "${OS_ARCH_KEY}")"
  if [[ -z "${asset}" ]]; then
    echo "bitrise-orb: 'tools: gh' cannot install here -- no pinned build for OS='${OS}' ARCH='${ARCH_RAW}'." >&2
    exit 1
  fi
  bin_dir="${ORB_VAL_STACK_BIN_DIR}"
  mkdir -p "${bin_dir}"
  if [[ -x "${bin_dir}/gh" ]] && [[ "$("${bin_dir}/gh" --version 2> /dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')" == "${version}" ]]; then
    echo "gh ${version} already present at ${bin_dir}/gh (cache hit) -- skipping."
    return
  fi
  local url="https://github.com/cli/cli/releases/download/v${version}/${asset}"
  local archive_path="/tmp/bitrise-orb-${asset}"
  download_and_verify "${url}" "${archive_path}" "${sha}" sha256 "gh ${version} (${OS_ARCH_KEY})"
  local extract_dir="/tmp/bitrise-orb-gh-extract"
  rm -rf "${extract_dir}"
  mkdir -p "${extract_dir}"
  case "${asset}" in
    *.zip)
      if ! command -v unzip > /dev/null 2>&1; then
        if [[ "${OS}" == "Linux" ]]; then
          apt_install unzip
        fi
      fi
      unzip -q "${archive_path}" -d "${extract_dir}"
      ;;
    *)
      tar -xf "${archive_path}" -C "${extract_dir}"
      ;;
  esac
  find "${extract_dir}" -type f -name gh -exec cp {} "${bin_dir}/gh" \;
  chmod +x "${bin_dir}/gh"
  rm -rf "${extract_dir}" "${archive_path}"
}

install_catalog_tools() {
  local plan_file="/tmp/.bitrise-orb-stack-plan"
  [[ -f "${plan_file}" ]] || return 0
  local found_any=0
  local entry name version
  while IFS= read -r line; do
    case "${line}" in
      tool=*)
        found_any=1
        entry="${line#tool=}"
        name="${entry%%@*}"
        version="${entry#*@}"
        case "${name}" in
          ripgrep) install_ripgrep "${version}" ;;
          gh) install_gh "${version}" ;;
          *)
            echo "bitrise-orb: internal error -- resolve-stack-plan.sh approved unknown tool '${name}' that install-stack.sh has no installer for." >&2
            exit 1
            ;;
        esac
        ;;
    esac
  done < "${plan_file}"
  if [[ "${found_any}" -eq 1 ]]; then
    {
      printf 'export PATH=%s:$PATH\n' "$(printf '%q' "${ORB_VAL_STACK_BIN_DIR}")"
    } >> "$BASH_ENV"
  fi
}

# =====================================================================================
# main
# =====================================================================================
echo "init-stack: profile='${ORB_VAL_PROFILE}' OS='${OS}' ARCH='${ARCH_RAW}'"

maybe_install_zstd

case "${ORB_VAL_PROFILE}" in
  none)
    echo "profile is 'none' -- installing nothing beyond the zstd fix above (and any 'tools' entries below)."
    ;;
  android-build) install_android_build ;;
  fastlane) install_fastlane ;;
  js-mobile) install_js_mobile ;;
  *)
    echo "bitrise-orb: internal error -- resolve-stack-plan.sh approved unknown profile '${ORB_VAL_PROFILE}'." >&2
    exit 1
    ;;
esac

install_catalog_tools

echo "init-stack finished. Versions on PATH after this command:"
# Each check is deliberately non-fatal (trailing "|| true") -- this is an informational
# summary, not a gate, so a tool this run legitimately didn't install must not abort the
# script under `set -e` just because it's absent.
command -v zstd > /dev/null 2>&1 && (zstd --version 2>&1 | head -1) || true
command -v java > /dev/null 2>&1 && (java -version 2>&1 | head -1) || true
command -v ruby > /dev/null 2>&1 && ruby --version || true
command -v fastlane > /dev/null 2>&1 && (fastlane --version 2>&1 | head -1) || true
command -v node > /dev/null 2>&1 && node --version || true
command -v rg > /dev/null 2>&1 && (rg --version | head -1) || true
command -v gh > /dev/null 2>&1 && (gh --version | head -1) || true
exit 0
