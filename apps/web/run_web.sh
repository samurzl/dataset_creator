#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-7860}"

python -m uvicorn web_dataset_creator.main:app --host "$HOST" --port "$PORT"

