import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'email_transaction_parser.dart';
import 'gmail_api_service.dart';

/// Single email classification audit record
class EmailAuditEntry {
  final String messageId;
  final String from;
  final String subject;
  final DateTime date;
  final bool isFlaggedAsTransaction;
  final bool isFlaggedAsSubscription;
  final bool isNoise;
  final String? noiseReason;
  final ExtractedEmailTransaction? transaction;
  final ExtractedEmailSubscription? subscription;
  final String snippet;

  const EmailAuditEntry({
    required this.messageId,
    required this.from,
    required this.subject,
    required this.date,
    required this.isFlaggedAsTransaction,
    required this.isFlaggedAsSubscription,
    required this.isNoise,
    this.noiseReason,
    this.transaction,
    this.subscription,
    required this.snippet,
  });
}

/// Comprehensive report of a dry-run test execution
class GmailTestRunReport {
  final int totalFound;
  final int totalFetched;
  final int noiseCount;
  final int transactionCount;
  final int subscriptionCount;
  final List<ExtractedEmailTransaction> transactions;
  final List<ExtractedEmailSubscription> subscriptions;
  final List<EmailAuditEntry> auditEntries;
  final String formattedLog;
  final String logFilePath;
  final DateTime executionTime;

  const GmailTestRunReport({
    required this.totalFound,
    required this.totalFetched,
    required this.noiseCount,
    required this.transactionCount,
    required this.subscriptionCount,
    required this.transactions,
    required this.subscriptions,
    required this.auditEntries,
    required this.formattedLog,
    required this.logFilePath,
    required this.executionTime,
  });
}

/// Standalone testing pipeline service that processes Gmail financial emails,
/// produces deep audit logs, and saves them to a separate local log file without
/// touching the user's active database.
class GmailTestPipelineService {
  final GmailApiService _apiService;
  final EmailTransactionParser _parser;

  GmailTestPipelineService({
    GmailApiService? apiService,
    EmailTransactionParser? parser,
  })  : _apiService = apiService ?? GmailApiService(),
        _parser = parser ?? EmailTransactionParser();

  /// Exports raw fetched emails and diagnostic tags to JSON files on disk.
  Future<String?> exportRawEmailsToJson({
    required List<GmailRawMessage> messages,
    String? userEmail,
    bool writeToWorkspaceLogs = true,
  }) async {
    return saveRealSyncJsonData(
      messages: messages,
      parser: _parser,
      userEmail: userEmail ?? 'unknown',
      writeToWorkspaceLogs: writeToWorkspaceLogs,
    );
  }

  /// Executes an end-to-end dry-run test:
  /// 1. Searches recent financial/subscription emails.
  /// 2. Fetches full bodies in batches of 10.
  /// 3. Parses and classifies on-device.
  /// 4. Generates a comprehensive audit log file and writes it to disk.
  /// 5. DOES NOT INSERT INTO SUPABASE DATABASE.
  Future<GmailTestRunReport> executeTestRun({
    required String accessToken,
    int maxEmails = 50,
    void Function(int current, int total, String message)? onProgress,
  }) async {
    final now = DateTime.now();
    debugPrint('\n================================================================');
    debugPrint('🚀 [GmailTestPipeline] Starting Dry-Run Test Pipeline');
    debugPrint('⏰ Time: $now');
    debugPrint('🔒 Database Saving: DISABLED (Testing Mode)');
    debugPrint('================================================================\n');

    onProgress?.call(0, 0, 'Searching candidate financial emails in Gmail...');
    final candidateIds = await _apiService.searchFinancialMessageIds(
      accessToken: accessToken,
      maxMessages: maxEmails,
    );

    debugPrint('[GmailTestPipeline] Located ${candidateIds.length} candidate messages.');

    if (candidateIds.isEmpty) {
      final emptyLog = _buildEmptyReportLog(now);
      final logPath = await _saveLogToFile(emptyLog, now);

      return GmailTestRunReport(
        totalFound: 0,
        totalFetched: 0,
        noiseCount: 0,
        transactionCount: 0,
        subscriptionCount: 0,
        transactions: const [],
        subscriptions: const [],
        auditEntries: const [],
        formattedLog: emptyLog,
        logFilePath: logPath,
        executionTime: now,
      );
    }

    onProgress?.call(0, candidateIds.length, 'Fetching email details on-device...');
    final rawMessages = await _apiService.fetchMessagesInBatches(
      accessToken: accessToken,
      messageIds: candidateIds,
      onProgress: (current, total) {
        onProgress?.call(current, total, 'Fetched $current of $total emails...');
      },
    );

    onProgress?.call(rawMessages.length, rawMessages.length, 'Analyzing and parsing emails on-device...');
    final auditEntries = <EmailAuditEntry>[];
    final extractedTxns = <ExtractedEmailTransaction>[];
    final extractedSubs = <ExtractedEmailSubscription>[];
    int noiseCount = 0;

    for (int i = 0; i < rawMessages.length; i++) {
      final msg = rawMessages[i];
      final diag = _parser.parseMessageWithDiagnostics(msg);

      if (diag.isNoise) {
        noiseCount++;
      }
      if (diag.output.transaction != null) {
        extractedTxns.add(diag.output.transaction!);
      }
      if (diag.output.subscription != null) {
        extractedSubs.add(diag.output.subscription!);
      }

      final snippet = msg.bodyText.length > 200
          ? '${msg.bodyText.substring(0, 200).replaceAll(RegExp(r'\s+'), ' ')}...'
          : msg.bodyText.replaceAll(RegExp(r'\s+'), ' ');

      auditEntries.add(EmailAuditEntry(
        messageId: msg.id,
        from: msg.from,
        subject: msg.subject,
        date: msg.date,
        isFlaggedAsTransaction: diag.isFlaggedAsTransaction,
        isFlaggedAsSubscription: diag.isFlaggedAsSubscription,
        isNoise: diag.isNoise,
        noiseReason: diag.noiseReason,
        transaction: diag.output.transaction,
        subscription: diag.output.subscription,
        snippet: snippet,
      ));
    }

    // Format full audit log
    final formattedLog = _buildComprehensiveAuditLog(
      executionTime: now,
      totalFound: candidateIds.length,
      totalFetched: rawMessages.length,
      noiseCount: noiseCount,
      transactions: extractedTxns,
      subscriptions: extractedSubs,
      entries: auditEntries,
    );

    // Save to disk
    final logPath = await _saveLogToFile(formattedLog, now);

    // Print summary to debug console
    debugPrint(formattedLog);

    return GmailTestRunReport(
      totalFound: candidateIds.length,
      totalFetched: rawMessages.length,
      noiseCount: noiseCount,
      transactionCount: extractedTxns.length,
      subscriptionCount: extractedSubs.length,
      transactions: extractedTxns,
      subscriptions: extractedSubs,
      auditEntries: auditEntries,
      formattedLog: formattedLog,
      logFilePath: logPath,
      executionTime: now,
    );
  }

  /// Writes log content to workspace directory, /tmp, and application documents directory
  Future<String> _saveLogToFile(
    String content,
    DateTime timestamp, {
    bool writeToWorkspaceLogs = false,
  }) async {
    final fileTimeStr =
        '${timestamp.year}${timestamp.month.toString().padLeft(2, '0')}${timestamp.day.toString().padLeft(2, '0')}_'
        '${timestamp.hour.toString().padLeft(2, '0')}${timestamp.minute.toString().padLeft(2, '0')}${timestamp.second.toString().padLeft(2, '0')}';

    String? preferredPath;

    // 1. Write directly to project workspace logs directory only if explicitly enabled
    if (writeToWorkspaceLogs) {
      try {
        final projectLogsDir = Directory('/Users/santosh/Setthi/setthi/logs');
        if (!projectLogsDir.existsSync()) {
          projectLogsDir.createSync(recursive: true);
        }
        final projectRunFile = File('${projectLogsDir.path}/gmail_test_run_$fileTimeStr.log');
        await projectRunFile.writeAsString(content);
        final projectLatestFile = File('${projectLogsDir.path}/latest_audit.log');
        await projectLatestFile.writeAsString(content);
        preferredPath = projectLatestFile.path;
        debugPrint('[GmailTestPipeline] Saved to project workspace: ${projectLatestFile.path}');
      } catch (e) {
        debugPrint('[GmailTestPipeline] Could not write to project workspace logs ($e)');
      }
    }

    // 2. Also write to /tmp for easy terminal access (cat /tmp/setthi_gmail_test_logs/latest_audit.log)
    try {
      final tmpDir = Directory('/tmp/setthi_gmail_test_logs');
      if (!tmpDir.existsSync()) {
        tmpDir.createSync(recursive: true);
      }
      final tmpRunFile = File('${tmpDir.path}/gmail_test_run_$fileTimeStr.log');
      await tmpRunFile.writeAsString(content);
      final tmpLatestFile = File('${tmpDir.path}/latest_audit.log');
      await tmpLatestFile.writeAsString(content);
      preferredPath ??= tmpLatestFile.path;
      debugPrint('[GmailTestPipeline] Saved to /tmp logs: ${tmpLatestFile.path}');
    } catch (e) {
      debugPrint('[GmailTestPipeline] Could not write to /tmp logs ($e)');
    }

    // 3. Application documents directory (standard sandboxed mobile path)
    try {
      final dir = await getApplicationDocumentsDirectory();
      final logsDir = Directory('${dir.path}/gmail_sync_test_logs');
      if (!logsDir.existsSync()) {
        logsDir.createSync(recursive: true);
      }
      final runFile = File('${logsDir.path}/gmail_test_run_$fileTimeStr.log');
      await runFile.writeAsString(content);
      final latestFile = File('${logsDir.path}/latest.log');
      await latestFile.writeAsString(content);
      preferredPath ??= runFile.path;
      debugPrint('[GmailTestPipeline] Saved to application documents: ${runFile.path}');
    } catch (e) {
      debugPrint('[GmailTestPipeline] Could not write to application documents ($e)');
    }

    return preferredPath ?? 'In-memory log (file system write not permitted)';
  }

  String _buildEmptyReportLog(DateTime now) {
    final buf = StringBuffer();
    buf.writeln('================================================================================');
    buf.writeln('          SETTHI ON-DEVICE GMAIL SYNC - TEST RUN AUDIT REPORT');
    buf.writeln('================================================================================');
    buf.writeln('Run Timestamp    : $now');
    buf.writeln('Mode             : DRY-RUN / TEST ONLY (No database records written)');
    buf.writeln('Candidate Emails : 0 matching query');
    buf.writeln('Status           : All caught up. No candidate financial emails found.');
    buf.writeln('================================================================================');
    return buf.toString();
  }

  String _buildComprehensiveAuditLog({
    required DateTime executionTime,
    required int totalFound,
    required int totalFetched,
    required int noiseCount,
    required List<ExtractedEmailTransaction> transactions,
    required List<ExtractedEmailSubscription> subscriptions,
    required List<EmailAuditEntry> entries,
  }) {
    final buf = StringBuffer();
    buf.writeln('================================================================================');
    buf.writeln('          SETTHI ON-DEVICE GMAIL SYNC - TEST RUN AUDIT REPORT');
    buf.writeln('================================================================================');
    buf.writeln('Run Timestamp        : $executionTime');
    buf.writeln('Mode                 : DRY-RUN / TEST ONLY (No database records written)');
    buf.writeln('Log Location         : logs/latest_audit.log');
    buf.writeln('Total Located        : $totalFound');
    buf.writeln('Total Fetched        : $totalFetched');
    buf.writeln('Noise / Discarded    : $noiseCount');
    buf.writeln('Flagged Transactions : ${transactions.length}');
    buf.writeln('Flagged Subscriptions: ${subscriptions.length}');
    buf.writeln('================================================================================\n');

    // Section 1: Flagged Transactions
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 1: FLAGGED TRANSACTIONS (${transactions.length})');
    buf.writeln('--------------------------------------------------------------------------------');
    if (transactions.isEmpty) {
      buf.writeln('No transactions flagged in this run.\n');
    } else {
      for (int i = 0; i < transactions.length; i++) {
        final t = transactions[i];
        buf.writeln('[TXN #${i + 1}]');
        buf.writeln('  • Merchant  : ${t.merchantName}');
        buf.writeln('  • Amount    : ${t.currency} ${t.amount.toStringAsFixed(2)}');
        buf.writeln('  • Issuer    : ${t.bankOrIssuer}');
        buf.writeln('  • Card Last4: ${t.cardLast4 ?? 'N/A'}');
        buf.writeln('  • Mode      : ${t.paymentMode}');
        buf.writeln('  • Type      : ${t.type.value.toUpperCase()}');
        buf.writeln('  • Date      : ${t.transactionDate}');
        buf.writeln('  • Narration : ${t.narration}');
        buf.writeln('  • Msg ID    : ${t.gmailMessageId}\n');
      }
    }

    // Section 2: Flagged Subscriptions & Invoices
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 2: FLAGGED SUBSCRIPTIONS & RECURRING BILLS (${subscriptions.length})');
    buf.writeln('--------------------------------------------------------------------------------');
    if (subscriptions.isEmpty) {
      buf.writeln('No recurring subscriptions flagged in this run.\n');
    } else {
      for (int i = 0; i < subscriptions.length; i++) {
        final s = subscriptions[i];
        buf.writeln('[SUB #${i + 1}]');
        buf.writeln('  • Service   : ${s.serviceName}');
        buf.writeln('  • Amount    : ${s.currency} ${s.expectedAmount.toStringAsFixed(2)}');
        buf.writeln('  • Frequency : ${s.frequency}');
        buf.writeln('  • Due Day   : ${s.typicalDueDay}');
        buf.writeln('  • Card Last4: ${s.cardLast4 ?? 'N/A'}');
        buf.writeln('  • Bill Date : ${s.billingDate}\n');
      }
    }

    // Section 3: Granular Per-Email Breakdown
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 3: GRANULAR AUDIT PER EMAIL (${entries.length} emails examined)');
    buf.writeln('--------------------------------------------------------------------------------');
    for (int i = 0; i < entries.length; i++) {
      final e = entries[i];
      final statusTag = e.isFlaggedAsTransaction
          ? '[FLAGGED TXN]'
          : (e.isFlaggedAsSubscription
              ? '[FLAGGED SUB]'
              : (e.isNoise ? '[DISCARDED NOISE]' : '[UNMATCHED]'));

      buf.writeln('Email #${i + 1} $statusTag');
      buf.writeln('  ID     : ${e.messageId}');
      buf.writeln('  From   : ${e.from}');
      buf.writeln('  Subject: ${e.subject}');
      buf.writeln('  Date   : ${e.date}');
      if (e.isNoise) {
        buf.writeln('  Reason : Filtered as noise (${e.noiseReason ?? 'Unknown'})');
      }
      if (e.isFlaggedAsTransaction) {
        final t = e.transaction!;
        buf.writeln('  Txn    : ${t.type.value.toUpperCase()} ${t.currency} ${t.amount.toStringAsFixed(2)} at ${t.merchantName} [${t.paymentMode}] (${t.bankOrIssuer})');
        buf.writeln('  Source : ${t.narration}');
      }
      if (e.isFlaggedAsSubscription) {
        final s = e.subscription!;
        buf.writeln('  Sub    : ${s.serviceName} (${s.currency} ${s.expectedAmount.toStringAsFixed(2)} / ${s.frequency})');
      }
      buf.writeln('  Snippet: "${e.snippet}"\n');
    }

    buf.writeln('================================================================================');
    buf.writeln('                        END OF TEST RUN REPORT');
    buf.writeln('================================================================================');
    return buf.toString();
  }

  /// Writes an audit report of real emails fetched from Gmail into the workspace logs directory
  static Future<String?> writeRealSyncAuditLog({
    required List<GmailRawMessage> messages,
    required List<ExtractedEmailTransaction> transactions,
    required List<ExtractedEmailSubscription> subscriptions,
    required EmailTransactionParser parser,
    required String userEmail,
  }) async {
    final now = DateTime.now();
    final fileTimeStr =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';

    final auditEntries = <EmailAuditEntry>[];
    int noiseCount = 0;

    for (final msg in messages) {
      final diag = parser.parseMessageWithDiagnostics(msg);
      if (diag.isNoise) noiseCount++;

      final snippet = msg.bodyText.length > 200
          ? '${msg.bodyText.substring(0, 200).replaceAll(RegExp(r'\s+'), ' ')}...'
          : msg.bodyText.replaceAll(RegExp(r'\s+'), ' ');

      auditEntries.add(EmailAuditEntry(
        messageId: msg.id,
        from: msg.from,
        subject: msg.subject,
        date: msg.date,
        isFlaggedAsTransaction: diag.isFlaggedAsTransaction,
        isFlaggedAsSubscription: diag.isFlaggedAsSubscription,
        isNoise: diag.isNoise,
        noiseReason: diag.noiseReason,
        transaction: diag.output.transaction,
        subscription: diag.output.subscription,
        snippet: snippet,
      ));
    }

    final buf = StringBuffer();
    buf.writeln('================================================================================');
    buf.writeln('          SETTHI ON-DEVICE GMAIL SYNC - REAL AUDIT REPORT');
    buf.writeln('================================================================================');
    buf.writeln('User Account         : $userEmail');
    buf.writeln('Run Timestamp        : $now');
    buf.writeln('Mode                 : PRODUCTION ON-DEVICE RUN (Live Gmail Data)');
    buf.writeln('Total Fetched        : ${messages.length}');
    buf.writeln('Noise / Discarded    : $noiseCount');
    buf.writeln('Flagged Statements   : ${transactions.length}');
    buf.writeln('Flagged Subscriptions: ${subscriptions.length}');
    buf.writeln('================================================================================\n');

    // Section 1: Statements
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 1: FLAGGED CREDIT STATEMENTS (${transactions.length})');
    buf.writeln('--------------------------------------------------------------------------------');
    if (transactions.isEmpty) {
      buf.writeln('No credit card statements flagged in this run.\n');
    } else {
      for (int i = 0; i < transactions.length; i++) {
        final t = transactions[i];
        buf.writeln('[STMT #${i + 1}]');
        buf.writeln('  • Issuer    : ${t.bankOrIssuer}');
        buf.writeln('  • Total Due : ${t.currency} ${t.statementTotalDue?.toStringAsFixed(2) ?? t.amount.toStringAsFixed(2)}');
        buf.writeln('  • Min Due   : ${t.statementMinDue != null ? '${t.currency} ${t.statementMinDue!.toStringAsFixed(2)}' : 'N/A'}');
        buf.writeln('  • Due Date  : ${t.statementDueDate ?? 'N/A'}');
        buf.writeln('  • Card Last4: ${t.cardLast4 ?? 'N/A'}');
        buf.writeln('  • Msg ID    : ${t.gmailMessageId}\n');
      }
    }

    // Section 2: Subscriptions
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 2: FLAGGED SUBSCRIPTIONS & RECURRING BILLS (${subscriptions.length})');
    buf.writeln('--------------------------------------------------------------------------------');
    if (subscriptions.isEmpty) {
      buf.writeln('No recurring subscriptions flagged in this run.\n');
    } else {
      for (int i = 0; i < subscriptions.length; i++) {
        final s = subscriptions[i];
        buf.writeln('[SUB #${i + 1}]');
        buf.writeln('  • Service   : ${s.serviceName}');
        buf.writeln('  • Amount    : ${s.currency} ${s.expectedAmount.toStringAsFixed(2)}');
        buf.writeln('  • Frequency : ${s.frequency}');
        buf.writeln('  • Due Day   : ${s.typicalDueDay}');
        buf.writeln('  • Card Last4: ${s.cardLast4 ?? 'N/A'}');
        buf.writeln('  • Bill Date : ${s.billingDate}\n');
      }
    }

    // Section 3: Granular Per-Email Breakdown
    buf.writeln('--------------------------------------------------------------------------------');
    buf.writeln('SECTION 3: GRANULAR AUDIT PER EMAIL (${auditEntries.length} real emails examined)');
    buf.writeln('--------------------------------------------------------------------------------');
    for (int i = 0; i < auditEntries.length; i++) {
      final e = auditEntries[i];
      final statusTag = e.isFlaggedAsTransaction
          ? '[FLAGGED STMT/TXN]'
          : (e.isFlaggedAsSubscription
              ? '[FLAGGED SUB]'
              : (e.isNoise ? '[DISCARDED NOISE]' : '[UNMATCHED]'));

      buf.writeln('Email #${i + 1} $statusTag');
      buf.writeln('  ID     : ${e.messageId}');
      buf.writeln('  From   : ${e.from}');
      buf.writeln('  Subject: ${e.subject}');
      buf.writeln('  Date   : ${e.date}');
      if (e.isNoise) {
        buf.writeln('  Reason : Filtered as noise (${e.noiseReason ?? 'Unknown'})');
      }
      if (e.isFlaggedAsTransaction) {
        final t = e.transaction!;
        buf.writeln('  Txn    : ${t.type.value.toUpperCase()} ${t.currency} ${t.amount.toStringAsFixed(2)} at ${t.merchantName} [${t.paymentMode}] (${t.bankOrIssuer})');
        buf.writeln('  Source : ${t.narration}');
      }
      if (e.isFlaggedAsSubscription) {
        final s = e.subscription!;
        buf.writeln('  Sub    : ${s.serviceName} (${s.currency} ${s.expectedAmount.toStringAsFixed(2)} / ${s.frequency})');
      }
      buf.writeln('  Snippet: "${e.snippet}"\n');
    }

    buf.writeln('================================================================================');
    buf.writeln('                        END OF REAL AUDIT REPORT');
    buf.writeln('================================================================================');

    final content = buf.toString();
    try {
      final projectLogsDir = Directory('/Users/santosh/Setthi/setthi/logs');
      if (!projectLogsDir.existsSync()) {
        projectLogsDir.createSync(recursive: true);
      }
      final projectRunFile = File('${projectLogsDir.path}/gmail_real_sync_$fileTimeStr.log');
      await projectRunFile.writeAsString(content);
      final projectLatestFile = File('${projectLogsDir.path}/latest_real_audit.log');
      await projectLatestFile.writeAsString(content);
      debugPrint('[GmailSyncNotifier] Real email audit log saved: ${projectLatestFile.path}');
      return projectLatestFile.path;
    } catch (e) {
      debugPrint('[GmailSyncNotifier] Could not write real sync log: $e');
      return null;
    }
  }

  /// Saves the complete, unfiltered raw Gmail API data alongside granular on-device
  /// categorization and tagging diagnostics into JSON files on disk for AI model training and consumption.
  ///
  /// Produces:
  /// 1. `logs/latest_gmail_sync.json`: Complete dataset with unfiltered messages, categorization, and raw API responses.
  /// 2. `logs/gmail_sync_<timestamp>.json`: Historical snapshot of this exact sync run.
  /// 3. `logs/latest_gmail_raw_api.json`: Pure array of the unmodified Gmail API responses (1:1 with Google's API).
  /// 4. Application documents mirror for persistent mobile access.
  static Future<String?> saveRealSyncJsonData({
    required List<GmailRawMessage> messages,
    required EmailTransactionParser parser,
    required String userEmail,
    bool writeToWorkspaceLogs = true,
  }) async {
    final now = DateTime.now();
    final fileTimeStr = now.toIso8601String().replaceAll(':', '-').replaceAll('.', '-');

    final jsonMessages = <Map<String, dynamic>>[];
    final unmodifiedRawList = <dynamic>[];

    for (final msg in messages) {
      if (msg.rawApiData != null) {
        unmodifiedRawList.add(msg.rawApiData);
      } else {
        unmodifiedRawList.add(msg.toMap());
      }

      final diag = parser.parseMessageWithDiagnostics(msg);
      final isTxn = diag.isFlaggedAsTransaction;
      final isSub = diag.isFlaggedAsSubscription;
      final isStmt = diag.isFlaggedAsStatement;

      String classification = 'UNMATCHED';
      if (diag.isNoise) {
        classification = 'DISCARDED_NOISE';
      } else if (isStmt) {
        classification = 'STATEMENT';
      } else if (isSub) {
        classification = 'SUBSCRIPTION';
      } else if (isTxn) {
        classification = 'CONFIRMED_PAYMENT';
      }

      final categorization = {
        'classification': classification,
        'category': diag.transaction?.category ??
            diag.subscription?.category ??
            (isStmt ? 'Bills & Utilities' : (isSub ? 'Subscription' : null)),
        'is_noise': diag.isNoise,
        'noise_reason': diag.noiseReason,
        'is_statement': isStmt,
        'is_subscription': isSub,
        'is_transaction': isTxn,
        'detected_issuer': diag.detectedIssuer,
        'detected_merchant': diag.detectedMerchant,
        'detected_amount': diag.detectedAmount,
        'detected_currency': diag.detectedCurrency,
        'detected_payment_mode': diag.detectedPaymentMode,
        'extracted_transaction': diag.transaction?.toMap(),
        'extracted_subscription': diag.subscription?.toMap(),
      };

      jsonMessages.add({
        'id': msg.id,
        'thread_id': msg.threadId,
        'from': msg.from,
        'subject': msg.subject,
        'date': msg.date.toIso8601String(),
        'internal_date_epoch_ms': msg.internalDateEpochMs,
        'body_text': msg.bodyText,
        'attachments': msg.attachments.map((a) => a.toMap()).toList(),
        'categorization': categorization,
        'raw_gmail_api': msg.rawApiData,
      });
    }

    final fullPayload = {
      'sync_timestamp': now.toIso8601String(),
      'user_email': userEmail,
      'total_messages_count': messages.length,
      'messages': jsonMessages,
      'raw_gmail_api_unmodified': unmodifiedRawList,
    };

    const encoder = JsonEncoder.withIndent('  ');
    final formattedJson = encoder.convert(fullPayload);
    final rawOnlyJson = encoder.convert(unmodifiedRawList);

    String? preferredPath;

    if (writeToWorkspaceLogs) {
      try {
        final projectLogsDir = Directory('/Users/santosh/Setthi/setthi/logs');
        if (!projectLogsDir.existsSync()) {
          projectLogsDir.createSync(recursive: true);
        }

        final runFile = File('${projectLogsDir.path}/gmail_sync_$fileTimeStr.json');
        await runFile.writeAsString(formattedJson);

        final latestFile = File('${projectLogsDir.path}/latest_gmail_sync.json');
        await latestFile.writeAsString(formattedJson);

        final rawOnlyFile = File('${projectLogsDir.path}/latest_gmail_raw_api.json');
        await rawOnlyFile.writeAsString(rawOnlyJson);

        preferredPath = latestFile.path;
        debugPrint('[GmailSyncNotifier] Real Gmail JSON data saved: ${latestFile.path}');
        debugPrint('[GmailSyncNotifier] Real Gmail Raw API JSON saved: ${rawOnlyFile.path}');
      } catch (e) {
        debugPrint('[GmailSyncNotifier] Could not write workspace JSON: $e');
      }
    }

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final deviceLogsDir = Directory('${docDir.path}/gmail_sync_logs');
      if (!deviceLogsDir.existsSync()) {
        deviceLogsDir.createSync(recursive: true);
      }
      final devLatest = File('${deviceLogsDir.path}/latest_gmail_sync.json');
      await devLatest.writeAsString(formattedJson);
      final devRaw = File('${deviceLogsDir.path}/latest_gmail_raw_api.json');
      await devRaw.writeAsString(rawOnlyJson);
      preferredPath ??= devLatest.path;
    } catch (_) {}

    // Fallback for headless tests where path_provider is not registered
    if (preferredPath == null) {
      try {
        final tmpDir = Directory('/tmp/setthi_gmail_test_logs');
        if (!tmpDir.existsSync()) {
          tmpDir.createSync(recursive: true);
        }
        final tmpFile = File('${tmpDir.path}/latest_gmail_sync.json');
        await tmpFile.writeAsString(formattedJson);
        preferredPath = tmpFile.path;
      } catch (_) {}
    }

    return preferredPath;
  }
}
