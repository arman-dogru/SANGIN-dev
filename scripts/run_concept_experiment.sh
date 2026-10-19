#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
RUN_ID="${1:-concept-$(date -u +%Y%m%dT%H%M%SZ)}"

cd "${PROJECT_ROOT}"
export PYTHONPATH="${PROJECT_ROOT}/src${PYTHONPATH:+:${PYTHONPATH}}"
export MPLCONFIGDIR="${PROJECT_ROOT}/artifacts/.mplconfig"

python3 -m panama_uav pipeline \
  --config "${PROJECT_ROOT}/configs/concept.toml" \
  --profile full \
  --run-id "${RUN_ID}" \
  --resume
