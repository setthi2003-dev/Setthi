import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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

  const PdfStatementImportState({
    this.isProcessing = false,
    this.statusMessage,
    this.errorMessage,
    this.result,
    this.isPasswordProtected = false,
    this.pendingBytes,
    this.pendingFileName,
  });

  PdfStatementImportState copyWith({
    bool? isProcessing,
    String? statusMessage,
    String? errorMessage,
    PdfStatementParseResult? result,
    bool? isPasswordProtected,
    Uint8List? pendingBytes,
    String? pendingFileName,
  }) {
    return PdfStatementImportState(
      isProcessing: isProcessing ?? this.isProcessing,
      statusMessage: statusMessage,
      errorMessage: errorMessage,
      result: result ?? this.result,
      isPasswordProtected: isPasswordProtected ?? this.isPasswordProtected,
      pendingBytes: pendingBytes ?? this.pendingBytes,
      pendingFileName: pendingFileName ?? this.pendingFileName,
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

  /// Prompts the user to pick a PDF statement file, parses the transactions,
  /// and writes the Supabase-compliant CSV file to the root directory.
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

      state = state.copyWith(
        isProcessing: true,
        statusMessage: 'Reading statement from ${pickedFile.name}...',
      );

      final user = ref.read(currentUserProvider);
      final parserService = ref.read(pdfStatementParserServiceProvider);

      final parseResult = await parserService.parsePdfAndExportCsv(
        pdfBytes: fileBytes,
        fileName: pickedFile.name,
        userId: user?.id,
      );

      if (parseResult.isPasswordProtected) {
        state = state.copyWith(
          isProcessing: false,
          isPasswordProtected: true,
          pendingBytes: fileBytes,
          pendingFileName: pickedFile.name,
          errorMessage: null,
          result: parseResult,
        );
        return parseResult;
      }

      ref.read(lastParsedPdfResultProvider.notifier).setResult(parseResult);

      if (parseResult.success) {
        state = state.copyWith(
          isProcessing: true,
          statusMessage: 'Adding ${parseResult.totalCount} transactions to your feed...',
        );

        final dbService = ref.read(supabaseDbServiceProvider);
        final saved = await dbService.saveBankTransactions(
          transactions: parseResult.transactions,
          userId: user?.id,
          fileName: pickedFile.name,
        );

        // Refresh transaction feed, telemetry metrics, cash flow rhythms, and habit profile across the app
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
              : 'Extracted ${parseResult.totalCount} transactions.',
          result: parseResult,
        );
      } else {
        state = state.copyWith(
          isProcessing: false,
          errorMessage: parseResult.errorMessage ?? 'Failed to extract transactions.',
          result: parseResult,
        );
      }

      return parseResult;
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

  /// Unlocks a password-protected PDF statement in memory and imports transactions
  Future<PdfStatementParseResult?> unlockWithPassword(String password) async {
    final pendingBytes = state.pendingBytes;
    final pendingName = state.pendingFileName;
    if (pendingBytes == null) return null;

    state = state.copyWith(
      isProcessing: true,
      statusMessage: 'Unlocking statement...',
      errorMessage: null,
    );

    try {
      final user = ref.read(currentUserProvider);
      final parserService = ref.read(pdfStatementParserServiceProvider);

      final parseResult = await parserService.parsePdfAndExportCsv(
        pdfBytes: pendingBytes,
        fileName: pendingName,
        userId: user?.id,
        password: password,
      );

      if (parseResult.isPasswordProtected) {
        state = state.copyWith(
          isProcessing: false,
          isPasswordProtected: true,
          errorMessage: 'Incorrect password. Please try again.',
          result: parseResult,
        );
        return parseResult;
      }

      ref.read(lastParsedPdfResultProvider.notifier).setResult(parseResult);

      if (parseResult.success) {
        state = state.copyWith(
          isProcessing: true,
          statusMessage: 'Adding ${parseResult.totalCount} transactions to your feed...',
        );

        final dbService = ref.read(supabaseDbServiceProvider);
        final saved = await dbService.saveBankTransactions(
          transactions: parseResult.transactions,
          userId: user?.id,
          fileName: pendingName,
        );

        ref.invalidate(transactionFeedProvider);
        ref.invalidate(balanceProvider);
        ref.invalidate(telemetryMetricsProvider);
        ref.invalidate(cashflowRhythmProvider);
        ref.invalidate(recurringCommitmentsProvider);
        ref.invalidate(habitProfileProvider);

        state = state.copyWith(
          isProcessing: false,
          isPasswordProtected: false,
          pendingBytes: null,
          pendingFileName: null,
          statusMessage: saved
              ? 'Successfully added ${parseResult.totalCount} transactions.'
              : 'Extracted ${parseResult.totalCount} transactions.',
          result: parseResult,
        );
      } else {
        state = state.copyWith(
          isProcessing: false,
          isPasswordProtected: false,
          pendingBytes: null,
          pendingFileName: null,
          errorMessage: parseResult.errorMessage ?? 'Failed to extract transactions.',
          result: parseResult,
        );
      }

      return parseResult;
    } catch (e) {
      debugPrint('[PdfStatementImportNotifier] Error unlocking: $e');
      final errorResult = PdfStatementParseResult(
        success: false,
        isPasswordProtected: true,
        errorMessage: 'Incorrect password or unreadable document. Please try again.',
      );
      state = state.copyWith(
        isProcessing: false,
        isPasswordProtected: true,
        errorMessage: 'Incorrect password or unreadable document. Please try again.',
        result: errorResult,
      );
      return errorResult;
    }
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
