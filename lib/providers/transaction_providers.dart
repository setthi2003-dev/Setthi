import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../models/ai_nudge_model.dart';
import '../models/transaction_group_model.dart';
import '../models/transaction_model.dart';
import '../services/fi_data_service.dart';
import '../services/setu_aa_service.dart';
import '../services/supabase_db_service.dart';
import 'auth_providers.dart';
import 'supabase_provider.dart';

/// Provider for the Setu Account Aggregator service instance
final setuAaServiceProvider = Provider<SetuAaService>((ref) {
  final dbService = ref.watch(supabaseDbServiceProvider);
  return SetuAaService(dbService: dbService);
});

/// State notifier storing the currently approved Setu AA consent ID,
/// with local persistence so the connection persists across app relaunches.
class ActiveConsentIdNotifier extends Notifier<String?> {
  /// Toggle to control disk persistence (can be disabled in test suites)
  static bool enablePersistence = true;

  static const _storageDir = '.setthi_cache';
  static const _fileName = 'active_consent.txt';

  static File _getFile() {
    return File('$_storageDir/$_fileName');
  }

  /// Loads the persisted consent ID from disk, if available
  static String? loadPersistedConsent() {
    if (!enablePersistence) return null;
    try {
      final file = _getFile();
      if (file.existsSync()) {
        final val = file.readAsStringSync().trim();
        return val.isNotEmpty ? val : null;
      }
    } catch (_) {}
    return null;
  }

  /// Persists the active consent ID to local disk
  static void savePersistedConsent(String id) {
    if (!enablePersistence) return;
    try {
      final file = _getFile();
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(id);
    } catch (_) {}
  }

  /// Deletes any cached consent ID from disk
  static void deletePersistedConsent() {
    if (!enablePersistence) return;
    try {
      final file = _getFile();
      if (file.existsSync()) {
        file.deleteSync();
      }
    } catch (_) {}
  }

  /// Discovers any active AA consent record in Supabase and syncs state
  Future<String?> refreshFromBackend() async {
    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      final user = ref.read(currentUserProvider);
      final activeConsent =
          await dbService.fetchActiveConsent(userId: user?.id);
      if (activeConsent != null && activeConsent['consent_id'] != null) {
        final cid = activeConsent['consent_id'] as String;
        if (state != cid) {
          setConsentId(cid);
        }
        return cid;
      }
    } catch (_) {}
    return null;
  }

  @override
  String? build() {
    final persisted = loadPersistedConsent();

    // Auto-discover active consent from Supabase whenever user session updates
    ref.listen<User?>(currentUserProvider, (previous, next) {
      if (next != null) {
        refreshFromBackend();
      }
    });

    // Also trigger immediate discovery on notifier creation
    Future.microtask(() async {
      await refreshFromBackend();
    });

    return persisted;
  }

  void setConsentId(String id) {
    state = id;
    savePersistedConsent(id);
  }

  void clear() {
    state = null;
    deletePersistedConsent();
  }
}

/// Provider managing the active Account Aggregator consent ID
final activeConsentIdProvider =
    NotifierProvider<ActiveConsentIdNotifier, String?>(
  ActiveConsentIdNotifier.new,
);

/// State notifier storing a pending Account Aggregator consent ID during the linking flow
class PendingConsentIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String id) => state = id;
  void clear() => state = null;
}

/// Provider managing an in-flight consent ID awaiting user approval in the WebView
final pendingConsentIdProvider =
    NotifierProvider<PendingConsentIdNotifier, String?>(
  PendingConsentIdNotifier.new,
);

/// Boolean indicating whether an approved Account Aggregator consent is currently active
final hasActiveConsentProvider = Provider<bool>((ref) {
  final consentId = ref.watch(activeConsentIdProvider);
  return consentId != null && consentId.isNotEmpty;
});

/// Repository contract implementation delegating to Supabase Edge Function
class BackendTransactionRepository implements TransactionRepository {
  final SupabaseDbService dbService;
  final String? consentId;

  BackendTransactionRepository({
    required this.dbService,
    this.consentId,
  });

  @override
  Future<List<BankTransaction>> fetchTransactions() async {
    await dbService.triggerBackendSync(consentId: consentId);
    return dbService.fetchStoredTransactions(
      limit: TransactionFeedNotifier.defaultPageSize,
      offset: 0,
    );
  }
}

/// Repository provider resolving to BackendTransactionRepository
final transactionRepositoryProvider = Provider<TransactionRepository>((ref) {
  final consentId = ref.watch(activeConsentIdProvider);
  final dbService = ref.watch(supabaseDbServiceProvider);
  return BackendTransactionRepository(
    dbService: dbService,
    consentId: consentId,
  );
});

/// AsyncNotifier managing the Setu Account Aggregator transaction feed state with on-demand pagination.
class TransactionFeedNotifier extends AsyncNotifier<List<BankTransaction>> {
  static const int defaultPageSize = 25;
  bool _hasMore = true;
  bool _isLoadingMore = false;
  int _totalCount = 0;

  bool get hasMore => _hasMore;
  bool get isLoadingMore => _isLoadingMore;
  int get totalCount => _totalCount;

  @override
  Future<List<BankTransaction>> build() async {
    ref.watch(currentUserProvider);
    final consentId = ref.watch(activeConsentIdProvider);
    final dbService = ref.watch(supabaseDbServiceProvider);

    // 1. Fetch total count of stored transactions for pagination metadata
    try {
      _totalCount = await dbService.countStoredTransactions();
    } catch (_) {}

    // 2. Fetch first page of stored transactions (on-demand pagination)
    List<BankTransaction> storedTxns = [];
    try {
      storedTxns = await dbService.fetchStoredTransactions(
        limit: defaultPageSize,
        offset: 0,
      );
      _hasMore = storedTxns.length >= defaultPageSize &&
          (_totalCount == 0 || storedTxns.length < _totalCount);
    } catch (_) {}

    // 3. Resolve active consent from local state or fallback to Supabase aa_consents table
    String? effectiveConsentId = consentId;
    if (effectiveConsentId == null || effectiveConsentId.isEmpty) {
      try {
        final activeConsent = await dbService.fetchActiveConsent();
        if (activeConsent != null && activeConsent['consent_id'] != null) {
          effectiveConsentId = activeConsent['consent_id'] as String;
          final cid = effectiveConsentId;
          Future.microtask(() {
            ref.read(activeConsentIdProvider.notifier).setConsentId(cid);
          });
        }
      } catch (_) {}
    } else {
      // If a consentId was loaded from disk, check if it still exists in Supabase (in case user reset tables)
      try {
        final activeConsent = await dbService.fetchActiveConsent();
        if (activeConsent == null &&
            SupabaseConfig.isConfigured &&
            dbService.currentUserId != null) {
          ActiveConsentIdNotifier.deletePersistedConsent();
          Future.microtask(() {
            ref.read(activeConsentIdProvider.notifier).clear();
          });
          return storedTxns;
        }
      } catch (_) {}
    }

    // 4. If no stored transactions exist yet, but an active consent is present, trigger backend sync
    if (storedTxns.isEmpty && effectiveConsentId != null && effectiveConsentId.isNotEmpty) {
      try {
        await dbService.triggerBackendSync(consentId: effectiveConsentId);
        _totalCount = await dbService.countStoredTransactions();
        storedTxns = await dbService.fetchStoredTransactions(
          limit: defaultPageSize,
          offset: 0,
        );
        _hasMore = storedTxns.length >= defaultPageSize &&
            (_totalCount == 0 || storedTxns.length < _totalCount);
      } catch (_) {}
    }

    // Return stored transactions
    return storedTxns;
  }

  /// Incremental on-demand pagination: loads the next page of transactions from Supabase
  Future<void> loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    _isLoadingMore = true;
    final currentList = state.value ?? [];
    state = AsyncData(currentList);

    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      final nextChunk = await dbService.fetchStoredTransactions(
        limit: defaultPageSize,
        offset: currentList.length,
      );

      if (nextChunk.isEmpty || nextChunk.length < defaultPageSize) {
        _hasMore = false;
      }

      final merged = [...currentList, ...nextChunk];
      final seen = <String>{};
      final deduped = merged.where((t) => seen.add(t.txnId)).toList();
      state = AsyncData(deduped);
    } catch (e) {
      state = AsyncData(currentList);
    } finally {
      _isLoadingMore = false;
      state = AsyncData(state.value ?? currentList);
    }
  }

  /// Updates the category for a transaction optimistically, updates Supabase in background,
  /// and optionally creates a merchant auto-categorization rule.
  Future<void> updateTransactionCategory({
    required String txnId,
    required String category,
    bool applyToAllFromMerchant = false,
    String? cleanMerchantName,
  }) async {
    final currentList = state.value ?? [];
    List<BankTransaction> updatedList;

    final cleanLower = cleanMerchantName?.toLowerCase().trim() ?? '';
    final isGeneric = cleanLower == 'others' ||
        cleanLower == 'other' ||
        cleanLower == 'transaction' ||
        cleanLower == 'transactions' ||
        cleanLower == 'transfer' ||
        cleanLower == 'unknown' ||
        cleanLower.isEmpty;

    if (applyToAllFromMerchant && !isGeneric && cleanMerchantName != null) {
      final targetName = cleanLower;
      updatedList = currentList.map((t) {
        if (t.cleanMerchantName.toLowerCase().trim() == targetName) {
          return t.copyWith(category: category);
        }
        return t;
      }).toList();
    } else {
      updatedList = currentList.map((t) {
        if (t.txnId == txnId) {
          return t.copyWith(category: category);
        }
        return t;
      }).toList();
    }

    state = AsyncData(updatedList);

    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      await dbService.updateTransactionCategory(
        txnId: txnId,
        category: category,
      );

      if (applyToAllFromMerchant && !isGeneric && cleanMerchantName != null) {
        await dbService.updateAllTransactionsCategoryByMerchant(
          cleanMerchantName: cleanMerchantName,
          category: category,
        );

        final keyword = cleanMerchantName.toLowerCase().trim();
        await dbService.saveMerchantRule(
          keyword: keyword,
          cleanName: cleanMerchantName,
          category: category,
        );
      }
    } catch (_) {}
  }

  /// Manually trigger a transaction sync from the backend edge function.
  Future<void> syncTransactions() async {
    var consentId = ref.read(activeConsentIdProvider);
    final dbService = ref.read(supabaseDbServiceProvider);

    if (consentId == null || consentId.isEmpty) {
      try {
        final activeConsent = await dbService.fetchActiveConsent();
        if (activeConsent != null && activeConsent['consent_id'] != null) {
          consentId = activeConsent['consent_id'] as String;
          ref.read(activeConsentIdProvider.notifier).setConsentId(consentId);
        }
      } catch (_) {}
    }

    if ((consentId == null || consentId.isEmpty) && !SupabaseConfig.isConfigured) {
      final stored = await dbService.fetchStoredTransactions(
        limit: defaultPageSize,
        offset: 0,
      );
      state = AsyncData(stored);
      return;
    }

    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      try {
        await dbService.triggerBackendSync(consentId: consentId);
      } on SetuConsentExpiredException catch (_) {
        ActiveConsentIdNotifier.deletePersistedConsent();
        ref.read(activeConsentIdProvider.notifier).clear();
        if (consentId != null) {
          await dbService.updateConsentStatus(consentId: consentId, status: 'EXPIRED');
        }
        final stored = await dbService.fetchStoredTransactions(
          limit: defaultPageSize,
          offset: 0,
        );
        if (stored.isNotEmpty) return stored;
        throw SetuConsentExpiredException(
          'Bank consent session has expired or completed. Please reconnect your bank.',
        );
      } catch (e) {
        // If repository is overridden (e.g. in widget tests with _FakeTestRepository)
        final repository = ref.read(transactionRepositoryProvider);
        if (repository is! BackendTransactionRepository) {
          final txns = await repository.fetchTransactions();
          return txns;
        }
        rethrow;
      }

      _totalCount = await dbService.countStoredTransactions();
      final freshStored = await dbService.fetchStoredTransactions(
        limit: defaultPageSize,
        offset: 0,
      );
      _hasMore = freshStored.length >= defaultPageSize &&
          (_totalCount == 0 || freshStored.length < _totalCount);
      return freshStored;
    });
  }

  /// Sets an approved consent and immediately initiates live data sync
  Future<void> setConsentAndSync(String consentId) async {
    ref.read(activeConsentIdProvider.notifier).setConsentId(consentId);
    ref.read(pendingConsentIdProvider.notifier).clear();
    final dbService = ref.read(supabaseDbServiceProvider);
    await dbService.recordConsent(consentId: consentId, status: 'ACTIVE');
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

/// Derived provider: whether more paginated transactions exist to load from database
final hasMoreTransactionsProvider = Provider<bool>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  final notifier = ref.watch(transactionFeedProvider.notifier);

  // If current list has fewer transactions than a full page, all are loaded
  if (transactions.isNotEmpty &&
      transactions.length < TransactionFeedNotifier.defaultPageSize) {
    return false;
  }

  return notifier.hasMore;
});

/// Derived provider: whether earlier transactions are currently being fetched
final isLoadingMoreTransactionsProvider = Provider<bool>((ref) {
  ref.watch(transactionFeedProvider);
  return ref.watch(transactionFeedProvider.notifier).isLoadingMore;
});

/// Derived provider: total transaction count stored
final totalTransactionsCountProvider = Provider<int>((ref) {
  return ref.watch(transactionFeedProvider.notifier).totalCount;
});

/// Derived provider: latest available bank balance
final latestBalanceProvider = Provider<double>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  if (transactions.isEmpty) return 0.0;
  return transactions.first.currentBalance;
});

/// Derived provider: stats for the active weekly window (spent vs. inflow)
final weeklyStatsProvider =
    Provider<({double spent, double inflow, String periodLabel, bool isLive})>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  if (transactions.isEmpty) {
    return (spent: 0.0, inflow: 0.0, periodLabel: 'this week', isLive: true);
  }

  final now = DateTime.now();
  DateTime latestTxnDate = transactions.first.transactionTimestamp;
  for (final t in transactions) {
    if (t.transactionTimestamp.isAfter(latestTxnDate)) {
      latestTxnDate = t.transactionTimestamp;
    }
  }

  // Live if latest transaction is within 7 days of now
  final isLive = now.difference(latestTxnDate).inDays.abs() <= 7;
  final anchorDate = isLive ? now : latestTxnDate;
  final sevenDaysBefore = anchorDate.subtract(const Duration(days: 7));

  var spent = transactions
      .where((t) =>
          t.isDebit &&
          t.transactionTimestamp.isAfter(sevenDaysBefore) &&
          !t.transactionTimestamp.isAfter(anchorDate))
      .fold(0.0, (acc, t) => acc + t.amount);

  var inflow = transactions
      .where((t) =>
          t.isCredit &&
          t.transactionTimestamp.isAfter(sevenDaysBefore) &&
          !t.transactionTimestamp.isAfter(anchorDate))
      .fold(0.0, (acc, t) => acc + t.amount);

  const shortMonths = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String label;
  if (isLive) {
    label = 'this week';
  } else {
    final startFmt = '${sevenDaysBefore.day} ${shortMonths[sevenDaysBefore.month - 1]}';
    final endFmt = '${anchorDate.day} ${shortMonths[anchorDate.month - 1]} ${anchorDate.year}';
    label = '$startFmt – $endFmt';
  }

  if (spent == 0.0 && inflow == 0.0) {
    final monthStart = DateTime(anchorDate.year, anchorDate.month, 1);
    final monthEnd = DateTime(anchorDate.year, anchorDate.month + 1, 1);
    spent = transactions
        .where((t) =>
            t.isDebit &&
            !t.transactionTimestamp.isBefore(monthStart) &&
            t.transactionTimestamp.isBefore(monthEnd))
        .fold(0.0, (acc, t) => acc + t.amount);
    inflow = transactions
        .where((t) =>
            t.isCredit &&
            !t.transactionTimestamp.isBefore(monthStart) &&
            t.transactionTimestamp.isBefore(monthEnd))
        .fold(0.0, (acc, t) => acc + t.amount);
    if (isLive) {
      label = 'this month';
    } else {
      label = '${shortMonths[anchorDate.month - 1]} ${anchorDate.year}';
    }
  }

  return (spent: spent, inflow: inflow, periodLabel: label, isLive: isLive);
});

/// Derived provider: transactions grouped by timeline section (legacy format)
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

/// Filter state notifier: Sort order (latestFirst vs oldestFirst)
class TransactionSortOrderNotifier extends Notifier<TransactionSortOrder> {
  @override
  TransactionSortOrder build() => TransactionSortOrder.latestFirst;

  @override
  TransactionSortOrder get state => super.state;
  @override
  set state(TransactionSortOrder value) => super.state = value;
}

final transactionSortOrderProvider =
    NotifierProvider<TransactionSortOrderNotifier, TransactionSortOrder>(
        TransactionSortOrderNotifier.new);

/// Filter state notifier: Type filter (all vs debitOnly vs creditOnly)
class TransactionTypeFilterNotifier extends Notifier<TransactionTypeFilter> {
  @override
  TransactionTypeFilter build() => TransactionTypeFilter.all;

  @override
  TransactionTypeFilter get state => super.state;
  @override
  set state(TransactionTypeFilter value) => super.state = value;
}

final transactionTypeFilterProvider =
    NotifierProvider<TransactionTypeFilterNotifier, TransactionTypeFilter>(
        TransactionTypeFilterNotifier.new);

/// Filter state notifier: Selected year filter (null = all years)
class TransactionSelectedYearNotifier extends Notifier<int?> {
  @override
  int? build() => null;

  @override
  int? get state => super.state;
  @override
  set state(int? value) => super.state = value;
}

final transactionSelectedYearProvider =
    NotifierProvider<TransactionSelectedYearNotifier, int?>(
        TransactionSelectedYearNotifier.new);

/// Derived provider: List of available years present in transactions (sorted descending)
final availableYearsProvider = Provider<List<int>>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  final years = transactions
      .map((t) => t.transactionTimestamp.year)
      .toSet()
      .toList();
  years.sort((a, b) => b.compareTo(a));
  return years;
});

/// Derived provider: Smart hierarchical transactions grouped by Year -> Month -> Date
final smartGroupedTransactionsProvider = Provider<List<YearGroup>>((ref) {
  final transactions = ref.watch(transactionFeedProvider).value ?? [];
  final sortOrder = ref.watch(transactionSortOrderProvider);
  final typeFilter = ref.watch(transactionTypeFilterProvider);
  final selectedYear = ref.watch(transactionSelectedYearProvider);

  return groupTransactionsSmartly(
    transactions: transactions,
    sortOrder: sortOrder,
    typeFilter: typeFilter,
    selectedYear: selectedYear,
  );
});

/// AsyncNotifier managing active AI proactive nudges for the carousel
class AiNudgesNotifier extends AsyncNotifier<List<AiNudge>> {
  @override
  Future<List<AiNudge>> build() async {
    ref.watch(currentUserProvider);
    final dbService = ref.watch(supabaseDbServiceProvider);
    return await dbService.fetchActiveNudges();
  }

  Future<void> dismiss(String nudgeId) async {
    final currentList = state.value ?? [];
    state = AsyncValue.data(currentList.where((n) => n.id != nudgeId).toList());
    final dbService = ref.read(supabaseDbServiceProvider);
    await dbService.dismissNudge(nudgeId);
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      final dbService = ref.read(supabaseDbServiceProvider);
      return await dbService.fetchActiveNudges();
    });
  }
}

final aiNudgesProvider =
    AsyncNotifierProvider<AiNudgesNotifier, List<AiNudge>>(AiNudgesNotifier.new);

/// Telemetry filter period index (0: 'all', 1: 'month', 2: '7d', 3: 'debits', 4: 'inflow')
class TelemetryPeriodIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;

  @override
  int get state => super.state;
  @override
  set state(int value) => super.state = value;
}

final telemetryPeriodIndexProvider =
    NotifierProvider<TelemetryPeriodIndexNotifier, int>(
        TelemetryPeriodIndexNotifier.new);

/// Telemetry metrics provider delivering real SQL aggregations from get_telemetry_metrics RPC
final telemetryMetricsProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final filterIndex = ref.watch(telemetryPeriodIndexProvider);
  const periods = ['all', 'month', '7d', 'debits', 'inflow'];
  final period = (filterIndex >= 0 && filterIndex < periods.length) ? periods[filterIndex] : 'all';
  ref.watch(currentUserProvider);
  ref.watch(transactionFeedProvider);
  final dbService = ref.watch(supabaseDbServiceProvider);
  return await dbService.fetchTelemetryMetrics(period: period);
});
