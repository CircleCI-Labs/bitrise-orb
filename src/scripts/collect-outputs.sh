#!/bin/bash
set -euo pipefail

# Parameters, via `environment:`:
#   ORB_VAL_ID               -- the same Step reference passed to create-config
#   ORB_VAL_OUTPUTS          -- the same flat output-alias block passed to create-config
#   ORB_VAL_STEP_LIB_SOURCE  -- the same default_step_lib_source
#   ORB_VAL_CONFIG_PATH      -- the bitrise.yml create-config already wrote
#   ORB_VAL_WORKFLOW_NAME    -- the workflow inside it to append the collector Step to
#
# WHY THIS COMMAND DOES NOT "READ THE ENVMAN STORE" LITERALLY:
# The bitrise-cli-handson spike report (section 4) verified, hands-on, that
# $ENVMAN_ENVSTORE_PATH does NOT survive past the end of `bitrise run` -- every Step in
# one run shares the same temp envstore file, and bitrise truncates it to `envs: []`
# internally as it threads values from one Step's process into the next Step's process.
# By the time `bitrise run` exits, there is nothing left on disk to read. The report is
# explicit: "Do not design the orb around reading this file post-hoc."
#
# The mechanism that DOES work, proven end-to-end in that report: OS-level env vars set
# on the outer `bitrise run` process (like $BASH_ENV itself) pass through unchanged into
# every Step's process, and a Step's `envman add` output becomes a plain inherited shell
# variable for every *subsequent* Step in the same run. So this command's job is to
# discover which output keys to look for (via `stepman step-info`, source-agnostic across
# all three reference grammars) and inject one more Step -- a plain script Step -- into
# the SAME bitrise.yml, immediately after the target Step, whose whole job is to read
# each expected output as a live shell variable and append `export KEY=value` lines to
# $BASH_ENV while still inside the running `bitrise run` process. That is what actually
# gets the values out.

if [[ ! -f "${ORB_VAL_CONFIG_PATH}" ]]; then
  echo "bitrise-orb: no bitrise.yml found at ${ORB_VAL_CONFIG_PATH} to append the output collector to." >&2
  echo "This command must run after create-config in the same job." >&2
  exit 1
fi

# --- Parse ORB_VAL_ID into stepman's own (--library, --id, --version) calling
# convention. This mirrors the reference grammar verified in the required-reading spike
# report (section 5): "<step_lib_source>::<step-id>@<version>", plus the special "git::"
# and "path::" source prefixes, all three confirmed source-agnostic for `stepman
# step-info` in the hands-on CLI spike report (section 7/8).
REF="${ORB_VAL_ID}"
LIBRARY=""
IDENT=""
VERSION=""

if [[ "${REF}" == git::* ]]; then
  LIBRARY="git"
  rest="${REF#git::}"
  if [[ "${rest}" == *@* ]]; then
    IDENT="${rest%@*}"
    VERSION="${rest##*@}"
  else
    IDENT="${rest}"
  fi
elif [[ "${REF}" == path::* ]]; then
  LIBRARY="path"
  IDENT="${REF#path::}"
else
  rest="${REF}"
  if [[ "${rest}" == *::* ]]; then
    LIBRARY="${rest%%::*}"
    rest="${rest#*::}"
  else
    LIBRARY="${ORB_VAL_STEP_LIB_SOURCE}"
  fi
  if [[ "${rest}" == *@* ]]; then
    IDENT="${rest%@*}"
    VERSION="${rest##*@}"
  else
    IDENT="${rest}"
  fi
fi

STEPMAN_ARGS=(step-info --library "${LIBRARY}" --id "${IDENT}" --format json)
if [[ -n "${VERSION}" ]]; then
  STEPMAN_ARGS+=(--version "${VERSION}")
fi

echo "Discovering declared outputs via: stepman ${STEPMAN_ARGS[*]}"
STEP_INFO_JSON=""
STEPMAN_ERR_FILE="$(mktemp)"
if OUTPUT="$(stepman "${STEPMAN_ARGS[@]}" 2>"${STEPMAN_ERR_FILE}")"; then
  STEP_INFO_JSON="${OUTPUT}"
else
  # Output discovery is a convenience layered on top of running the Step, not a
  # precondition for it (Locked Decision #5's spirit, extended to this orb's own
  # plumbing rather than the Step's own execution) -- if stepman can't resolve step-info
  # for some reason (an unreachable private git:: source, an unusual custom StepLib),
  # warn and continue with zero declared outputs. The Step itself still runs normally;
  # it just won't have its outputs auto-exported to $BASH_ENV.
  echo "Warning: 'stepman step-info' failed -- continuing without automatic output export:" >&2
  cat "${STEPMAN_ERR_FILE}" >&2 || true
fi
rm -f "${STEPMAN_ERR_FILE}"

OUTPUT_KEYS=()
if [[ -n "${STEP_INFO_JSON}" ]]; then
  # Each element of step.outputs is a map with the output's own key plus an "opts" key
  # (verified directly against a real activated step.yml, hands-on CLI spike report
  # section 7/8) -- subtract "opts" rather than assume alphabetical key order.
  while IFS= read -r key; do
    [[ -n "${key}" ]] && OUTPUT_KEYS+=("${key}")
  done < <(echo "${STEP_INFO_JSON}" | jq -r '(.step.outputs // []) | map((keys - ["opts"])[0]) | .[]')
fi

if [[ "${#OUTPUT_KEYS[@]}" -eq 0 ]]; then
  echo "This Step declares no outputs (or output discovery was unavailable) -- nothing to export, skipping."
  exit 0
fi

echo "Declared output keys: ${OUTPUT_KEYS[*]}"

# --- Resolve any alias the user configured for a given output key (Bitrise's own
# config-level output aliasing, already written into the Step's own `outputs:` block by
# create-config). Parsed the same way create-config parses this same flat block.
SUBST_OUTPUTS="$(circleci env subst "${ORB_VAL_OUTPUTS}")"
# Strip ALL whitespace, not just spaces, before testing for emptiness -- see the matching
# comment in scripts/create-config.sh's flat_to_list() for why (a blank/null YAML
# document fed to yq is not guaranteed to degrade to "{}" the way an explicit empty
# string does here).
SUBST_OUTPUTS_STRIPPED="${SUBST_OUTPUTS//[$' \t\n']/}"
if [[ -z "${SUBST_OUTPUTS_STRIPPED}" ]]; then
  ALIASES_JSON="{}"
else
  ALIASES_JSON="$(printf '%s\n' "${SUBST_OUTPUTS}" | yq eval -o=json '.' -)"
fi

# --- Build the collector script body. For every declared key, prefer its alias (if the
# user set one) but fall back to the vendor's own declared name.
#
# NOTE: whether Bitrise's config-level output aliasing renames the *live shell variable*
# it forwards to subsequent Steps in the same run, or leaves the original name set too
# alongside a second aliased copy, was NOT hands-on verified in either spike report --
# only the aliasing *config syntax* is documented. Check both names defensively rather
# than assume either behavior.
COLLECTOR_SCRIPT=$'#!/usr/bin/env bash\nset -uo pipefail\n'
for KEY in "${OUTPUT_KEYS[@]}"; do
  ALIAS="$(echo "${ALIASES_JSON}" | jq -r --arg k "${KEY}" '.[$k] // empty')"
  if [[ -n "${ALIAS}" ]]; then
    # Prefer the alias, but only if it actually holds a non-empty value -- fall back to
    # the vendor's own declared name otherwise, covering both possible real behaviors of
    # Bitrise's aliasing (a true rename, vs. leaving the original set too) with one check.
    COLLECTOR_SCRIPT+="if [ -n \"\${${ALIAS}:-}\" ]; then echo \"export ${ALIAS}=\$(printf '%q' \"\${${ALIAS}}\")\" >> \"\$BASH_ENV\"; elif [ -n \"\${${KEY}:-}\" ]; then echo \"export ${ALIAS}=\$(printf '%q' \"\${${KEY}}\")\" >> \"\$BASH_ENV\"; fi"$'\n'
  else
    COLLECTOR_SCRIPT+="if [ -n \"\${${KEY}:-}\" ]; then echo \"export ${KEY}=\$(printf '%q' \"\${${KEY}}\")\" >> \"\$BASH_ENV\"; fi"$'\n'
  fi
done
COLLECTOR_SCRIPT+='echo "bitrise-orb: exported declared outputs to \$BASH_ENV"'

# --- Append the collector as a second Step in the same workflow, immediately after the
# target Step. If the target Step fails (and isn't is_always_run), Bitrise skips every
# subsequent Step -- so this collector simply won't run, which is correct: there is
# nothing to collect from a Step that failed, and `bitrise run`'s own non-zero exit is
# what surfaces that failure (Locked Decision #5).
COLLECTOR_SCRIPT="${COLLECTOR_SCRIPT}" ORB_VAL_WORKFLOW_NAME="${ORB_VAL_WORKFLOW_NAME}" \
  yq eval -i '.workflows[strenv(ORB_VAL_WORKFLOW_NAME)].steps += [{"script@1": {"title": "bitrise-orb: export declared Step outputs to BASH_ENV", "inputs": [{"content": strenv(COLLECTOR_SCRIPT)}]}}]' "${ORB_VAL_CONFIG_PATH}"

echo "Appended output collector Step. Final bitrise.yml at ${ORB_VAL_CONFIG_PATH}:"
cat "${ORB_VAL_CONFIG_PATH}"
