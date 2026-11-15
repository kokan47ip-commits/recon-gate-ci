#!/usr/bin/env bash
# Repeatable installation tests for recon-gate-bootstrap.sh.
#
# Usage: bash tests/recon-installer.test.sh [path-to-installer]
#
# Covers package.json shapes (multiline, single-line, empty, CRLF, BOM,
# duplicate top-level "scripts" keys) and permission preservation across
# modes 664/660/2640 and umasks 022/077/002. Exits non-zero on any failure.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER=${1:-"$ROOT/recon-gate-bootstrap.sh"}
if [ ! -f "$INSTALLER" ]; then
  echo "error: installer not found: $INSTALLER" >&2
  exit 1
fi
INSTALLER=$(cd "$(dirname "$INSTALLER")" && pwd)/$(basename "$INSTALLER")

command -v node >/dev/null 2>&1 || { echo "error: node is required" >&2; exit 1; }
command -v stat >/dev/null 2>&1 || { echo "error: stat is required" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/recon-installer.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$*"; }

new_project() {
  local name=$1
  local dir="$WORK/$name"
  mkdir -p "$dir/prisma"
  printf '%s\n' "$dir"
}

run_install() {
  local dir=$1 log=$2
  ( cd "$dir" && bash "$INSTALLER" >"$log" 2>&1 )
}

check_json() {
  local label=$1 file=$2
  if node - "$file" <<'NODE'
const fs = require("fs");
const raw = fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, "");
const p = JSON.parse(raw);
if (p.scripts["recon:preview"] !== "node scripts/recon-preview.mjs") process.exit(1);
NODE
  then ok "$label: valid JSON with recon:preview"
  else bad "$label: JSON/script check failed"; return 1
  fi
}

# --- multiline ---------------------------------------------------------------
d=$(new_project multiline)
cat >"$d/package.json" <<'JSON'
{
  "name": "multiline",
  "config": {
    "scripts": {
      "nested": "echo nested"
    }
  },
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "jest"
  },
  "private": true
}
JSON
cp "$d/package.json" "$d/before.json"
if run_install "$d" "$d/install.log"; then
  ok "multiline: installer exit 0"
  check_json "multiline" "$d/package.json"
  if node - "$d/before.json" "$d/package.json" <<'NODE'
const fs = require("fs");
const before = fs.readFileSync(process.argv[2], "utf8");
const after = fs.readFileSync(process.argv[3], "utf8");
const line = '    "recon:preview": "node scripts/recon-preview.mjs",\n';
if (!after.includes(line)) process.exit(1);
if (after.replace(line, "") !== before) process.exit(1);
const p = JSON.parse(after);
if (p.config.scripts.nested !== "echo nested") process.exit(1);
if (Object.keys(p.scripts).join(",") !== "recon:preview,dev,build,test") process.exit(1);
NODE
  then ok "multiline: only one line inserted; nested/scripts/order untouched"
  else bad "multiline: formatting or byte-preservation check failed"
  fi
else
  bad "multiline: installer failed"; sed 's/^/    /' "$d/install.log"
fi

# --- single-line -------------------------------------------------------------
d=$(new_project single-line)
cat >"$d/package.json" <<'JSON'
{
  "name": "single",
  "scripts": { "dev": "next dev", "test": "jest" },
  "private": true
}
JSON
if run_install "$d" "$d/install.log"; then
  check_json "single-line" "$d/package.json"
  if grep -q '"scripts": { "recon:preview": "node scripts/recon-preview.mjs", "dev": "next dev", "test": "jest" }' "$d/package.json"; then
    ok "single-line: remains on one line"
  else
    bad "single-line: object was split across lines"
  fi
else
  bad "single-line: installer failed"; sed 's/^/    /' "$d/install.log"
fi

# --- empty -------------------------------------------------------------------
d=$(new_project empty)
cat >"$d/package.json" <<'JSON'
{
  "name": "empty",
  "scripts": {
  },
  "private": true
}
JSON
if run_install "$d" "$d/install.log"; then
  check_json "empty" "$d/package.json"
  if node - "$d/package.json" <<'NODE'
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (Object.keys(p.scripts).length !== 1) process.exit(1);
NODE
  then ok "empty: sole script, valid JSON, no trailing comma"
  else bad "empty: unexpected scripts content"
  fi
else
  bad "empty: installer failed"; sed 's/^/    /' "$d/install.log"
fi

# --- CRLF --------------------------------------------------------------------
d=$(new_project crlf)
printf '{\r\n  "name": "crlf",\r\n  "scripts": {\r\n    "dev": "next dev"\r\n  }\r\n}\r\n' >"$d/package.json"
if run_install "$d" "$d/install.log"; then
  check_json "CRLF" "$d/package.json"
  if node - "$d/package.json" <<'NODE'
const fs = require("fs");
const s = fs.readFileSync(process.argv[2], "utf8");
if (/(?<!\r)\n/.test(s)) process.exit(1);
NODE
  then ok "CRLF: no bare LF introduced"
  else bad "CRLF: line endings changed"
  fi
else
  bad "CRLF: installer failed"; sed 's/^/    /' "$d/install.log"
fi

# --- BOM ---------------------------------------------------------------------
d=$(new_project bom)
printf '\xEF\xBB\xBF{\n  "name": "bom",\n  "scripts": {\n    "dev": "next dev"\n  }\n}\n' >"$d/package.json"
if run_install "$d" "$d/install.log"; then
  check_json "BOM" "$d/package.json"
  if [ "$(head -c 3 "$d/package.json" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    ok "BOM: UTF-8 BOM preserved"
  else
    bad "BOM: BOM was dropped"
  fi
else
  bad "BOM: installer failed"; sed 's/^/    /' "$d/install.log"
fi

# --- duplicate top-level "scripts" keys --------------------------------------
d=$(new_project duplicate)
cat >"$d/package.json" <<'JSON'
{
  "name": "duplicate",
  "scripts": {
    "a": "echo a"
  },
  "scripts": {
    "b": "echo b"
  }
}
JSON
cp "$d/package.json" "$d/before.json"
if run_install "$d" "$d/install.log"; then
  bad "duplicate: installer should have failed"
else
  ok "duplicate: installer refused"
  if grep -q 'has 2 top-level "scripts" keys' "$d/install.log"; then
    ok "duplicate: error reports the count"
  else
    bad "duplicate: error does not report the count"
  fi
  if cmp -s "$d/before.json" "$d/package.json"; then
    ok "duplicate: package.json unchanged"
  else
    bad "duplicate: package.json was modified"
  fi
fi

# --- permissions under umask -------------------------------------------------
for spec in "664 022" "660 077" "2640 002"; do
  set -- $spec
  mode=$1 umask_value=$2
  d=$(new_project "mode-$mode-$umask_value")
  cat >"$d/package.json" <<'JSON'
{
  "name": "mode-test",
  "scripts": {
    "dev": "next dev"
  }
}
JSON
  chmod "$mode" "$d/package.json"
  before_mode=$(stat -c '%a' "$d/package.json")
  if ( cd "$d" && umask "$umask_value" && bash "$INSTALLER" >"$d/install.log" 2>&1 ); then
    after_mode=$(stat -c '%a' "$d/package.json")
    if [ "$before_mode" = "$after_mode" ]; then
      ok "mode $mode/umask $umask_value: preserved $after_mode"
    else
      bad "mode $mode/umask $umask_value: became $after_mode"
    fi
    if find "$d" -maxdepth 1 -name 'package.json.recon-*.tmp' | grep -q .; then
      bad "mode $mode/umask $umask_value: temp file left behind"
    else
      ok "mode $mode/umask $umask_value: no temp file"
    fi
    check_json "mode $mode/umask $umask_value" "$d/package.json"
  else
    bad "mode $mode/umask $umask_value: installer failed"; sed 's/^/    /' "$d/install.log"
  fi
done

# --- idempotency -------------------------------------------------------------
d=$(new_project idempotent)
cat >"$d/package.json" <<'JSON'
{
  "name": "idempotent",
  "scripts": {
    "dev": "next dev"
  }
}
JSON
if run_install "$d" "$d/first.log"; then
  sum1=$(sha256sum "$d/package.json" | cut -d' ' -f1)
  if run_install "$d" "$d/second.log"; then
    sum2=$(sha256sum "$d/package.json" | cut -d' ' -f1)
    if [ "$sum1" = "$sum2" ] && grep -q 'already set (unchanged)' "$d/second.log"; then
      ok "idempotent: second run leaves file byte-identical"
    else
      bad "idempotent: second run changed the file"
    fi
  else
    bad "idempotent: second run failed"; sed 's/^/    /' "$d/second.log"
  fi
else
  bad "idempotent: first run failed"; sed 's/^/    /' "$d/first.log"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
