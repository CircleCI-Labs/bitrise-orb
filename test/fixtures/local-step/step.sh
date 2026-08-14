#!/usr/bin/env bash
set -euo pipefail

envman add --key LOCAL_STEP_OUT --value "produced_by_local_step"
echo "local-step: added LOCAL_STEP_OUT via envman"
