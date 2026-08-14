#!/bin/bash
set -euo pipefail

# Parameters, via `environment:`:
#   ORB_VAL_DEPLOY_DIR             -- directory to create and export as $BITRISE_DEPLOY_DIR
#   ORB_VAL_EXTRA_ENV              -- flat "NAME: value" YAML block of extra/override env vars, or ""
#   ORB_VAL_SKIP_DEFAULT_MAPPING   -- "1"/"0" (boolean-as-string, see below)
#
# NOTE on booleans: CircleCI interpolates a boolean-typed parameter inside an
# `environment:` value as the literal string "0" or "1", never "true"/"false" -- verified
# in the act-orb-conventions spec against act-orb's own run-act.sh. Compare against "1"/"0"
# accordingly, not against "true"/"false".

mkdir -p "${ORB_VAL_DEPLOY_DIR}"
echo "export BITRISE_DEPLOY_DIR=$(printf '%q' "${ORB_VAL_DEPLOY_DIR}")" >>"$BASH_ENV"

if [[ "${ORB_VAL_SKIP_DEFAULT_MAPPING}" != "1" ]]; then
  echo "Mapping CircleCI's built-in environment variables onto their Bitrise equivalents..."
  {
    echo "export BITRISE_SOURCE_DIR=$(printf '%q' "$(pwd)")"
    [[ -n "${CIRCLE_SHA1:-}" ]] && echo "export BITRISE_GIT_COMMIT=$(printf '%q' "${CIRCLE_SHA1}")"
    [[ -n "${CIRCLE_BRANCH:-}" ]] && echo "export BITRISE_GIT_BRANCH=$(printf '%q' "${CIRCLE_BRANCH}")"
    [[ -n "${CIRCLE_TAG:-}" ]] && echo "export BITRISE_GIT_TAG=$(printf '%q' "${CIRCLE_TAG}")"
    [[ -n "${CIRCLE_BUILD_NUM:-}" ]] && echo "export BITRISE_BUILD_NUMBER=$(printf '%q' "${CIRCLE_BUILD_NUM}")"
    [[ -n "${CIRCLE_PROJECT_REPONAME:-}" ]] && echo "export BITRISE_APP_TITLE=$(printf '%q' "${CIRCLE_PROJECT_REPONAME}")"
  } >>"$BASH_ENV"
else
  echo "skip-default-mapping is true -- not exporting the built-in CircleCI -> Bitrise environment mapping."
fi

if [[ -n "${ORB_VAL_EXTRA_ENV// /}" ]]; then
  echo "Applying extra-env overrides (these are appended after the mapping above, so they win)..."
  # Locked Decision #8's `circleci env subst` treatment applies here too, so "$SOME_SECRET"
  # inside a value resolves at runtime without ever entering the packed config.
  SUBSTITUTED_EXTRA_ENV="$(circleci env subst "${ORB_VAL_EXTRA_ENV}")"
  # extra-env is intentionally a simpler grammar than the Step inputs/outputs blocks: one
  # "NAME: value" pair per line, single-line values only. A plain split on the first colon
  # is safe here (unlike for Step inputs) because environment variable NAMES can never
  # legally contain YAML-special characters, so there's no ambiguity to resolve with a
  # real YAML parser -- see scripts/create-config.sh for the yq-based transform used where
  # a real parse genuinely is required.
  while IFS= read -r line; do
    [[ -z "${line// /}" ]] && continue
    key="${line%%:*}"
    key="${key// /}"
    value="${line#*:}"
    value="${value# }"
    [[ -z "${key}" ]] && continue
    echo "export ${key}=$(printf '%q' "${value}")" >>"$BASH_ENV"
  done <<<"${SUBSTITUTED_EXTRA_ENV}"
fi

echo "bitrise-orb environment mapping applied. Exported BITRISE_* variables:"
grep -E '^export BITRISE_' "$BASH_ENV" || true
