import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transaction_model.dart';
import '../services/fi_data_service.dart';
import '../services/setu_aa_service.dart';

/// Provider for the Setu Account Aggregator service instance
final setuAaServiceProvider = Provider<SetuAaService>((ref) {
  return SetuAaService();
});

/// State notifier storing the currently approved Setu AA consent ID,
/// with local persistence so the connection persists across app relaunches.
class ActiveConsentIdNotifier extends Notifier<String?> {
  /// Toggle to control disk persistence (can be disabled in test suites)
  static bool enablePersistence = true;

  static String get _filePath =>
      '${Directory.systemTemp.path}/setthi_active_consent.txt';

  @override
  String? build() {
    if (!enablePersistence) return null;
    return _loadSavedConsentId();
  }

  static String? _loadSavedConsentId() {
    try {
      final file = File(_filePath);
      if (file.existsSync()) {
        final id = file.readAsStringSync().trim();
        if (id.isNotEmpty) return id;
      }
    } catch (_) {}
    return null;
  }

  static void deletePersistedConsent() {
    try {
      final file = File(_filePath);
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  void setConsentId(String? consentId) {
    state = consentId;
    if (!enablePersistence) return;
    try {
      final file = File(_filePath);
      if (consentId != null && consentId.isNotEmpty) {
        file.writeAsStringSync(consentId.trim());
      } else if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  void clear() {
    setConsentId(null);
  }
}

final activeConsentIdProvider =
    NotifierProvider<ActiveConsentIdNotifier, String?>(
  ActiveConsentIdNotifier.new,
);

/// State notifier storing the most recently initiated consent ID
class PendingConsentIdNotifier extends Notifier<String?> {
  @override
  String? build() => SetuAaService.lastCreatedConsentId;

  void set(String? id) {
    SetuAaService.lastCreatedConsentId = id;
    state = id;
  }

  void clear() {
    SetuAaService.lastCreatedConsentId = null;
    state = null;
  }
}

final pendingConsentIdProvider =
    NotifierProvider<PendingConsentIdNotifier, String?>(
  PendingConsentIdNotifier.new,
);

/// Boolean indicating whether an approved Account Aggregator consent is currently active
final hasActiveConsentProvider = Provider<bool>((ref) {
  final consentId = ref.watch(activeConsentIdProvider);
  return consentId != null && consentId.isNotEmpty;
});

/// Repository provider resolving to SetuAaService
final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  final consentId = ref.watch(activeConsentIdProvider);
  final aaService = ref.watch(setuAaServiceProvider);
  aaService.activeConsentId = consentId;
  return aaService;
});

/// AsyncNotifier managing the Setu Account Aggregator transaction feed state.
class TransactionFeedNotifier extends AsyncNotifier<List<BankTransaction>> {
  @override
  Future<List<BankTransaction>> build() async {
    final consentId = ref.watch(activeConsentIdProvider);
    // If no bank has been linked yet, return an empty transaction list
    if (consentId == null || consentId.isEmpty) {
      return [];
    }

    final repository = ref.watch(transactionRepositoryProvider);
    return repository.fetchTransactions();
  }

  /// Manually trigger a transaction sync from the Setu AA gateway.
  Future<void> syncTransactions() async {
    final consentId = ref.read(activeConsentIdProvider);
    if (consentId == null || consentId.isEmpty) {
      state = const AsyncData([]);
      return;
    }

    final repository = ref.read(transactionRepositoryProvider);
    state = const AsyncLoading();
    state = await AsyncValue.guard(() => repository.fetchTransactions());
  }

  /// Sets an approved consent and immediately initiates live data sync
  Future<void> setConsentAndSync(String consentId) async {
    ref.read(activeConsentIdProvider.notifier).setConsentId(consentId);
    ref.read(pendingConsentIdProvider.notifier).clear();
    await syncTransactions();
  }

  /// Checks if a consent ID has become ACTIVE on Setu's server and syncs if approved
  Future<bool> checkAndSyncConsent(String consentId) async {
    final aaService = ref.read(setuAaServiceProvider);
    final status = await aaService.checkConsentStatus(consentId);
    if (status == 'ACTIVE') {
      await setConsentAndSync(consentId);
      return true;
    }
    return false;
  }
}

/// Main state notifier provider for the transaction feed
final transactionFeedProvider =
    AsyncNotifierProvider<TransactionFeedNotifier, List<BankTransaction>>(
  TransactionFeedNotifier.new,
);

/// Derived provider: latest available bank balance
final latestBalanceProvider = Provider<double>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  if (transactions.isEmpty) return 0.0;
  return transactions.first.currentBalance;
});

/// Derived provider: stats for the last 7 days (spent vs. inflow)
final weeklyStatsProvider = Provider<({double spent, double inflow})>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));

  final spent = transactions
      .where((t) => t.isDebit && t.transactionTimestamp.isAfter(sevenDaysAgo))
      .fold(0.0, (acc, t) => acc + t.amount);

  final inflow = transactions
      .where((t) => t.isCredit && t.transactionTimestamp.isAfter(sevenDaysAgo))
      .fold(0.0, (acc, t) => acc + t.amount);

  return (spent: spent, inflow: inflow);
});

/// Derived provider: transactions grouped by timeline section
final groupedTransactionsProvider =
    Provider<Map<String, List<BankTransaction>>>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  final Map<String, List<BankTransaction>> groups = {};

  for (final txn in transactions) {
    final key = txn.dateGroup;
    if (!groups.containsKey(key)) {
      groups[key] = [];
    }
    groups[key]!.add(txn);
  }

  return groups;
});
