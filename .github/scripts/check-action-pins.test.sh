#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guard="$root/.github/scripts/check-action-pins.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/pinned" "$tmp/mutable"

cat >"$tmp/pinned/workflow.yml" <<'YAML'
name: pinned
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4.4.0
      - uses: ./.github/actions/local
YAML

cat >"$tmp/mutable/workflow.yml" <<'YAML'
name: mutable
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
YAML

bash "$guard" "$tmp/pinned"

set +e
output=$(bash "$guard" "$tmp/mutable" 2>&1)
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "self-test failed: guard accepted actions/checkout@v4" >&2
  exit 1
fi

if [[ "$output" != *"Action must be pinned"* ]]; then
  echo "self-test failed: guard failed without the expected error" >&2
  echo "$output" >&2
  exit 1
fi

echo "action-pin guard self-test passed: mutable ref rejected"
