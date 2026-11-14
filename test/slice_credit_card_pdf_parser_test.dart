import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/services/slice_credit_card_pdf_parser_service.dart';

void main() {
  group('SliceCreditCardPdfParserService Tests', () {
    late SliceCreditCardPdfParserService parser;
    late File testPdfFile;

    setUp(() {
      parser = SliceCreditCardPdfParserService();
      testPdfFile = File('/Users/santosh/Setthi/setthi/1a172cb6e60bbd4d_slice_Credit_Card_Statement_-_October_2026.pdf');
    });

    test('parses Slice Credit Card PDF with 100% mathematical accuracy', () async {
      expect(await testPdfFile.exists(), isTrue, reason: 'Test PDF must exist');

      final result = await parser.parsePdfFile(testPdfFile);

      expect(result.success, isTrue);
      expect(result.errorMessage, isNull);

      // Verify Statement Summary
      final summary = result.summary;
      expect(summary.spends, closeTo(44565.46, 0.01));
      expect(summary.refundsAndRepayments, closeTo(2000.00, 0.01));
      expect(summary.cashback, closeTo(125.00, 0.01));
      expect(summary.interest, 0.0);
      expect(summary.surcharge, 0.0);
      expect(summary.totalAmountDue, closeTo(42440.46, 0.01));
      expect(summary.minAmountDue, closeTo(2122.02, 0.01));
      expect(summary.cardLast4, '2254');
      expect(summary.billingCycle, '21 SEP - 20 OCT');
      expect(summary.dueDate?.day, 5);
      expect(summary.dueDate?.month, 11);
      expect(summary.isBalanced, isTrue);

      // Verify Transactions Breakdown
      expect(result.transactions.length, 36);
      expect(result.spendsCount, 33);
      expect(result.refundsCount, 1);
      expect(result.cashbackCount, 2);

      // Mathematical Balance check:
      // Spends sum == 44,565.46
      // Refunds sum == 2,000.00
      // Cashback sum == 125.00
      expect(result.totalDebitAmount, closeTo(44565.46, 0.01));
      expect(result.totalCreditAmount, closeTo(2125.00, 0.01));
      expect(result.isMathematicallyVerified, isTrue);

      // Verify specific sample transactions
      final jioSpend = result.transactions.firstWhere((t) => t.merchantName == 'Jio');
      expect(jioSpend.amount, 666.0);
      expect(jioSpend.paymentMode, 'UPI');
      expect(jioSpend.transactionType, 'DEBIT');
      expect(jioSpend.section, 'SPEND');
      expect(jioSpend.category, 'Bills & Utilities');

      final medplusSpend = result.transactions.firstWhere((t) => t.merchantName == 'Medplus');
      expect(medplusSpend.amount, 120.0);
      expect(medplusSpend.paymentMode, 'Card');
      expect(medplusSpend.transactionType, 'DEBIT');
      expect(medplusSpend.section, 'SPEND');
      expect(medplusSpend.category, 'Healthcare');

      final refundTxn = result.transactions.firstWhere((t) => t.section == 'REFUND');
      expect(refundTxn.merchantName, 'Indian institute');
      expect(refundTxn.amount, 2000.0);
      expect(refundTxn.transactionType, 'CREDIT');
      expect(refundTxn.category, 'Refund / Reversal');

      final cashbackTxn = result.transactions.firstWhere((t) => t.merchantName == 'Instamart' && t.section == 'CASHBACK');
      expect(cashbackTxn.amount, 50.0);
      expect(cashbackTxn.transactionType, 'CREDIT');
      expect(cashbackTxn.category, 'Cashback & Rewards');

      // Verify deterministic reference ID uniqueness
      final refIds = result.transactions.map((t) => t.referenceId).toSet();
      expect(refIds.length, 36, reason: 'Every transaction must have a unique referenceId');
    });
  });
}
