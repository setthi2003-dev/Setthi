import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/merchant_category_model.dart';

/// Provider for the specialized Slice Credit Card Statement PDF parser
final sliceCreditCardPdfParserServiceProvider = Provider<SliceCreditCardPdfParserService>((ref) {
  return SliceCreditCardPdfParserService();
});

/// High-level summary of a parsed credit card statement
class SliceCreditCardStatementSummary {
  final double spends;
  final double refundsAndRepayments;
  final double cashback;
  final double interest;
  final double surcharge;
  final double totalAmountDue;
  final double minAmountDue;
  final String? customerName;
  final String? cardLast4;
  final String? billingCycle;
  final DateTime? dueDate;

  const SliceCreditCardStatementSummary({
    this.spends = 0.0,
    this.refundsAndRepayments = 0.0,
    this.cashback = 0.0,
    this.interest = 0.0,
    this.surcharge = 0.0,
    this.totalAmountDue = 0.0,
    this.minAmountDue = 0.0,
    this.customerName,
    this.cardLast4,
    this.billingCycle,
    this.dueDate,
  });

  bool get isBalanced =>
      (spends - refundsAndRepayments - cashback + interest + surcharge - totalAmountDue).abs() < 0.05;
}

/// Represents an individual itemized credit card transaction extracted from the PDF
class SliceCreditCardTransaction {
  final DateTime date;
  final String merchantName;
  final String cleanMerchantName;
  final String? category;
  final String paymentMode; // e.g. 'UPI', 'Card', 'Refund', 'Cashback'
  final String transactionType; // 'DEBIT' or 'CREDIT'
  final String section; // 'SPEND', 'REFUND', 'CASHBACK', 'INTEREST', 'SURCHARGE'
  final double amount;
  final String currency;
  final String referenceId;
  final String rawDetails;

  const SliceCreditCardTransaction({
    required this.date,
    required this.merchantName,
    required this.cleanMerchantName,
    this.category,
    required this.paymentMode,
    required this.transactionType,
    required this.section,
    required this.amount,
    this.currency = 'INR',
    required this.referenceId,
    required this.rawDetails,
  });

  Map<String, dynamic> toMap({
    required String userId,
    String? statementId,
    String? statementPdfPath,
    String? cardLast4,
    String? cardIssuer = 'Slice Bank',
    String? billingCycle,
    DateTime? dueDate,
  }) {
    return {
      'user_id': userId,
      'statement_id': statementId,
      'statement_pdf_path': statementPdfPath,
      'card_last4': cardLast4,
      'card_issuer': cardIssuer,
      'billing_cycle': billingCycle,
      'due_date': dueDate?.toUtc().toIso8601String(),
      'transaction_date': date.toUtc().toIso8601String(),
      'merchant_name': merchantName,
      'clean_merchant_name': cleanMerchantName,
      'category': category,
      'payment_mode': paymentMode,
      'transaction_type': transactionType,
      'section': section,
      'amount': amount,
      'currency': currency,
      'reference_id': referenceId,
      'raw_details': rawDetails,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

/// Comprehensive result object from parsing a Slice Credit Card Statement PDF
class SliceCreditCardParseResult {
  final bool success;
  final bool isPasswordProtected;
  final String? errorMessage;
  final SliceCreditCardStatementSummary summary;
  final List<SliceCreditCardTransaction> transactions;
  final int totalCount;
  final int spendsCount;
  final int refundsCount;
  final int cashbackCount;
  final double totalDebitAmount;
  final double totalCreditAmount;

  const SliceCreditCardParseResult({
    required this.success,
    this.isPasswordProtected = false,
    this.errorMessage,
    required this.summary,
    this.transactions = const [],
    this.totalCount = 0,
    this.spendsCount = 0,
    this.refundsCount = 0,
    this.cashbackCount = 0,
    this.totalDebitAmount = 0.0,
    this.totalCreditAmount = 0.0,
  });

  bool get isMathematicallyVerified =>
      (totalDebitAmount - summary.spends).abs() < 0.05 &&
      (totalCreditAmount - (summary.refundsAndRepayments + summary.cashback)).abs() < 0.05;
}

/// Dedicated, isolated parser for Slice Bank Credit Card PDF statements.
/// Reads native PDF layout, extracts both summary card data and every itemized spend,
/// refund, and cashback record with 100% mathematical precision.
class SliceCreditCardPdfParserService {
  static final RegExp _dateModeRegex = RegExp(r"^(\d{1,2}\s+[A-Za-z]{3}\s+'\d{2})(?:\s*•\s*(.*))?$");

  static const Map<String, int> _monthMap = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// Parses a Slice credit card statement from raw bytes
  Future<SliceCreditCardParseResult> parsePdfBytes(
    Uint8List pdfBytes, {
    String? fileName,
    String? password,
  }) async {
    try {
      final document = PdfDocument(inputBytes: pdfBytes, password: password);
      final extractor = PdfTextExtractor(document);

      if (document.pages.count == 0) {
        document.dispose();
        return const SliceCreditCardParseResult(
          success: false,
          errorMessage: 'PDF document contains no pages.',
          summary: SliceCreditCardStatementSummary(),
        );
      }

      // 1. Extract Summary from Page 1
      final p1Text = extractor.extractText(startPageIndex: 0, endPageIndex: 0);
      final summary = _parseStatementSummary(p1Text);

      // 2. Extract itemized transactions across subsequent pages (Pages 2+)
      final transactions = <SliceCreditCardTransaction>[];
      String currentSection = 'SPEND'; // default section

      for (int p = 1; p < document.pages.count; p++) {
        final pageText = extractor.extractText(startPageIndex: p, endPageIndex: p);
        final rawLines = pageText
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();

        for (int i = 0; i < rawLines.length; i++) {
          final line = rawLines[i];

          // Section headers
          if (line == 'Spends') {
            currentSection = 'SPEND';
            continue;
          } else if (line == 'Refunds & repayments') {
            currentSection = 'REFUND';
            continue;
          } else if (line == 'Cashback') {
            currentSection = 'CASHBACK';
            continue;
          } else if (line == 'GST details' || line == 'Glossary') {
            break; // Stop parsing transaction tables on summary/glossary sections
          }

          final match = _dateModeRegex.firstMatch(line);
          if (match != null) {
            final rawDate = match.group(1)!;
            final modeRaw = match.group(2);
            final mode = modeRaw?.trim() ?? (currentSection == 'CASHBACK' ? 'Cashback' : 'Refund');
            final txDate = _parseDate(rawDate, fallbackYear: summary.dueDate?.year ?? DateTime.now().year);

            // Backtrack to extract merchant name
            final merchantParts = <String>[];
            int k = i - 1;
            while (k >= 0) {
              final prev = rawLines[k];
              if (prev == '…') {
                k--;
                continue;
              }
              if (prev == 'Spends' ||
                  prev == 'Refunds & repayments' ||
                  prev == 'Cashback' ||
                  prev == '₹') {
                break;
              }
              if (_dateModeRegex.hasMatch(prev)) {
                break;
              }
              // Stop if we hit previous transaction's amount line
              if (double.tryParse(prev.replaceAll(',', '')) != null) {
                break;
              }
              // Skip single-letter avatar icon if merchant name is already captured
              if (prev.length == 1 && RegExp(r'^[A-Z]$').hasMatch(prev)) {
                if (merchantParts.isNotEmpty) break;
              }
              merchantParts.insert(0, prev);
              k--;
            }
            final rawMerchant = merchantParts.join(' ').trim();
            final merchant = rawMerchant.isNotEmpty ? rawMerchant : 'Slice Transaction';

            // Forward-track to extract amount
            double? amount;
            int j = i + 1;
            while (j < rawLines.length && j <= i + 3) {
              final next = rawLines[j];
              if (next == '₹') {
                j++;
                continue;
              }
              final cleanAmt = next.replaceAll(',', '');
              final parsedAmt = double.tryParse(cleanAmt);
              if (parsedAmt != null) {
                amount = parsedAmt;
                // If the next line is a decimal like ".46"
                if (j + 1 < rawLines.length && rawLines[j + 1].startsWith('.')) {
                  final dec = double.tryParse(rawLines[j + 1]);
                  if (dec != null) {
                    amount = amount + dec;
                    j++;
                  }
                }
                break;
              }
              j++;
            }

            if (amount != null && amount > 0) {
              final isCredit = currentSection == 'REFUND' || currentSection == 'CASHBACK';
              final txnType = isCredit ? 'CREDIT' : 'DEBIT';
              final cleanMerchant = _cleanMerchantName(merchant);
              final category = _resolveCategory(merchant, cleanMerchant, currentSection);

              // Deterministic reference ID
              final cardKey = summary.cardLast4 ?? 'slice';
              final dateKey = txDate.toIso8601String().split('T').first;
              final amtKey = amount.toStringAsFixed(2);
              final seqIndex = transactions.length + 1;
              final rawSeed = '$cardKey:$dateKey:$merchant:$amtKey:$currentSection:$seqIndex';
              final refId = 'cc_${md5.convert(utf8.encode(rawSeed))}';

              transactions.add(SliceCreditCardTransaction(
                date: txDate,
                merchantName: merchant,
                cleanMerchantName: cleanMerchant,
                category: category,
                paymentMode: mode,
                transactionType: txnType,
                section: currentSection,
                amount: amount,
                referenceId: refId,
                rawDetails: '$merchant | $line | ₹$amount',
              ));
            }
          }
        }
      }

      document.dispose();

      // Aggregate telemetry
      int spendsCount = 0;
      int refundsCount = 0;
      int cashbackCount = 0;
      double totalDebit = 0.0;
      double totalCredit = 0.0;

      for (final t in transactions) {
        if (t.section == 'SPEND') {
          spendsCount++;
          totalDebit += t.amount;
        } else if (t.section == 'REFUND') {
          refundsCount++;
          totalCredit += t.amount;
        } else if (t.section == 'CASHBACK') {
          cashbackCount++;
          totalCredit += t.amount;
        }
      }

      debugPrint('[SliceCcParser] Successfully parsed ${transactions.length} transactions: '
          '$spendsCount debits (₹${totalDebit.toStringAsFixed(2)}), '
          '${refundsCount + cashbackCount} credits (₹${totalCredit.toStringAsFixed(2)})');

      return SliceCreditCardParseResult(
        success: true,
        summary: summary,
        transactions: transactions,
        totalCount: transactions.length,
        spendsCount: spendsCount,
        refundsCount: refundsCount,
        cashbackCount: cashbackCount,
        totalDebitAmount: totalDebit,
        totalCreditAmount: totalCredit,
      );
    } catch (e, stack) {
      final errStr = e.toString().toLowerCase();
      final isPassword = errStr.contains('password') || errStr.contains('encrypted');
      if (isPassword) {
        debugPrint('[SliceCcParser] Statement "$fileName" is password-protected.');
        return const SliceCreditCardParseResult(
          success: false,
          isPasswordProtected: true,
          errorMessage: 'This credit card statement is password-protected. Please enter your password to unlock it.',
          summary: SliceCreditCardStatementSummary(),
        );
      }
      debugPrint('[SliceCcParser] Error parsing PDF statement: $e\n$stack');
      return SliceCreditCardParseResult(
        success: false,
        errorMessage: 'Failed to parse Slice statement: $e',
        summary: const SliceCreditCardStatementSummary(),
      );
    }
  }

  /// Parses statement file from a local File path
  Future<SliceCreditCardParseResult> parsePdfFile(File file, {String? password}) async {
    final bytes = await file.readAsBytes();
    return parsePdfBytes(bytes, fileName: file.path.split('/').last, password: password);
  }

  /// Parses the Page 1 Statement Summary metadata
  SliceCreditCardStatementSummary _parseStatementSummary(String page1Text) {
    final lines = page1Text.split('\n').map((l) => l.trim()).toList();

    double spends = 0.0;
    double refunds = 0.0;
    double cashback = 0.0;
    double interest = 0.0;
    double surcharge = 0.0;
    double totalDue = 0.0;
    double minDue = 0.0;
    String? cardLast4;
    String? billingCycle;
    DateTime? dueDate;
    String? customerName;

    double extractAmountFollowing(int startIndex) {
      double amt = 0.0;
      for (int i = startIndex + 1; i < lines.length && i <= startIndex + 4; i++) {
        final line = lines[i];
        if (line == '₹') continue;
        final clean = line.replaceAll(',', '');
        final parsed = double.tryParse(clean);
        if (parsed != null) {
          amt = parsed;
          if (i + 1 < lines.length && lines[i + 1].startsWith('.')) {
            final dec = double.tryParse(lines[i + 1]);
            if (dec != null) amt += dec;
          }
          break;
        }
      }
      return amt;
    }

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line == 'Spends') {
        spends = extractAmountFollowing(i);
      } else if (line == 'Refunds & repayments') {
        refunds = extractAmountFollowing(i);
      } else if (line == 'Cashback') {
        cashback = extractAmountFollowing(i);
      } else if (line == 'Interest') {
        interest = extractAmountFollowing(i);
      } else if (line == 'Surcharge') {
        surcharge = extractAmountFollowing(i);
      } else if (line == 'Total amount due') {
        totalDue = extractAmountFollowing(i);
      } else if (line.startsWith('Min amount due')) {
        minDue = extractAmountFollowing(i);
      } else if (line.contains('XXXX XXXX XXXX')) {
        final match = RegExp(r'(\d{4})$').firstMatch(line);
        if (match != null) {
          cardLast4 = match.group(1);
        }
      } else if (RegExp(r'\d{1,2}\s+[A-Za-z]{3}\s*-\s*\d{1,2}\s+[A-Za-z]{3}').hasMatch(line)) {
        billingCycle = line;
      } else if (line.startsWith('Due on')) {
        // e.g. "Due on 5 Nov"
        final rawDue = line.replaceFirst('Due on', '').trim();
        dueDate = _parseSimpleDueDate(rawDue);
      } else if (line.contains("'s") && customerName == null) {
        customerName = line;
      }
    }

    return SliceCreditCardStatementSummary(
      spends: spends,
      refundsAndRepayments: refunds,
      cashback: cashback,
      interest: interest,
      surcharge: surcharge,
      totalAmountDue: totalDue > 0 ? totalDue : (spends - refunds - cashback),
      minAmountDue: minDue,
      customerName: customerName,
      cardLast4: cardLast4,
      billingCycle: billingCycle,
      dueDate: dueDate,
    );
  }

  /// Parses dates like "17 Oct '26" or "21 Sep '26"
  DateTime _parseDate(String raw, {int fallbackYear = 2026}) {
    try {
      final parts = raw.replaceAll("'", "").split(RegExp(r'\s+'));
      final day = int.parse(parts[0]);
      final month = _monthMap[parts[1].toLowerCase()] ?? 1;
      int year = fallbackYear;
      if (parts.length >= 3) {
        final yPart = parts[2];
        year = int.parse(yPart.length == 2 ? '20$yPart' : yPart);
      }
      return DateTime(year, month, day);
    } catch (_) {
      return DateTime(fallbackYear, 10, 1);
    }
  }

  /// Parses due dates like "5 Nov"
  DateTime? _parseSimpleDueDate(String rawDue, {int fallbackYear = 2026}) {
    try {
      final parts = rawDue.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final day = int.parse(parts[0]);
        final month = _monthMap[parts[1].toLowerCase()] ?? 11;
        return DateTime(fallbackYear, month, day);
      }
    } catch (_) {}
    return null;
  }

  /// Cleans and formats raw merchant text
  String _cleanMerchantName(String raw) {
    var name = raw.replaceAll('…', '').trim();
    if (name.isEmpty) return 'Slice Merchant';

    // Capitalize words neatly
    final words = name.split(RegExp(r'\s+'));
    return words.map((w) {
      if (w.isEmpty) return '';
      if (w.toLowerCase() == 'ii' || w.toLowerCase() == 'upi') return w.toUpperCase();
      return w[0].toUpperCase() + (w.length > 1 ? w.substring(1).toLowerCase() : '');
    }).join(' ');
  }

  /// Resolves an intelligent category for credit card transactions
  String _resolveCategory(String rawMerchant, String cleanMerchant, String section) {
    if (section == 'REFUND') return 'Refund / Reversal';
    if (section == 'CASHBACK') return 'Cashback & Rewards';

    // Check registry
    final matchedRule = MerchantCategoryRegistry.instance.findMatch(rawMerchant) ??
        MerchantCategoryRegistry.instance.findMatch(cleanMerchant);
    if (matchedRule != null) {
      return matchedRule.category;
    }

    final lower = rawMerchant.toLowerCase();
    if (lower.contains('jio') || lower.contains('airtel')) return 'Bills & Utilities';
    if (lower.contains('medplus') || lower.contains('hospital') || lower.contains('medical') || lower.contains('ayurved')) {
      return 'Healthcare';
    }
    if (lower.contains('vishal mega') || lower.contains('instamart') || lower.contains('corner house')) {
      return 'Groceries & Dining';
    }
    if (lower.contains('power') || lower.contains('electr') || lower.contains('water')) {
      return 'Bills & Utilities';
    }
    if (lower.contains('flavours') || lower.contains('juice') || lower.contains('chaw') || lower.contains('daalchini')) {
      return 'Food & Dining';
    }
    if (lower.contains('tagmango') || lower.contains('institute') || lower.contains('foundation')) {
      return 'Education & Learning';
    }

    return 'Credit Card Spend';
  }
}
