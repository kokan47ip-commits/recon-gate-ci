#!/usr/bin/env bash
# Repeatable end-to-end test for scripts/recon-preview.sql on real PostgreSQL.
#
# Requires PostgreSQL server binaries and a psql client. Point the test at them:
#
#   PG_BINDIR=/path/to/postgres/bin PSQL=/path/to/psql \
#     bash tests/recon-gate-postgres.test.sh
#
# If omitted, PG_BINDIR is taken from `pg_config --bindir` and PSQL from PATH.
# The test creates a temporary cluster/databases/project, runs the installer,
# then asserts:
#   - all-green fixture: exit 0, PASSED, A7 notice present;
#   - A0-broken fixture: exit 3, A5-A12 skipped, both A0 names reported,
#     and no A7 notice / Boolean error / raw mapped-table error.
#
# Set RECON_KEEP=1 to keep the temporary directory for inspection.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
INSTALLER="$ROOT/recon-gate-bootstrap.sh"
SCHEMA="$ROOT/tests/fixtures/recon-min-schema.sql"
SEED="$ROOT/tests/fixtures/recon-min-seed.sql"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
ok()  { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$*"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$*"; }

[ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
[ -f "$SCHEMA" ] || die "schema fixture not found: $SCHEMA"
[ -f "$SEED" ] || die "seed fixture not found: $SEED"
command -v node >/dev/null 2>&1 || die "node is required"
command -v npm >/dev/null 2>&1 || die "npm is required"
[ "$(id -u)" -ne 0 ] || die "initdb refuses to run as root; run this test as a normal user"

PG_BINDIR=${PG_BINDIR:-}
if [ -z "$PG_BINDIR" ] && command -v pg_config >/dev/null 2>&1; then
  PG_BINDIR=$(pg_config --bindir)
fi
[ -n "$PG_BINDIR" ] || die "set PG_BINDIR to the PostgreSQL bin directory"
for bin in initdb pg_ctl postgres; do
  [ -x "$PG_BINDIR/$bin" ] || die "missing executable: $PG_BINDIR/$bin"
done

PSQL=${PSQL:-$(command -v psql || true)}
[ -n "$PSQL" ] || die "set PSQL to a psql client binary"
if [ ! -x "$PSQL" ]; then
  resolved=$(command -v "$PSQL" 2>/dev/null || true)
  [ -n "$resolved" ] || die "psql not executable: $PSQL"
  PSQL=$resolved
fi
PSQL=$(cd "$(dirname "$PSQL")" && pwd)/$(basename "$PSQL")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/recon-pg.XXXXXX")
DATA="$TMP/data"
SOCK="$TMP/socket"
PROJ="$TMP/project"
PORT=${PGPORT:-$(node -e 'const s=require("net").createServer();s.listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')}
PASS=0
FAIL=0

cleanup() {
  if [ -d "$DATA" ]; then
    "$PG_BINDIR/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true
  fi
  if [ "${RECON_KEEP:-0}" = "1" ]; then
    printf 'kept temporary files: %s\n' "$TMP"
  else
    rm -rf "$TMP" || true
  fi
}
trap cleanup EXIT

mkdir -p "$SOCK" "$PROJ/prisma" "$TMP/bin"
cat >"$TMP/bin/psql" <<SH
#!/bin/sh
exec "$PSQL" "\$@"
SH
chmod +x "$TMP/bin/psql"

"$PG_BINDIR/initdb" -D "$DATA" -U postgres -A trust --no-locale -E UTF8 >"$TMP/initdb.log" 2>&1 \
  || { cat "$TMP/initdb.log"; die "initdb failed"; }
"$PG_BINDIR/pg_ctl" -D "$DATA" -o "-p $PORT -k $SOCK -h 127.0.0.1" -l "$TMP/postgres.log" -w start >/dev/null \
  || { cat "$TMP/postgres.log"; die "PostgreSQL failed to start"; }

psql_cmd() {
  "$PSQL" -h 127.0.0.1 -p "$PORT" -U postgres -v ON_ERROR_STOP=1 "$@"
}

psql_cmd -d postgres \
  -c 'CREATE DATABASE recon_pass;' \
  -c 'CREATE DATABASE recon_fail;' \
  -c 'CREATE DATABASE recon_a2;' \
  -c 'CREATE DATABASE recon_a5;' \
  -c 'CREATE DATABASE recon_a11;' \
  -c 'CREATE DATABASE recon_a12;' >"$TMP/create.log" 2>&1 \
  || { cat "$TMP/create.log"; die "could not create test databases"; }

for db in recon_pass recon_fail recon_a2 recon_a5 recon_a11 recon_a12; do
  psql_cmd -d "$db" -f "$SCHEMA" -f "$SEED" >"$TMP/schema-$db.log" 2>&1 \
    || { cat "$TMP/schema-$db.log"; die "could not load schema/seed into $db"; }
done

psql_cmd -d recon_fail -c 'ALTER TABLE "Customer" DROP COLUMN "customerNo";' -c 'DROP TABLE "Quotation";' >"$TMP/break-a0.log" 2>&1 \
  || { cat "$TMP/break-a0.log"; die "could not introduce A0 failures"; }

# A2: two no-entry ADJUSTMENT vouchers with opposing imbalances. A2 fails both;
# A3 ignores them (no entries) and A4 still balances globally. The matching
# voucher:ADJUSTMENT sequence row keeps A11 clean.
psql_cmd -d recon_a2 \
  -c 'INSERT INTO "Voucher"(id, "voucherNo", "voucherType", "totalDebit", "totalCredit", status) VALUES ('\''voucher-a2-plus'\'', '\''VCH-ADJ-0001'\'', '\''ADJUSTMENT'\'', 100, 200, '\''POSTED'\''), ('\''voucher-a2-minus'\'', '\''VCH-ADJ-0002'\'', '\''ADJUSTMENT'\'', 200, 100, '\''POSTED'\'');' \
  -c 'INSERT INTO "Sequence"("key", prefix, "nextNo") VALUES ('\''voucher:ADJUSTMENT'\'', '\''VCH-ADJ-'\'', 3);' >"$TMP/break-a2.log" 2>&1 \
  || { cat "$TMP/break-a2.log"; die "could not build A2 fixture"; }

# A5: amendment is 200 in the ledger but the invoice still says 1100, so the
# original 1000 + live 200 no longer equals the invoice total.
psql_cmd -d recon_a5 \
  -c 'UPDATE "Voucher" SET "totalDebit" = 200, "totalCredit" = 200 WHERE id = '\''voucher-amendment'\'';' \
  -c 'UPDATE "VoucherEntry" SET debit = 200, credit = 200 WHERE id = '\''ve-amendment-1'\'';' >"$TMP/break-a5.log" 2>&1 \
  || { cat "$TMP/break-a5.log"; die "could not build A5 fixture"; }

# A11: invoice sequence nextNo is one ahead of the highest document number.
psql_cmd -d recon_a11 \
  -c 'UPDATE "Sequence" SET "nextNo" = 3 WHERE "key" = '\''invoice'\'';' >"$TMP/break-a11.log" 2>&1 \
  || { cat "$TMP/break-a11.log"; die "could not build A11 fixture"; }

# A12: a second quotation reuses QTN-0001.
psql_cmd -d recon_a12 \
  -c 'INSERT INTO "Quotation"(id, "quoteNo") VALUES ('\''quotation-2'\'', '\''QTN-0001'\'');' >"$TMP/break-a12.log" 2>&1 \
  || { cat "$TMP/break-a12.log"; die "could not build A12 fixture"; }

printf '{\n  "name": "recon-gate-postgres-test",\n  "private": true,\n  "scripts": {\n    "dev": "next dev"\n  }\n}\n' >"$PROJ/package.json"
if ! ( cd "$PROJ" && bash "$INSTALLER" >"$TMP/install.log" 2>&1 ); then
  cat "$TMP/install.log"
  die "installer failed"
fi
grep -q 'a0_failed' "$PROJ/scripts/recon-preview.sql" \
  || die "generated SQL does not use the boolean a0_failed variable"
ok "installer generated SQL with boolean a0_failed guard"

run_gate() {
  local db=$1 log=$2
  ( cd "$PROJ" && \
    DIRECT_URL="postgresql://postgres@127.0.0.1:$PORT/$db" \
    PATH="$TMP/bin:$PATH" \
    npm run --silent recon:preview >"$log" 2>&1 )
}

expect_exit() {
  local label=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then ok "$label: exit $got"; else bad "$label: expected exit $want, got $got"; fi
}
expect_contains() {
  local label=$1 pattern=$2 file=$3
  if grep -Fq -- "$pattern" "$file"; then ok "$label"; else bad "$label: missing [$pattern]"; fi
}
expect_absent() {
  local label=$1 pattern=$2 file=$3
  if grep -Fq -- "$pattern" "$file"; then bad "$label: found [$pattern]"; else ok "$label"; fi
}

# --- all-green path ----------------------------------------------------------
if run_gate recon_pass "$TMP/pass.log"; then PASS_EXIT=0; else PASS_EXIT=$?; fi
expect_exit "pass" 0 "$PASS_EXIT"
expect_contains "pass: gate passed" 'Preview reconciliation PASSED: all checks A0-A12 green.' "$TMP/pass.log"
expect_contains "pass: A7 ran" 'A7 info: 1 live amendment voucher(s)' "$TMP/pass.log"
expect_absent "pass: A0 skip not taken" 'A0 failed: skipping A5-A12' "$TMP/pass.log"
expect_absent "pass: no Boolean error" 'Boolean expected' "$TMP/pass.log"

# --- A0-skip path ------------------------------------------------------------
if run_gate recon_fail "$TMP/fail.log"; then FAIL_EXIT=0; else FAIL_EXIT=$?; fi
expect_exit "A0-skip" 3 "$FAIL_EXIT"
expect_contains "A0-skip: skip message" 'A0 failed: skipping A5-A12 (document checks depend on the mapped tables)' "$TMP/fail.log"
expect_contains "A0-skip: Customer reported" '"Customer"."customerNo"' "$TMP/fail.log"
expect_contains "A0-skip: Quotation reported" '"Quotation"."quoteNo"' "$TMP/fail.log"
expect_contains "A0-skip: final failure" 'Preview reconciliation FAILED: 2 issue(s)' "$TMP/fail.log"
expect_absent "A0-skip: A5-A12 did not run" 'A7 info' "$TMP/fail.log"
expect_absent "A0-skip: no Boolean error" 'Boolean expected' "$TMP/fail.log"
expect_absent "A0-skip: no raw Quotation relation error" 'relation "Quotation" does not exist' "$TMP/fail.log"
expect_absent "A0-skip: no raw customerNo column error" 'column "customerNo" does not exist' "$TMP/fail.log"

A0_LINES=$(grep -c '^A0:' "$TMP/fail.log" || true)
if [ "$A0_LINES" = "2" ]; then ok "A0-skip: exactly two A0 details"; else bad "A0-skip: expected 2 A0 details, got $A0_LINES"; fi

# --- targeted negative fixtures ---------------------------------------------
run_negative() {
  local label=$1 db=$2 pattern=$3 expected=$4
  local log="$TMP/$label.log"
  local code
  if run_gate "$db" "$log"; then code=0; else code=$?; fi
  expect_exit "$label" 3 "$code"
  expect_contains "$label: final failure" "Preview reconciliation FAILED: $expected issue(s)" "$log"
  expect_contains "$label: expected check" "$pattern" "$log"
  expect_absent "$label: no Boolean error" 'Boolean expected' "$log"
}

run_negative "voucher-imbalance" recon_a2 'A2:' 2
run_negative "invoice-amendment-mismatch" recon_a5 'A5:' 1
run_negative "sequence-drift" recon_a11 'A11:' 1
run_negative "duplicate-numbers" recon_a12 'A12:' 1

expect_contains "sequence-drift: invoice detail" 'sequence invoice' "$TMP/sequence-drift.log"
expect_contains "duplicate-numbers: quotation detail" 'Quotation duplicate QTN-0001' "$TMP/duplicate-numbers.log"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '\n--- pass.log ---\n'; tail -40 "$TMP/pass.log" 2>/dev/null || true
  printf '\n--- fail.log ---\n'; tail -40 "$TMP/fail.log" 2>/dev/null || true
  for log in "$TMP/voucher-imbalance.log" "$TMP/invoice-amendment-mismatch.log" "$TMP/sequence-drift.log" "$TMP/duplicate-numbers.log"; do
    [ -f "$log" ] || continue
    printf '\n--- %s ---\n' "$(basename "$log")"; tail -30 "$log" || true
  done
  exit 1
fi
