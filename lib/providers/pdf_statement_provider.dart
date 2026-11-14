import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/transaction_model.dart';
import '../services/pdf_statement_parser_service.dart';
import 'auth_providers.dart';
import 'supabase_provider.dart';
import 'transaction_providers.dart';

/// Provider for the [PdfStatementParserService] singleton instance
final pdfStatementParserServiceProvider = Provider<PdfStatementParserService>((ref) {
  return PdfStatementParserService();
});

/// State notifier storing the latest parsed PDF statement result
class LastParsedPdfResultNotifier extends Notifier<PdfStatementParseResult?> {
  @override
  PdfStatementParseResult? build() {
    ref.listen<User?>(currentUserProvider, (prev, next) {
      if (prev?.id != next?.id) {
        state = null;
      }
    });
    return null;
  }

  void setResult(PdfStatementParseResult result) {
    state = result;
  }

  void clear() {
    state = null;
  }
}

final lastParsedPdfResultProvider =
    NotifierProvider<LastParsedPdfResultNotifier, PdfStatementParseResult?>(
  LastParsedPdfResultNotifier.new,
);

class PdfStatementImportState {
  final bool isProcessing;
  final String? statusMessage;
  final String? errorMessage;
  final PdfStatementParseResult? result;
  final bool isPasswordProtected;
  final Uint8List? pendingBytes;
  final String? pendingFileName;
  final String? pendingStoragePath;

  const PdfStatementImportState({
    this.isProcessing = false,
    this.statusMessage,
    this.errorMessage,
    this.result,
    this.isPasswordProtected = false,
    this.pendingBytes,
    this.pendingFileName,
    this.pendingStoragePath,
  });

  PdfStatementImportState copyWith({
    bool? isProcessing,
    String? statusMessage,
    String? errorMessage,
    PdfStatementParseResult? result,
    bool? isPasswordProtected,
    Uint8List? pendingBytes,
    String? pendingFileName,
    String? pendingStoragePath,
  }) {
    return PdfStatementImportState(
      isProcessing: isProcessing ?? this.isProcessing,
      statusMessage: statusMessage,
      errorMessage: errorMessage,
      result: result ?? this.result,
      isPasswordProtected: isPasswordProtected ?? this.isPasswordProtected,
      pendingBytes: pendingBytes ?? this.pendingBytes,
      pendingFileName: pendingFileName ?? this.pendingFileName,
      pendingStoragePath: pendingStoragePath ?? this.pendingStoragePath,
    );
  }
}

class PdfStatementImportNotifier extends Notifier<PdfStatementImportState> {
  @override
  PdfStatementImportState build() {
    ref.listen<User?>(currentUserProvider, (prev, next) {
      if (prev?.id != next?.id) {
        state = const PdfStatementImportState();
      }
    });
    return const PdfStatementImportState();
  }

  /// Prompts the user to pick a PDF statement file, uploads it to Supabase Storage,
  /// and runs the Financial Statement Intelligence API via Supabase Edge Function.
  Future<PdfStatementParseResult?> pickAndParsePdf() async {
    state = state.copyWith(
      isProcessing: true,
      statusMessage: 'Selecting PDF statement file...',
      errorMessage: null,
    );

    try {
      List<PlatformFile> pickedFiles = [];
      try {
        pickedFiles = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['pdf'],
        );
      } catch (pickerErr) {
        debugPrint('[PdfPicker] Custom picker fallback to any: $pickerErr');
        pickedFiles = await FilePicker.pickFiles(
          type: FileType.any,
        );
      }

      if (pickedFiles.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          statusMessage: null,
        );
        return null;
      }

      final pickedFile = pickedFiles.first;
      if (!pickedFile.name.toLowerCase().endsWith('.pdf')) {
        state = state.copyWith(
          isProcessing: false,
          errorMessage: 'Please select a valid PDF bank statement file.',
        );
        return null;
      }

      final fileBytes = await pickedFile.xFile.readAsBytes();
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {}

      if (fileBytes.isEmpty) {
        state = state.copyWith(
          isProcessing: false,
          errorMessage: 'The selected PDF file is empty.',
        );
        return null;
      }

      final user = ref.read(currentUserProvider);
      final dbService = ref.read(supabaseDbServiceProvider);

      if (user == null) {
        state = state.copyWith(
          isProcessing: false,
          errorMessage: 'Please sign in to upload statements.',
        );
        return null;
      }

      state = state.copyWith(
        isProcessing: true,
        statusMessage: 'Uploading ${pickedFile.name} to secure vault...',
      );

      final storagePath = await dbService.uploadStatementPdfToStorage(
        userId: user.id,
        filename: pickedFile.name,
        pdfBytes: fileBytes,
      );

      if (storagePath == null) {
        state = state.copyWith(
          isProcessing: false,
          errorMessage: 'Could not upload statement PDF to storage vault.',
        );
        return null;
      }

      state = state.copyWith(
        isProcessing: true,
        statusMessage: 'Analyzing statement layout & OCR with Setthi AI... (~15s)',
        pendingBytes: fileBytes,
        pendingFileName: pickedFile.name,
        pendingStoragePath: storagePath,
      );

      try {
        final backendResult = await dbService.processStatementViaBackend(
          storagePath: storagePath,
          filename: pickedFile.name,
        );

        return await _handleBackendStatementResponse(
          response: backendResult,
          fileName: pickedFile.name,
          storagePath: storagePath,
          fileBytes: fileBytes,
        );
      } catch (backendErr) {
        debugPrint('[PdfStatementImportNotifier] Backend statement error: $backendErr');
        if (backendErr.toString().toLowerCase().contains('password')) {
          final parseResult = PdfStatementParseResult(
            success: false,
            isPasswordProtected: true,
            fileName: pickedFile.name,
            errorMessage: 'This PDF statement is password-protected.',
          );
          state = state.copyWith(
            isProcessing: false,
            isPasswordProtected: true,
            pendingBytes: fileBytes,
            pendingFileName: pickedFile.name,
            pendingStoragePath: storagePath,
            result: parseResult,
          );
          return parseResult;
        }
        rethrow;
      }
    } catch (e) {
      debugPrint('[PdfStatementImportNotifier] Error: $e');
      final errorResult = PdfStatementParseResult(
        success: false,
        errorMessage: 'Error processing statement: $e',
      );
      state = state.copyWith(
        isProcessing: false,
        errorMessage: 'Error processing statement: $e',
        result: errorResult,
      );
      return errorResult;
    }
  }

  /// Unlocks a password-protected PDF statement via backend and imports transactions
  Future<PdfStatementParseResult?> unlockWithPassword(String password) async {
    final pendingBytes = state.pendingBytes;
    final pendingName = state.pendingFileName;
    final pendingPath = state.pendingStoragePath;
    if (pendingBytes == null) return null;

    final user = ref.read(currentUserProvider);
    final dbService = ref.read(supabaseDbServiceProvider);

    state = state.copyWith(
      isProcessing: true,
      statusMessage: 'Unlocking statement and analyzing with Setthi AI... (~15s)',
      errorMessage: null,
    );

    try {
      String? storagePath = pendingPath;
      if (storagePath == null && user != null && pendingName != null) {
        storagePath = await dbService.uploadStatementPdfToStorage(
          userId: user.id,
          filename: pendingName,
          pdfBytes: pendingBytes,
        );
      }

      if (storagePath == null) {
        throw Exception('Could not locate uploaded statement path.');
      }

      final response = await dbService.processStatementViaBackend(
        storagePath: storagePath,
        filename: pendingName,
        password: password,
      );

      return await _handleBackendStatementResponse(
        response: response,
        fileName: pendingName ?? 'statement.pdf',
        storagePath: storagePath,
        fileBytes: pendingBytes,
      );
    } catch (e) {
      debugPrint('[PdfStatementImportNotifier] Unlock error: $e');
      final isWrongPassword = e.toString().toLowerCase().contains('password');
      final errorResult = PdfStatementParseResult(
        success: false,
        isPasswordProtected: isWrongPassword,
        errorMessage: isWrongPassword
            ? 'Incorrect password. Please try again.'
            : 'Error processing statement: $e',
      );
      state = state.copyWith(
        isProcessing: false,
        isPasswordProtected: isWrongPassword,
        errorMessage: errorResult.errorMessage,
        result: errorResult,
      );
      return errorResult;
    }
  }

  Future<PdfStatementParseResult?> _handleBackendStatementResponse({
    required Map<String, dynamic> response,
    required String fileName,
    required String storagePath,
    required Uint8List fileBytes,
  }) async {
    final status = response['status']?.toString();

    if (status == 'password_required') {
      final parseResult = PdfStatementParseResult(
        success: false,
        isPasswordProtected: true,
        fileName: fileName,
        errorMessage: 'This PDF statement is password-protected.',
      );
      state = state.copyWith(
        isProcessing: false,
        isPasswordProtected: true,
        pendingBytes: fileBytes,
        pendingFileName: fileName,
        pendingStoragePath: storagePath,
        errorMessage: null,
        result: parseResult,
      );
      return parseResult;
    }

    if (status == 'completed') {
      final rawResult = response['raw_result'] as Map<String, dynamic>?;
      final dbPayload = rawResult?['database_payload'] as Map<String, dynamic>?;
      final bankRows = (dbPayload?['bank_transactions'] as List?) ?? [];
      final cardRows = (dbPayload?['credit_card_transactions'] as List?) ?? [];

      final txns = <BankTransaction>[];
      int debitCount = 0;
      int creditCount = 0;
      double totalDebit = 0.0;
      double totalCredit = 0.0;

      for (final r in bankRows) {
        if (r is! Map) continue;
        final isDebit = r['type']?.toString().toUpperCase() == 'DEBIT';
        final amt = double.tryParse(r['amount']?.toString() ?? '0') ?? 0.0;
        final bal = double.tryParse(r['current_balance']?.toString() ?? '0') ?? 0.0;
        final timestamp = DateTime.tryParse(r['transaction_timestamp']?.toString() ?? '') ?? DateTime.now();

        if (isDebit) {
          debitCount++;
          totalDebit += amt;
        } else {
          creditCount++;
          totalCredit += amt;
        }

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

      for (final r in cardRows) {
        if (r is! Map) continue;
        final isDebit = r['transaction_type']?.toString().toUpperCase() == 'DEBIT';
        final amt = double.tryParse(r['amount']?.toString() ?? '0') ?? 0.0;
        final timestamp = DateTime.tryParse(r['transaction_date']?.toString() ?? '') ?? DateTime.now();

        if (isDebit) {
          debitCount++;
          totalDebit += amt;
        } else {
          creditCount++;
          totalCredit += amt;
        }

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

      // If in-memory txns are empty, fall back to querying the database directly
      if (txns.isEmpty) {
        try {
          final dbService = ref.read(supabaseDbServiceProvider);
          final fetched = await dbService.fetchStoredTransactions(limit: 250);
          if (fetched.isNotEmpty) {
            txns.addAll(fetched);
            debitCount = txns.where((t) => t.isDebit).length;
            creditCount = txns.where((t) => t.isCredit).length;
            totalDebit = txns.where((t) => t.isDebit).fold(0.0, (s, t) => s + t.amount);
            totalCredit = txns.where((t) => t.isCredit).fold(0.0, (s, t) => s + t.amount);
          }
        } catch (_) {}
      }

      final totalCount = (response['total_transactions'] as num?)?.toInt() ?? txns.length;
      final parseResult = PdfStatementParseResult(
        success: true,
        fileName: fileName,
        totalCount: totalCount,
        debitCount: debitCount,
        creditCount: creditCount,
        totalDebitAmount: totalDebit,
        totalCreditAmount: totalCredit,
        latestBalance: (response['closing_balance'] as num?)?.toDouble() ?? 0.0,
        transactions: txns,
      );

      ref.read(lastParsedPdfResultProvider.notifier).setResult(parseResult);

      // Invalidate app-wide feeds and balances so the UI immediately reflects new data
      ref.invalidate(transactionFeedProvider);
      ref.invalidate(balanceProvider);
      ref.invalidate(telemetryMetricsProvider);
      ref.invalidate(cashflowRhythmProvider);
      ref.invalidate(recurringCommitmentsProvider);
      ref.invalidate(habitProfileProvider);

      final issuer = response['issuer_or_bank'] ?? 'statement';
      state = state.copyWith(
        isProcessing: false,
        isPasswordProtected: false,
        pendingBytes: null,
        pendingFileName: null,
        pendingStoragePath: null,
        statusMessage: 'Successfully added $totalCount transactions from $issuer.',
        result: parseResult,
      );
      return parseResult;
    }

    final errMsg = response['message']?.toString() ?? response['error']?.toString() ?? 'Failed to extract statement';
    final parseResult = PdfStatementParseResult(
      success: false,
      fileName: fileName,
      errorMessage: errMsg,
    );
    state = state.copyWith(
      isProcessing: false,
      errorMessage: errMsg,
      result: parseResult,
    );
    return parseResult;
  }

  /// Clears any transient error message
  void clearError() {
    if (state.errorMessage != null) {
      state = state.copyWith(errorMessage: null);
    }
  }

  /// Sets a validation or operational error message
  void setError(String message) {
    state = state.copyWith(errorMessage: message);
  }

  /// Manually synchronizes the currently parsed transactions to Supabase if needed
  Future<bool> storeTransactionsToSupabase() async {
    final parseResult = state.result ?? ref.read(lastParsedPdfResultProvider);
    if (parseResult == null || parseResult.transactions.isEmpty) return false;

    state = state.copyWith(
      isProcessing: true,
      statusMessage: 'Adding ${parseResult.totalCount} transactions to your feed...',
    );

    final user = ref.read(currentUserProvider);
    final dbService = ref.read(supabaseDbServiceProvider);

    final saved = await dbService.saveBankTransactions(
      transactions: parseResult.transactions,
      userId: user?.id,
      fileName: parseResult.fileName,
    );

    ref.invalidate(transactionFeedProvider);
    ref.invalidate(balanceProvider);
    ref.invalidate(telemetryMetricsProvider);
    ref.invalidate(cashflowRhythmProvider);
    ref.invalidate(recurringCommitmentsProvider);
    ref.invalidate(habitProfileProvider);

    state = state.copyWith(
      isProcessing: false,
      statusMessage: saved
          ? 'Successfully added ${parseResult.totalCount} transactions.'
          : 'Unable to save transactions. Please try again.',
    );

    return saved;
  }

  void reset() {
    state = const PdfStatementImportState();
  }
}

final pdfStatementImportProvider =
    NotifierProvider<PdfStatementImportNotifier, PdfStatementImportState>(
  PdfStatementImportNotifier.new,
);
