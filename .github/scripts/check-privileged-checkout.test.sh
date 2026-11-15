#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
guard="$root/.github/scripts/check-privileged-checkout.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/normal" "$tmp/missing" "$tmp/decided"

cat >"$tmp/normal/workflow.yml" <<'YAML'
name: normal
on:
  push:
  pull_request:
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

cat >"$tmp/missing/workflow.yml" <<'YAML'
name: missing-decision
on:
  pull_request_target:
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
YAML

cat >"$tmp/decided/workflow.yml" <<'YAML'
name: decided
on:
  workflow_run:
    workflows: ["recon-gate"]
    types: [completed]
jobs:
  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          allow-unsafe-pr-checkout: false
YAML

bash "$guard" "$tmp/normal"
bash "$guard" "$tmp/decided"

set +e
output=$(bash "$guard" "$tmp/missing" 2>&1)
status=$?
set -e

if [[ $status -eq 0 ]]; then
  echo "self-test failed: privileged workflow without a decision was accepted" >&2
  exit 1
fi

if [[ "$output" != *"allow-unsafe-pr-checkout"* ]]; then
  echo "self-test failed: guard failed without the expected message" >&2
  echo "$output" >&2
  exit 1
fi

echo "privileged checkout guard self-test passed: missing decision rejected"
