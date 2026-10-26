import 'dart:convert';
import 'dart:math';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/merchant_category_model.dart';
import '../models/transaction_model.dart';

/// Result object containing parsed transactions and export telemetry
class PdfStatementParseResult {
  final bool success;
  final bool isPasswordProtected;
  final String? errorMessage;
  final String? fileName;
  final int totalCount;
  final int debitCount;
  final int creditCount;
  final double totalDebitAmount;
  final double totalCreditAmount;
  final double latestBalance;
  final String? csvFilePath;
  final String? rootCsvFilePath;
  final String csvContent;
  final List<BankTransaction> transactions;
  final List<Map<String, dynamic>> rawRows;

  PdfStatementParseResult({
    required this.success,
    this.isPasswordProtected = false,
    this.errorMessage,
    this.fileName,
    this.totalCount = 0,
    this.debitCount = 0,
    this.creditCount = 0,
    this.totalDebitAmount = 0.0,
    this.totalCreditAmount = 0.0,
    this.latestBalance = 0.0,
    this.csvFilePath,
    this.rootCsvFilePath,
    this.csvContent = '',
    this.transactions = const [],
    this.rawRows = const [],
  });
}

/// Robust PDF Bank Statement Parser and CSV Generator service.
/// Extracts tabular financial records from PDF statements, maps them to the
/// Supabase `bank_transactions` table schema, and writes the output CSV file
/// to the workspace root directory and application documents directory.
class PdfStatementParserService {
  /// Regular expressions for detecting transaction dates in standard Indian banking statements:
  /// Examples: 01/10/2024, 01-10-2024, 01.10.2024, 01 Oct 2024, 01-Oct-2024, 2024-10-01
  static final RegExp _dateRegex = RegExp(
    r'^(?:#?\s*\d{1,5}[\.\-\)]?\s+)?(\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4}|\d{1,2}[/\s\-](?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[/\s\-]\d{2,4}|\d{4}[/\-\.]\d{1,2}[/\-\.]\d{1,2})(?:\s|$|(?=[()]))',
    caseSensitive: false,
  );

  /// Number parser regex to extract financial currency amounts with decimals or currency indicators
  static final RegExp _amountRegex = RegExp(
    r'(?:(?:Rs\.?|INR)\s*(-?(?:\d{1,3}(?:,\d{2,3})+|\d+)(?:\.\d{1,2})?)|(?:\b|\s|^)(-?(?:\d{1,3}(?:,\d{2,3})+|\d+)\.\d{1,2}))',
    caseSensitive: false,
  );

  /// Generates a compliant RFC-4122 v4 UUID without external dependencies
  static String generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10
    final hexChars = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .toList();
    return '${hexChars.sublist(0, 4).join()}-${hexChars.sublist(4, 6).join()}-${hexChars.sublist(6, 8).join()}-${hexChars.sublist(8, 10).join()}-${hexChars.sublist(10, 16).join()}';
  }

  /// Convenience wrapper for parsing PDF bytes
  Future<PdfStatementParseResult> parsePdfBytes(
    Uint8List pdfBytes, {
    String? fileName,
    String? userId,
    String? accountId,
    String? password,
  }) => parsePdfAndExportCsv(
    pdfBytes: pdfBytes,
    fileName: fileName,
    userId: userId,
    accountId: accountId,
    password: password,
  );

  /// Validates that a parsed transaction strictly conforms to the expected structural schema
  /// and is not an erroneous header, footer, or corrupt record.
  static bool isValidTransactionRecord(BankTransaction txn) {
    // 1. Amount validation: must be finite, non-zero, and positive
    if (txn.amount.isNaN || txn.amount.isInfinite || txn.amount <= 0) {
      return false;
    }

    // 2. Balance validation: must be finite and non-negative
    if (txn.currentBalance.isNaN ||
        txn.currentBalance.isInfinite ||
        txn.currentBalance < 0) {
      return false;
    }

    // 3. Timestamp validation: realistic date between year 2000 and near future
    final currentYear = DateTime.now().year;
    final year = txn.transactionTimestamp.year;
    if (year < 2000 || year > currentYear + 1) {
      return false;
    }

    // 4. Type validation: must be either DEBIT or CREDIT
    if (txn.type != TransactionType.debit &&
        txn.type != TransactionType.credit) {
      return false;
    }

    // 5. Narration validation: must be non-empty and not metadata or headers
    final narration = txn.narration.trim();
    if (narration.isEmpty || narration.length < 2) {
      return false;
    }

    final upperNarration = narration.toUpperCase();
    const disallowedPhrases = [
      'ADDRESS OF CUSTOMER',
      'BRANCH ADDRESS',
      'CUSTOMER DETAILS',
      'CUSTOMER ID',
      'BRANCH CODE',
      'LANDMARK',
      'PARTICULARS',
      'CHEQUE NO',
      'TRANSACTION TYPE',
      'DEBIT(RS)',
      'CREDIT(RS)',
      'BALANCE(RS)',
      'DATE(VALUE DATE)',
      'EFFECTIVE AVAILABLE BALANCE',
      'COMPUTER GENERATED STATEMENT',
      'TOTAL WITHDRAWAL',
      'TOTAL DEPOSIT',
      'STATEMENT OF THE ACCOUNT',
      'REPORT GENERATION',
      'ACCOUNT HOLDER',
      'NOMINEE REGISTERED',
    ];

    for (final phrase in disallowedPhrases) {
      if (upperNarration.contains(phrase)) {
        return false;
      }
    }

    // 6. Mode validation: must be a non-empty string
    if (txn.mode.trim().isEmpty) {
      return false;
    }

    return true;
  }

  /// Validates that a finalized CSV row strictly matches the 16-column
  /// Supabase `bank_transactions` table schema structure.
  static bool isValidCsvRow(List<dynamic> row) {
    // Must contain exactly 16 columns matching table schema
    if (row.length != 16) {
      return false;
    }

    // Required non-empty string columns: id, user_id, account_id, txn_id, type, mode, timestamp
    for (final idx in [0, 1, 2, 3, 4, 5, 8]) {
      final val = row[idx]?.toString().trim() ?? '';
      if (val.isEmpty) return false;
    }

    // Type must be DEBIT or CREDIT
    final typeStr = row[4].toString().toUpperCase();
    if (typeStr != 'DEBIT' && typeStr != 'CREDIT') {
      return false;
    }

    // Amount must be a positive number
    final amt = double.tryParse(row[6].toString().replaceAll(',', ''));
    if (amt == null || amt <= 0 || amt.isNaN || amt.isInfinite) {
      return false;
    }

    // Balance must be a valid non-negative number
    final bal = double.tryParse(row[7].toString().replaceAll(',', ''));
    if (bal == null || bal < 0 || bal.isNaN || bal.isInfinite) {
      return false;
    }

    // Timestamp must be a parseable ISO date in realistic range
    final timestamp = DateTime.tryParse(row[8].toString());
    if (timestamp == null ||
        timestamp.year < 2000 ||
        timestamp.year > DateTime.now().year + 1) {
      return false;
    }

    // Narration must not be empty
    final narration = row[9]?.toString().trim() ?? '';
    if (narration.isEmpty) {
      return false;
    }

    return true;
  }

  /// Ensures that all transactions have monotonically ordered timestamps,
  /// preserving intra-day transaction sequence for both ascending (oldest-first)
  /// and descending (newest-first) bank statements.
  static List<BankTransaction> ensureMonotonicTimestamps(List<BankTransaction> txns) {
    if (txns.length <= 1) return txns;

    // 1. Detect statement chronological direction
    bool isChronologicalAscending = false;
    final firstDate = txns.first.transactionTimestamp;
    final lastDate = txns.last.transactionTimestamp;
    if (lastDate.isAfter(firstDate)) {
      isChronologicalAscending = true;
    } else if (firstDate.isAfter(lastDate)) {
      isChronologicalAscending = false;
    } else {
      int minIdx = 0;
      int maxIdx = 0;
      DateTime minD = firstDate;
      DateTime maxD = firstDate;
      for (int i = 0; i < txns.length; i++) {
        final d = txns[i].transactionTimestamp;
        if (d.isBefore(minD)) {
          minD = d;
          minIdx = i;
        }
        if (d.isAfter(maxD)) {
          maxD = d;
          maxIdx = i;
        }
      }
      isChronologicalAscending = maxIdx >= minIdx;
    }

    // Normalize list to strictly chronological order (oldest to newest)
    final chronologicalTxns = isChronologicalAscending
        ? List<BankTransaction>.from(txns)
        : txns.reversed.toList();

    // 2. Group transactions by calendar day key ('YYYY-MM-DD')
    final dayGroups = <String, List<int>>{};
    for (int i = 0; i < chronologicalTxns.length; i++) {
      final t = chronologicalTxns[i];
      final key =
          '${t.transactionTimestamp.year}-${t.transactionTimestamp.month.toString().padLeft(2, '0')}-${t.transactionTimestamp.day.toString().padLeft(2, '0')}';
      dayGroups.putIfAbsent(key, () => []).add(i);
    }

    final result = List<BankTransaction>.from(chronologicalTxns);

    // 3. For each calendar day, assign increasing minute offsets and strictly increasing sequence (1..N)
    for (final indices in dayGroups.values) {
      final count = indices.length;
      for (int pos = 0; pos < count; pos++) {
        final txnIndex = indices[pos];
        final txn = result[txnIndex];

        final adjustedTime = DateTime.utc(
          txn.transactionTimestamp.year,
          txn.transactionTimestamp.month,
          txn.transactionTimestamp.day,
          12,
          0,
        ).add(Duration(minutes: pos + 1));

        result[txnIndex] = txn.copyWith(
          transactionTimestamp: adjustedTime,
          seq: txnIndex + 1,
        );
      }
    }

    return result;
  }

  /// Formats transactions into a CSV string matching Supabase bank_transactions schema
  String formatTransactionsToCsv(
    List<BankTransaction> transactions, {
    String? userId,
    String? accountId,
    String? fileName,
    String? explicitRowId,
  }) {
    final csvRows = <List<dynamic>>[
      [
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
      ],
    ];

    final nowUtcIso = DateTime.now().toUtc().toIso8601String();
    final effectiveUserId = userId ?? '00000000-0000-0000-0000-000000000000';
    final effectiveAccountId = accountId ?? generateUuidV4();

    // Filter out rows that do not fit the transaction structure
    final validTxns = transactions.where(isValidTransactionRecord).toList();
    final orderedTxns = ensureMonotonicTimestamps(validTxns);

    for (final txn in orderedTxns) {
      final rowId = explicitRowId ?? generateUuidV4();
      final rawMetadata = jsonEncode({
        'source': 'pdf_statement',
        'fileName': fileName ?? 'bank_statement.pdf',
        'parsedAt': nowUtcIso,
        'originalTxnId': txn.txnId,
      });

      final rowList = [
        rowId,
        effectiveUserId,
        effectiveAccountId,
        txn.txnId,
        txn.type.value,
        txn.mode,
        txn.amount,
        txn.currentBalance,
        txn.transactionTimestamp.toUtc().toIso8601String(),
        txn.narration,
        txn.cleanMerchantName,
        txn.category ?? 'Uncategorized',
        rawMetadata,
        nowUtcIso,
        txn.spendTier,
        txn.isRecurring,
      ];

      // Final structural sanity check before appending to CSV rows
      if (isValidCsvRow(rowList)) {
        csvRows.add(rowList);
      }
    }

    return Csv().encode(csvRows);
  }

  /// Parses the input PDF statement bytes, constructs structured records matching
  /// Supabase `bank_transactions`, and writes a CSV file to the root directory.
  Future<PdfStatementParseResult> parsePdfAndExportCsv({
    required Uint8List pdfBytes,
    String? fileName,
    String? userId,
    String? accountId,
    String? password,
  }) async {
    try {
      final document = PdfDocument(inputBytes: pdfBytes, password: password);
      final extractor = PdfTextExtractor(document);
      final textLines = extractor.extractTextLines();
      document.dispose();

      if (textLines.isEmpty) {
        return PdfStatementParseResult(
          success: false,
          errorMessage:
              'Unable to read text from this PDF. Please ensure you upload a digital statement directly downloaded from your bank app or net banking.',
          fileName: fileName,
        );
      }

      final parsedTransactions = <BankTransaction>[];
      final rawRowMaps = <Map<String, dynamic>>[];

      // Step 0: Pre-clean and join lines where narrow PDF columns split tokens
      // across lines (e.g. UPI reference IDs split mid-token before a date/timestamp).
      final cleanedLines = <String>[];
      for (int i = 0; i < textLines.length; i++) {
        final lineStr = textLines[i].text.trim();
        if (lineStr.isEmpty) continue;

        if (cleanedLines.isNotEmpty &&
            RegExp(r'/\d*$').hasMatch(cleanedLines.last) &&
            RegExp(r'^\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}').hasMatch(lineStr)) {
          cleanedLines[cleanedLines.length - 1] =
              '${cleanedLines.last}$lineStr';
        } else {
          cleanedLines.add(lineStr);
        }
      }

      // Step 1: Group lines into logical transaction blocks
      final List<List<String>> transactionBlocks = [];
      List<String> currentBlock = [];
      double detectedOpeningBalance = 0.0;

      for (int i = 0; i < cleanedLines.length; i++) {
        final lineStr = cleanedLines[i];

        final lower = lineStr.toLowerCase();

        // Detect initial opening balance from account summary
        if (lower.contains('opening balance')) {
          final amtMatches = _amountRegex.allMatches(lineStr).toList();
          if (amtMatches.isNotEmpty) {
            final lastMatch = amtMatches.last;
            final token = (lastMatch.group(1) ?? lastMatch.group(2))
                ?.replaceAll(',', '')
                .trim();
            if (token != null) {
              final bal = double.tryParse(token);
              if (bal != null) {
                detectedOpeningBalance = bal;
              }
            }
          }
          continue;
        }

        // Detect explicit end-of-statement termination (only after transactions have been read)
        if (transactionBlocks.isNotEmpty &&
            (lower.contains('end of statement') ||
             lower.contains('*** end of statement') ||
             lower.contains('--- end of report ---') ||
             lower.contains('this statement is closed'))) {
          if (currentBlock.isNotEmpty) {
            transactionBlocks.add(List.from(currentBlock));
            currentBlock.clear();
          }
          break;
        }

        // Summary header/footer lines that should be skipped without prematurely terminating statement reading
        if (lower.contains('account summary') ||
            lower.contains('effective available balance') ||
            lower.contains('effective balance') ||
            lower.contains('computer generated statement') ||
            lower.contains('total withdrawal') ||
            lower.contains('total deposit') ||
            lower.contains('closing balance') ||
            lower.contains('statement summary')) {
          if (currentBlock.isNotEmpty) {
            transactionBlocks.add(List.from(currentBlock));
            currentBlock.clear();
          }
          continue;
        }

        // Filter bank disclaimer / legal boilerplate that sometimes spans
        // multiple lines at the end of a statement (Canara Bank page 20+).
        if (_isDisclaimerLine(lower)) {
          continue;
        }

        // Skip standalone page number footers: "page 1", "Page 1 of 20", "1", etc.
        if (_isPageFooter(lower, lineStr)) {
          continue;
        }

        // Skip table headers, customer metadata, and pagination banners without dropping active transaction block
        if (lower.contains('statement generated') ||
            lower.contains('savings account transactions') ||
            lower.contains('current account transactions') ||
            lower.contains('# date description') ||
            lower.contains('customer details') ||
            lower.contains('customer id') ||
            lower.contains('branch address') ||
            lower.contains('branch phone') ||
            lower.contains('address of customer') ||
            lower.contains('account holder') ||
            lower.contains('account no.') ||
            lower.contains('crn ') ||
            lower.contains('account statement') ||
            lower.contains('currency indian rupee') ||
            lower.contains('nominee registered') ||
            lower.contains('account status') ||
            lower.contains('account type') ||
            lower.contains('micr ') ||
            lower.contains('contact no') ||
            lower.contains('email id') ||
            lower.contains('ifs code') ||
            lower.contains('ifsc code') ||
            lower.contains('branch code') ||
            lower.contains('report generation') ||
            lower.contains('statement of the account') ||
            lower.contains('landmark') ||
            lower.contains('date(value') ||
            lower.contains('particulars') ||
            lower.contains('cheque no') ||
            lower.contains('ref no.') ||
            lower.contains('transaction type') ||
            lower.contains('debit(rs)') ||
            lower.contains('credit(rs)') ||
            lower.contains('balance(rs)')) {
          // Just skip the header/banner line without clearing currentBlock
          continue;
        }

        // Skip stand-alone date range banner lines without amounts (e.g. "05 Jul 2026 - 06 Oct 2026")
        if (lower.contains(' - ') &&
            !lower.contains('.') &&
            _amountRegex.allMatches(lineStr).isEmpty) {
          continue;
        }

        // Detect totals summary line with only numbers/dashes (e.g. "13,903.46 13,000.00")
        // Only treat as table totals if the current transaction block already contains its amounts
        if (RegExp(r'^[\s\d,.\-]+$').hasMatch(lineStr) &&
            _amountRegex.allMatches(lineStr).length >= 2) {
          final blockText = currentBlock.join(' ');
          final blockAmounts = _amountRegex.allMatches(blockText).length;
          if (blockAmounts >= 2) {
            if (currentBlock.isNotEmpty) {
              transactionBlocks.add(List.from(currentBlock));
              currentBlock.clear();
            }
            continue;
          }
        }

        // Check if line begins with a transaction date (with optional row number)
        if (_startsWithDate(lineStr)) {
          if (currentBlock.isNotEmpty) {
            transactionBlocks.add(List.from(currentBlock));
            currentBlock.clear();
          }
          currentBlock.add(lineStr);
        } else if (currentBlock.isNotEmpty) {
          // Append continuation narration or amounts line
          currentBlock.add(lineStr);
        }
      }

      if (currentBlock.isNotEmpty) {
        transactionBlocks.add(currentBlock);
      }

      // Step 1B: Stitch orphan date-only blocks into the next transaction block.
      // Some banks (e.g. Canara) split date onto a separate line at page
      // boundaries, producing a block like ["9/08/2026"] followed by the
      // narration+amounts block. Merge these orphans forward.
      _stitchOrphanDateBlocks(transactionBlocks);

      // Step 1C: Reconnect word-wrapped counterparty fragments.
      // Narrow PDF columns sometimes split words mid-way (e.g. "SANTOS" on
      // one line + "H" on the next), producing broken narrations. Fix them.
      for (int bi = 0; bi < transactionBlocks.length; bi++) {
        transactionBlocks[bi] = _reconnectSplitWords(transactionBlocks[bi]);
      }

      // Step 2: Parse each transaction block into structured records
      double previousKnownBalance = detectedOpeningBalance;
      final dailyOccurrenceMap = <String, int>{};

      for (int bIndex = 0; bIndex < transactionBlocks.length; bIndex++) {
        final block = transactionBlocks[bIndex];
        final parsedTxn = _parseBlockToTransaction(
          block,
          previousBalance: previousKnownBalance,
          userId: userId,
          index: bIndex,
          occurrenceMap: dailyOccurrenceMap,
        );

        if (parsedTxn != null) {
          parsedTransactions.add(parsedTxn);
          if (parsedTxn.currentBalance > 0) {
            previousKnownBalance = parsedTxn.currentBalance;
          }
        }
      }

      if (parsedTransactions.isEmpty) {
        return PdfStatementParseResult(
          success: false,
          errorMessage:
              'Unable to find transactions in this statement. Please make sure this document contains your transaction history.',
          fileName: fileName,
        );
      }

      // Step 2B: Strict structural validation filter
      // Discard any rows that do not fit the required transaction schema
      final validTransactions = parsedTransactions
          .where(isValidTransactionRecord)
          .toList();

      if (validTransactions.isEmpty) {
        return PdfStatementParseResult(
          success: false,
          errorMessage:
              'No verified transactions could be recognized in this statement. Please check the document and try again.',
          fileName: fileName,
        );
      }

      // Step 3: Format records to match Supabase `bank_transactions` table exactly:
      // Columns: id, user_id, account_id, txn_id, type, mode, amount, current_balance,
      // transaction_timestamp, narration, clean_merchant_name, category, raw_data,
      // created_at, spend_tier, is_recurring
      final List<List<dynamic>> csvRows = [
        [
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
        ],
      ];

      final nowUtcIso = DateTime.now().toUtc().toIso8601String();
      double totalDebit = 0.0;
      double totalCredit = 0.0;
      int debitCount = 0;
      int creditCount = 0;
      final effectiveUserId = userId ?? '00000000-0000-0000-0000-000000000000';
      final effectiveAccountId = accountId ?? generateUuidV4();
      final finalizedTransactions = <BankTransaction>[];

      final orderedTransactions = ensureMonotonicTimestamps(validTransactions);

      for (final txn in orderedTransactions) {
        final rowId = generateUuidV4();
        final isCredit = txn.type == TransactionType.credit;

        final rawMetadata = jsonEncode({
          'source': 'pdf_statement',
          'fileName': fileName ?? 'bank_statement.pdf',
          'parsedAt': nowUtcIso,
          'originalTxnId': txn.txnId,
        });

        final rowList = [
          rowId,
          effectiveUserId,
          effectiveAccountId,
          txn.txnId,
          txn.type.value,
          txn.mode,
          txn.amount.toStringAsFixed(2),
          txn.currentBalance.toStringAsFixed(2),
          txn.transactionTimestamp.toUtc().toIso8601String(),
          txn.narration,
          txn.cleanMerchantName,
          txn.category ?? 'Uncategorized',
          rawMetadata,
          nowUtcIso,
          txn.spendTier,
          txn.isRecurring ? 'true' : 'false',
        ];

        // Before finalizing the CSV data, filter out any row that does not fit the structure at all
        if (!isValidCsvRow(rowList)) {
          debugPrint(
            '[PDF Statement Parser] Discarding row failing structural validation: $rowList',
          );
          continue;
        }

        if (isCredit) {
          totalCredit += txn.amount;
          creditCount++;
        } else {
          totalDebit += txn.amount;
          debitCount++;
        }

        csvRows.add(rowList);
        finalizedTransactions.add(txn);

        rawRowMaps.add({
          'id': rowId,
          'user_id': effectiveUserId,
          'account_id': effectiveAccountId,
          'txn_id': txn.txnId,
          'type': txn.type.value,
          'mode': txn.mode,
          'amount': txn.amount,
          'current_balance': txn.currentBalance,
          'transaction_timestamp': txn.transactionTimestamp.toIso8601String(),
          'narration': txn.narration,
          'clean_merchant_name': txn.cleanMerchantName,
          'category': txn.category ?? 'Uncategorized',
          'raw_data': rawMetadata,
          'created_at': nowUtcIso,
          'spend_tier': txn.spendTier,
          'is_recurring': txn.isRecurring,
          'seq': txn.seq,
        });
      }

      // Step 4: Generate in-memory CSV string for preview or testing
      final csvString = Csv().encode(csvRows);

      // Resolve true closing balance based on statement direction
      bool isAscending = false;
      if (finalizedTransactions.length > 1) {
        final firstDate = finalizedTransactions.first.transactionTimestamp;
        final lastDate = finalizedTransactions.last.transactionTimestamp;
        if (lastDate.isAfter(firstDate)) {
          isAscending = true;
        } else if (firstDate.isAfter(lastDate)) {
          isAscending = false;
        } else {
          isAscending = true;
        }
      }

      BankTransaction? closingTxn;
      if (isAscending) {
        for (int i = finalizedTransactions.length - 1; i >= 0; i--) {
          if (finalizedTransactions[i].currentBalance > 0) {
            closingTxn = finalizedTransactions[i];
            break;
          }
        }
      } else {
        for (int i = 0; i < finalizedTransactions.length; i++) {
          if (finalizedTransactions[i].currentBalance > 0) {
            closingTxn = finalizedTransactions[i];
            break;
          }
        }
      }

      final latestBal = closingTxn?.currentBalance ??
          (finalizedTransactions.isNotEmpty
              ? (isAscending
                  ? finalizedTransactions.last.currentBalance
                  : finalizedTransactions.first.currentBalance)
              : 0.0);

      return PdfStatementParseResult(
        success: true,
        fileName: fileName,
        totalCount: finalizedTransactions.length,
        debitCount: debitCount,
        creditCount: creditCount,
        totalDebitAmount: totalDebit,
        totalCreditAmount: totalCredit,
        latestBalance: latestBal,
        csvFilePath: null,
        rootCsvFilePath: null,
        csvContent: csvString,
        transactions: finalizedTransactions,
        rawRows: rawRowMaps,
      );
    } catch (e, stack) {
      final errStr = e.toString().toLowerCase();
      final isPassword = errStr.contains('password') || errStr.contains('encrypted');
      if (isPassword) {
        debugPrint('[PDF Statement Parser] Statement "$fileName" is password-protected.');
        return PdfStatementParseResult(
          success: false,
          isPasswordProtected: true,
          errorMessage: 'This statement is password-protected. Please enter your password to unlock it.',
          fileName: fileName,
        );
      }
      debugPrint('[PDF Statement Parser] Unexpected parsing error: $e\n$stack');
      return PdfStatementParseResult(
        success: false,
        errorMessage: 'Unable to read this statement. Please check the document format and try again.',
        fileName: fileName,
      );
    }
  }

  /// Checks if a string line begins with a date pattern
  bool _startsWithDate(String line) {
    final trimmed = line.trim();
    return _dateRegex.hasMatch(trimmed);
  }

  // ---------------------------------------------------------------------------
  // Universal structural filters (bank-agnostic)
  // ---------------------------------------------------------------------------

  /// Detects standalone page number footers like "page 1", "Page 3 of 20",
  /// or bare page numbers ("1", "12") that leak into narrations.
  static bool _isPageFooter(String lower, String raw) {
    // "page X" or "page X of Y"
    if (RegExp(r'^page\s+\d+(\s+of\s+\d+)?\s*$').hasMatch(lower)) return true;
    // Bare single- or double-digit page numbers at the very start of a line
    if (RegExp(r'^\d{1,3}$').hasMatch(raw.trim())) return true;
    return false;
  }

  /// Detects legal disclaimer / boilerplate text that sometimes spans the
  /// last 1-2 pages of bank PDFs (e.g. Canara Bank page 20).
  static bool _isDisclaimerLine(String lower) {
    const disclaimerSignals = [
      'terms and conditions',
      'disclaimer',
      'subject to',
      'jurisdiction',
      'liability',
      'authorized signatory',
      'digitally signed',
      'this is a computer generated',
      'any discrepancy',
      'grievance',
      'banking ombudsman',
      'rbi circular',
      'reserve bank of india',
      'the bank shall not',
      'customers are requested',
      'kindly report',
      'registered office',
      'head office',
      'toll free',
      'www.',
      'http',
    ];
    for (final signal in disclaimerSignals) {
      if (lower.contains(signal)) return true;
    }
    return false;
  }

  /// Merges orphan date-only blocks into the next transaction block.
  /// An orphan is a block that contains only a date line (no amounts),
  /// typically produced when a page break separates the date row from
  /// its narration/amounts continuation on the next page.
  static void _stitchOrphanDateBlocks(List<List<String>> blocks) {
    for (int i = blocks.length - 1; i >= 0; i--) {
      final block = blocks[i];
      if (block.isEmpty) continue;

      // An orphan block has 1-2 lines, starts with a date, and carries no
      // financial amount whatsoever.
      if (block.length > 2) continue;
      final joined = block.join(' ');
      if (!PdfStatementParserService._dateRegex.hasMatch(block.first.trim())) {
        continue;
      }
      if (PdfStatementParserService._amountRegex.hasMatch(joined)) continue;

      // Merge into the *next* block (the narration/amounts that follow)
      if (i + 1 < blocks.length) {
        blocks[i + 1].insertAll(0, block);
        blocks.removeAt(i);
      }
    }
  }

  /// Reconnects word fragments that were split across two adjacent lines
  /// in narrow PDF columns. Example: ["SANTOS", "H PATIL"] → ["SANTOSH PATIL"].
  /// Only joins when the previous line ends with an uppercase letter (no space/
  /// punctuation) and the next line starts with an uppercase letter, suggesting
  /// a mid-word split rather than a natural line break.
  static List<String> _reconnectSplitWords(List<String> lines) {
    if (lines.length < 2) return lines;
    final result = <String>[lines.first];
    for (int i = 1; i < lines.length; i++) {
      final prev = result.last;
      final curr = lines[i];
      // If previous line ends with an uppercase letter and current line starts
      // with 1-3 uppercase letters followed by a space or end-of-string,
      // the fragment was likely split mid-word.
      if (prev.isNotEmpty &&
          curr.isNotEmpty &&
          RegExp(r'[A-Z]$').hasMatch(prev) &&
          RegExp(r'^[A-Z]{1,3}(\s|$)').hasMatch(curr)) {
        // Concatenate without a space to heal the split word
        result[result.length - 1] = prev + curr;
      } else {
        result.add(curr);
      }
    }
    return result;
  }

  /// Parses a combined block of lines into a single `BankTransaction`
  BankTransaction? _parseBlockToTransaction(
    List<String> blockLines, {
    required double previousBalance,
    String? userId,
    required int index,
    Map<String, int>? occurrenceMap,
  }) {
    if (blockLines.isEmpty) return null;

    final firstLine = blockLines.first;
    final dateMatch = _dateRegex.firstMatch(firstLine);
    if (dateMatch == null) return null;

    final rawDateStr = dateMatch.group(1) ?? dateMatch.group(0)!;
    final txnDateTime = _parseIndianDate(rawDateStr) ?? DateTime.now();

    // Skip statement date range banners like "05 Jul 2026 - 06 Oct 2026"
    if (blockLines.length == 1 &&
        blockLines.first.contains(' - ') &&
        !blockLines.first.contains('.')) {
      return null;
    }

    // The remainder of the lines after date extraction form the row content
    final fullBlockText = blockLines.join(' ');
    final upperBlock = fullBlockText.toUpperCase();

    // Drop account profile / branch header metadata blocks
    if (upperBlock.contains('ACCOUNT NO') ||
        upperBlock.contains('IFSC CODE') ||
        upperBlock.contains('NOMINEE REGISTERED') ||
        upperBlock.contains('ACCOUNT STATUS') ||
        upperBlock.contains('ACCOUNT TYPE') ||
        upperBlock.contains('BRANCH CODE') ||
        upperBlock.contains('BRANCH ADDRESS') ||
        upperBlock.contains('ADDRESS OF CUSTOMER') ||
        upperBlock.contains('CUSTOMER ID') ||
        upperBlock.contains('CUSTOMER DETAILS') ||
        upperBlock.contains('ACCOUNT HOLDER') ||
        upperBlock.contains('LANDMARK') ||
        upperBlock.contains('DATE(VALUE DATE)') ||
        upperBlock.contains('PARTICULARS') ||
        upperBlock.contains('CHEQUE NO') ||
        upperBlock.contains('TRANSACTION TYPE') ||
        upperBlock.contains('DEBIT(RS)') ||
        upperBlock.contains('CREDIT(RS)') ||
        upperBlock.contains('BALANCE(RS)') ||
        upperBlock.contains('REPORT GENERATION') ||
        upperBlock.contains('STATEMENT OF THE ACCOUNT') ||
        upperBlock.contains('MICR ')) {
      return null;
    }

    // Validate transaction date year
    final currentYear = DateTime.now().year;
    if (txnDateTime.year > currentYear + 1 || txnDateTime.year < 2000) {
      return null;
    }

    final afterDate = fullBlockText.substring(dateMatch.end).trim();

    // Extract all numeric currency tokens from the block
    final amountMatches = _amountRegex.allMatches(afterDate).toList();
    final numbers = <double>[];

    for (final m in amountMatches) {
      final token = (m.group(1) ?? m.group(2))?.replaceAll(',', '').trim();
      if (token != null && token.isNotEmpty) {
        final val = double.tryParse(token);
        if (val != null) {
          numbers.add(val.abs());
        }
      }
    }

    if (numbers.isEmpty) {
      final fallbackMatches = RegExp(
        r'(?:^|\s)(-?\d{2,}(?:,\d{2,3})*)(?:\s|$)',
      ).allMatches(afterDate);
      for (final m in fallbackMatches) {
        final token = m.group(1)?.replaceAll(',', '').trim();
        if (token != null && token.isNotEmpty) {
          final val = double.tryParse(token);
          if (val != null) {
            numbers.add(val.abs());
          }
        }
      }
    }

    if (numbers.isEmpty) {
      return null;
    }

    double txnAmount = 0.0;
    double currentBal = 0.0;
    TransactionType txnType = TransactionType.debit;

    // Detect DR/CR indicators in narration
    final hasCrIndicator =
        upperBlock.contains('(CR)') ||
        upperBlock.contains('/CR/') ||
        upperBlock.contains(' CR ') ||
        upperBlock.endsWith('CR') ||
        upperBlock.contains('CREDIT') ||
        upperBlock.contains('REFUND') ||
        upperBlock.contains('SALARY') ||
        upperBlock.contains('INTEREST PAID');

    final hasDrIndicator =
        upperBlock.contains('(DR)') ||
        upperBlock.contains('/DR/') ||
        upperBlock.contains(' DR ') ||
        upperBlock.endsWith('DR') ||
        upperBlock.contains('DEBIT') ||
        upperBlock.contains('WITHDRAWAL') ||
        upperBlock.contains('TRANSFER TO');

    if (numbers.length >= 2) {
      // In bank statement tables, the last number is the running balance,
      // and the second-to-last is the debit or credit transaction amount.
      txnAmount = numbers[numbers.length - 2];
      currentBal = numbers[numbers.length - 1];

      final crExpected = (previousBalance + txnAmount);
      final drExpected = (previousBalance - txnAmount);

      if (previousBalance > 0 && (crExpected - currentBal).abs() < 0.05) {
        txnType = TransactionType.credit;
      } else if (previousBalance > 0 &&
          (drExpected - currentBal).abs() < 0.05) {
        txnType = TransactionType.debit;
      } else if (hasCrIndicator && !hasDrIndicator) {
        txnType = TransactionType.credit;
      } else if (hasDrIndicator) {
        txnType = TransactionType.debit;
      } else if (previousBalance > 0) {
        // If balance increased, credit; if decreased, debit
        if (currentBal > previousBalance) {
          txnType = TransactionType.credit;
        } else {
          txnType = TransactionType.debit;
        }
      } else {
        txnType = TransactionType.debit;
      }
    } else {
      // Single number layout: [Amount]
      txnAmount = numbers[0];
      currentBal = previousBalance;
      txnType = hasCrIndicator ? TransactionType.credit : TransactionType.debit;
    }

    if (txnAmount <= 0) return null;

    // Clean narration by removing the trailing numbers from the text and leading value dates
    String cleanNarration = afterDate.replaceFirst(
      RegExp(r'^\s*\([0-9A-Za-z/\.\-]+\)\s*'),
      '',
    );
    if (numbers.isNotEmpty) {
      // Cut off trailing balance and amounts to preserve pure merchant narration
      for (int k = 0; k < numbers.length; k++) {
        cleanNarration = cleanNarration.replaceFirst(
          RegExp(r'[,0-9]+\.[0-9]{1,2}'),
          '',
        );
      }
    }
    cleanNarration = cleanNarration
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'(?:Rs\.?|INR|\(Dr\)|\(Cr\)|DR|CR|[\-])\s*$'), '')
        .trim();

    if (cleanNarration.isEmpty) {
      cleanNarration = afterDate
          .replaceFirst(RegExp(r'^\s*\([0-9A-Za-z/\.\-]+\)\s*'), '')
          .trim();
      if (cleanNarration.isEmpty) cleanNarration = afterDate;
    }

    // Detect payment mode from narration prefix.
    // Hierarchical priority: explicit prefix > keyword in narration > block context.
    // IMPORTANT: CHQ detection requires a real cheque reference, not just the
    // word "Chq" from a Canara-style "Chq: 0" column placeholder.
    String mode = 'OTHER';
    final normNarr = cleanNarration.trim().toUpperCase();
    if (RegExp(r'^(PCI|PCD)/').hasMatch(normNarr)) {
      mode = 'CARD';
    } else if (RegExp(r'^UPI/').hasMatch(normNarr)) {
      mode = 'UPI';
    } else if (RegExp(r'^(RECD:)?IMPS/|^MB:RECEIVED').hasMatch(normNarr)) {
      mode = 'IMPS';
    } else if (normNarr.contains('DECLINE') ||
        normNarr.contains('CHG') ||
        normNarr.contains('CHARGE') ||
        normNarr.contains('FEE') ||
        normNarr.contains('INTEREST') ||
        normNarr.contains('SBINT')) {
      mode = 'BANK';
    } else if (normNarr.contains('NEFT')) {
      mode = 'NEFT';
    } else if (normNarr.contains('RTGS')) {
      mode = 'RTGS';
    } else if (normNarr.contains('ATM') || normNarr.contains('CASH')) {
      mode = 'CASH';
    } else if (_hasRealChequeReference(normNarr)) {
      mode = 'CHQ';
    } else if (normNarr.contains('ACH') ||
        normNarr.contains('NACH') ||
        normNarr.contains('ECS')) {
      mode = 'AUTODEBIT';
    } else if (normNarr.contains('NETBANKING') || normNarr.contains('INB')) {
      mode = 'NETBANKING';
    } else if (upperBlock.contains('CARD') ||
        upperBlock.contains('POS') ||
        upperBlock.contains('ECOM')) {
      mode = 'CARD';
    } else if (upperBlock.contains('UPI')) {
      mode = 'UPI';
    }

    // Mask sensitive financial PII in raw narrations
    final sanitizedNarration = _sanitizeNarrationPii(cleanNarration);

    // Infer category and merchant name
    final matchedRule = MerchantCategoryRegistry.instance.findMatch(
      sanitizedNarration,
    );
    final category = matchedRule?.category;
    final precomputedName = matchedRule?.cleanName;

    // Deterministic unique txn_id based on immutable transaction properties
    final dateIsoStr = txnDateTime.toIso8601String().split('T').first;
    final normNarration = sanitizedNarration.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final fingerprint = '${dateIsoStr}_${txnAmount.toStringAsFixed(2)}_${txnType.value}_$normNarration';
    final occ = occurrenceMap != null
        ? occurrenceMap.update(fingerprint, (v) => v + 1, ifAbsent: () => 1)
        : 1;
    final hashHex = (fingerprint.hashCode & 0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
    final uniqueRef = occ > 1
        ? 'STMT_${dateIsoStr}_${hashHex}_$occ'
        : 'STMT_${dateIsoStr}_$hashHex';

    return BankTransaction(
      txnId: uniqueRef,
      type: txnType,
      mode: mode,
      amount: txnAmount,
      currentBalance: currentBal,
      transactionTimestamp: txnDateTime,
      narration: sanitizedNarration,
      category: category,
      precomputedMerchantName: precomputedName,
      seq: index + 1,
    );
  }

  /// Masks sensitive financial PII such as full account numbers, card numbers, and mobile numbers
  static String _sanitizeNarrationPii(String raw) {
    var text = raw;
    // Mask 9-18 digit account numbers / card numbers (leaving last 4 digits visible)
    text = text.replaceAllMapped(
      RegExp(r'\b\d{5,14}(\d{4})\b'),
      (m) => '••••${m.group(1)}',
    );
    // Mask 10-digit mobile numbers in UPI handles (e.g. 9876543210@paytm -> 98••••3210@paytm)
    text = text.replaceAllMapped(
      RegExp(r'\b(?:\+91|91)?([6-9]\d{1})\d{5}(\d{3})(?=@|\b)'),
      (m) => '${m.group(1)}••••${m.group(2)}',
    );
    return text;
  }

  /// Returns true only if the narration contains a genuine cheque reference,
  /// NOT a Canara-style placeholder column like "Chq: 0" or "Chq:000000".
  static bool _hasRealChequeReference(String upper) {
    if (!upper.contains('CHQ') && !upper.contains('CHEQUE')) return false;
    // Reject "CHQ: 0", "CHQ:0", "CHQ:000000", "CHQ : 0" — these are empty
    // cheque-number columns printed by banks like Canara for non-cheque txns.
    if (RegExp(r'CHQ\s*:\s*0+\b', caseSensitive: false).hasMatch(upper)) {
      return false;
    }
    // Reject dangling "Chq:" at end-of-string with no number following
    if (RegExp(r'CHQ\s*:\s*$', caseSensitive: false).hasMatch(upper)) {
      return false;
    }
    // Reject placeholder where cheque number is only bullets or zeros
    if (RegExp(r'CHQ\s*:\s*[•\u2022\s0]+$', caseSensitive: false).hasMatch(upper)) {
      return false;
    }
    return true;
  }

  /// Parses date formats commonly found in Indian bank statements
  DateTime? _parseIndianDate(String raw) {
    try {
      final clean = raw.trim().replaceAll(RegExp(r'[\.\-\s]+'), '/');
      final parts = clean.split('/');

      if (parts.length >= 3) {
        int day = 0;
        int month = 0;
        int year = 0;

        // YYYY/MM/DD
        if (parts[0].length == 4) {
          year = int.parse(parts[0]);
          month = int.tryParse(parts[1]) ?? 1;
          day = int.tryParse(parts[2]) ?? 1;
        } else {
          // DD/MM/YYYY or DD/Mon/YYYY
          day = int.tryParse(parts[0]) ?? 1;
          final mStr = parts[1].toLowerCase();
          const monthMap = {
            'jan': 1,
            'feb': 2,
            'mar': 3,
            'apr': 4,
            'may': 5,
            'jun': 6,
            'jul': 7,
            'aug': 8,
            'sep': 9,
            'oct': 10,
            'nov': 11,
            'dec': 12,
          };

          if (monthMap.containsKey(mStr.substring(0, min(3, mStr.length)))) {
            month = monthMap[mStr.substring(0, min(3, mStr.length))]!;
          } else {
            month = int.tryParse(parts[1]) ?? 1;
          }

          year = int.tryParse(parts[2]) ?? DateTime.now().year;
          if (year < 100) {
            final nowYear = DateTime.now().year;
            final twoDigitNow = nowYear % 100;
            if (year <= twoDigitNow + 1) {
              year += 2000;
            } else {
              year += 1900;
            }
          }
        }

        return DateTime(year, month, day, 12, 0);
      }
    } catch (_) {}
    return null;
  }
}
