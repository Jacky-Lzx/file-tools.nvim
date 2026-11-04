#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export NVIM_LOG_FILE="${TMPDIR:-/tmp}/file-tools-tests.log"
export XDG_STATE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/file-tools-state.XXXXXX")"
trap 'rm -rf "$XDG_STATE_HOME"' EXIT
for suite in core tree icons theme; do
  nvim --headless -u NONE -i NONE -n -l "tests/$suite.lua"
done
