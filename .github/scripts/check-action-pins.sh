#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <workflow-directory>" >&2
  exit 2
fi

workflow_dir=$1
if [[ ! -d "$workflow_dir" ]]; then
  echo "error: workflow directory not found: $workflow_dir" >&2
  exit 2
fi

status=0
while IFS=: read -r file line_no content; do
  ref="${content#*uses:}"
  ref="${ref%%#*}"
  ref="$(printf '%s' "$ref" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$ref" in
    ./*) continue ;;
  esac
  if [[ ! "$ref" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
    echo "::error file=${file},line=${line_no}::Action must be pinned to a full 40-character commit SHA: ${ref}"
    status=1
  fi
done < <(grep -RInE '^[[:space:]]*(-[[:space:]]*)?uses:' "$workflow_dir" --include='*.yml' --include='*.yaml' || true)

exit "$status"
