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

# Locked Decision #8: resolve "$MY_SECRET"-style references inside the user's flat
# inputs/outputs blocks via CircleCI's own built-in `circleci env subst`, so a secret
# value never has to be written into the packed orb config -- only into this job's
# runtime environment. This is the exact, documented mechanism (not this orb's own
# resolution logic) per the orb-best-practices spec, section 4.
SUBST_INPUTS="$(circleci env subst "${ORB_VAL_INPUTS}")"
SUBST_OUTPUTS="$(circleci env subst "${ORB_VAL_OUTPUTS}")"

# Bitrise's `inputs:`/`outputs:` in a bitrise.yml Step block are a LIST of single-key
# maps, not a plain map -- verified directly against a real activated step.yml (see the
# required-reading spike report, and the hands-on CLI spike report section 7). Converting
# the user's flat "key: value" block into that shape needs a real YAML parse, not a
# text-based re-indent: a value may be a multi-line block scalar (e.g. a `content: |`
# script body), and re-indenting that correctly by hand means redoing what a YAML
# emitter already does for free. yq's `to_entries`/`map` (mirroring jq) do exactly this
# transform and re-emit correctly-indented YAML regardless of value shape.
flat_to_list() {
  local flat="$1" out_file="$2"
  # Strip ALL whitespace (not just spaces) before testing for emptiness: a value that's
  # nothing but blank/newline characters would otherwise fall through to `yq ... to_entries`
  # on a blank/null YAML document, which is not guaranteed to degrade to an empty list --
  # under `set -e` that could abort this whole script instead of just meaning "no inputs".
  local flat_stripped="${flat//[$' \t\n']/}"
  if [[ -z "${flat_stripped}" ]]; then
    echo '[]' >"${out_file}"
  else
    printf '%s\n' "${flat}" | yq eval 'to_entries | map({(.key): .value})' - >"${out_file}"
  fi
}

INPUTS_LIST_FILE="${WORK_DIR}/.inputs.list.yml"
OUTPUTS_LIST_FILE="${WORK_DIR}/.outputs.list.yml"
flat_to_list "${SUBST_INPUTS}" "${INPUTS_LIST_FILE}"
flat_to_list "${SUBST_OUTPUTS}" "${OUTPUTS_LIST_FILE}"

# Build the single Step block, keyed by the user's verbatim step reference string.
# Supports all three reference grammars this orb passes through untouched (Locked
# Decision #4): "<step-id>@<version>" (against step-lib-source), "git::<url>@<ref>", and
# "path::<local-path>". yq's strenv()/load() let us build this as a real YAML document
# node instead of string-concatenating a value that may contain "::"/"@"/quotes -- yq
# handles whatever quoting the emitted YAML key actually needs.
STEP_BLOCK_FILE="${WORK_DIR}/.step-block.yml"
ORB_VAL_ID="${ORB_VAL_ID}" INPUTS_LIST_FILE="${INPUTS_LIST_FILE}" \
  yq eval -n '{(strenv(ORB_VAL_ID)): {"inputs": load(strenv(INPUTS_LIST_FILE))}}' \
  >"${STEP_BLOCK_FILE}"

if [[ "$(yq eval 'length' "${OUTPUTS_LIST_FILE}")" != "0" ]]; then
  # Bitrise's own config-level output aliasing (`outputs: - ORIGINAL_KEY: alias`).
  # Passing the user's block through gives them this mechanism for free -- Locked
  # Decision #4's last bullet explicitly asks this orb to expose it, not reimplement it.
  ORB_VAL_ID="${ORB_VAL_ID}" OUTPUTS_LIST_FILE="${OUTPUTS_LIST_FILE}" \
    yq eval -i '.[strenv(ORB_VAL_ID)].outputs = load(strenv(OUTPUTS_LIST_FILE))' "${STEP_BLOCK_FILE}"
fi

# Assemble the full, minimal, throwaway bitrise.yml. Deliberately omits:
#   - `meta:` (the bitrise.io: stack: block is a hosted-platform concern; this orb's
#     executor choice is the equivalent -- see the required-reading spike report's
#     Stack discussion and this repo's README executor-mapping table)
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
  }' >"${ORB_VAL_CONFIG_PATH}"

echo "Synthesized bitrise.yml at ${ORB_VAL_CONFIG_PATH}:"
cat "${ORB_VAL_CONFIG_PATH}"
