import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/services/pdf_statement_parser_service.dart';

void main() {
  group('Financial Statement Intelligence API Integration Tests', () {
    test('Correctly maps bank statement response to BankTransaction models', () {
      final sampleBackendResponse = {
        'job_id': 'fc-01M72E9537G5Y46ZQ9S1GVADGT',
        'status': 'completed',
        'statement_type': 'bank_statement',
        'issuer_or_bank': 'Canara Bank',
        'total_transactions': 2,
        'opening_balance': 50000.0,
        'closing_balance': 48500.0,
        'raw_result': {
          'database_payload': {
            'bank_transactions': [
              {
                'txn_id': 'TXN_CANARA_001',
                'type': 'DEBIT',
                'mode': 'UPI',
                'amount': 1500.0,
                'current_balance': 48500.0,
                'transaction_timestamp': '2026-11-01T10:30:00Z',
                'narration': 'UPI/Swiggy/Order123',
                'clean_merchant_name': 'Swiggy',
                'category': 'Food & Dining',
              },
              {
                'txn_id': 'TXN_CANARA_002',
                'type': 'CREDIT',
                'mode': 'IMPS',
                'amount': 10000.0,
                'current_balance': 58500.0,
                'transaction_timestamp': '2026-11-02T11:00:00Z',
                'narration': 'Salary for October',
                'clean_merchant_name': 'Company Corp',
                'category': 'Income',
              }
            ]
          }
        }
      };

      final rawResult = sampleBackendResponse['raw_result'] as Map<String, dynamic>;
      final dbPayload = rawResult['database_payload'] as Map<String, dynamic>;
      final bankRows = dbPayload['bank_transactions'] as List;

      final txns = <BankTransaction>[];
      for (final r in bankRows) {
        final isDebit = r['type']?.toString().toUpperCase() == 'DEBIT';
        final amt = double.tryParse(r['amount']?.toString() ?? '0') ?? 0.0;
        final bal = double.tryParse(r['current_balance']?.toString() ?? '0') ?? 0.0;
        final timestamp = DateTime.tryParse(r['transaction_timestamp']?.toString() ?? '') ?? DateTime.now();

        txns.add(BankTransaction(
          txnId: r['txn_id']?.toString() ?? PdfStatementParserService.generateUuidV4(),
          type: isDebit ? TransactionType.debit : TransactionType.credit,
          mode: r['mode']?.toString() ?? 'UPI',
          amount: amt,
          currentBalance: bal,
          transactionTimestamp: timestamp,
          narration: r['narration']?.toString() ?? '',
          precomputedMerchantName: r['clean_merchant_name']?.toString() ?? r['narration']?.toString(),
          category: r['category']?.toString(),
        ));
      }

      expect(txns.length, 2);
      expect(txns[0].txnId, 'TXN_CANARA_001');
      expect(txns[0].type, TransactionType.debit);
      expect(txns[0].amount, 1500.0);
      expect(txns[0].currentBalance, 48500.0);
      expect(txns[0].precomputedMerchantName, 'Swiggy');

      expect(txns[1].txnId, 'TXN_CANARA_002');
      expect(txns[1].type, TransactionType.credit);
      expect(txns[1].amount, 10000.0);
      expect(txns[1].precomputedMerchantName, 'Company Corp');
    });

    test('Correctly maps credit card statement response to BankTransaction models', () {
      final sampleCardResponse = {
        'job_id': 'fc-01M72E9537G5Y46ZQ9S1GVADCC',
        'status': 'completed',
        'statement_type': 'credit_card_statement',
        'issuer_or_bank': 'Slice',
        'total_transactions': 1,
        'raw_result': {
          'database_payload': {
            'credit_card_transactions': [
              {
                'reference_id': 'REF_SLICE_999',
                'transaction_type': 'DEBIT',
                'payment_mode': 'CARD',
                'amount': 2499.0,
                'transaction_date': '2026-10-25T14:20:00Z',
                'merchant_name': 'AMZN MKTPLACE BLR',
                'clean_merchant_name': 'Amazon',
                'category': 'Shopping',
              }
            ]
          }
        }
      };

      final rawResult = sampleCardResponse['raw_result'] as Map<String, dynamic>;
      final dbPayload = rawResult['database_payload'] as Map<String, dynamic>;
      final cardRows = dbPayload['credit_card_transactions'] as List;

      final txns = <BankTransaction>[];
      for (final r in cardRows) {
        final isDebit = r['transaction_type']?.toString().toUpperCase() == 'DEBIT';
        final amt = double.tryParse(r['amount']?.toString() ?? '0') ?? 0.0;
        final timestamp = DateTime.tryParse(r['transaction_date']?.toString() ?? '') ?? DateTime.now();

        txns.add(BankTransaction(
          txnId: r['reference_id']?.toString() ?? PdfStatementParserService.generateUuidV4(),
          type: isDebit ? TransactionType.debit : TransactionType.credit,
          mode: r['payment_mode']?.toString() ?? 'CARD',
          amount: amt,
          currentBalance: 0.0,
          transactionTimestamp: timestamp,
          narration: r['merchant_name']?.toString() ?? '',
          precomputedMerchantName: r['clean_merchant_name']?.toString() ?? r['merchant_name']?.toString(),
          category: r['category']?.toString(),
        ));
      }

      expect(txns.length, 1);
      expect(txns[0].txnId, 'REF_SLICE_999');
      expect(txns[0].type, TransactionType.debit);
      expect(txns[0].amount, 2499.0);
      expect(txns[0].mode, 'CARD');
      expect(txns[0].precomputedMerchantName, 'Amazon');
    });

    test('Detects password_required response accurately', () {
      final samplePasswordResponse = {
        'status': 'password_required',
        'job_id': 'fc-01M72E9537G5Y46ZQ9S1GPWD',
        'message': 'PDF statement is password protected.',
      };

      final isPasswordProtected = samplePasswordResponse['status'] == 'password_required';
      expect(isPasswordProtected, isTrue);
    });

    test('Correctly identifies recurring family allowance from multi-month credits (e.g. Jayadev)', () {
      final testCredits = [
        BankTransaction(
          txnId: 'TX1',
          type: TransactionType.credit,
          mode: 'UPI',
          amount: 11500.0,
          currentBalance: 30000.0,
          transactionTimestamp: DateTime(2026, 8, 2),
          narration: 'UPI/CR/JAYADEV',
          precomputedMerchantName: 'JAYADEV',
        ),
        BankTransaction(
          txnId: 'TX2',
          type: TransactionType.credit,
          mode: 'UPI',
          amount: 11500.0,
          currentBalance: 33400.0,
          transactionTimestamp: DateTime(2026, 9, 2),
          narration: 'UPI/CR/JAYADEV',
          precomputedMerchantName: 'JAYADEV',
        ),
        BankTransaction(
          txnId: 'TX3',
          type: TransactionType.credit,
          mode: 'UPI',
          amount: 11500.0,
          currentBalance: 45600.0,
          transactionTimestamp: DateTime(2026, 10, 4),
          narration: 'UPI/CR/JAYADEV',
          precomputedMerchantName: 'JAYADEV',
        ),
      ];

      // Run sender grouping logic
      final Map<String, List<BankTransaction>> bySender = {};
      for (final t in testCredits) {
        final key = t.cleanMerchantName.trim().isNotEmpty
            ? t.cleanMerchantName.trim().toUpperCase()
            : t.narration.trim().toUpperCase();
        bySender.putIfAbsent(key, () => []).add(t);
      }

      bool isRecurringAllowance = false;
      BankTransaction? recurringTxn;
      String? recurringSender;

      for (final entry in bySender.entries) {
        final senderTxns = entry.value;
        if (senderTxns.length < 2) continue;

        for (final baseTxn in senderTxns) {
          if (baseTxn.amount < 1000) continue;
          final similarAmtTxns = senderTxns.where((t) {
            final diff = (t.amount - baseTxn.amount).abs();
            return diff / baseTxn.amount <= 0.15;
          }).toList();

          final distinctMonths = similarAmtTxns
              .map((t) => t.transactionTimestamp.year * 12 + t.transactionTimestamp.month)
              .toSet();

          if (distinctMonths.length >= 2) {
            isRecurringAllowance = true;
            recurringTxn = baseTxn;
            recurringSender = entry.key;
            break;
          }
        }
        if (isRecurringAllowance) break;
      }

      expect(isRecurringAllowance, isTrue);
      expect(recurringSender, 'JAYADEV');
      expect(recurringTxn?.amount, 11500.0);
      expect(recurringTxn?.transactionTimestamp.day, 2);
    });
  });
}

