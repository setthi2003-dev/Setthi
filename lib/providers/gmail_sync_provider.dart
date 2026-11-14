import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/reminder_model.dart';
import '../services/auth_service.dart';
import '../services/email_transaction_parser.dart';
import '../services/gmail_api_service.dart';
import '../services/gmail_rate_limiter.dart';
import '../services/gmail_test_pipeline_service.dart';
import '../services/slice_credit_card_pdf_parser_service.dart';
import 'auth_providers.dart';
import 'supabase_provider.dart';
import 'transaction_providers.dart';

enum GmailSyncStatus {
  idle,
  authenticating,
  searching,
  fetching,
  parsing,
  saving,
  completed,
  error,
}

class GmailSyncState {
  final GmailSyncStatus status;
  final int totalFound;
  final int processedCount;
  final String? currentStepMessage;
  final List<ExtractedEmailTransaction> extractedTransactions;
  final List<ExtractedEmailSubscription> extractedSubscriptions;
  final List<Map<String, dynamic>> savedTransactions;
  final List<ReminderModel> savedReminders;
  final int totalSavedCount;
  final int newlySavedTransactionsCount;
  final int newlySavedSubscriptionsCount;
  final int newlySavedRemindersCount;
  final DateTime? lastSyncTime;
  final String? errorMessage;
  final bool isConnected;
  final String? connectedEmail;

  const GmailSyncState({
    this.status = GmailSyncStatus.idle,
    this.totalFound = 0,
    this.processedCount = 0,
    this.currentStepMessage,
    this.extractedTransactions = const [],
    this.extractedSubscriptions = const [],
    this.savedTransactions = const [],
    this.savedReminders = const [],
    this.totalSavedCount = 0,
    this.newlySavedTransactionsCount = 0,
    this.newlySavedSubscriptionsCount = 0,
    this.newlySavedRemindersCount = 0,
    this.lastSyncTime,
    this.errorMessage,
    this.isConnected = false,
    this.connectedEmail,
  });

  bool get isSyncing =>
      status == GmailSyncStatus.authenticating ||
      status == GmailSyncStatus.searching ||
      status == GmailSyncStatus.fetching ||
      status == GmailSyncStatus.parsing ||
      status == GmailSyncStatus.saving;

  double get progressRatio {
    if (totalFound == 0) return 0.0;
    return (processedCount / totalFound).clamp(0.0, 1.0);
  }

  GmailSyncState copyWith({
    GmailSyncStatus? status,
    int? totalFound,
    int? processedCount,
    String? currentStepMessage,
    List<ExtractedEmailTransaction>? extractedTransactions,
    List<ExtractedEmailSubscription>? extractedSubscriptions,
    List<Map<String, dynamic>>? savedTransactions,
    List<ReminderModel>? savedReminders,
    int? totalSavedCount,
    int? newlySavedTransactionsCount,
    int? newlySavedSubscriptionsCount,
    int? newlySavedRemindersCount,
    DateTime? lastSyncTime,
    String? errorMessage,
    bool? isConnected,
    String? connectedEmail,
    bool clearConnectedEmail = false,
  }) {
    return GmailSyncState(
      status: status ?? this.status,
      totalFound: totalFound ?? this.totalFound,
      processedCount: processedCount ?? this.processedCount,
      currentStepMessage: currentStepMessage ?? this.currentStepMessage,
      extractedTransactions:
          extractedTransactions ?? this.extractedTransactions,
      extractedSubscriptions:
          extractedSubscriptions ?? this.extractedSubscriptions,
      savedTransactions: savedTransactions ?? this.savedTransactions,
      savedReminders: savedReminders ?? this.savedReminders,
      totalSavedCount: totalSavedCount ?? this.totalSavedCount,
      newlySavedTransactionsCount:
          newlySavedTransactionsCount ?? this.newlySavedTransactionsCount,
      newlySavedSubscriptionsCount:
          newlySavedSubscriptionsCount ?? this.newlySavedSubscriptionsCount,
      newlySavedRemindersCount:
          newlySavedRemindersCount ?? this.newlySavedRemindersCount,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      errorMessage: errorMessage,
      isConnected: isConnected ?? this.isConnected,
      connectedEmail: clearConnectedEmail
          ? null
          : (connectedEmail ?? this.connectedEmail),
    );
  }
}

/// Provider for the [GmailRateLimiter] singleton
final gmailRateLimiterProvider = Provider<GmailRateLimiter>((ref) {
  return GmailRateLimiter.instance;
});

/// Provider for the [GmailApiService] singleton
final gmailApiServiceProvider = Provider<GmailApiService>((ref) {
  return GmailApiService(rateLimiter: ref.watch(gmailRateLimiterProvider));
});

/// Provider for the [EmailTransactionParser] singleton
final emailTransactionParserProvider = Provider<EmailTransactionParser>((ref) {
  return EmailTransactionParser();
});

/// Provider for the [GmailTestPipelineService] singleton
final gmailTestPipelineServiceProvider = Provider<GmailTestPipelineService>((ref) {
  return GmailTestPipelineService(
    apiService: ref.watch(gmailApiServiceProvider),
    parser: ref.watch(emailTransactionParserProvider),
  );
});

/// Riverpod StateNotifier coordinating on-device Gmail fetching, parsing, and DB upserts.
class GmailSyncNotifier extends Notifier<GmailSyncState> {
  static const String _prefLastSyncPrefix = 'gmail_last_sync_epoch_';
  static const String _prefConnectedPrefix = 'gmail_is_connected_';
  static const String _prefConnectedEmailPrefix = 'gmail_connected_email_';
  static const String _prefProcessedIdsPrefix = 'gmail_processed_ids_';
  static const int _maxStoredIds = 3000;

  @override
  GmailSyncState build() {
    ref.listen<User?>(currentUserProvider, (prev, next) {
      if (prev?.id != next?.id) {
        _loadStateForUser(next?.id);
      }
    });

    final currentUserId = ref.read(currentUserProvider)?.id;
    _loadStateForUser(currentUserId);
    return const GmailSyncState();
  }

  Future<void> _loadStateForUser(String? userId) async {
    if (userId == null) {
      state = const GmailSyncState();
      return;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final lastSyncEpoch = prefs.getInt('$_prefLastSyncPrefix$userId');
      final isConnected = prefs.getBool('$_prefConnectedPrefix$userId') ?? false;
      final connectedEmail = prefs.getString('$_prefConnectedEmailPrefix$userId');

      DateTime? lastSync;
      if (lastSyncEpoch != null) {
        lastSync = DateTime.fromMillisecondsSinceEpoch(lastSyncEpoch);
      }

      final dbService = ref.read(supabaseDbServiceProvider);
      await dbService.cleanupDuplicateSubscriptions(userId);
      final savedTxns = await dbService.fetchEmailExtractedTransactions(userId: userId);
      final totalSaved = await dbService.countEmailExtractedTransactions(userId);
      final savedReminders = await dbService.fetchReminders(userId: userId);

      state = state.copyWith(
        lastSyncTime: lastSync,
        isConnected: isConnected,
        connectedEmail: isConnected ? connectedEmail : null,
        savedTransactions: savedTxns,
        savedReminders: savedReminders,
        totalSavedCount: totalSaved,
      );

      // Verify connection in the background ONLY if the user previously explicitly connected Gmail.
      // NEVER auto-connect an unlinked or new user account.
      if (isConnected && connectedEmail != null && connectedEmail.isNotEmpty) {
        Future.microtask(() async {
          try {
            final authService = ref.read(authServiceProvider);
            final check = await authService.connectAndGetGmailAccessToken(
              promptIfUnauthenticated: false,
              expectedEmail: connectedEmail,
            );
            if (check.isSuccess) {
              if (check.email != null && check.email!.isNotEmpty) {
                await prefs.setString('$_prefConnectedEmailPrefix$userId', check.email!);
              }
              state = state.copyWith(
                isConnected: true,
                connectedEmail: check.email ?? state.connectedEmail,
              );
            } else {
              debugPrint('[GmailSyncNotifier] Background check: Gmail token invalid or expired for $connectedEmail');
            }
          } catch (_) {}
        });
      }
    } catch (e) {
      debugPrint('[GmailSyncNotifier] Error loading preferences: $e');
    }
  }

  /// Refreshes saved email transactions from the Supabase production table
  Future<void> refreshSavedTransactions() async {
    final user = ref.read(currentUserProvider);
    if (user == null) return;
    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      await dbService.cleanupDuplicateSubscriptions(user.id);
      final savedTxns = await dbService.fetchEmailExtractedTransactions(userId: user.id);
      final totalSaved = await dbService.countEmailExtractedTransactions(user.id);
      final savedReminders = await dbService.fetchReminders(userId: user.id);
      state = state.copyWith(
        savedTransactions: savedTxns,
        savedReminders: savedReminders,
        totalSavedCount: totalSaved,
      );
    } catch (e) {
      debugPrint('[GmailSyncNotifier] Error refreshing saved email txns: $e');
    }
  }

  /// Triggers full on-device sync of credit card charges and subscription emails,
  /// saving directly into the dedicated public.email_extracted_transactions Supabase table.
  Future<void> syncGmailTransactions({bool forceFullSync = false}) async {
    if (state.isSyncing) return;

    final user = ref.read(currentUserProvider);
    if (user == null) {
      state = state.copyWith(
        status: GmailSyncStatus.error,
        errorMessage: 'Please sign in to Setthi before connecting Gmail.',
      );
      return;
    }

    final userId = user.id;

    // 1. Authenticate silently if already connected, or prompt interactive if new
    state = state.copyWith(
      status: GmailSyncStatus.authenticating,
      currentStepMessage: 'Checking Google authorization...',
      errorMessage: null,
    );

    final authService = ref.read(authServiceProvider);
    GmailAuthResult authResult;

    if (state.isConnected) {
      // User is already connected: try silent token retrieval first (ZERO POPUP)
      authResult = await authService.connectAndGetGmailAccessToken(
        promptIfUnauthenticated: false,
        expectedEmail: state.connectedEmail,
      );
      if (!authResult.isSuccess) {
        // If silent token has expired, prompt interactive sign-in
        state = state.copyWith(
          currentStepMessage: 'Refreshing Google authorization...',
        );
        authResult = await authService.connectAndGetGmailAccessToken(
          promptIfUnauthenticated: true,
          expectedEmail: state.connectedEmail,
        );
      }
    } else {
      // First-time connection: prompt interactive sign-in with full account chooser
      authResult = await authService.connectAndGetGmailAccessToken(
        promptIfUnauthenticated: true,
      );
    }

    if (!authResult.isSuccess) {
      state = state.copyWith(
        status: GmailSyncStatus.error,
        errorMessage: authResult.errorMessage ??
            'Gmail permission was not granted. Please link your account to scan alerts.',
      );
      return;
    }

    final accessToken = authResult.accessToken!;
    final email = authResult.email;

    // Persist connected status and email
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_prefConnectedPrefix$userId', true);
    if (email != null && email.isNotEmpty) {
      await prefs.setString('$_prefConnectedEmailPrefix$userId', email);
    }
    state = state.copyWith(
      isConnected: true,
      connectedEmail: email ?? state.connectedEmail,
    );

    try {
      // 2. Search message IDs
      state = state.copyWith(
        status: GmailSyncStatus.searching,
        currentStepMessage: 'Searching for credit card alerts & subscriptions...',
      );

      final gmailService = ref.read(gmailApiServiceProvider);

      // If user requested full sync, OR if no transactions have been saved yet to Supabase,
      // scan the past 90 days (newer_than:90d).
      // Otherwise, scan incrementally with a 3-day safety window before lastSyncTime.
      DateTime? searchAfterDate;
      if (forceFullSync || state.totalSavedCount == 0 || state.lastSyncTime == null) {
        searchAfterDate = null;
      } else {
        searchAfterDate = state.lastSyncTime!.subtract(const Duration(days: 3));
      }

      final candidateIds = await gmailService.searchFinancialMessageIds(
        accessToken: accessToken,
        afterDate: forceFullSync ? null : searchAfterDate,
        maxMessages: 150,
        unfiltered: true,
        accountEmail: email,
      );

      // Load already processed IDs to ensure deduplication
      final rawProcessedJson = prefs.getString('$_prefProcessedIdsPrefix$userId');
      final Set<String> processedIds = (rawProcessedJson != null && !forceFullSync)
          ? Set<String>.from(jsonDecode(rawProcessedJson) as List)
          : <String>{};

      // Check if any existing statement in the database is missing its PDF attachment;
      // if so, always re-fetch it to download and store the PDF
      final dbService = ref.read(supabaseDbServiceProvider);
      final existingTxns = state.savedTransactions.isNotEmpty
          ? state.savedTransactions
          : await dbService.fetchEmailExtractedTransactions(userId: userId);

      final missingPdfMsgIds = existingTxns
          .where((t) =>
              t['is_statement'] == true &&
              (t['statement_pdf_path'] == null || t['statement_pdf_path'].toString().trim().isEmpty))
          .map((t) => t['gmail_message_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty && !id.startsWith('sub_'))
          .toSet();

      final idSet = candidateIds.where((id) => !processedIds.contains(id)).toSet();
      idSet.addAll(missingPdfMsgIds);
      final newIdsToFetch = idSet.take(150).toList();

      if (newIdsToFetch.isEmpty) {
        final now = DateTime.now();
        await prefs.setInt('$_prefLastSyncPrefix$userId', now.millisecondsSinceEpoch);

        final currentSaved = await dbService.fetchEmailExtractedTransactions(userId: userId);
        final totalSaved = await dbService.countEmailExtractedTransactions(userId);

        state = state.copyWith(
          status: GmailSyncStatus.completed,
          currentStepMessage: 'All caught up! No new financial emails found.',
          totalFound: 0,
          processedCount: 0,
          savedTransactions: currentSaved,
          totalSavedCount: totalSaved,
          newlySavedTransactionsCount: 0,
          newlySavedSubscriptionsCount: 0,
          lastSyncTime: now,
        );
        return;
      }

      // 3. Fetch full message contents in batches of 10
      state = state.copyWith(
        status: GmailSyncStatus.fetching,
        totalFound: newIdsToFetch.length,
        processedCount: 0,
        currentStepMessage: 'Reading ${newIdsToFetch.length} financial alerts on-device...',
      );

      final rawMessages = await gmailService.fetchMessagesInBatches(
        accessToken: accessToken,
        messageIds: newIdsToFetch,
        accountEmail: email,
        onProgress: (fetched, total) {
          state = state.copyWith(
            processedCount: fetched,
            currentStepMessage: 'Fetched $fetched of $total emails...',
          );
        },
      );

      // Save full fetched raw emails to JSON file for offline inspection & audit
      try {
        final testPipeline = ref.read(gmailTestPipelineServiceProvider);
        final exportedPath = await testPipeline.exportRawEmailsToJson(
          messages: rawMessages,
          userEmail: email ?? 'unknown',
          writeToWorkspaceLogs: true,
        );
        debugPrint('[GmailSyncNotifier] 📄 Auditing emails JSON saved at: $exportedPath');
      } catch (e) {
        debugPrint('[GmailSyncNotifier] Warning: Failed to export audit JSON: $e');
      }

      // 4. Serverless ML Classification (Modal Pipeline) & Statement Attachment Processing
      state = state.copyWith(
        status: GmailSyncStatus.parsing,
        currentStepMessage: 'Classifying ${rawMessages.length} emails with Setthi ML...',
      );

      // A. Serverless ML Batch Classification via Supabase Edge Function (Modal)
      final emailBatchPayload = rawMessages.map((msg) => {
        'id': msg.id,
        'subject': msg.subject,
        'from': msg.from,
        'date': msg.date.toIso8601String(),
        'body': msg.bodyText,
      }).toList();

      int totalRemindersSaved = 0;
      const int mlBatchSize = 8;
      final totalBatches = (emailBatchPayload.length / mlBatchSize).ceil();

      final List<Map<String, dynamic>> allAlerts = [];
      final Set<String> successfullyClassifiedIds = {};
      for (var i = 0; i < emailBatchPayload.length; i += mlBatchSize) {
        final end = (i + mlBatchSize < emailBatchPayload.length) ? i + mlBatchSize : emailBatchPayload.length;
        final chunk = emailBatchPayload.sublist(i, end);
        final batchNum = (i ~/ mlBatchSize) + 1;

        state = state.copyWith(
          status: GmailSyncStatus.parsing,
          currentStepMessage: 'Classifying batch $batchNum of $totalBatches with Setthi ML...',
          processedCount: end,
        );

        try {
          final result = await dbService.classifyEmailsViaBackend(
            messages: chunk,
          );
          final saved = (result['saved_count'] as num?)?.toInt() ?? 0;
          totalRemindersSaved += saved;
          final batchAlerts = (result['alerts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          allAlerts.addAll(batchAlerts);
          for (final msg in chunk) {
            final id = msg['id']?.toString();
            if (id != null && id.isNotEmpty) successfullyClassifiedIds.add(id);
          }
          debugPrint('[GmailSyncNotifier] ML Batch $batchNum classified: $saved reminders saved to DB');
        } catch (e) {
          debugPrint('[GmailSyncNotifier] Note: ML batch $batchNum error: $e');
        }
      }

      // Process PDF attachments ONLY for credit card statements confirmed by the ML classification model
      final rawMessagesById = {for (final m in rawMessages) m.id: m};
      for (final alert in allAlerts) {
        if (alert['type'] == 'credit_card_statement') {
          final sourceIds = (alert['source_message_ids'] as List?)?.cast<String>() ??
              [alert['message_id']?.toString() ?? ''];
          for (final msgId in sourceIds) {
            final rawMsg = rawMessagesById[msgId];
            if (rawMsg != null && rawMsg.attachments.isNotEmpty) {
              final pdfAttachment = rawMsg.attachments.where((a) => a.isPdf).firstOrNull ?? rawMsg.attachments.first;
              try {
                final pdfBytes = await gmailService.downloadAttachmentBytes(
                  accessToken: accessToken,
                  messageId: rawMsg.id,
                  attachmentId: pdfAttachment.attachmentId,
                  directData: pdfAttachment.directData,
                  accountEmail: email,
                );

                if (pdfBytes != null && pdfBytes.isNotEmpty) {
                  final rawFilename = pdfAttachment.filename.isNotEmpty ? pdfAttachment.filename : 'statement.pdf';
                  final safeFilename = '${rawMsg.id}_${rawFilename.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}';
                  final storagePath = await dbService.uploadStatementPdfToStorage(
                    userId: userId,
                    filename: safeFilename,
                    pdfBytes: pdfBytes,
                  );

                  if (storagePath != null) {
                    debugPrint('[GmailSyncNotifier] Attached statement PDF stored: $storagePath');

                    // Dispatch statement intelligence to backend pipeline
                    dbService.processStatementViaBackend(
                      storagePath: storagePath,
                      filename: safeFilename,
                      messageId: rawMsg.id,
                      waitForCompletion: true,
                    ).then((res) {
                      debugPrint(
                        '[GmailSyncNotifier] Cloud statement extraction complete: ${res['status']} '
                        '(${res['total_transactions']} txns from ${res['issuer_or_bank'] ?? 'statement'})',
                      );
                      // Invalidate providers so the transaction feed, reminders, and habit profile immediately refresh
                      ref.invalidate(remindersProvider);
                      ref.invalidate(transactionFeedProvider);
                      ref.invalidate(habitProfileProvider);
                      ref.invalidate(balanceProvider);
                    }).catchError((err) {
                      debugPrint('[GmailSyncNotifier] Cloud statement extraction error: $err');
                    });
                  }
                }
              } catch (e) {
                debugPrint('[GmailSyncNotifier] Failed to process statement PDF for ${rawMsg.id}: $e');
              }
            }
          }
        }
      }

      // Purge any legacy false-positive records created by older hardcoded heuristics
      await dbService.clearLegacyExtractedSubscriptions(userId: userId);

      // Fetch the latest ML-confirmed reminders from Supabase
      final updatedReminders = await dbService.fetchReminders(userId: userId);

      // Invalidate providers to trigger fresh reactive updates across the UI
      ref.invalidate(remindersProvider);
      ref.invalidate(recurringCommitmentsProvider);

      // Update persistent deduplication state ONLY for emails that successfully passed classification
      processedIds.addAll(successfullyClassifiedIds);
      final trimmedIds = processedIds.length > _maxStoredIds
          ? processedIds.toList().sublist(processedIds.length - _maxStoredIds)
          : processedIds.toList();

      await prefs.setString('$_prefProcessedIdsPrefix$userId', jsonEncode(trimmedIds));
      final now = DateTime.now();
      await prefs.setInt('$_prefLastSyncPrefix$userId', now.millisecondsSinceEpoch);

      state = state.copyWith(
        status: GmailSyncStatus.completed,
        currentStepMessage: 'Sync complete! $totalRemindersSaved financial alerts confirmed by Setthi ML.',
        savedReminders: updatedReminders,
        newlySavedRemindersCount: totalRemindersSaved,
        lastSyncTime: now,
      );
    } catch (e, stack) {
      debugPrint('[GmailSyncNotifier] Error during Gmail sync: $e\n$stack');
      state = state.copyWith(
        status: GmailSyncStatus.error,
        errorMessage: 'Sync error: $e',
      );
    }
  }

  /// Disconnects Gmail account and resets local sync timestamps
  Future<void> disconnectGmail() async {
    final user = ref.read(currentUserProvider);
    final authService = ref.read(authServiceProvider);

    await authService.disconnectGmail();

    if (user != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_prefConnectedPrefix${user.id}', false);
      await prefs.remove('$_prefConnectedEmailPrefix${user.id}');
      await prefs.remove('$_prefLastSyncPrefix${user.id}');
    }

    state = state.copyWith(
      status: GmailSyncStatus.idle,
      isConnected: false,
      clearConnectedEmail: true,
      lastSyncTime: null,
    );
  }

  /// Decrypts a password-protected credit card statement stored in Supabase Storage,
  /// parses itemized transactions, and persists them into public.credit_card_transactions.
  Future<SliceCreditCardParseResult> unlockCreditCardStatement({
    required String statementPdfPath,
    required String password,
    String? statementId,
    String? cardLast4,
    String? billingCycle,
    DateTime? dueDate,
  }) async {
    final user = ref.read(currentUserProvider);
    final userId = user?.id ?? ref.read(supabaseClientProvider)?.auth.currentUser?.id ?? Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      return const SliceCreditCardParseResult(
        success: false,
        errorMessage: 'User session not found. Please log in.',
        summary: SliceCreditCardStatementSummary(),
      );
    }

    final dbService = ref.read(supabaseDbServiceProvider);
    final pdfBytes = await dbService.downloadStatementPdfFromStorage(storagePath: statementPdfPath);
    if (pdfBytes == null || pdfBytes.isEmpty) {
      return const SliceCreditCardParseResult(
        success: false,
        errorMessage: 'Unable to retrieve statement PDF file from storage.',
        summary: SliceCreditCardStatementSummary(),
      );
    }

    final sliceParser = ref.read(sliceCreditCardPdfParserServiceProvider);
    final parseResult = await sliceParser.parsePdfBytes(
      pdfBytes,
      fileName: statementPdfPath.split('/').last,
      password: password,
    );

    if (parseResult.success && parseResult.transactions.isNotEmpty) {
      await dbService.saveCreditCardTransactions(
        transactions: parseResult.transactions,
        userId: userId,
        statementId: statementId,
        statementPdfPath: statementPdfPath,
        cardLast4: parseResult.summary.cardLast4 ?? cardLast4,
        billingCycle: parseResult.summary.billingCycle ?? billingCycle,
        dueDate: parseResult.summary.dueDate ?? dueDate,
      );
      debugPrint(
        '[GmailSyncNotifier] Successfully unlocked and saved ${parseResult.transactions.length} credit card transactions.',
      );
    }

    return parseResult;
  }

  void reset() {
    state = state.copyWith(
      status: GmailSyncStatus.idle,
      errorMessage: null,
      currentStepMessage: null,
      totalFound: 0,
      processedCount: 0,
    );
  }

  void clearError() {
    state = state.copyWith(
      errorMessage: null,
      status: GmailSyncStatus.idle,
    );
  }
}

final gmailSyncProvider = NotifierProvider<GmailSyncNotifier, GmailSyncState>(
  GmailSyncNotifier.new,
);

