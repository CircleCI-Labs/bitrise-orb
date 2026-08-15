#!/bin/bash
set -euo pipefail

# Parameters, via `environment:` (see install.sh for why this indirection exists):
#   ORB_VAL_ID               -- the Step reference, passed through verbatim (Locked Decision #4)
#   ORB_VAL_INPUTS           -- flat "key: value" YAML block of Step inputs, or ""
#   ORB_VAL_OUTPUTS          -- flat "ORIGINAL_KEY: alias" YAML block of output aliases, or ""
#   ORB_VAL_STEP_LIB_SOURCE  -- default_step_lib_source to emit
#   ORB_VAL_CONFIG_PATH      -- where to write the synthesized bitrise.yml
#   ORB_VAL_WORKFLOW_NAME    -- name of the single workflow inside it

WORK_DIR="$(dirname "${ORB_VAL_CONFIG_PATH}")"
mkdir -p "${WORK_DIR}"

# Bitrise's `inputs:`/`outputs:` in a bitrise.yml Step block are a LIST of single-key
# maps, not a plain map -- verified directly against a real activated step.yml (see this
# project's spike report, bitrise.md section 2). Converting the user's flat "key: value"
# block into that shape needs a real YAML parse, not a text-based re-indent: a value may
# be a multi-line block scalar (e.g. a `content: |` script body), and re-indenting that
# correctly by hand means redoing what a YAML emitter already does for free. yq's
# `to_entries`/`map` (mirroring jq) do exactly this transform and re-emit
# correctly-indented YAML regardless of value shape.
#
# Locked Decision #8: resolve "$MY_SECRET"-style references inside the user's flat
# inputs/outputs blocks via CircleCI's own built-in `circleci env subst`, so a secret
# value never has to be written into the packed orb config -- only into this job's
# runtime environment.
#
# SECURITY (shell-correctness review, Finding #2): this function deliberately does NOT
# run `circleci env subst` over the whole block and then hand the result to a YAML
# parser. `circleci env subst` does plain textual "$VAR" replacement with no concept of
# YAML -- if it ran first, every YAML-significant byte in a resolved secret (a "#", a
# ": ", an embedded newline) would become live document syntax: silent truncation at a
# "#", a value silently nulled because it starts with "#", one YAML key silently
# overriding another via a smuggled newline + "key: value" line, or a hard parse crash
# on an innocuous "note: Meeting: 3:30pm"-shaped value -- all reproduced against this
# exact transform. Instead: parse the RAW block (the bytes the pipeline author actually
# wrote, which are already known-good YAML) into the list-of-maps shape FIRST, then
# substitute each already-parsed scalar VALUE individually and reinject it as a YAML
# string node via yq's strenv() -- never re-tokenized as YAML syntax, no matter what a
# runtime secret happens to contain.
parse_flat_yaml_block() {
  local raw="$1" out_file="$2"
  # Strip ALL whitespace (not just spaces) before testing for emptiness: a value that's
  # nothing but blank/newline characters would otherwise fall through to yq on a
  # blank/null YAML document, which is not guaranteed to degrade to an empty list --
  # under `set -e` that could abort this whole script instead of just meaning "no inputs".
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
    # Already Bitrise's own list-of-single-key-maps shape -- e.g. pasted straight out of
    # a real bitrise.yml, leading "-" and all. Pass it through unchanged rather than force
    # it through the flat-map-only to_entries transform below, which would silently
    # misparse it into numeric "0"/"1" keys with no error at all (ux-north-star review,
    # Finding #1). Both shapes are accepted for exactly this reason -- Bitrise's own
    # syntax verbatim, or this orb's simpler flat shorthand.
    printf '%s\n' "${raw}" > "${list_file}"
  elif [[ "${shape}" == "!!map" ]]; then
    printf '%s\n' "${raw}" | yq eval 'to_entries | map({(.key): .value})' - > "${list_file}"
  else
    echo "bitrise-orb: 'inputs'/'outputs' must be either flat \"key: value\" pairs or Bitrise's own list-of-maps \"- key: value\" shape -- got a bare ${shape#!!} value:" >&2
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

INPUTS_LIST_FILE="${WORK_DIR}/.inputs.list.yml"
OUTPUTS_LIST_FILE="${WORK_DIR}/.outputs.list.yml"
parse_flat_yaml_block "${ORB_VAL_INPUTS}" "${INPUTS_LIST_FILE}"
parse_flat_yaml_block "${ORB_VAL_OUTPUTS}" "${OUTPUTS_LIST_FILE}"

# Build the single Step block, keyed by the user's verbatim step reference string.
# Supports all three reference grammars this orb passes through untouched (Locked
# Decision #4): "<step-id>@<version>" (against step-lib-source), "git::<url>@<ref>", and
# "path::<local-path>". yq's strenv()/load() let us build this as a real YAML document
# node instead of string-concatenating a value that may contain "::"/"@"/quotes -- yq
# handles whatever quoting the emitted YAML key actually needs.
STEP_BLOCK_FILE="${WORK_DIR}/.step-block.yml"
ORB_VAL_ID="${ORB_VAL_ID}" INPUTS_LIST_FILE="${INPUTS_LIST_FILE}" \
  yq eval -n '{(strenv(ORB_VAL_ID)): {"inputs": load(strenv(INPUTS_LIST_FILE))}}' \
  > "${STEP_BLOCK_FILE}"

if [[ "$(yq eval 'length' "${OUTPUTS_LIST_FILE}")" != "0" ]]; then
  # Bitrise's own config-level output aliasing (`outputs: - ORIGINAL_KEY: alias`).
  # Passing the user's block through gives them this mechanism for free -- Locked
  # Decision #4's last bullet explicitly asks this orb to expose it, not reimplement it.
  ORB_VAL_ID="${ORB_VAL_ID}" OUTPUTS_LIST_FILE="${OUTPUTS_LIST_FILE}" \
    yq eval -i '.[strenv(ORB_VAL_ID)].outputs = load(strenv(OUTPUTS_LIST_FILE))' "${STEP_BLOCK_FILE}"
fi

# Assemble the full, minimal, throwaway bitrise.yml. Deliberately omits:
#   - `meta:` (the bitrise.io: stack: block is a hosted-platform concern; this orb's
#     executor choice is the equivalent -- see this project's spike report's Stack
#     discussion and this repo's README executor-mapping table)
#   - git-clone / activate-ssh-key (CircleCI's own `checkout` already did this)
#   - deploy-to-bitrise-io (CircleCI's store_artifacts/store_test_results on
#     $BITRISE_DEPLOY_DIR are the equivalent -- see map-env.sh and the README)
STEP_LIB_SOURCE="${ORB_VAL_STEP_LIB_SOURCE}" WORKFLOW_NAME="${ORB_VAL_WORKFLOW_NAME}" \
  STEP_BLOCK_FILE="${STEP_BLOCK_FILE}" \
  yq eval -n '{
    "format_version": "13",
    "default_step_lib_source": strenv(STEP_LIB_SOURCE),
    "workflows": {
      (strenv(WORKFLOW_NAME)): {
        "steps": [load(strenv(STEP_BLOCK_FILE))]
      }
    }
  }' > "${ORB_VAL_CONFIG_PATH}"

echo "Synthesized bitrise.yml at ${ORB_VAL_CONFIG_PATH}."

# SECURITY (security review, Finding #3 -- HIGH): this used to unconditionally `cat` the
# synthesized file, which by this point contains every "$SECRET"-style inputs/outputs
# reference already resolved to its real value via `circleci env subst` above --
# printing it relies entirely on that value being an exact-match, CircleCI-registered
# secret for log masking to catch it; anything else (an API key embedded in a larger
# string, a derived value) leaked in full, on every run. Gated behind an explicit
# opt-in debug parameter instead, per the review's own suggested fix.
orb_bool_is_true() {
  case "${1:-}" in
    1 | true | True | TRUE) return 0 ;;
    *) return 1 ;;
  esac
}
if orb_bool_is_true "${ORB_VAL_DEBUG_DUMP_CONFIG:-}"; then
  echo "debug-dump-config is true -- printing the fully-resolved file (may contain resolved secrets):"
  cat "${ORB_VAL_CONFIG_PATH}"
fi
