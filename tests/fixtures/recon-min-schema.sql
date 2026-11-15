-- Minimal schema for exercising scripts/recon-preview.sql against real Postgres.
-- It contains every table/column A0 and A5-A12 read, but no business data.
-- Apply together with recon-min-seed.sql for the all-green path.

CREATE TABLE "Ledger" (id text PRIMARY KEY);
CREATE TABLE "Role" (id text PRIMARY KEY);
CREATE TABLE "User" (id text PRIMARY KEY);
CREATE TABLE "FinancialYear" (id text PRIMARY KEY, "isActive" boolean NOT NULL DEFAULT false);

CREATE TABLE "Voucher" (
  id text PRIMARY KEY,
  "voucherNo" text NOT NULL,
  "voucherType" text NOT NULL,
  "totalDebit" numeric(14,2) NOT NULL DEFAULT 0,
  "totalCredit" numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'POSTED',
  "sourceModule" text,
  "sourceId" text,
  "reversalOfId" text
);

CREATE TABLE "VoucherEntry" (
  id text PRIMARY KEY,
  "voucherId" text NOT NULL REFERENCES "Voucher"(id),
  debit numeric(14,2) NOT NULL DEFAULT 0,
  credit numeric(14,2) NOT NULL DEFAULT 0
);

CREATE TABLE "Customer" (
  id text PRIMARY KEY,
  "customerNo" text NOT NULL
);

CREATE TABLE "Group" (
  id text PRIMARY KEY,
  "groupNo" text NOT NULL
);

CREATE TABLE "Booking" (
  id text PRIMARY KEY,
  "bookingNo" text NOT NULL,
  "totalAmount" numeric(14,2) NOT NULL DEFAULT 0,
  "paidAmount" numeric(14,2) NOT NULL DEFAULT 0,
  "balanceAmount" numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'CONFIRMED'
);

CREATE TABLE "Invoice" (
  id text PRIMARY KEY,
  "invoiceNo" text NOT NULL,
  "totalAmount" numeric(14,2) NOT NULL DEFAULT 0,
  "amountPaid" numeric(14,2) NOT NULL DEFAULT 0,
  balance numeric(14,2) NOT NULL DEFAULT 0,
  status text NOT NULL DEFAULT 'ISSUED',
  "voucherId" text REFERENCES "Voucher"(id)
);

CREATE TABLE "Payment" (
  id text PRIMARY KEY,
  "receiptNo" text NOT NULL,
  "paymentNo" text,
  "bookingId" text REFERENCES "Booking"(id),
  "paymentType" text NOT NULL DEFAULT 'RECEIPT',
  amount numeric(14,2) NOT NULL DEFAULT 0
);

CREATE TABLE "SupplierPayment" (
  id text PRIMARY KEY,
  "paymentNo" text NOT NULL
);

CREATE TABLE "Ticket" (
  id text PRIMARY KEY,
  "ticketNo" text NOT NULL
);

CREATE TABLE "HotelReservation" (
  id text PRIMARY KEY,
  "reservationNo" text NOT NULL
);

CREATE TABLE "TransportBooking" (
  id text PRIMARY KEY,
  "transportNo" text NOT NULL
);

CREATE TABLE "VisaApplication" (
  id text PRIMARY KEY,
  "applicationNo" text NOT NULL
);

CREATE TABLE "Expense" (
  id text PRIMARY KEY,
  "expenseNo" text NOT NULL
);

CREATE TABLE "Quotation" (
  id text PRIMARY KEY,
  "quoteNo" text NOT NULL
);

CREATE TABLE "Sequence" (
  "key" text PRIMARY KEY,
  prefix text,
  "nextNo" bigint NOT NULL DEFAULT 1
);
