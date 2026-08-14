#!/bin/bash
set -euo pipefail

# Parameters, via `environment:`:
#   ORB_VAL_CONFIG_PATH    -- the bitrise.yml to run
#   ORB_VAL_WORKFLOW_NAME  -- the workflow inside it to run
#
# Deliberately thin (Locked Decision #5, "no failure wrapping, no assertion layer"): no
# retries, no swallowed exit codes, no pre-validation of the Step's own inputs. If the
# Step fails, `bitrise run` exits non-zero, its own stderr is already on the console
# unmodified, and this `run` step fails the job exactly the way a native CircleCI `run`
# step failing would.

if [[ ! -f "${ORB_VAL_CONFIG_PATH}" ]]; then
  echo "bitrise-orb: no bitrise.yml found at ${ORB_VAL_CONFIG_PATH}." >&2
  echo "This command expects create-config to have already written one earlier in this job." >&2
  exit 1
fi

# `--ci` (before the subcommand) suppresses interactive prompts, e.g. the `deps:`
# apt-get confirmation prompt some Steps trigger -- confirmed against `bitrise run
# --help`'s own flag documentation.
echo "Running: bitrise --ci run \"${ORB_VAL_WORKFLOW_NAME}\" --config \"${ORB_VAL_CONFIG_PATH}\""
bitrise --ci run "${ORB_VAL_WORKFLOW_NAME}" --config "${ORB_VAL_CONFIG_PATH}"
