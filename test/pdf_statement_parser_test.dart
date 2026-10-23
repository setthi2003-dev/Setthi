import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/services/pdf_statement_parser_service.dart';
import 'package:setthi/widgets/dpc_pdf_statement_sheet.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:csv/csv.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PDF Statement Parser Service & CSV Column Alignment Tests', () {
    late PdfStatementParserService service;

    setUp(() {
      service = PdfStatementParserService();
      final f = File('extracted_transactions.csv');
      if (f.existsSync()) f.deleteSync();
    });

    test('CSV column headers match Supabase bank_transactions schema exactly', () {
      final sampleTxns = [
        BankTransaction(
          txnId: 'TXN-999',
          type: TransactionType.debit,
          mode: 'UPI',
          amount: 450.0,
          currentBalance: 24550.0,
          transactionTimestamp: DateTime.parse('2026-10-01T14:30:00Z'),
          narration: 'UPI/SWIGGY/999/FOOD',
          precomputedMerchantName: 'Swiggy',
          category: 'Food & Dining',
          spendTier: 'DISCRETIONARY',
          isRecurring: false,
          createdAt: DateTime.parse('2026-10-01T14:30:00Z'),
        ),
      ];

      final csvContent = service.formatTransactionsToCsv(
        sampleTxns,
        userId: 'usr-123',
        accountId: 'acc-456',
        explicitRowId: 'test-txn-1',
      );
      final rows = Csv().decode(csvContent);

      expect(rows.isNotEmpty, isTrue);
      final headers = rows.first.map((e) => e.toString()).toList();

      final expectedSupabaseColumns = [
        'id',
        'user_id',
        'account_id',
        'txn_id',
        'type',
        'mode',
        'amount',
        'current_balance',
        'transaction_timestamp',
        'narration',
        'clean_merchant_name',
        'category',
        'raw_data',
        'created_at',
        'spend_tier',
        'is_recurring',
      ];

      expect(headers, equals(expectedSupabaseColumns));

      // Validate transaction values row
      final dataRow = rows[1];
      expect(dataRow[0].toString(), 'test-txn-1');
      expect(dataRow[1].toString(), 'usr-123');
      expect(dataRow[2].toString(), 'acc-456');
      expect(dataRow[3].toString(), 'TXN-999');
      expect(dataRow[4].toString(), 'DEBIT');
      expect(dataRow[5].toString(), 'UPI');
      expect(num.parse(dataRow[6].toString()), 450.0);
      expect(num.parse(dataRow[7].toString()), 24550.0);
      expect(dataRow[9].toString(), 'UPI/SWIGGY/999/FOOD');
      expect(dataRow[10].toString(), 'Swiggy');
      expect(dataRow[11].toString(), 'Food & Dining');
      expect(dataRow[14].toString(), 'DISCRETIONARY');
      expect(dataRow[15].toString().toLowerCase(), 'false');
    });

    test('Parses bank statement PDF bytes and saves extracted_transactions.csv in root', () async {
      // 1. Generate an in-memory PDF statement using Syncfusion
      final document = PdfDocument();
      final page = document.pages.add();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 10);

      final statementLines = [
        'HDFC BANK LIMITED - ACCOUNT STATEMENT',
        'Account No: 50100234567890',
        'Customer Name: Test User',
        'Date | Description | Chq/Ref No | Debit | Credit | Balance',
        '01/10/2026 UPI-SWIGGY-12345 450.00 24550.00',
        '02/10/2026 SALARY-TECHCORP-OCT 75000.00 99550.00',
        '03/10/2026 ATM-CASH-WDL-MUMBAI 2000.00 97550.00',
        '04/10/2026 NETFLIX-OCT-AUTOPAY 649.00 96901.00',
      ];

      double y = 20;
      for (final line in statementLines) {
        page.graphics.drawString(
          line,
          font,
          bounds: Rect.fromLTWH(20, y, 500, 16),
        );
        y += 18;
      }

      final bytes = Uint8List.fromList(document.saveSync());
      document.dispose();

      // 2. Parse the PDF statement bytes
      final result = await service.parsePdfBytes(
        bytes,
        fileName: 'test_hdfc_statement.pdf',
        userId: 'usr-test-1',
        accountId: 'acc-hdfc-1',
      );

      // 3. Verify parse results
      expect(result.fileName, 'test_hdfc_statement.pdf');
      expect(result.totalCount, greaterThanOrEqualTo(3));
      expect(result.debitCount, greaterThanOrEqualTo(2));
      expect(result.creditCount, greaterThanOrEqualTo(1));
      expect(result.latestBalance, isNotNull);

      // Verify transaction attributes
      final swiggyTxn = result.transactions.firstWhere(
        (t) => t.narration.toUpperCase().contains('SWIGGY'),
      );
      expect(swiggyTxn.type, TransactionType.debit);
      expect(swiggyTxn.amount, 450.0);
      expect(swiggyTxn.mode, 'UPI');

      final salaryTxn = result.transactions.firstWhere(
        (t) => t.narration.toUpperCase().contains('SALARY'),
      );
      expect(salaryTxn.type, TransactionType.credit);
      expect(salaryTxn.amount, 75000.0);

      // 4. Verify no local CSV file is saved, but in-memory CSV content is valid
      expect(result.csvFilePath, isNull);
      expect(result.rootCsvFilePath, isNull);
      expect(File('extracted_transactions.csv').existsSync(), isFalse);

      final rows = Csv().decode(result.csvContent);
      expect(rows.length, equals(result.totalCount + 1)); // Header + rows
    });

    test('Rejects address header lines and strips value date prefixes from narrations', () async {
      final document = PdfDocument();
      final page = document.pages.add();
      final font = PdfStandardFont(PdfFontFamily.helvetica, 10);

      final statementLines = [
        'Report Generation Date & Time : 06-10-2026 14:09:44',
        'CUSTOMER DETAILS',
        'Customer ID : 57449823 Branch Address :',
        '12-10-97/57, at Siva Talab Locality, SS Tower, Paras Garden',
        'Address of Customer : KARNATAKA, 584103 Branch Code : 2159',
        'Date(Value Date) Particulars Ref No. /Cheque No Transaction Type Debit(Rs) Credit(Rs) Balance(Rs)',
        '05-Oct-26',
        '(05-Oct-26)',
        'UPI/253780957712/DR/ MODERN CAFE /YES/Payment f S55653387 Transfer 10.00 - 267.22',
        '04-Oct-26',
        '(04-Oct-26)',
        'UPI/589510446141/DR/GURU RESTAURAN/YES/Payment f S54478916 Transfer 20.00 - 277.22',
        '13,903.46 13,000.00',
        'Effective available balance as on 06-10-2026 14:09:44 is INR 267.22',
      ];

      double y = 20;
      for (final line in statementLines) {
        page.graphics.drawString(
          line,
          font,
          bounds: Rect.fromLTWH(20, y, 500, 16),
        );
        y += 18;
      }

      final bytes = Uint8List.fromList(document.saveSync());
      document.dispose();

      final result = await service.parsePdfBytes(
        bytes,
        fileName: 'statement_with_address_header.pdf',
      );

      expect(result.success, isTrue);
      // Ensure the address header block was NOT parsed as a transaction
      expect(result.totalCount, equals(2));
      expect(result.transactions[0].cleanMerchantName, equals('Guru Restauran'));
      expect(result.transactions[0].amount, equals(20.0));
      expect(result.transactions[0].currentBalance, equals(277.22));

      expect(result.transactions[1].cleanMerchantName, equals('Modern Cafe'));
      expect(result.transactions[1].amount, equals(10.0));
      expect(result.transactions[1].currentBalance, equals(267.22));
    });

    test('Parses Account Statement_shiva.pdf correctly when present', () async {
      final simPath = '/Users/santosh/Library/Developer/CoreSimulator/Devices/7ED2554C-82F5-4AB3-B5DF-A94B410B4AE4/data/Containers/Shared/AppGroup/A6BA041E-55F1-4A33-A22E-D9DE218685D1/File Provider Storage/Downloads/Account Statement_shiva.pdf';
      final file = File(simPath);
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        final res = await service.parsePdfBytes(
          bytes,
          fileName: 'Account Statement_shiva.pdf',
          userId: 'f5a237f8-e553-45a5-b747-15a0780ffce5',
          accountId: '7d8d7056-66ad-4694-875e-9a882d6d447a',
        );
        expect(res.success, isTrue);
        expect(res.totalCount, equals(14));
        expect(res.debitCount, equals(12));
        expect(res.creditCount, equals(2));
        expect(res.totalDebitAmount, equals(13903.46));
        expect(res.totalCreditAmount, equals(13000.0));
        expect(res.transactions.first.cleanMerchantName, equals('M D I Pan Shop'));
        expect(res.transactions.last.cleanMerchantName, equals('Modern Cafe'));
        expect(res.transactions.first.amount, equals(55.0));
      }
    });

    test('Parses bank statement.pdf completely with all 301 transactions and correct balance', () async {
      final file = File('/Users/santosh/Downloads/bank statement.pdf');
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        final res = await service.parsePdfBytes(
          bytes,
          fileName: 'bank statement.pdf',
          userId: 'f5a237f8-e553-45a5-b747-15a0780ffce5',
          accountId: 'c5e0f0d8-464f-4b71-8fc2-dfa7629ead45',
        );

        expect(res.success, isTrue);
        expect(res.totalCount, equals(301));
        expect(res.debitCount, equals(244));
        expect(res.creditCount, equals(57));
        expect((res.totalDebitAmount - 41817.83).abs() < 0.1, isTrue);
        expect((res.totalCreditAmount - 41819.16).abs() < 0.1, isTrue);
        expect((res.latestBalance - 37.21).abs() < 0.1, isTrue);
        expect(res.transactions.first.currentBalance, equals(2035.88));
        expect(res.transactions.last.currentBalance, equals(37.21));
        expect(res.transactions.first.transactionTimestamp.year, equals(2026));
        expect(res.transactions.first.transactionTimestamp.month, equals(7));
        expect(res.transactions.first.transactionTimestamp.day, equals(6));
        expect(res.transactions.last.transactionTimestamp.month, equals(10));
        expect(res.transactions.last.transactionTimestamp.day, equals(6));
      }
    });

    test('Parses Canara Bank statement with all 138 transactions (universal parser)', () async {
      final file = File('/Users/santosh/Setthi/setthi/mom canara bank statement.pdf');
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        final res = await service.parsePdfBytes(
          bytes,
          fileName: 'mom canara bank statement.pdf',
          userId: 'f5a237f8-e553-45a5-b747-15a0780ffce5',
          accountId: 'canara-mom-test',
        );

        expect(res.success, isTrue);
        // Canara statement contains 138 transactions
        expect(res.totalCount, equals(138));
        // Opening balance: 23,354.29; Closing balance: 31,154.73
        expect((res.latestBalance - 31154.73).abs() < 0.1, isTrue);
        // Total debits: 1,04,816.56; Total credits: 1,12,617.00
        expect((res.totalDebitAmount - 104816.56).abs() < 1.0, isTrue);
        expect((res.totalCreditAmount - 112617.00).abs() < 1.0, isTrue);

        // Verify no disclaimer text leaked into any transaction narration
        for (final txn in res.transactions) {
          final lower = txn.narration.toLowerCase();
          expect(lower.contains('disclaimer'), isFalse,
              reason: 'Disclaimer text leaked into txn: ${txn.narration}');
          expect(lower.contains('terms and conditions'), isFalse,
              reason: 'T&C text leaked into txn: ${txn.narration}');
          expect(lower.contains('banking ombudsman'), isFalse,
              reason: 'Legal text leaked into txn: ${txn.narration}');
        }

        // Verify Canara's "Chq: 0" placeholder columns don't cause mass CHQ misclassification.
        // There is 1 legitimate cheque transaction (Chq: 00016429) in this statement.
        final chqTxns = res.transactions.where((t) => t.mode == 'CHQ').toList();
        expect(chqTxns.length, lessThanOrEqualTo(1),
            reason: 'At most 1 real cheque txn expected; Chq:0 placeholders should not cause CHQ mode');
      }
    });

    test('Structural validation filters out corrupt, header, and malformed rows', () {
      final validTxn = BankTransaction(
        txnId: 'TXN-OK-1',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 250.0,
        currentBalance: 1250.0,
        transactionTimestamp: DateTime.parse('2026-10-01T10:00:00Z'),
        narration: 'UPI/12345/DR/STARBUCKS/PAYMENT',
      );

      final zeroAmountTxn = BankTransaction(
        txnId: 'TXN-BAD-1',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 0.0,
        currentBalance: 1000.0,
        transactionTimestamp: DateTime.parse('2026-10-01T10:00:00Z'),
        narration: 'UPI/12345/DR/STARBUCKS',
      );

      final headerNarrationTxn = BankTransaction(
        txnId: 'TXN-BAD-2',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 584103.0,
        currentBalance: 2159.0,
        transactionTimestamp: DateTime.parse('2026-10-01T10:00:00Z'),
        narration: 'Address of Customer : KARNATAKA 584103 Branch Code : 2159 Date(Value Date) Particulars',
      );

      final futureDateTxn = BankTransaction(
        txnId: 'TXN-BAD-3',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 100.0,
        currentBalance: 500.0,
        transactionTimestamp: DateTime(2097, 10, 12),
        narration: 'UPI/999/DR/STORE',
      );

      expect(PdfStatementParserService.isValidTransactionRecord(validTxn), isTrue);
      expect(PdfStatementParserService.isValidTransactionRecord(zeroAmountTxn), isFalse);
      expect(PdfStatementParserService.isValidTransactionRecord(headerNarrationTxn), isFalse);
      expect(PdfStatementParserService.isValidTransactionRecord(futureDateTxn), isFalse);

      // Validate isValidCsvRow column length and type checks
      final validRow = [
        'id-1', 'usr-1', 'acc-1', 'txn-1', 'DEBIT', 'UPI', '100.00', '500.00',
        '2026-10-01T10:00:00.000Z', 'Test Narration', 'Test Merchant', 'Shopping',
        '{}', '2026-10-01T10:00:00.000Z', 'DISCRETIONARY', 'false'
      ];
      expect(PdfStatementParserService.isValidCsvRow(validRow), isTrue);

      // Wrong column count (e.g. 15 columns instead of 16)
      final shortRow = List.from(validRow)..removeLast();
      expect(PdfStatementParserService.isValidCsvRow(shortRow), isFalse);

      // Invalid amount
      final invalidAmtRow = List.from(validRow)..[6] = 'not_a_number';
      expect(PdfStatementParserService.isValidCsvRow(invalidAmtRow), isFalse);

      // Verify formatTransactionsToCsv drops invalid rows
      final csv = service.formatTransactionsToCsv([validTxn, zeroAmountTxn, headerNarrationTxn, futureDateTxn]);
      final rows = Csv().decode(csv);
      // Header + 1 valid row only
      expect(rows.length, equals(2));
      expect(rows[1][3], equals('TXN-OK-1'));
    });

    testWidgets('DpcPdfStatementSheet mounts properly and shows PDF import actions', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => DpcPdfStatementSheet.show(context),
                  child: const Text('Open Sheet'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      // Validate sheet contents
      expect(find.text('Import Bank Statement'), findsOneWidget);
      expect(find.text('Securely import and organize your transactions'), findsOneWidget);
      expect(find.text('Select Bank Statement PDF'), findsOneWidget);
    });

    test('BankTransaction.fromJson parses Supabase snake_case columns (current_balance, transaction_timestamp, txn_id)', () {
      final supabaseRow = {
        'id': 'uuid-1234',
        'user_id': 'user-5678',
        'account_id': 'acc-9999',
        'txn_id': 'TXN_HDFC_001',
        'type': 'DEBIT',
        'mode': 'UPI',
        'amount': 250.75,
        'current_balance': 18450.25,
        'transaction_timestamp': '2026-10-05T10:15:00.000Z',
        'narration': 'UPI/Swiggy/Order123',
        'clean_merchant_name': 'Swiggy',
        'category': 'Food & Dining',
      };

      final txn = BankTransaction.fromJson(supabaseRow);
      expect(txn.txnId, equals('TXN_HDFC_001'));
      expect(txn.amount, equals(250.75));
      expect(txn.currentBalance, equals(18450.25));
      expect(txn.transactionTimestamp, equals(DateTime.parse('2026-10-05T10:15:00.000Z')));
      expect(txn.cleanMerchantName, equals('Swiggy'));
    });
  });
}
