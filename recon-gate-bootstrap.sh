#!/usr/bin/env bash
# Self-contained installer for the preview reconciliation gate.
# Run from the project root:  bash recon-gate-bootstrap.sh
# Creates:
#   scripts/recon-preview.sql
#   scripts/recon-preview.mjs
# Adds npm script: recon:preview
# Does NOT connect to any database. Read-only gate; run it yourself afterwards.

set -euo pipefail

if [ ! -f package.json ] || [ ! -d prisma ]; then
  echo "error: run this from the project root (package.json and prisma/ expected)." >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required (it edits package.json and runs the gate)." >&2
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "warning: psql is not on PATH. Install the PostgreSQL client tools before running the gate." >&2
fi

mkdir -p scripts

cat > scripts/recon-preview.sql <<'SQL'
-- Read-only reconciliation gate for the Sites preview database.
-- Usage: npm run recon:preview
-- Exit 0 = passed. Exit 3 = at least one check failed.

\set ON_ERROR_STOP on
\pset pager off
SET client_min_messages TO notice;

DROP TABLE IF EXISTS _recon_failures;
CREATE TEMP TABLE _recon_failures (
  check_code text NOT NULL,
  detail     text NOT NULL
);

-- A0. Mapping self-check. Fails loudly if the Prisma table/column names below
-- do not exist, so a renamed field cannot silently disable A11.
INSERT INTO _recon_failures(check_code, detail)
WITH expected(tbl, col, seq_key, purpose) AS (VALUES
  ('Customer',          'customerNo',    'customer',          'customer numbers'),
  ('Group',             'groupNo',       'group',             'group numbers'),
  ('Booking',           'bookingNo',     'booking',           'booking numbers'),
  ('Invoice',           'invoiceNo',     'invoice',           'invoice numbers'),
  ('Payment',           'receiptNo',     'receipt/refund',    'receipt numbers'),
  ('SupplierPayment',   'paymentNo',     'supplierPayment',   'supplier payment numbers'),
  ('Ticket',            'ticketNo',      'ticket',            'ticket numbers'),
  ('HotelReservation',  'reservationNo', 'hotelReservation',  'hotel reservation numbers'),
  ('TransportBooking',  'transportNo',   'transport',         'transport numbers'),
  ('VisaApplication',   'applicationNo', 'visa',              'visa application numbers'),
  ('Expense',           'expenseNo',     'expense',           'expense numbers'),
  ('Quotation',         'quoteNo',       'quotation',         'quotation numbers')
)
SELECT 'A0',
       format('missing column %I.%I for %s (sequence key %s)',
              e.tbl, e.col, e.purpose, e.seq_key)
FROM expected e
WHERE NOT EXISTS (
  SELECT 1
  FROM information_schema.columns c
  WHERE c.table_schema = current_schema()
    AND c.table_name = e.tbl
    AND c.column_name = e.col
);

-- If A0 failed, the checks that use the mapped document tables may be unable to
-- run. Skip them so the gate reports the A0 names instead of aborting with a raw
-- "relation/column does not exist" error. Keep this boolean: psql's \if rejects
-- a count greater than 1 ("Boolean expected").
SELECT (COUNT(*) > 0) AS a0_failed FROM _recon_failures WHERE check_code = 'A0' \gset

-- A1. Seed/config present.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A1',
       format('seed missing: ledgers=%s roles=%s users=%s active_fy=%s',
              (SELECT COUNT(*) FROM "Ledger"),
              (SELECT COUNT(*) FROM "Role"),
              (SELECT COUNT(*) FROM "User"),
              (SELECT COUNT(*) FROM "FinancialYear" WHERE "isActive"))
WHERE (SELECT COUNT(*) FROM "Ledger") = 0
   OR (SELECT COUNT(*) FROM "Role") = 0
   OR (SELECT COUNT(*) FROM "User") = 0
   OR (SELECT COUNT(*) FROM "FinancialYear" WHERE "isActive") <> 1;

-- A2. Every non-cancelled voucher balances.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A2',
       format('voucher %s (%s) Dr %s <> Cr %s',
              "voucherNo", "voucherType", "totalDebit", "totalCredit")
FROM "Voucher"
WHERE status <> 'CANCELLED'
  AND ABS("totalDebit" - "totalCredit") > 0.01;

-- A3. Entries sum to voucher totals.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A3',
       format('voucher %s entries Dr %s / Cr %s vs header Dr %s / Cr %s',
              v."voucherNo", SUM(e.debit), SUM(e.credit), v."totalDebit", v."totalCredit")
FROM "VoucherEntry" e
JOIN "Voucher" v ON v.id = e."voucherId"
WHERE v.status <> 'CANCELLED'
GROUP BY v."voucherNo", v."totalDebit", v."totalCredit"
HAVING ABS(SUM(e.debit) - SUM(e.credit)) > 0.01
    OR ABS(SUM(e.debit) - v."totalDebit") > 0.01
    OR ABS(SUM(e.credit) - v."totalCredit") > 0.01;

-- A4. Global Dr = Cr.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A4', format('Dr %s <> Cr %s (diff %s)', dr, cr, diff)
FROM (
  SELECT ROUND(SUM("totalDebit")::numeric, 2)  AS dr,
         ROUND(SUM("totalCredit")::numeric, 2) AS cr,
         ROUND((SUM("totalDebit") - SUM("totalCredit"))::numeric, 2) AS diff
  FROM "Voucher" WHERE status <> 'CANCELLED'
) t
WHERE ABS(diff) > 0.01;

\if :a0_failed
\echo 'A0 failed: skipping A5-A12 (document checks depend on the mapped tables)'
\else

-- A5. Invoice total = original sales voucher + live amendments.
INSERT INTO _recon_failures(check_code, detail)
WITH originals AS (
  SELECT i.id AS invoice_id, i."invoiceNo", i."totalAmount",
         v."totalDebit" AS original_total
  FROM "Invoice" i
  JOIN "Voucher" v ON v.id = i."voucherId"
),
live_adjustments AS (
  SELECT "sourceId" AS invoice_id,
         ROUND(SUM(CASE WHEN "voucherType" = 'CREDIT_NOTE'
                        THEN -"totalCredit" ELSE "totalDebit" END)::numeric, 2) AS adjustment_total
  FROM "Voucher"
  WHERE "sourceModule" = 'BOOKING_AMENDMENT'
    AND status = 'POSTED'
    AND "reversalOfId" IS NULL
  GROUP BY "sourceId"
)
SELECT 'A5',
       format('invoice %s: original %s + amendments %s <> total %s',
              o."invoiceNo", o.original_total, COALESCE(a.adjustment_total, 0), o."totalAmount")
FROM originals o
LEFT JOIN live_adjustments a ON a.invoice_id = o.invoice_id
WHERE ABS(o.original_total + COALESCE(a.adjustment_total, 0) - o."totalAmount") > 0.01;

-- A6. Non-cancelled invoices have a sales voucher.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A6', format('invoice %s has no sales voucher (total %s)', i."invoiceNo", i."totalAmount")
FROM "Invoice" i
LEFT JOIN "Voucher" v ON v.id = i."voucherId"
WHERE i.status <> 'CANCELLED' AND v.id IS NULL;

-- A7. Amendment vouchers link to a real invoice.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A7', format('%s amendment voucher(s) not linked to an invoice', orphans)
FROM (
  SELECT COUNT(*) FILTER (
           WHERE "sourceId" IS NULL
              OR NOT EXISTS (SELECT 1 FROM "Invoice" i WHERE i.id = v."sourceId")
         ) AS orphans
  FROM "Voucher" v
  WHERE "sourceModule" = 'BOOKING_AMENDMENT'
    AND status = 'POSTED'
    AND "reversalOfId" IS NULL
) t
WHERE orphans > 0;

DO $$
DECLARE n int;
BEGIN
  SELECT COUNT(*) INTO n FROM "Voucher"
  WHERE "sourceModule" = 'BOOKING_AMENDMENT'
    AND status = 'POSTED'
    AND "reversalOfId" IS NULL;
  RAISE NOTICE 'A7 info: % live amendment voucher(s)', n;
END $$;

-- A8. Booking balance = max(total - paid, 0).
-- DECISION: overpaid booking with balance 0 PASSES (excess is customer credit).
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A8',
       format('booking %s: total %s, paid %s, balance %s (expected %s)',
              "bookingNo", "totalAmount", "paidAmount", "balanceAmount",
              GREATEST("totalAmount" - "paidAmount", 0))
FROM "Booking"
WHERE status <> 'CANCELLED'
  AND (
    ABS("balanceAmount" - GREATEST("totalAmount" - "paidAmount", 0)) > 0.01
    OR "balanceAmount" < -0.01
  );

-- A9. Invoice balance = max(total - paid, 0). Same overpayment decision.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A9',
       format('invoice %s: total %s, paid %s, balance %s (expected %s)',
              "invoiceNo", "totalAmount", "amountPaid", "balance",
              GREATEST("totalAmount" - "amountPaid", 0))
FROM "Invoice"
WHERE status <> 'CANCELLED'
  AND (
    ABS("balance" - GREATEST("totalAmount" - "amountPaid", 0)) > 0.01
    OR "balance" < -0.01
  );

-- A10. Booking paid = net receipts.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A10',
       format('booking %s: paid %s <> receipts net %s',
              b."bookingNo", b."paidAmount", b.receipt_net)
FROM (
  SELECT b.id, b."bookingNo", b."paidAmount",
         ROUND(COALESCE(SUM(CASE WHEN p."paymentType" = 'REFUND'
                                 THEN -p.amount ELSE p.amount END), 0)::numeric, 2) AS receipt_net
  FROM "Booking" b
  LEFT JOIN "Payment" p ON p."bookingId" = b.id
  GROUP BY b.id, b."bookingNo", b."paidAmount"
) b
WHERE ABS(b."paidAmount" - b.receipt_net) > 0.01;

-- A11. Sequence continuity. Two failure modes, both loud:
--   (1) a mapped sequence whose nextNo <> highest document number + 1;
--   (2) a Sequence row with no document mapping at all.
INSERT INTO _recon_failures(check_code, detail)
WITH docs AS (
  SELECT 'customer'            AS key, "customerNo"   AS doc_no FROM "Customer"
  UNION ALL SELECT 'group',            "groupNo"                  FROM "Group"
  UNION ALL SELECT 'booking',          "bookingNo"                FROM "Booking"
  UNION ALL SELECT 'invoice',          "invoiceNo"                FROM "Invoice"
  UNION ALL SELECT 'receipt',          "receiptNo"                FROM "Payment" WHERE "receiptNo" LIKE 'RCP-%'
  UNION ALL SELECT 'refund',           "receiptNo"                FROM "Payment" WHERE "receiptNo" LIKE 'RFD-%'
  UNION ALL SELECT 'supplierPayment',  "paymentNo"                FROM "SupplierPayment"
  UNION ALL SELECT 'ticket',           "ticketNo"                 FROM "Ticket"
  UNION ALL SELECT 'hotelReservation', "reservationNo"            FROM "HotelReservation"
  UNION ALL SELECT 'transport',        "transportNo"              FROM "TransportBooking"
  UNION ALL SELECT 'visa',             "applicationNo"            FROM "VisaApplication"
  UNION ALL SELECT 'expense',          "expenseNo"                FROM "Expense"
  UNION ALL SELECT 'quotation',        "quoteNo"                  FROM "Quotation"
  UNION ALL SELECT 'voucher:' || "voucherType", "voucherNo"        FROM "Voucher"
),
maxes AS (
  SELECT key, MAX(CAST(NULLIF(regexp_replace(doc_no, '\D', '', 'g'), '') AS bigint)) AS max_no
  FROM docs GROUP BY key
),
mapped AS (SELECT DISTINCT key FROM docs)
SELECT 'A11',
       format('sequence %s (prefix %s): nextNo %s, expected %s',
              s.key, COALESCE(s.prefix, ''), s."nextNo", COALESCE(m.max_no, 0) + 1)
FROM "Sequence" s
LEFT JOIN maxes m ON m.key = s.key
WHERE s.key IN (SELECT key FROM mapped)
  AND s."nextNo" <> COALESCE(m.max_no, 0) + 1

UNION ALL

SELECT 'A11',
       format('sequence %s (nextNo %s) has no document mapping; add its table/column to A11',
              s.key, s."nextNo")
FROM "Sequence" s
WHERE s.key NOT IN (SELECT key FROM mapped)
  AND s.key NOT LIKE 'voucher:%';

-- A12. No duplicate document numbers.
INSERT INTO _recon_failures(check_code, detail)
SELECT 'A12', format('%s duplicate %s (%s rows)', entity, doc_no, n)
FROM (
  SELECT 'Booking' AS entity, "bookingNo" AS doc_no, COUNT(*) AS n
  FROM "Booking" GROUP BY "bookingNo" HAVING COUNT(*) > 1
  UNION ALL
  SELECT 'Invoice', "invoiceNo", COUNT(*) FROM "Invoice" GROUP BY "invoiceNo" HAVING COUNT(*) > 1
  UNION ALL
  SELECT 'Voucher', "voucherNo", COUNT(*) FROM "Voucher" GROUP BY "voucherNo" HAVING COUNT(*) > 1
  UNION ALL
  SELECT 'Payment', "receiptNo", COUNT(*) FROM "Payment" GROUP BY "receiptNo" HAVING COUNT(*) > 1
  UNION ALL
  SELECT 'Quotation', "quoteNo", COUNT(*) FROM "Quotation" GROUP BY "quoteNo" HAVING COUNT(*) > 1
) d;

\endif

-- Final gate.
DO $$
DECLARE total int; details text;
BEGIN
  SELECT COUNT(*) INTO total FROM _recon_failures;
  IF total > 0 THEN
    SELECT string_agg(format('%s: %s', check_code, detail), E'\n' ORDER BY check_code)
    INTO details
    FROM (SELECT * FROM _recon_failures ORDER BY check_code LIMIT 20) f;
    RAISE EXCEPTION 'Preview reconciliation FAILED: % issue(s)%', total, E'\n' || details;
  END IF;
  RAISE NOTICE 'Preview reconciliation PASSED: all checks A0-A12 green.';
END $$;
SQL

cat > scripts/recon-preview.mjs <<'MJS'
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

function loadDotEnv() {
  if (!existsSync(".env")) return;
  for (const line of readFileSync(".env", "utf8").split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/);
    if (!m) continue;
    let value = m[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) value = value.slice(1, -1);
    if (!process.env[m[1]]) process.env[m[1]] = value;
  }
}

loadDotEnv();

const url =
  process.env.DIRECT_URL ||
  process.env.DIRECT_DATABASE_URL ||
  process.env.DATABASE_URL;

if (!url) {
  console.error("recon:preview needs DIRECT_URL (or DIRECT_DATABASE_URL/DATABASE_URL).");
  process.exit(2);
}
if (url.startsWith("prisma://") || url.startsWith("prisma+postgres://")) {
  console.error("recon:preview needs a direct postgres:// URL, not a pooled/Accelerate URL.");
  process.exit(2);
}

const result = spawnSync(
  "psql",
  [url, "-v", "ON_ERROR_STOP=1", "-f", "scripts/recon-preview.sql"],
  { stdio: "inherit" },
);

if (result.error) {
  console.error("psql not found. Install the PostgreSQL client tools (postgresql-client).");
  process.exit(2);
}
process.exit(result.status ?? 1);
MJS

node <<'NODE'
// Insert only the recon:preview entry. package.json is never re-serialised, so
// indentation, key order, spacing and line endings stay byte-for-byte intact.
const fs = require("fs");
const file = "package.json";
const desired = "node scripts/recon-preview.mjs";
const raw = fs.readFileSync(file, "utf8");
const bom = raw.charCodeAt(0) === 0xfeff ? "\ufeff" : "";
const text = bom ? raw.slice(1) : raw;
const pkg = JSON.parse(text);

if (!pkg.scripts || typeof pkg.scripts !== "object" || Array.isArray(pkg.scripts)) {
  console.error("error: package.json has no scripts object.");
  process.exit(1);
}

const existing = pkg.scripts["recon:preview"];
if (existing === desired) {
  console.log("package.json: recon:preview already set (unchanged)");
  process.exit(0);
}
if (existing !== undefined) {
  console.error(`error: package.json already has a different recon:preview: ${existing}`);
  process.exit(1);
}

// Find every TOP-LEVEL "scripts" object opening brace (ignore nested keys).
function findTopLevelScriptsOpens(source) {
  const opens = [];
  let depth = 0;
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === '"') {
      const start = i;
      i += 1;
      while (i < source.length) {
        if (source[i] === "\\") { i += 2; continue; }
        if (source[i] === '"') break;
        i += 1;
      }
      const key = source.slice(start + 1, i);
      i += 1;
      if (depth === 1 && key === "scripts") {
        let j = i;
        while (j < source.length && /\s/.test(source[j])) j += 1;
        if (source[j] === ":") {
          j += 1;
          while (j < source.length && /\s/.test(source[j])) j += 1;
          if (source[j] === "{") opens.push(j);
        }
      }
      continue;
    }
    if (ch === "{") depth += 1;
    else if (ch === "}") depth -= 1;
    i += 1;
  }
  return opens;
}

function findMatchingBrace(source, openIndex) {
  let depth = 0;
  let inString = false;
  let escaped = false;
  for (let i = openIndex; i < source.length; i += 1) {
    const ch = source[i];
    if (inString) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return i;
    }
  }
  return -1;
}

const opens = findTopLevelScriptsOpens(text);
if (opens.length === 0) {
  console.error("error: could not locate the top-level scripts object in package.json.");
  process.exit(1);
}
if (opens.length > 1) {
  console.error(
    `error: package.json has ${opens.length} top-level "scripts" keys; refusing to guess which one to edit. Remove the duplicate(s) and rerun.`,
  );
  process.exit(1);
}
const open = opens[0];
const close = findMatchingBrace(text, open);
if (close < 0) {
  console.error("error: could not find the end of the top-level scripts object in package.json.");
  process.exit(1);
}

const inner = text.slice(open + 1, close);
const leading = (inner.match(/^[ \t]*/) || [""])[0];
const emptyObject = inner.trim() === "";
const multiline = inner.includes("\n");
const eol = text.includes("\r\n") ? "\r\n" : "\n";
const nextLine = inner.match(/\r?\n([ \t]+)"/);
const closingIndent = (inner.match(/\r?\n([ \t]*)[ \t]*$/) || ["", ""])[1];
const indent = nextLine ? nextLine[1] : `${closingIndent}  `;
const entry = `"recon:preview": "${desired}"`;

let insertAt = open + 1;
let insertion;
if (emptyObject) {
  // No trailing comma: the inserted entry is the only member.
  insertion = multiline ? `${eol}${indent}${entry}` : entry;
} else if (!multiline) {
  // Single-line scripts object: keep it on one line.
  insertAt = open + 1 + leading.length;
  insertion = `${entry}, `;
} else {
  insertion = `${eol}${indent}${entry},`;
}

const updated = text.slice(0, insertAt) + insertion + text.slice(insertAt);

// Validate before writing: valid JSON, script present, every existing script intact,
// and the file equals the original once the inserted text is removed.
const updatedPkg = JSON.parse(updated);
if (updatedPkg.scripts["recon:preview"] !== desired) {
  console.error("error: recon:preview did not land in the scripts object.");
  process.exit(1);
}
for (const [key, value] of Object.entries(pkg.scripts)) {
  if (updatedPkg.scripts[key] !== value) {
    console.error(`error: existing script ${key} changed; aborting without writing.`);
    process.exit(1);
  }
}
if (updated.slice(0, insertAt) + updated.slice(insertAt + insertion.length) !== text) {
  console.error("error: edit would alter text outside the inserted line; aborting.");
  process.exit(1);
}

// Atomic replace: write a sibling temp file, then rename over package.json, so a
// crash cannot leave a truncated manifest behind. writeFileSync's mode is masked
// by the process umask, so chmod the temp file to the original bits (including
// group/setuid/setgid) before the rename.
const stat = fs.statSync(file);
const mode = stat.mode & 0o7777;
const tmp = `${file}.recon-${process.pid}.tmp`;
try {
  fs.writeFileSync(tmp, bom + updated, { mode });
  fs.chmodSync(tmp, mode);
  fs.renameSync(tmp, file);
} catch (error) {
  try { if (fs.existsSync(tmp)) fs.unlinkSync(tmp); } catch { /* ignore cleanup failure */ }
  console.error(`error: could not atomically update package.json: ${error.message}`);
  process.exit(1);
}
console.log("package.json: added recon:preview (formatting preserved)");
NODE

cat <<'DONE'

Installed:
  scripts/recon-preview.sql
  scripts/recon-preview.mjs
  package.json -> "recon:preview": "node scripts/recon-preview.mjs"

Next:
  1. Ensure .env or the environment has DIRECT_URL pointing at the PREVIEW Postgres
     (a direct postgres:// URL, not prisma://).
  2. Confirm the Prisma field names A0 expects:
       rg -n "model (Customer|Group|Booking|Invoice|Payment|SupplierPayment|Ticket|HotelReservation|TransportBooking|VisaApplication|Expense|Quotation)" -A 10 prisma/schema.prisma
  3. Run and capture the exit code:
       npm run recon:preview; echo "exit=$?"

The gate is read-only. Do not run it against production.
DONE
