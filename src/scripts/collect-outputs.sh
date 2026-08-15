#!/bin/bash
set -euo pipefail

# Parameters, via `environment:`:
#   ORB_VAL_ID               -- the same Step reference passed to create-config
#   ORB_VAL_OUTPUTS          -- the same flat output-alias block passed to create-config
#   ORB_VAL_EXTRA_OUTPUTS    -- newline-separated list of additional env var NAMES to
#                               export verbatim, unioned with the Step's declared outputs
#   ORB_VAL_STEP_LIB_SOURCE  -- the same default_step_lib_source
#   ORB_VAL_CONFIG_PATH      -- the bitrise.yml create-config already wrote
#   ORB_VAL_WORKFLOW_NAME    -- the workflow inside it to append the collector Step to
#
# WHY THIS COMMAND DOES NOT LITERALLY READ AN ENVMAN ENVSTORE FILE:
# Per this project's spike report (bitrise.md's env-var-handoff discussion, sourced
# directly from bitrise-io/bitrise's own cli/run_util.go): `bitrise` does not shell out
# to a separate `envman run` per Step to build the next Step's environment -- it
# constructs the merged env directly and hands it to the child process. A Step's own
# `envman add` output becomes a live, inherited shell variable for every *subsequent*
# Step in the same `bitrise run` invocation -- confirmed hands-on against the real CLI
# while building this orb, using the same fixture this repo's own test-deploy.yml
# exercises (test/fixtures/local-step). So this command's job is to discover which
# output keys to look for (via `stepman step-info`, source-agnostic across all three
# reference grammars, unioned with any "extra-outputs" the caller named explicitly) and
# inject one more Step -- a plain script Step -- into the SAME bitrise.yml, immediately
# after the target Step, whose whole job is to read each expected output as a live shell
# variable and append `export KEY=value` lines to $BASH_ENV while still inside the
# running `bitrise run` process. That is what actually gets the values out.

if [[ ! -f "${ORB_VAL_CONFIG_PATH}" ]]; then
  echo "bitrise-orb: no bitrise.yml found at ${ORB_VAL_CONFIG_PATH} to append the output collector to." >&2
  echo "This command must run after create-config in the same job." >&2
  exit 1
fi

IDENTIFIER_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# --- Parse ORB_VAL_ID into stepman's own (--library, --id, --version) calling
# convention. Mirrors the reference grammar in this project's spike report (bitrise.md,
# section 5/6): "<step_lib_source>::<step-id>@<version>", plus the special "git::" and
# "path::" source prefixes -- all three source-agnostic for `stepman step-info`,
# confirmed hands-on while building this orb.
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
if OUTPUT="$(stepman "${STEPMAN_ARGS[@]}" 2> "${STEPMAN_ERR_FILE}")"; then
  STEP_INFO_JSON="${OUTPUT}"
else
  # Output discovery is a convenience layered on top of running the Step, not a
  # precondition for it (Locked Decision #5's spirit, extended to this orb's own
  # plumbing rather than the Step's own execution) -- if stepman can't resolve step-info
  # for some reason (an unreachable private git:: source, an unusual custom StepLib),
  # warn and continue with zero declared outputs. The Step itself still runs normally;
  # any "extra-outputs" the caller named explicitly are still exported below.
  echo "Warning: 'stepman step-info' failed -- continuing without automatic discovery of declared outputs (any 'extra-outputs' you set will still be exported):" >&2
  cat "${STEPMAN_ERR_FILE}" >&2 || true
fi
rm -f "${STEPMAN_ERR_FILE}"

DECLARED_KEYS=()
if [[ -n "${STEP_INFO_JSON}" ]]; then
  # Each element of step.outputs is a map with the output's own key plus an "opts" key
  # (verified directly against a real activated step.yml) -- subtract "opts" rather than
  # assume alphabetical key order.
  while IFS= read -r key; do
    [[ -n "${key}" ]] && DECLARED_KEYS+=("${key}")
  done < <(echo "${STEP_INFO_JSON}" | jq -r '(.step.outputs // []) | map((keys - ["opts"])[0]) | .[]')
fi

# --- "extra-outputs": additional env var NAMES to export verbatim, unioned with the
# declared keys above. Deliberately opt-in and name-only (no values, no aliasing) --
# this is the fix for the reviewing architect's finding: `collect-outputs` only ever
# exported outputs a Step's own step.yml DECLARED, which is precise but not faithful to
# Bitrise -- on Bitrise, `envman add --key X --value Y` makes X available to every
# subsequent Step whether or not any step.yml declares it, and that is exactly how
# Bitrise's own docs tell users to pass values between Steps from a `script` Step (whose
# step.yml declares zero outputs). Without this, that exact pattern does nothing on this
# orb, silently, with a green build. See the README's "Outputs" section for the
# motivating example.
EXTRA_KEYS=()
while IFS= read -r name; do
  name="${name//[$' \t\r']/}"
  [[ -z "${name}" ]] && continue
  if [[ ! "${name}" =~ ${IDENTIFIER_RE} ]]; then
    echo "bitrise-orb: invalid 'extra-outputs' entry '${name}' -- must be a plain environment variable name matching [A-Za-z_][A-Za-z0-9_]*." >&2
    exit 1
  fi
  EXTRA_KEYS+=("${name}")
done <<< "${ORB_VAL_EXTRA_OUTPUTS}"

# Union + de-duplicate, without relying on bash 4+ associative arrays (CircleCI's macOS
# executor's default /bin/bash is 3.2, which has none) -- a delimited "seen" string and a
# substring test does the same job.
SEEN_KEYS=""
OUTPUT_KEYS=()
for KEY in "${DECLARED_KEYS[@]:-}" "${EXTRA_KEYS[@]:-}"; do
  [[ -z "${KEY}" ]] && continue
  case "${SEEN_KEYS}" in
    *"|${KEY}|"*) continue ;;
  esac
  SEEN_KEYS="${SEEN_KEYS}|${KEY}|"
  OUTPUT_KEYS+=("${KEY}")
done

if [[ "${#OUTPUT_KEYS[@]}" -eq 0 ]]; then
  echo "This Step declares no outputs, no 'extra-outputs' were set (or output discovery was unavailable) -- nothing to export, skipping."
  exit 0
fi

echo "Declared output keys: ${DECLARED_KEYS[*]:-none}"
echo "Extra output keys: ${EXTRA_KEYS[*]:-none}"
echo "Exporting: ${OUTPUT_KEYS[*]}"

# --- Resolve any alias the user configured for a given output key (Bitrise's own
# config-level output aliasing, already written into the Step's own `outputs:` block by
# create-config). Parsed with the same shape-aware, substitute-each-value-individually
# helper create-config.sh's parse_flat_yaml_block() uses -- see that file for why:
# substituting the whole block first and re-parsing the RESULT as YAML means any
# YAML-significant byte inside a resolved secret ("#", ": ", an embedded newline)
# becomes live document syntax (shell-correctness review, Finding #2). "extra-outputs"
# entries are never aliased -- Bitrise's own aliasing mechanism only knows about a
# Step's declared outputs.
parse_flat_yaml_block() {
  local raw="$1" out_file="$2"
  local raw_stripped="${raw//[$' \t\n']/}"
  if [[ -z "${raw_stripped}" ]]; then
    echo '[]' > "${out_file}"
    return
  fi

  local shape
  if ! shape="$(printf '%s\n' "${raw}" | yq eval 'tag' - 2>&1)"; then
    echo "bitrise-orb: could not parse the following as YAML:" >&2
    printf '%s\n' "${raw}" >&2
    echo "${shape}" >&2
    exit 1
  fi

  local list_file
  list_file="$(mktemp)"
  if [[ "${shape}" == "!!seq" ]]; then
    printf '%s\n' "${raw}" > "${list_file}"
  elif [[ "${shape}" == "!!map" ]]; then
    printf '%s\n' "${raw}" | yq eval 'to_entries | map({(.key): .value})' - > "${list_file}"
  else
    echo "bitrise-orb: 'outputs' must be either flat \"key: value\" pairs or Bitrise's own list-of-maps \"- key: value\" shape -- got a bare ${shape#!!} value:" >&2
    printf '%s\n' "${raw}" >&2
    exit 1
  fi

  local count i raw_value resolved_value
  count="$(yq eval 'length' "${list_file}")"
  for ((i = 0; i < count; i++)); do
    raw_value="$(yq eval ".[${i}] | to_entries[0].value" "${list_file}")"
    resolved_value="$(circleci env subst "${raw_value}")"
    RESOLVED_VALUE="${resolved_value}" yq eval -i \
      ".[${i}] |= (to_entries[0].key as \$k | {(\$k): strenv(RESOLVED_VALUE)})" "${list_file}"
  done

  mv "${list_file}" "${out_file}"
}

ALIASES_JSON="{}"
OUTPUTS_LIST_FILE="$(mktemp)"
parse_flat_yaml_block "${ORB_VAL_OUTPUTS}" "${OUTPUTS_LIST_FILE}"
if [[ "$(yq eval 'length' "${OUTPUTS_LIST_FILE}")" != "0" ]]; then
  ALIASES_JSON="$(yq eval -o=json 'map(to_entries[0]) | from_entries' "${OUTPUTS_LIST_FILE}")"
fi
rm -f "${OUTPUTS_LIST_FILE}"

# --- Build the collector script body. For every key, prefer its alias (if the user set
# one) but fall back to the vendor's own declared name.
#
# SECURITY (shell-correctness review, Finding #1 -- CRITICAL, arbitrary command
# execution): KEY and ALIAS get spliced directly into ${...} expansions of the generated
# bash source below, which is written into the synthesized bitrise.yml as a script@1
# Step and then actually EXECUTED by `bitrise run`. ALIAS in particular comes straight
# from the user-supplied "outputs" parameter (after `circleci env subst`, so it can also
# come from a runtime env var's value) -- an unvalidated alias like
# `HOME}"; touch /tmp/PWNED; a="` closes the surrounding expansion/quote early and drops
# an arbitrary command into the token stream. Validate every KEY/ALIAS against a strict
# identifier pattern before using it to build shell source, and abort loudly otherwise.
# Never interpolate an untrusted string directly into a ${...} position of generated
# shell source.
#
# NOTE: whether Bitrise's config-level output aliasing renames the *live shell variable*
# it forwards to subsequent Steps in the same run, or leaves the original name set too
# alongside a second aliased copy, was not something this project's spike report
# verified -- only the aliasing *config syntax* is documented. Check both names
# defensively rather than assume either behavior.
COLLECTOR_SCRIPT=$'#!/usr/bin/env bash\nset -uo pipefail\n'
for KEY in "${OUTPUT_KEYS[@]}"; do
  if [[ ! "${KEY}" =~ ${IDENTIFIER_RE} ]]; then
    echo "bitrise-orb: refusing to export output key '${KEY}' -- not a valid environment variable name matching [A-Za-z_][A-Za-z0-9_]*." >&2
    exit 1
  fi
  ALIAS="$(echo "${ALIASES_JSON}" | jq -r --arg k "${KEY}" '.[$k] // empty')"
  if [[ -n "${ALIAS}" ]]; then
    if [[ ! "${ALIAS}" =~ ${IDENTIFIER_RE} ]]; then
      echo "bitrise-orb: refusing to use output alias '${ALIAS}' for '${KEY}' -- not a valid environment variable name matching [A-Za-z_][A-Za-z0-9_]*." >&2
      exit 1
    fi
    # Prefer the alias, but only if it actually holds a non-empty value -- fall back to
    # the vendor's own declared name otherwise, covering both possible real behaviors of
    # Bitrise's aliasing (a true rename, vs. leaving the original set too) with one check.
    COLLECTOR_SCRIPT+="if [ -n \"\${${ALIAS}:-}\" ]; then echo \"export ${ALIAS}=\$(printf '%q' \"\${${ALIAS}}\")\" >> \"\$BASH_ENV\"; elif [ -n \"\${${KEY}:-}\" ]; then echo \"export ${ALIAS}=\$(printf '%q' \"\${${KEY}}\")\" >> \"\$BASH_ENV\"; fi"$'\n'
  else
    COLLECTOR_SCRIPT+="if [ -n \"\${${KEY}:-}\" ]; then echo \"export ${KEY}=\$(printf '%q' \"\${${KEY}}\")\" >> \"\$BASH_ENV\"; fi"$'\n'
  fi
done
COLLECTOR_SCRIPT+='echo "bitrise-orb: exported Step outputs to \$BASH_ENV"'

# --- Append the collector as a second Step in the same workflow, immediately after the
# target Step. If the target Step fails (and isn't is_always_run), Bitrise skips every
# subsequent Step -- so this collector simply won't run, which is correct: there is
# nothing to collect from a Step that failed, and `bitrise run`'s own non-zero exit is
# what surfaces that failure (Locked Decision #5).
COLLECTOR_SCRIPT="${COLLECTOR_SCRIPT}" ORB_VAL_WORKFLOW_NAME="${ORB_VAL_WORKFLOW_NAME}" \
  yq eval -i '.workflows[strenv(ORB_VAL_WORKFLOW_NAME)].steps += [{"script@1": {"title": "bitrise-orb: export Step outputs to BASH_ENV", "inputs": [{"content": strenv(COLLECTOR_SCRIPT)}]}}]' "${ORB_VAL_CONFIG_PATH}"

echo "Appended output collector Step. Final bitrise.yml at ${ORB_VAL_CONFIG_PATH}:"
cat "${ORB_VAL_CONFIG_PATH}"
