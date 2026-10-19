#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STAGE="${1:-}"

case "${STAGE}" in
  proof|01|1)
    STAGE_NAME="proof"
    CONFIG_NAME="concept.toml"
    ;;
  pilot|02|2)
    STAGE_NAME="pilot"
    CONFIG_NAME="ladder_02_pilot.toml"
    ;;
  medium|03|3)
    STAGE_NAME="medium"
    CONFIG_NAME="ladder_03_medium.toml"
    ;;
  preflight|04|4)
    STAGE_NAME="preflight"
    CONFIG_NAME="ladder_04_preflight.toml"
    ;;
  full|05|5)
    STAGE_NAME="full"
    CONFIG_NAME="ladder_05_full.toml"
    ;;
  *)
    echo "Usage: $0 {proof|pilot|medium|preflight|full} [run-id]" >&2
    exit 2
    ;;
esac

RUN_ID="${2:-ladder-${STAGE_NAME}-$(date -u +%Y%m%dT%H%M%SZ)}"

cd "${PROJECT_ROOT}"
export PYTHONPATH="${PROJECT_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
export MPLCONFIGDIR="${PROJECT_ROOT}/artifacts/.mplconfig"

python3 -m panama_uav pipeline \
  --config "${PROJECT_ROOT}/configs/${CONFIG_NAME}" \
  --profile full \
  --run-id "${RUN_ID}" \
  --resume
