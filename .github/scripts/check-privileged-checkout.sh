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

while IFS= read -r -d '' file; do
  if ! awk '
    /^[[:space:]]*(pull_request_target|workflow_run)[[:space:]]*:/ { found = 1 }
    /^[[:space:]]*on:.*(pull_request_target|workflow_run)/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file"; then
    continue
  fi

  if ! awk -v file="$file" '
    function finish() {
      if (in_checkout && !decided) {
        printf "::error file=%s,line=%d::Privileged workflow checkout must set allow-unsafe-pr-checkout (true or false)\n", file, checkout_line
        failed = 1
      }
      in_checkout = 0
      decided = 0
    }
    BEGIN { in_checkout = 0; decided = 0; failed = 0 }
    {
      match($0, /^[ ]*/)
      indent = RLENGTH

      if (in_checkout && $0 !~ /^[ ]*$/ && $0 !~ /^[ ]*#/ && indent < checkout_indent) finish()
      if (in_checkout && indent <= checkout_indent && $0 ~ /^[ ]*-[ ]/) finish()

      if ($0 ~ /^[ ]*(-[ ]*)?uses:[ ]*actions\/checkout@/) {
        if (in_checkout) finish()
        in_checkout = 1
        decided = 0
        checkout_line = NR
        checkout_indent = indent
        next
      }

      if (in_checkout && $0 ~ /^[ ]*allow-unsafe-pr-checkout:[ ]*(true|false)([ ]*(#.*)?)?$/) {
        decided = 1
      }
    }
    END { if (in_checkout) finish(); exit(failed ? 1 : 0) }
  ' "$file"; then
    status=1
  fi
done < <(find "$workflow_dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)

exit "$status"
