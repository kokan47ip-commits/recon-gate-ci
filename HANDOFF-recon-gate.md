# Handoff — apply and run the preview reconciliation gate

Paste the block below into the project chat (the workspace that contains `package.json`, `prisma/` and `scripts/`).

---

Apply and run the preview reconciliation gate in this project.

**Input:** `recon-gate-bootstrap.sh`, supplied alongside this message. It is a self-contained installer that creates `scripts/recon-preview.sql`, `scripts/recon-preview.mjs` and adds the npm script `recon:preview`. Save it at the repository root; do not modify its contents.

## Steps

1. Confirm you are in the project root: `package.json` and `prisma/schema.prisma` exist, and `git status` is clean or only has the new installer.
2. Place `recon-gate-bootstrap.sh` at the root and run:
   ```bash
   bash recon-gate-bootstrap.sh
   ```
   Expected: `package.json: added recon:preview (formatting preserved)`, followed by the three installed items and the next steps. The npm script is inserted textually — existing indentation, key order, spacing and line endings are untouched, and the rest of `package.json` is not rewritten. Re-running is a no-op; a different existing `recon:preview` is refused. If it reports a missing `node` or warns `psql` is absent, stop and report.
3. Confirm the Prisma names the gate asserts (A0):
   ```bash
   rg -n "model (Customer|Group|Booking|Invoice|Payment|SupplierPayment|Ticket|HotelReservation|TransportBooking|VisaApplication|Expense|Quotation)" -A 10 prisma/schema.prisma
   ```
   Expected document-number fields: `customerNo`, `groupNo`, `bookingNo`, `invoiceNo`, `receiptNo`, `paymentNo`, `ticketNo`, `reservationNo`, `transportNo`, `applicationNo`, `expenseNo`, `quoteNo`.
   If any differ, edit **both** the `expected` VALUES list (A0) and the matching line in the `docs` CTE (A11) in `scripts/recon-preview.sql`. Do not delete a mapping to make the gate pass — A11 is designed to fail if a `Sequence` key has no document mapping.
4. Confirm the preview database URL is available as `DIRECT_URL` in `.env` (or the environment) and is a direct `postgres://` URL for the **preview** database — not `prisma://`, not production.
5. Run the gate and capture the exit code:
   ```bash
   npm run recon:preview; echo "exit=$?"
   ```
6. Report back:
   - the complete console output (the NOTICE lines and any `ERROR:` details),
   - the exact `exit=` value,
   - if A0 fails, the `rg` output from step 3,
   - if A11 reports an unmapped sequence, the sequence key it names.

## Constraints

- The gate is read-only except for a session-local temp table; it must not modify application tables.
- A0 validates the Prisma table/column names the document checks rely on. If A0 records any missing name, **every dependent check (A5–A12)** is skipped — the script prints `A0 failed: skipping A5-A12 (document checks depend on the mapped tables)` — so the missing names are reported instead of a raw SQL abort. A1–A4 still run (they use only the core voucher/ledger tables), and the run still fails with exit 3. Do not remove mappings to force a pass.
- Never point it at production.
- Do not “fix” a failing check by editing data or deleting vouchers/sequences. Report the failure with its exact message and the affected document numbers.
- Do not change the A8/A9 overpayment rule: an overpaid booking or invoice with `balance = 0` passes because the excess is customer credit; a negative balance fails.
- If `psql` is missing, install the PostgreSQL client tools (`postgresql-client`) and rerun; do not substitute a different SQL client.

## Acceptance

```
NOTICE:  A7 info: N live amendment voucher(s)
NOTICE:  Preview reconciliation PASSED: all checks A0-A12 green.
exit=0
```

Anything else is a failure to report, with the exit code and full output.

---

## Notes for the human

- The gate covers: seed presence, voucher balance, entry totals, Dr = Cr, invoice ↔ sales voucher + live amendments, amendment linkage, booking/invoice balances (clamped overpayment allowed), receipts vs paid amounts, sequence continuity for customer/group/booking/invoice/receipt/refund/supplier payment/ticket/hotel/transport/visa/expense/quotation/all voucher types, and duplicate document numbers.
- Import-only checks (source-vs-target row counts, aggregate totals, per-ledger trial-balance diff, FK orphans) are deliberately **not** in this gate. Run them only after the SQLite → Postgres import, in their separate file.
- Exit codes: `0` pass, `3` one or more checks failed (psql `ON_ERROR_STOP`), `2` configuration problem (missing URL, pooled URL, missing `psql`).
- Installer behaviour on `package.json`: the `recon:preview` entry is inserted as text at the existing indentation (multiline, single-line, empty, CRLF and BOM files keep their shape); an identical entry is left alone, and an existing different one aborts without writing. Duplicate top-level `"scripts"` keys are rejected with an explicit count instead of guessing. The installer validates the edited JSON, verifies no bytes outside the inserted text changed, and replaces the file atomically (temp file + rename) with the original permission bits restored explicitly — including group and setuid/setgid bits, independent of umask.
