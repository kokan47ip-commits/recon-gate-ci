-- Populated fixture for the all-green reconciliation run.
--
-- One balanced sales voucher (1000), one linked DEBIT_NOTE amendment (100),
-- an invoice for 1100, a booking paid 450 (500 receipt minus 50 refund), and
-- matching sequence rows. A2-A12 therefore execute on non-empty tables.

INSERT INTO "Ledger"(id) VALUES ('ledger-1');
INSERT INTO "Role"(id) VALUES ('role-1');
INSERT INTO "User"(id) VALUES ('user-1');
INSERT INTO "FinancialYear"(id, "isActive") VALUES ('fy-1', true);

INSERT INTO "Customer"(id, "customerNo") VALUES ('cust-1', 'CUS-0001');
INSERT INTO "Group"(id, "groupNo") VALUES ('group-1', 'GRP-0001');
INSERT INTO "Booking"(id, "bookingNo", "totalAmount", "paidAmount", "balanceAmount", status)
VALUES ('booking-1', 'BKG-0001', 1100, 450, 650, 'CONFIRMED');

INSERT INTO "Voucher"(id, "voucherNo", "voucherType", "totalDebit", "totalCredit", status, "sourceModule", "sourceId", "reversalOfId")
VALUES ('voucher-sales', 'VCH-SLS-0001', 'SALES', 1000, 1000, 'POSTED', NULL, NULL, NULL);

INSERT INTO "Invoice"(id, "invoiceNo", "totalAmount", "amountPaid", balance, status, "voucherId")
VALUES ('invoice-1', 'INV-0001', 1100, 450, 650, 'ISSUED', 'voucher-sales');

INSERT INTO "Voucher"(id, "voucherNo", "voucherType", "totalDebit", "totalCredit", status, "sourceModule", "sourceId", "reversalOfId")
VALUES ('voucher-amendment', 'VCH-AMD-0001', 'DEBIT_NOTE', 100, 100, 'POSTED', 'BOOKING_AMENDMENT', 'invoice-1', NULL);

INSERT INTO "VoucherEntry"(id, "voucherId", debit, credit) VALUES
  ('ve-sales-1', 'voucher-sales', 1000, 1000),
  ('ve-amendment-1', 'voucher-amendment', 100, 100);

INSERT INTO "Payment"(id, "receiptNo", "paymentNo", "bookingId", "paymentType", amount) VALUES
  ('payment-receipt-1', 'RCP-0001', 'PAY-0001', 'booking-1', 'RECEIPT', 500),
  ('payment-refund-1', 'RFD-0001', 'PAY-0002', 'booking-1', 'REFUND', 50);

INSERT INTO "SupplierPayment"(id, "paymentNo") VALUES ('supplier-payment-1', 'SUP-0001');
INSERT INTO "Ticket"(id, "ticketNo") VALUES ('ticket-1', 'TKT-0001');
INSERT INTO "HotelReservation"(id, "reservationNo") VALUES ('hotel-1', 'HTL-0001');
INSERT INTO "TransportBooking"(id, "transportNo") VALUES ('transport-1', 'TRN-0001');
INSERT INTO "VisaApplication"(id, "applicationNo") VALUES ('visa-1', 'VSA-0001');
INSERT INTO "Expense"(id, "expenseNo") VALUES ('expense-1', 'EXP-0001');
INSERT INTO "Quotation"(id, "quoteNo") VALUES ('quotation-1', 'QTN-0001');

INSERT INTO "Sequence"("key", prefix, "nextNo") VALUES
  ('customer', 'CUS-', 2),
  ('group', 'GRP-', 2),
  ('booking', 'BKG-', 2),
  ('invoice', 'INV-', 2),
  ('receipt', 'RCP-', 2),
  ('refund', 'RFD-', 2),
  ('supplierPayment', 'SUP-', 2),
  ('ticket', 'TKT-', 2),
  ('hotelReservation', 'HTL-', 2),
  ('transport', 'TRN-', 2),
  ('visa', 'VSA-', 2),
  ('expense', 'EXP-', 2),
  ('quotation', 'QTN-', 2),
  ('voucher:SALES', 'VCH-SLS-', 2),
  ('voucher:DEBIT_NOTE', 'VCH-AMD-', 2);
