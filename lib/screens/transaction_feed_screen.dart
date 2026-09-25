import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../config/supabase_config.dart';
import '../models/transaction_group_model.dart';
import '../models/transaction_model.dart';
import '../providers/auth_providers.dart';
import '../providers/supabase_provider.dart';
import '../providers/transaction_providers.dart';
import '../widgets/dpc_floating_dock.dart';
import '../widgets/dpc_hero_carousel.dart';
import '../widgets/dpc_telemetry_cards.dart';
import '../widgets/slide_to_confirm.dart';
import '../widgets/bank_sync_permission_sheet.dart';
import '../widgets/setthi_ai_sheet.dart';
import '../providers/chat_providers.dart';
import 'setu_consent_webview.dart';

/// Full DPC Redesign of the Setthi Transaction Feed & Telemetry Dashboard.
/// Implements:
/// - Screen A: Dashboard & Hero Carousel
/// - Screen B: Telemetry & Analytics Dashboard
/// - Floating Bottom Navigation Dock
/// - Pure OLED True-Black Surfaces (#000000) & #0D0D11 Card Bases
class TransactionFeedScreen extends ConsumerStatefulWidget {
  const TransactionFeedScreen({super.key});

  @override
  ConsumerState<TransactionFeedScreen> createState() =>
      _TransactionFeedScreenState();
}

class _TransactionFeedScreenState extends ConsumerState<TransactionFeedScreen> {
  final ScrollController _scrollController = ScrollController();
  int _activeNavIndex =
      0; // 0: Dashboard (Screen A), 1: Telemetry (Screen B, kept for reference)
  int _telemetryFilterIndex = 0; // Kept for reference

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activeConsentIdProvider.notifier).refreshFromBackend();
    });
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_activeNavIndex != 0) return;
    _checkAutoFetch(_scrollController.position);
  }

  void _checkAutoFetch(ScrollMetrics metrics) {
    if (metrics.maxScrollExtent <= 0) return;
    // Auto-fetch earlier transactions when user scrolls within 350px of the bottom
    if (metrics.pixels >= metrics.maxScrollExtent - 350) {
      final hasMore = ref.read(hasMoreTransactionsProvider);
      final isLoadingMore = ref.read(isLoadingMoreTransactionsProvider);
      if (hasMore && !isLoadingMore) {
        ref.read(transactionFeedProvider.notifier).loadMore();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final transactionFeedAsync = ref.watch(transactionFeedProvider);
    final hasActiveConsent = ref.watch(hasActiveConsentProvider);
    final isSyncing = transactionFeedAsync.isLoading;

    return Scaffold(
      backgroundColor: DpcColors.bgOled,
      appBar: _buildDpcAppBar(context, ref, hasActiveConsent),
      extendBody: true,
      body: RefreshIndicator(
        onRefresh: () => _handleSyncAction(context, ref),
        color: DpcColors.accentPositive,
        backgroundColor: DpcColors.surfaceDark,
        child: transactionFeedAsync.when(
          data: (transactions) => _buildBodyContent(
            context,
            ref,
            transactions,
            hasActiveConsent,
            isSyncing,
          ),
          loading: () {
            if (transactionFeedAsync.hasValue) {
              return _buildBodyContent(
                context,
                ref,
                transactionFeedAsync.value!,
                hasActiveConsent,
                isSyncing,
              );
            }
            return _buildSkeletonLoader();
          },
          error: (err, stack) {
            if (transactionFeedAsync.hasValue &&
                transactionFeedAsync.value!.isNotEmpty) {
              return _buildBodyContent(
                context,
                ref,
                transactionFeedAsync.value!,
                hasActiveConsent,
                isSyncing,
              );
            }
            return _buildErrorState(context, ref, err.toString());
          },
        ),
      ),
      bottomNavigationBar: DpcFloatingNavDock(
        activeIndex: _activeNavIndex,
        onHomeTap: () {
          if (_activeNavIndex != 0) {
            setState(() => _activeNavIndex = 0);
          } else if (_scrollController.hasClients) {
            _scrollController.animateTo(
              0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
            );
          }
        },
        onAiChatTap: () => SetthiAiSheet.show(context),
        onSyncTap: () => _handleSyncAction(context, ref),
        onBankTap: () => _showLinkBankBottomSheet(context, ref),
        onProfileTap: () {
          setState(() => _activeNavIndex = 1);
        },
        isSyncing: isSyncing,
        hasActiveConsent: hasActiveConsent,
      ),
    );
  }

  /// Utility Navigation Bar (Top) as specified in DPC Screen A:
  PreferredSizeWidget _buildDpcAppBar(
    BuildContext context,
    WidgetRef ref,
    bool hasActiveConsent,
  ) {
    if (_activeNavIndex == 1) {
      // Profile Screen AppBar
      return AppBar(
        elevation: 0,
        backgroundColor: DpcColors.bgOled,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 18,
        title: const Text(
          'Profile & Account',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
      );
    }

    if (_activeNavIndex == 2) {
      // Telemetry Screen AppBar
      return AppBar(
        elevation: 0,
        backgroundColor: DpcColors.bgOled,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 18,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: DpcColors.textPrimary),
          onPressed: () => setState(() => _activeNavIndex = 0),
        ),
        title: const Text(
          'Telemetry & Analytics',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
      );
    }

    // Home AppBar (Profile button removed; moved to bottom dock)
    return AppBar(
      elevation: 0,
      backgroundColor: DpcColors.bgOled,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 18,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Setthi Brand with app logo
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/app icon/Setthi.png',
                  width: 28,
                  height: 28,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: DpcColors.heroPastel1,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: DpcColors.textContrast,
                      size: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 9),
              const Text(
                'Setthi',
                style: TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
            ],
          ),

          // Right: Status connection badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: hasActiveConsent
                  ? DpcColors.accentPositive.withValues(alpha: 0.12)
                  : DpcColors.surfaceDark,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: hasActiveConsent
                    ? DpcColors.accentPositive.withValues(alpha: 0.3)
                    : DpcColors.surfaceBorder,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: hasActiveConsent
                        ? DpcColors.accentPositive
                        : DpcColors.accentLevel,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  hasActiveConsent ? 'Bank Live' : 'Sandbox',
                  style: TextStyle(
                    color: hasActiveConsent
                        ? DpcColors.accentPositive
                        : DpcColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodyContent(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
    bool hasActiveConsent,
    bool isSyncing,
  ) {
    if (_activeNavIndex == 1) {
      // Dedicated Profile Screen
      return _buildProfileScreen(context, ref);
    }
    if (_activeNavIndex == 2) {
      // Screen B: Telemetry & Analytics Dashboard
      return _buildTelemetryScreen(context, ref, transactions);
    }
    // Screen A: Dashboard & Hero Carousel
    return _buildDashboardScreen(
      context,
      ref,
      transactions,
      hasActiveConsent,
      isSyncing,
    );
  }

  // ==========================================
  // SCREEN A: DASHBOARD & HERO CAROUSEL
  // ==========================================
  Widget _buildDashboardScreen(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
    bool hasActiveConsent,
    bool isSyncing,
  ) {
    final balance = ref.watch(latestBalanceProvider);
    final weeklyStats = ref.watch(weeklyStatsProvider);
    final yearGroups = ref.watch(smartGroupedTransactionsProvider);
    final sortOrder = ref.watch(transactionSortOrderProvider);
    final typeFilter = ref.watch(transactionTypeFilterProvider);
    final selectedYear = ref.watch(transactionSelectedYearProvider);
    final availableYears = ref.watch(availableYearsProvider);
    final totalMatchingTxns = yearGroups.fold<int>(
      0,
      (acc, y) => acc + y.transactionCount,
    );
    final hasMore = ref.watch(hasMoreTransactionsProvider);
    final isLoadingMore = ref.watch(isLoadingMoreTransactionsProvider);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        _checkAutoFetch(notification.metrics);
        return false;
      },
      child: CustomScrollView(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
            child: _buildHeroAggregate(
              balance,
              hasActiveConsent,
              weeklyStats: weeklyStats,
              isSyncing: isSyncing,
            ),
          ),
        ),

        // 2. Floating Horizontal Hero Carousel (Screen edge-to-edge with peeking affordance)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 8),
            child: DpcHeroCarousel(
              items: _buildHeroCarouselItems(
                context,
                ref,
                hasActiveConsent: hasActiveConsent,
                weeklyStats: weeklyStats,
                isSyncing: isSyncing,
              ),
            ),
          ),
        ),

        if (transactions.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
              child: _buildFilterAndSortBar(
                context,
                ref,
                totalTransactions: transactions.length,
                matchingTransactions: totalMatchingTxns,
                sortOrder: sortOrder,
                typeFilter: typeFilter,
                selectedYear: selectedYear,
                availableYears: availableYears,
              ),
            ),
          ),

        // Transactions Feed or Empty State
        if (transactions.isEmpty)
          SliverToBoxAdapter(
            child: _buildEmptyState(context, ref, hasActiveConsent, isSyncing),
          )
        else if (yearGroups.isEmpty)
          SliverToBoxAdapter(child: _buildFilterEmptyState(context, ref))
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, yearIndex) {
                final yearGroup = yearGroups[yearIndex];
                final showYearHeader = availableYears.length > 1;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Minimalist Year Header (if multi-year data exists)
                    if (showYearHeader) ...[
                      Padding(
                        padding: EdgeInsets.only(
                          top: yearIndex == 0 ? 4 : 20,
                          bottom: 8,
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${yearGroup.year}',
                              style: const TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                height: 1,
                                color: DpcColors.surfaceBorder,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Months within this Year
                    for (
                      int mIdx = 0;
                      mIdx < yearGroup.monthGroups.length;
                      mIdx++
                    ) ...[
                      _buildMonthSection(
                        context,
                        yearGroup.monthGroups[mIdx],
                        isFirstInYear: mIdx == 0 && !showYearHeader,
                      ),
                    ],
                  ],
                );
              }, childCount: yearGroups.length),
            ),
          ),

        // On-Demand Pagination Footer
        if (transactions.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              child: Center(
                child: hasMore
                    ? (isLoadingMore
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: DpcColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: DpcColors.surfaceBorder,
                                width: 1,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: DpcColors.accentPositive,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Loading earlier transactions...',
                                  style: TextStyle(
                                    color: DpcColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: () => ref
                                .read(transactionFeedProvider.notifier)
                                .loadMore(),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: DpcColors.textPrimary,
                              side: const BorderSide(
                                color: DpcColors.surfaceBorder,
                                width: 1,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                            ),
                            icon: const Icon(
                              Icons.history_rounded,
                              size: 16,
                              color: DpcColors.textSecondary,
                            ),
                            label: const Text(
                              'Load Earlier Transactions',
                              style: TextStyle(
                                color: DpcColors.textSecondary,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ))
                    : Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                color: DpcColors.accentPositive.withValues(alpha: 0.15),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.check_rounded,
                                size: 10,
                                color: DpcColors.accentPositive,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              sortOrder == TransactionSortOrder.latestFirst
                                  ? "You're all caught up • Earliest transaction reached"
                                  : "You're all caught up • Latest transaction reached",
                              style: const TextStyle(
                                color: DpcColors.textSecondary,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                letterSpacing: -0.1,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),

        const SliverToBoxAdapter(
          child: SizedBox(height: 100), // padding for floating dock
        ),
      ],
    ),
  );
  }

  /// Timeline Filter & Sort Bar
  Widget _buildFilterAndSortBar(
    BuildContext context,
    WidgetRef ref, {
    required int totalTransactions,
    required int matchingTransactions,
    required TransactionSortOrder sortOrder,
    required TransactionTypeFilter typeFilter,
    required int? selectedYear,
    required List<int> availableYears,
  }) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          // 1. Latest / Oldest Toggle Chip
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                ref
                    .read(transactionSortOrderProvider.notifier)
                    .state = sortOrder == TransactionSortOrder.latestFirst
                    ? TransactionSortOrder.oldestFirst
                    : TransactionSortOrder.latestFirst;
              },
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceDark,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: sortOrder == TransactionSortOrder.latestFirst
                        ? const Color(0xFF86E3CE).withValues(alpha: 0.5)
                        : const Color(0xFFFFB3BA).withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      sortOrder == TransactionSortOrder.latestFirst
                          ? Icons.south_rounded
                          : Icons.north_rounded,
                      size: 12,
                      color: sortOrder == TransactionSortOrder.latestFirst
                          ? const Color(0xFF86E3CE)
                          : const Color(0xFFFFB3BA),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sortOrder == TransactionSortOrder.latestFirst
                          ? 'Latest'
                          : 'Oldest',
                      style: TextStyle(
                        color: sortOrder == TransactionSortOrder.latestFirst
                            ? const Color(0xFF86E3CE)
                            : const Color(0xFFFFB3BA),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          Container(width: 1, height: 16, color: DpcColors.surfaceBorder),
          const SizedBox(width: 8),

          // 2. Flow: All Flows
          _buildFilterChip(
            label: 'All Flows',
            isSelected: typeFilter == TransactionTypeFilter.all,
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.all,
          ),
          const SizedBox(width: 6),

          // 3. Flow: Debits
          _buildFilterChip(
            label: 'Debits ↓',
            isSelected: typeFilter == TransactionTypeFilter.debitOnly,
            accentColor: const Color(0xFFFF6E7F),
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.debitOnly,
          ),
          const SizedBox(width: 6),

          // 4. Flow: Credits
          _buildFilterChip(
            label: 'Credits ↑',
            isSelected: typeFilter == TransactionTypeFilter.creditOnly,
            accentColor: DpcColors.accentPositive,
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.creditOnly,
          ),
          const SizedBox(width: 6),

          // 5. Flow: Untagged (both credits & debits)
          _buildFilterChip(
            label: 'Untagged',
            isSelected: typeFilter == TransactionTypeFilter.untagged,
            accentColor: const Color(0xFFFBBF24),
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.untagged,
          ),

          // 5. Years (if multi-year)
          if (availableYears.length > 1) ...[
            const SizedBox(width: 8),
            Container(width: 1, height: 16, color: DpcColors.surfaceBorder),
            const SizedBox(width: 8),
            _buildFilterChip(
              label: 'All Years',
              isSelected: selectedYear == null,
              onTap: () =>
                  ref.read(transactionSelectedYearProvider.notifier).state =
                      null,
            ),
            for (final y in availableYears) ...[
              const SizedBox(width: 6),
              _buildFilterChip(
                label: '$y',
                isSelected: selectedYear == y,
                accentColor: const Color(0xFFA78BFA),
                onTap: () =>
                    ref.read(transactionSelectedYearProvider.notifier).state =
                        y,
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    Color? accentColor,
  }) {
    final effectiveAccent = accentColor ?? DpcColors.accentPositive;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? effectiveAccent.withValues(alpha: 0.14)
                : DpcColors.surfaceDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? effectiveAccent.withValues(alpha: 0.7)
                  : DpcColors.surfaceBorder,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? effectiveAccent : DpcColors.textSecondary,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMonthSection(
    BuildContext context,
    MonthGroup monthGroup, {
    bool isFirstInYear = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Month Header Ribbon
        Padding(
          padding: EdgeInsets.only(top: isFirstInYear ? 4 : 16, bottom: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceTrack,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DpcColors.surfaceBorder, width: 1),
                ),
                child: Text(
                  monthGroup.title.toUpperCase(),
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(height: 1, color: DpcColors.surfaceBorder),
              ),
              const SizedBox(width: 8),
              // Monthly Outflow & Inflow summary
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (monthGroup.totalDebit > 0) ...[
                    Text(
                      '-${BankTransaction.formatRupees(monthGroup.totalDebit)}',
                      style: const TextStyle(
                        color: Color(0xFFFF6E7F),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (monthGroup.totalCredit > 0)
                    Text(
                      '+${BankTransaction.formatRupees(monthGroup.totalCredit)}',
                      style: const TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),

        // Day Groups within this Month
        for (final dayGroup in monthGroup.dayGroups) ...[
          _buildDayGroup(context, dayGroup),
        ],
      ],
    );
  }

  Widget _buildDayGroup(BuildContext context, DayGroup dayGroup) {
    final isToday = dayGroup.title.startsWith('Today');
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Day Header
          Padding(
            padding: const EdgeInsets.only(
              top: 6,
              bottom: 6,
            ),
            child: Row(
              children: [
                if (isToday)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: const BoxDecoration(
                      color: DpcColors.accentPositive,
                      shape: BoxShape.circle,
                    ),
                  ),
                Text(
                  dayGroup.title,
                  style: TextStyle(
                    color: isToday
                        ? DpcColors.textPrimary
                        : DpcColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.1,
                  ),
                ),
              ],
            ),
          ),

          // Day Grouped Transactions (Unboxed, clean minimalist layout)
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: dayGroup.transactions.length,
            separatorBuilder: (context, _) => const Divider(
              height: 12,
              thickness: 0.5,
              color: DpcColors.surfaceBorder,
              indent: 50,
            ),
            itemBuilder: (context, itemIdx) {
              return _buildTransactionTile(
                context,
                dayGroup.transactions[itemIdx],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildFilterEmptyState(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
      child: Center(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: DpcColors.surfaceDark,
                shape: BoxShape.circle,
                border: Border.all(color: DpcColors.surfaceBorder),
              ),
              child: const Icon(
                Icons.filter_alt_off_rounded,
                size: 28,
                color: DpcColors.textSecondary,
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'No transactions match this filter',
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try changing your flow type or year selection.',
              style: TextStyle(color: DpcColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.all;
                ref.read(transactionSelectedYearProvider.notifier).state = null;
              },
              child: const Text(
                'Reset Filters',
                style: TextStyle(
                  color: DpcColors.accentPositive,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Floating Horizontal Hero Carousel Items as defined in DPC Screen A
  List<DpcHeroCardItem> _buildHeroCarouselItems(
    BuildContext context,
    WidgetRef ref, {
    required bool hasActiveConsent,
    required ({double spent, double inflow, String periodLabel, bool isLive}) weeklyStats,
    required bool isSyncing,
  }) {
    final activeNudges = ref.watch(aiNudgesProvider).value ?? [];

    LinearGradient resolveNudgeGradient(String style) {
      switch (style) {
        case 'heroPastel1':
          return DpcColors.heroPastel1;
        case 'heroPastel2':
          return DpcColors.heroPastel2;
        case 'heroPastel3':
          return DpcColors.heroPastel3;
        case 'heroPastel4':
          return DpcColors.heroPastel4;
        default:
          return DpcColors.heroPastel2;
      }
    }

    final card1 = DpcHeroCardItem(
      title: 'Setu AA ReBIT Gateway',
      subtitle: hasActiveConsent
          ? 'Consent Active • Live Real-time Bank Sync'
          : 'Connect your bank account via RBI Regulated Account Aggregator',
      badgeText: hasActiveConsent ? 'ACTIVE • RBI AA' : 'CONNECT',
      icon: hasActiveConsent
          ? Icons.verified_rounded
          : Icons.account_balance_rounded,
      gradient: DpcColors.heroPastel1,
      actionLabel: hasActiveConsent
          ? (isSyncing ? 'Syncing...' : 'Sync Transactions')
          : 'Link Bank',
      onTap: () => hasActiveConsent
          ? _handleSyncAction(context, ref)
          : _showLinkBankBottomSheet(context, ref),
    );

    // Card 2: Dynamic Nudge 1 or Fallback Cashflow Overview
    final card2 = activeNudges.isNotEmpty
        ? DpcHeroCardItem(
            title: activeNudges[0].headline,
            subtitle: activeNudges[0].body,
            badgeText: activeNudges[0].badgeText,
            icon: Icons.lightbulb_rounded,
            gradient: resolveNudgeGradient(activeNudges[0].cardStyle),
            actionLabel: activeNudges[0].actionLabel ?? 'Ask Setthi AI',
            onTap: () => SetthiAiSheet.show(
              context,
              initialPrompt:
                  'Why is this happening: "${activeNudges[0].headline}" - ${activeNudges[0].body}? What should I do?',
            ),
          )
        : DpcHeroCardItem(
            title: 'Cashflow Overview',
            subtitle: weeklyStats.isLive
                ? '${BankTransaction.formatRupees(weeklyStats.spent)} spent • ${BankTransaction.formatRupees(weeklyStats.inflow)} inflow this week'
                : '${BankTransaction.formatRupees(weeklyStats.spent)} spent • ${BankTransaction.formatRupees(weeklyStats.inflow)} inflow (${weeklyStats.periodLabel})',
            badgeText: 'ANALYTICS',
            icon: Icons.insights_rounded,
            gradient: DpcColors.heroPastel2,
            actionLabel: 'View Telemetry',
            onTap: () => setState(() => _activeNavIndex = 2),
          );

    // Card 3: Dynamic Nudge 2 or Fallback Smart Categorization
    final card3 = activeNudges.length > 1
        ? DpcHeroCardItem(
            title: activeNudges[1].headline,
            subtitle: activeNudges[1].body,
            badgeText: activeNudges[1].badgeText,
            icon: Icons.bolt_rounded,
            gradient: resolveNudgeGradient(activeNudges[1].cardStyle),
            actionLabel: activeNudges[1].actionLabel ?? 'Ask Setthi AI',
            onTap: () => SetthiAiSheet.show(
              context,
              initialPrompt:
                  'Regarding "${activeNudges[1].headline}": ${activeNudges[1].body}. Can you break this down for me?',
            ),
          )
        : DpcHeroCardItem(
            title: 'Smart Categorization',
            subtitle:
                'Automated UPI narration cleaner and merchant brand tagging',
            badgeText: 'FINANCIAL AI',
            icon: Icons.auto_awesome_rounded,
            gradient: DpcColors.heroPastel3,
            actionLabel: 'Timeline Feed',
            onTap: () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  300,
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutCubic,
                );
              }
            },
          );

    final card4 = DpcHeroCardItem(
      title: 'Security & Vault',
      subtitle:
          'Zero-secret on-device architecture secured with Supabase Vault',
      badgeText: 'ENCRYPTED',
      icon: Icons.lock_rounded,
      gradient: DpcColors.heroPastel4,
      actionLabel: 'Profile & Settings',
      onTap: () => setState(() => _activeNavIndex = 1),
    );

    return [card1, card2, card3, card4];
  }

  /// 1. Prominent Hero Aggregate:
  /// Free-floating without container constraints as per DPC Rule.
  Widget _buildHeroAggregate(
    double balance,
    bool hasActiveConsent, {
    ({double spent, double inflow, String periodLabel, bool isLive})? weeklyStats,
    bool isSyncing = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'TOTAL AVAILABLE BALANCE',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              BankTransaction.formatRupees(balance),
              style: DpcTypography.displayMetric,
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: DpcColors.surfaceDark,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: DpcColors.surfaceBorder, width: 1),
              ),
              child: const Text(
                'INR',
                style: TextStyle(
                  color: DpcColors.accentPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        if (hasActiveConsent && weeklyStats != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.trending_down_rounded,
                size: 14,
                color: weeklyStats.spent > 0
                    ? const Color(0xFFFF6E7F)
                    : DpcColors.textMuted,
              ),
              const SizedBox(width: 4),
              Text(
                weeklyStats.spent > 0
                    ? (weeklyStats.isLive
                        ? '${BankTransaction.formatRupees(weeklyStats.spent)} outflow this week'
                        : '${BankTransaction.formatRupees(weeklyStats.spent)} outflow (${weeklyStats.periodLabel})')
                    : 'All accounts verified & synced',
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (weeklyStats.inflow > 0) ...[
                const SizedBox(width: 8),
                const Text(
                  '•',
                  style: TextStyle(color: DpcColors.surfaceBorder),
                ),
                const SizedBox(width: 8),
                Text(
                  '+${BankTransaction.formatRupees(weeklyStats.inflow)} in',
                  style: const TextStyle(
                    color: DpcColors.accentPositive,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }

  /// 5. Individual Transaction Row in Minimalist DPC Style
  Widget _buildTransactionTile(BuildContext context, BankTransaction txn) {
    final isDebit = txn.isDebit;
    final amountColor = isDebit
        ? DpcColors.textPrimary
        : DpcColors.accentPositive;

    return InkWell(
      onTap: () => _showTransactionDetailsModal(context, txn),
      borderRadius: BorderRadius.circular(8),
      splashColor: DpcColors.surfaceTrack.withValues(alpha: 0.3),
      child: Padding(
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            // Category Icon with subtle tinted squircle
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color:
                    (isDebit
                            ? DpcColors.surfaceTrack
                            : DpcColors.accentPositive)
                        .withValues(alpha: isDebit ? 0.6 : 0.12),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color:
                      (isDebit
                              ? DpcColors.surfaceBorder
                              : DpcColors.accentPositive)
                          .withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                txn.icon,
                color: isDebit
                    ? DpcColors.textSecondary
                    : DpcColors.accentPositive,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            // Clean Merchant name & Time / Mode
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    txn.cleanMerchantName,
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        '${txn.formattedTime} • ${txn.mode}',
                        style: const TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (txn.category != null && txn.category!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _showCategoryPickerModal(context, txn),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: txn.accentColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: txn.accentColor.withValues(alpha: 0.3),
                                  width: 0.8,
                                ),
                              ),
                              child: Text(
                                txn.category!,
                                style: TextStyle(
                                  color: txn.accentColor,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.1,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _showCategoryPickerModal(context, txn),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: DpcColors.surfaceTrack.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: DpcColors.surfaceBorder,
                                width: 0.8,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.add_rounded,
                                  size: 10,
                                  color: DpcColors.textMuted,
                                ),
                                SizedBox(width: 2),
                                Text(
                                  'Tag',
                                  style: TextStyle(
                                    color: DpcColors.textMuted,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // High-contrast clean Amount
            Text(
              '${isDebit ? '- ' : '+ '}${txn.formattedAmount}',
              style: TextStyle(
                color: amountColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // SCREEN: DEDICATED PROFILE & ACCOUNT PAGE
  // ==========================================
  Widget _buildProfileScreen(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final email = user?.email ?? 'Member';
    final fullName = user?.userMetadata?['full_name'] as String? ?? 'Setthi Member';
    final hasActiveConsent = ref.watch(hasActiveConsentProvider);
    final activeConsentId = ref.watch(activeConsentIdProvider);
    final balance = ref.watch(latestBalanceProvider);
    final aiCredits = ref.watch(aiCreditsProvider);

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Profile Identity Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: DpcDecorations.cardBase(radius: 24),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: const BoxDecoration(
                    gradient: DpcColors.heroPastel2,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      email.isNotEmpty ? email[0].toUpperCase() : 'S',
                      style: const TextStyle(
                        color: DpcColors.textContrast,
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fullName,
                        style: const TextStyle(
                          color: DpcColors.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        email,
                        style: const TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceTrack,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: DpcColors.surfaceBorder, width: 1),
                        ),
                        child: const Text(
                          'Verified Member',
                          style: TextStyle(
                            color: DpcColors.accentPositive,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 2. Setthi Financial Intelligence Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: DpcDecorations.cardBase(radius: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(
                          Icons.auto_awesome_rounded,
                          color: DpcColors.textPrimary,
                          size: 18,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Financial Intelligence',
                          style: TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: DpcColors.surfaceTrack,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      child: const Text(
                        'ACTIVE ENGINE',
                        style: TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Automated telemetry, habit detection, and conversational financial assistance synchronized with your bank feeds.',
                  style: TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    RichText(
                      text: TextSpan(
                        children: [
                          TextSpan(
                            text: '$aiCredits ',
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          TextSpan(
                            text: aiCredits == 1 ? 'credit remaining' : 'credits remaining',
                            style: const TextStyle(
                              color: DpcColors.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    InkWell(
                      onTap: () => SetthiAiSheet.show(context),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceTrack,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Ask Setthi',
                              style: TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(width: 4),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 13,
                              color: DpcColors.textSecondary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 3. Bank Connection & Account Aggregator Card
          Container(
            padding: const EdgeInsets.all(18),
            decoration: DpcDecorations.cardBase(radius: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Banking & Setu AA',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: hasActiveConsent
                            ? DpcColors.accentPositive.withValues(alpha: 0.12)
                            : DpcColors.accentLevel.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        hasActiveConsent ? 'Active' : 'Unlinked',
                        style: TextStyle(
                          color: hasActiveConsent
                              ? DpcColors.accentPositive
                              : DpcColors.accentLevel,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  hasActiveConsent
                      ? 'Connected via RBI-regulated Setu Account Aggregator. Live balance: ${BankTransaction.formatRupees(balance)}'
                      : 'Link your bank account using Setu Account Aggregator to automatically track UPI spending.',
                  style: const TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
                if (activeConsentId != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Consent ID: $activeConsentId',
                    style: const TextStyle(
                      color: DpcColors.textMuted,
                      fontSize: 10,
                      fontFamily: 'Courier',
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _showLinkBankBottomSheet(context, ref),
                    icon: Icon(
                      hasActiveConsent ? Icons.sync_rounded : Icons.link_rounded,
                      size: 16,
                      color: DpcColors.textContrast,
                    ),
                    label: Text(
                      hasActiveConsent ? 'Manage Bank Consent' : 'Connect Bank Account',
                      style: const TextStyle(
                        color: DpcColors.textContrast,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DpcColors.accentPositive,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // 4. Account Actions (Sign Out & Delete Account)
          const Text(
            'ACCOUNT ACTIONS',
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 12),

          // Sign Out Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              onPressed: () async {
                ref.read(authBypassProvider.notifier).reset();
                await ref.read(authServiceProvider).signOut();
              },
              icon: const Icon(
                Icons.logout_rounded,
                color: DpcColors.textPrimary,
                size: 18,
              ),
              label: const Text(
                'Sign Out',
                style: TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: DpcColors.surfaceDark,
                side: const BorderSide(
                  color: DpcColors.surfaceBorder,
                  width: 1,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Delete Account Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton.icon(
              key: const Key('delete_account_button'),
              onPressed: () => _showDeleteAccountConfirmationModal(context, ref),
              icon: const Icon(
                Icons.delete_forever_rounded,
                color: DpcColors.accentNegative,
                size: 18,
              ),
              label: const Text(
                'Delete Account',
                style: TextStyle(
                  color: DpcColors.accentNegative,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: OutlinedButton.styleFrom(
                backgroundColor: DpcColors.accentNegative.withValues(alpha: 0.06),
                side: BorderSide(
                  color: DpcColors.accentNegative.withValues(alpha: 0.4),
                  width: 1,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Displays the confirmation bottom sheet for irreversible account and data deletion
  void _showDeleteAccountConfirmationModal(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        bool isDeleting = false;

        return StatefulBuilder(
          builder: (modalContext, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: DpcColors.surfaceDark,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                border: Border(
                  top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
                  left: BorderSide(color: DpcColors.surfaceBorder, width: 1),
                  right: BorderSide(color: DpcColors.surfaceBorder, width: 1),
                ),
              ),
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 14,
                bottom: MediaQuery.of(modalContext).padding.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Drag handle
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: DpcColors.surfaceTrack,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  // Warning Icon + Title
                  Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: DpcColors.accentNegative.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DpcColors.accentNegative.withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        child: const Icon(
                          Icons.warning_amber_rounded,
                          color: DpcColors.accentNegative,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Delete Account & Data',
                              style: TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.3,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'PERMANENT & IRREVERSIBLE ACTION',
                              style: TextStyle(
                                color: DpcColors.accentNegative,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  // Explanation box
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: DpcColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: DpcColors.surfaceBorder),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'The following data will be permanently purged from our servers:',
                          style: TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildPurgeBullet('All synced bank transactions and balance logs'),
                        _buildPurgeBullet('All Setu Account Aggregator consents and links'),
                        _buildPurgeBullet('Custom merchant categorizations and rules'),
                        _buildPurgeBullet('Setthi AI chat logs, prompt history, and nudges'),
                        _buildPurgeBullet('User profile credentials and active sessions'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Actions
                  if (isDeleting)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: CircularProgressIndicator(
                          valueColor: AlwaysStoppedAnimation<Color>(DpcColors.accentNegative),
                        ),
                      ),
                    )
                  else ...[
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        key: const Key('confirm_delete_account_button'),
                        onPressed: () async {
                          setModalState(() => isDeleting = true);
                          try {
                            final success = await ref.read(authServiceProvider).deleteAccount();
                            if (success && context.mounted) {
                              Navigator.of(modalContext).pop();
                              ref.read(authBypassProvider.notifier).reset();
                              ref.invalidate(transactionFeedProvider);
                              ref.invalidate(telemetryMetricsProvider);
                              ref.invalidate(hasActiveConsentProvider);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: DpcColors.surfaceDark,
                                  behavior: SnackBarBehavior.floating,
                                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  content: const Row(
                                    children: [
                                      Icon(Icons.check_circle_rounded, color: DpcColors.accentPositive, size: 18),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Account and associated data deleted permanently.',
                                          style: TextStyle(color: DpcColors.textPrimary, fontSize: 13),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            setModalState(() => isDeleting = false);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: DpcColors.surfaceDark,
                                  content: Text('Failed to delete account: $e', style: const TextStyle(color: DpcColors.accentNegative)),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.delete_forever_rounded, size: 18),
                        label: const Text(
                          'Permanently Delete Account',
                          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: DpcColors.accentNegative,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.of(modalContext).pop(),
                        child: const Text(
                          'Cancel, Keep My Account',
                          style: TextStyle(
                            color: DpcColors.textSecondary,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  static Widget _buildPurgeBullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Icon(Icons.circle, size: 5, color: DpcColors.accentNegative),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================
  // SCREEN B: TELEMETRY & ANALYTICS DASHBOARD
  // ==========================================
  Widget _buildTelemetryScreen(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
  ) {
    final weeklyStats = ref.watch(weeklyStatsProvider);
    final balance = ref.watch(latestBalanceProvider);
    final telemetryAsync = ref.watch(telemetryMetricsProvider);
    final telemetryData = telemetryAsync.value;

    // Live Aggregated Metrics from get_telemetry_metrics RPC
    final totalSpent = ((telemetryData?['total_spent'] ?? weeklyStats.spent) as num).toDouble();
    final totalInflow = ((telemetryData?['total_inflow'] ?? weeklyStats.inflow) as num).toDouble();
    final savingsRatio = ((telemetryData?['savings_ratio'] ??
            (totalInflow > 0
                ? ((totalInflow - totalSpent) / totalInflow).clamp(0.0, 1.0)
                : 0.0)) as num)
        .toDouble();
    final discretionaryRatio =
        ((telemetryData?['discretionary_ratio'] ?? 0.0) as num).toDouble();
    final dailyVelocity = ((telemetryData?['daily_velocity'] ??
            (totalSpent > 0 ? (totalSpent / 7).roundToDouble() : 0.0)) as num)
        .toDouble();
    final healthScore =
        ((telemetryData?['financial_health_score'] ?? 50) as num).toInt();

    final filterOptions = [
      'All Time',
      'This Month',
      'Last 7 Days',
      'Debits',
      'Inflow',
    ];

    // Channel Volume Distribution from live DB
    final rawChannels = telemetryData?['channel_distribution'];
    final List<dynamic> channelList = rawChannels is List ? rawChannels : [];
    final List<DpcLiquidVolumeItem> channelItems = [];
    if (channelList.isNotEmpty) {
      final colors = [
        DpcColors.accentPrimary,
        DpcColors.accentLevel,
        DpcColors.accentPositive,
        const Color(0xFFC084FC),
      ];
      for (var i = 0; i < channelList.length && i < 3; i++) {
        final item = channelList[i] as Map<String, dynamic>;
        final mode = item['mode']?.toString() ?? 'Other';
        final pct = ((item['percentage'] ?? 0) as num).toDouble();
        final rawAmt = item['amount'];
        final amt = rawAmt != null ? ((rawAmt as num).toDouble()) : 0.0;
        final amountText = amt > 0 ? BankTransaction.formatRupees(amt) : '${pct.round()}%';
        channelItems.add(DpcLiquidVolumeItem(
          label: mode == 'FT' ? 'Bank FT' : (mode == 'OTHERS' ? 'Other' : mode),
          amount: amountText,
          fraction: (pct / 100.0).clamp(0.0, 1.0),
          color: colors[i % colors.length],
        ));
      }
    }
    if (channelItems.isEmpty) {
      channelItems.addAll([
        DpcLiquidVolumeItem(
          label: 'UPI Transfers',
          amount: '0%',
          fraction: 0.0,
          color: DpcColors.accentPrimary,
        ),
        DpcLiquidVolumeItem(
          label: 'ATM / Cash',
          amount: '0%',
          fraction: 0.0,
          color: DpcColors.accentLevel,
        ),
        DpcLiquidVolumeItem(
          label: 'NetBanking / FT',
          amount: '0%',
          fraction: 0.0,
          color: DpcColors.accentPositive,
        ),
      ]);
    }

    // Weekly Outflow Velocity from live DB
    final rawWeekly = telemetryData?['weekly_outflow_velocity'];
    final List<dynamic> weeklyList = rawWeekly is List ? rawWeekly : [];
    final List<DpcPhaseGaugeItem> weeklyItems = [];
    if (weeklyList.isNotEmpty) {
      double maxWeekly = 1.0;
      for (final w in weeklyList) {
        if (w is Map) {
          final amt = ((w['amount'] ?? 0.0) as num).toDouble();
          if (amt > maxWeekly) maxWeekly = amt;
        }
      }
      final colors = [
        DpcColors.accentPositive,
        DpcColors.accentPrimary,
        DpcColors.accentLevel,
        DpcColors.accentPositive,
      ];
      for (var i = 0; i < weeklyList.length; i++) {
        final w = weeklyList[i] as Map<String, dynamic>;
        final label = w['label']?.toString() ?? 'Week ${i + 1}';
        final amt = ((w['amount'] ?? 0.0) as num).toDouble();
        final prog = amt > 0 ? (amt / maxWeekly).clamp(0.05, 1.0) : 0.0;
        weeklyItems.add(DpcPhaseGaugeItem(
          stage: label,
          progress: prog,
          metric: BankTransaction.formatRupees(amt),
          color: colors[i % colors.length],
        ));
      }
    }
    if (weeklyItems.isEmpty) {
      weeklyItems.addAll([
        const DpcPhaseGaugeItem(
          stage: 'Week 1',
          progress: 0.0,
          metric: '₹0',
          color: DpcColors.accentPositive,
        ),
        const DpcPhaseGaugeItem(
          stage: 'Week 2',
          progress: 0.0,
          metric: '₹0',
          color: DpcColors.accentPrimary,
        ),
        const DpcPhaseGaugeItem(
          stage: 'Week 3',
          progress: 0.0,
          metric: '₹0',
          color: DpcColors.accentLevel,
        ),
        const DpcPhaseGaugeItem(
          stage: 'Week 4',
          progress: 0.0,
          metric: '₹0',
          color: DpcColors.accentPositive,
        ),
      ]);
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Screen Title
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TELEMETRY & ANALYTICS',
                    style: DpcTypography.badgeTag,
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Cash Flow Telemetry',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: DpcDecorations.cardBase(radius: 20),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.insights_rounded,
                      size: 14,
                      color: DpcColors.accentPositive,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      telemetryAsync.isLoading ? 'Calculating...' : 'Live Metrics',
                      style: const TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 1. Segmented Filter Bar wired to period index provider
          DpcSegmentedFilterBar(
            filters: filterOptions,
            selectedIndex: _telemetryFilterIndex,
            onSelect: (index) {
              setState(() => _telemetryFilterIndex = index);
              ref.read(telemetryPeriodIndexProvider.notifier).state = index;
            },
          ),
          const SizedBox(height: 20),

          // 2. 2x2 Telemetry Grid Cards
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DpcTelemetryCard(
                    data: DpcTelemetryMetricData(
                      title: 'Savings Retention',
                      icon: Icons.savings_rounded,
                      valueText: '${(savingsRatio * 100).round()}%',
                      fraction: savingsRatio.clamp(0.0, 1.0),
                      traitTag: savingsRatio > 0.4
                          ? 'High Savings'
                          : (savingsRatio > 0 ? 'Normal' : 'No Inflow'),
                      accentColor: savingsRatio > 0
                          ? DpcColors.accentPositive
                          : DpcColors.textMuted,
                      definition:
                          'How much of the money that came in you actually kept. For example, 40% means for every ₹100 received, you kept ₹40 as savings.',
                      formula: '(Total Inflow - Total Outflow) / Total Inflow',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DpcTelemetryCard(
                    data: DpcTelemetryMetricData(
                      title: 'Discretionary Ratio',
                      icon: Icons.pie_chart_outline_rounded,
                      valueText: '${(discretionaryRatio * 100).round()}%',
                      fraction: discretionaryRatio.clamp(0.0, 1.0),
                      traitTag: discretionaryRatio > 0.4
                          ? 'High Impulse'
                          : 'Disciplined',
                      accentColor: discretionaryRatio > 0.4
                          ? DpcColors.accentNegative
                          : DpcColors.accentPrimary,
                      definition:
                          'The share of your spending that went to "wants" (food delivery, shopping, outings) instead of "needs" (bills, rent, groceries).',
                      formula: 'Discretionary Outflow / Total Outflow',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: DpcTelemetryCard(
                    data: DpcTelemetryMetricData(
                      title: 'Daily Velocity',
                      icon: Icons.speed_rounded,
                      valueText: BankTransaction.formatRupees(dailyVelocity),
                      fraction: (dailyVelocity / 2000.0).clamp(0.05, 1.0),
                      traitTag: dailyVelocity > 1500 ? 'High Burn' : 'Balanced',
                      accentColor: DpcColors.accentLevel,
                      definition:
                          'How fast you spend money each day on average. It shows your daily cash burn rate so you can pace yourself.',
                      formula: 'Total Outflows / Active Days',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DpcTelemetryCard(
                    data: DpcTelemetryMetricData(
                      title: 'Financial Health',
                      icon: Icons.health_and_safety_rounded,
                      valueText: '$healthScore%',
                      fraction: (healthScore / 100.0).clamp(0.0, 1.0),
                      traitTag: healthScore >= 80
                          ? 'Budget Pro'
                          : (healthScore >= 50 ? 'Stable' : 'Needs Care'),
                      accentColor: healthScore >= 70
                          ? DpcColors.accentPositive
                          : (healthScore >= 50
                              ? DpcColors.accentLevel
                              : DpcColors.accentNegative),
                      definition:
                          'Your overall money fitness score from 0 to 100. It checks if you are saving enough, keeping impulse spending low, and holding a safe balance.',
                      formula:
                          'Weighted composite (Savings Rate + Spend Discipline + Balance Runway)',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          // 3. Split Telemetry Card:
          // Left: Circular radial gauge (Savings / Retention)
          // Right: Key-value metrics
          DpcSplitTelemetryCard(
            title: 'Cash Flow Distribution',
            gaugeProgress: savingsRatio.clamp(0.0, 1.0),
            gaugeLabel: 'Retention',
            gaugeColor: savingsRatio > 0 ? DpcColors.accentPositive : DpcColors.textMuted,
            keyValues: [
              (
                label: 'Total Inflow',
                value: BankTransaction.formatRupees(totalInflow),
                color: DpcColors.accentPositive,
              ),
              (
                label: 'Total Outflows',
                value: BankTransaction.formatRupees(totalSpent),
                color: DpcColors.accentNegative,
              ),
              (
                label: 'Current Balance',
                value: BankTransaction.formatRupees(balance),
                color: DpcColors.textPrimary,
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 4. Liquid Volume Cards (3-Column Channel Breakdown)
          const Text(
            'CHANNEL VOLUME DISTRIBUTION',
            style: DpcTypography.badgeTag,
          ),
          const SizedBox(height: 10),
          DpcLiquidVolumeRow(
            items: channelItems,
          ),
          const SizedBox(height: 20),

          // 5. Phase-Based Multi-Gauge Cards (Weekly velocity breakdown)
          const Text('WEEKLY OUTFLOW VELOCITY', style: DpcTypography.badgeTag),
          const SizedBox(height: 10),
          DpcPhaseMultiGaugeRow(
            items: weeklyItems,
          ),
        ],
      ),
    );
  }

  // ==========================================
  // EMPTY, LOADING & ERROR STATES
  // ==========================================
  Widget _buildEmptyState(
    BuildContext context,
    WidgetRef ref,
    bool hasActiveConsent,
    bool isSyncing,
  ) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              color: DpcColors.surfaceDark,
              shape: BoxShape.circle,
              border: Border.all(
                color: hasActiveConsent
                    ? DpcColors.accentPositive.withValues(alpha: 0.35)
                    : DpcColors.surfaceBorder,
                width: 1,
              ),
            ),
            child: Icon(
              hasActiveConsent
                  ? Icons.account_balance_rounded
                  : Icons.account_balance_outlined,
              size: 44,
              color: hasActiveConsent
                  ? DpcColors.accentPositive
                  : DpcColors.textSecondary,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            hasActiveConsent
                ? 'Bank Connected Successfully'
                : 'No Bank Account Linked',
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasActiveConsent
                ? 'Your Account Aggregator consent is active. Slide below to authorize Setthi to fetch and display your transactions.'
                : 'Connect your bank account via Setu Account Aggregator to view real-time transactions and balance.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          if (!hasActiveConsent) ...[
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _showLinkBankBottomSheet(context, ref),
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.accentPositive,
                foregroundColor: DpcColors.textContrast,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
              ),
              icon: const Icon(Icons.link_rounded),
              label: const Text(
                'Link Bank Account',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ] else ...[
            const SizedBox(height: 24),
            DpcSlideToConfirm(
              label: 'Slide to Fetch Transactions  ››',
              completedLabel: 'Authorizing & Fetching Data...',
              onConfirmed: () async {
                await ref
                    .read(transactionFeedProvider.notifier)
                    .syncTransactions();
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSkeletonLoader() {
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(height: 100, decoration: DpcDecorations.cardBase(radius: 20)),
        const SizedBox(height: 16),
        Container(height: 210, decoration: DpcDecorations.cardBase(radius: 28)),
        const SizedBox(height: 16),
        Container(height: 60, decoration: DpcDecorations.cardBase(radius: 16)),
      ],
    );
  }

  Widget _buildErrorState(BuildContext context, WidgetRef ref, String error) {
    final lower = error.toLowerCase();
    final isConsentIssue =
        lower.contains('consent use exceeded') ||
        lower.contains('consent expired') ||
        lower.contains('consent not active') ||
        lower.contains('consent revoked') ||
        lower.contains('no active account aggregator consent') ||
        lower.contains('fidata') ||
        lower.contains('datarange');

    final isNetworkIssue =
        lower.contains('socketexception') ||
        lower.contains('timed out') ||
        lower.contains('clientexception') ||
        lower.contains('connection');

    final String title;
    final String message;
    if (isConsentIssue) {
      title = 'Bank Session Expired';
      message =
          'Your previous bank connection session has completed or expired. Reconnect your bank account via Setu Account Aggregator to continue.';
    } else if (isNetworkIssue) {
      title = 'Connection Timeout';
      message =
          'Unable to reach the banking gateway. Please check your internet connection and try again.';
    } else {
      title = 'Unable to Sync Transactions';
      message =
          'A temporary error occurred while retrieving your bank transactions. You can retry or reconnect your bank account.';
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: DpcDecorations.cardBase(radius: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color:
                      (isConsentIssue
                              ? DpcColors.accentLevel
                              : DpcColors.accentNegative)
                          .withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        (isConsentIssue
                                ? DpcColors.accentLevel
                                : DpcColors.accentNegative)
                            .withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Icon(
                  isConsentIssue
                      ? Icons.account_balance_outlined
                      : isNetworkIssue
                      ? Icons.wifi_off_rounded
                      : Icons.sync_problem_rounded,
                  color: isConsentIssue
                      ? DpcColors.accentLevel
                      : DpcColors.accentNegative,
                  size: 26,
                ),
              ),
              const SizedBox(height: 18),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),
              // Action Buttons
              if (isConsentIssue) ...[
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      ActiveConsentIdNotifier.deletePersistedConsent();
                      ref.read(activeConsentIdProvider.notifier).clear();
                      _showLinkBankBottomSheet(context, ref);
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DpcColors.accentPositive,
                      foregroundColor: DpcColors.textContrast,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    icon: const Icon(Icons.add_link_rounded, size: 18),
                    label: const Text(
                      'Connect Bank Account',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: OutlinedButton(
                    onPressed: () {
                      ActiveConsentIdNotifier.deletePersistedConsent();
                      ref.read(activeConsentIdProvider.notifier).clear();
                      ref
                          .read(transactionFeedProvider.notifier)
                          .syncTransactions();
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DpcColors.textSecondary,
                      side: const BorderSide(color: DpcColors.surfaceBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Clear Stale Session',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ] else ...[
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: () => ref
                        .read(transactionFeedProvider.notifier)
                        .syncTransactions(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DpcColors.surfaceTrack,
                      foregroundColor: DpcColors.textPrimary,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                        side: const BorderSide(color: DpcColors.surfaceBorder),
                      ),
                    ),
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: const Text(
                      'Try Again',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  height: 42,
                  child: OutlinedButton(
                    onPressed: () => _showLinkBankBottomSheet(context, ref),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DpcColors.textSecondary,
                      side: const BorderSide(color: DpcColors.surfaceBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text(
                      'Link Different Bank',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ==========================================
  // BOTTOM SHEETS & MODALS (DPC OLED STYLED)
  // ==========================================
  Future<void> _handleSyncAction(BuildContext context, WidgetRef ref) async {
    var hasActiveConsent = ref.read(hasActiveConsentProvider);
    if (!hasActiveConsent) {
      try {
        final dbService = ref.read(supabaseDbServiceProvider);
        final activeConsent = await dbService.fetchActiveConsent();
        if (activeConsent != null && activeConsent['consent_id'] != null) {
          final cid = activeConsent['consent_id'] as String;
          ref.read(activeConsentIdProvider.notifier).setConsentId(cid);
          hasActiveConsent = true;
        }
      } catch (_) {}
    }

    if (!hasActiveConsent) {
      final pendingConsentId = ref.read(pendingConsentIdProvider);
      if (pendingConsentId != null && pendingConsentId.isNotEmpty) {
        final success = await ref
            .read(transactionFeedProvider.notifier)
            .checkAndSyncConsent(pendingConsentId);
        if (success && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: DpcColors.surfaceDark,
              content: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: DpcColors.accentPositive,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Bank linked & transactions synced!',
                    style: TextStyle(color: DpcColors.textPrimary),
                  ),
                ],
              ),
            ),
          );
          return;
        }
      }
      if (context.mounted) {
        await _showLinkBankBottomSheet(context, ref);
      }
    } else {
      await ref.read(transactionFeedProvider.notifier).syncTransactions();
    }
  }

  /// DPC Styled Link Bank Bottom Sheet
  Future<void> _showLinkBankBottomSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final phoneController = TextEditingController();
    bool isCreatingConsent = false;
    String? errorMessage;

    final consentInfo = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DpcColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (sheetContext, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 16,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: DpcColors.surfaceTrack,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: DpcColors.accentPositive.withValues(
                            alpha: 0.15,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DpcColors.accentPositive.withValues(
                              alpha: 0.3,
                            ),
                          ),
                        ),
                        child: const Icon(
                          Icons.account_balance_rounded,
                          color: DpcColors.accentPositive,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Link Bank via Account Aggregator',
                              style: TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2),
                            Text(
                              'Setu AA ReBIT Gateway (RBI Regulated)',
                              style: TextStyle(
                                color: DpcColors.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'MOBILE NUMBER LINKED TO BANK',
                    style: TextStyle(
                      color: DpcColors.textMuted,
                      fontSize: 10,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: 'e.g. 1234567890',
                      hintStyle: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 14,
                      ),
                      prefixIcon: const Icon(
                        Icons.phone_iphone_rounded,
                        color: DpcColors.textMuted,
                        size: 18,
                      ),
                      filled: true,
                      fillColor: DpcColors.bgOled,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                          color: DpcColors.accentPositive,
                          width: 1.5,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Setu AA will send a secure verification OTP to this mobile number.',
                    style: TextStyle(color: DpcColors.textMuted, fontSize: 11),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      errorMessage!,
                      style: const TextStyle(
                        color: DpcColors.accentNegative,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: isCreatingConsent
                          ? null
                          : () async {
                              final user = ref.read(currentUserProvider);
                              if (user == null && SupabaseConfig.isConfigured) {
                                if (modalContext.mounted) {
                                  Navigator.of(modalContext).pop();
                                }
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Please sign in to your account first so your bank data is securely linked.',
                                    ),
                                    backgroundColor: DpcColors.accentNegative,
                                  ),
                                );
                                ref.read(authBypassProvider.notifier).reset();
                                return;
                              }

                              final mobile = phoneController.text.trim();
                              if (mobile.length < 10) {
                                setModalState(() {
                                  errorMessage =
                                      'Please enter a valid 10-digit mobile number';
                                });
                                return;
                              }
                              setModalState(() {
                                isCreatingConsent = true;
                                errorMessage = null;
                              });

                              try {
                                final aaService = ref.read(
                                  setuAaServiceProvider,
                                );
                                final result = await aaService.createConsent(
                                  mobileNumber: mobile,
                                );
                                final consentId = result['consentId'] as String;
                                final consentUrl = result['url'] as String;

                                ref
                                    .read(pendingConsentIdProvider.notifier)
                                    .set(consentId);

                                try {
                                  await ref
                                      .read(supabaseDbServiceProvider)
                                      .recordConsent(
                                        consentId: consentId,
                                        status: 'PENDING',
                                        vua: '$mobile@onemoney',
                                      );
                                } catch (_) {}

                                if (modalContext.mounted) {
                                  Navigator.of(modalContext).pop({
                                    'consentId': consentId,
                                    'consentUrl': consentUrl,
                                  });
                                }
                              } catch (e) {
                                setModalState(() {
                                  isCreatingConsent = false;
                                  errorMessage = 'Error: $e';
                                });
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DpcColors.accentPositive,
                        foregroundColor: DpcColors.textContrast,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: isCreatingConsent
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: DpcColors.textContrast,
                              ),
                            )
                          : const Text(
                              'Initiate Setu AA Verification',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (consentInfo == null || !context.mounted) return;

    final consentId = consentInfo['consentId'] as String;
    final consentUrl = consentInfo['consentUrl'] as String;
    final aaService = ref.read(setuAaServiceProvider);

    final approved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SetuConsentWebView(
          consentUrl: consentUrl,
          consentId: consentId,
          aaService: aaService,
        ),
      ),
    );

    bool isApproved = approved == true;
    if (!isApproved) {
      try {
        final status = await aaService.checkConsentStatus(consentId);
        if (status == 'ACTIVE') {
          isApproved = true;
        }
      } catch (_) {}
    }

    if (isApproved && context.mounted) {
      ref.read(activeConsentIdProvider.notifier).setConsentId(consentId);
      ref.read(pendingConsentIdProvider.notifier).clear();
      try {
        await ref
            .read(supabaseDbServiceProvider)
            .recordConsent(consentId: consentId, status: 'ACTIVE');
      } catch (_) {}

      if (context.mounted) {
        // Display the sliding permission sheet to authorize data sync
        await BankSyncPermissionSheet.show(
          context: context,
          consentId: consentId,
          onSyncRequested: () async {
            await ref
                .read(transactionFeedProvider.notifier)
                .setConsentAndSync(consentId);
          },
        );
      }
    }
  }

  /// DPC Styled Transaction Details Modal
  void _showTransactionDetailsModal(BuildContext context, BankTransaction txn) {
    showModalBottomSheet(
      context: context,
      backgroundColor: DpcColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DpcColors.surfaceTrack,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color:
                            (txn.isDebit
                                    ? DpcColors.accentPrimary
                                    : DpcColors.accentPositive)
                                .withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        txn.icon,
                        color: txn.isDebit
                            ? DpcColors.accentPrimary
                            : DpcColors.accentPositive,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            txn.cleanMerchantName,
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            txn.isDebit ? 'Debit / Outflow' : 'Credit / Inflow',
                            style: const TextStyle(
                              color: DpcColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${txn.isDebit ? "- " : "+ "}${txn.formattedAmount}',
                      style: TextStyle(
                        color: txn.isDebit
                            ? DpcColors.accentNegative
                            : DpcColors.accentPositive,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _buildCategoryDetailRow(context, txn),
                if (txn.category == null || txn.category!.isEmpty)
                  _buildQuickCategoryRow(context, txn),
                _buildDetailRow('Mode', txn.mode),
                _buildDetailRow('Timestamp', txn.formattedDate),
                _buildDetailRow('Balance After', txn.formattedBalance),
                _buildDetailRow('Txn ID', txn.txnId),
                _buildDetailRow('Narration', txn.narration),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: txn.txnId));
                      Navigator.of(context).pop();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          backgroundColor: DpcColors.surfaceDark,
                          content: Text(
                            'Transaction ID copied to clipboard!',
                            style: TextStyle(color: DpcColors.textPrimary),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy Transaction ID'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DpcColors.textPrimary,
                      side: const BorderSide(color: DpcColors.surfaceBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(label, style: DpcTypography.componentLabel),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Interactive Category row inside Transaction Details modal
  Widget _buildCategoryDetailRow(BuildContext context, BankTransaction txn) {
    final hasCategory = txn.category != null && txn.category!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(
            width: 90,
            child: Text('Category', style: DpcTypography.componentLabel),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  _showCategoryPickerModal(context, txn);
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: hasCategory
                        ? txn.accentColor.withValues(alpha: 0.12)
                        : DpcColors.surfaceTrack,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: hasCategory
                          ? txn.accentColor.withValues(alpha: 0.35)
                          : DpcColors.accentLevel.withValues(alpha: 0.35),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasCategory) ...[
                        Text(
                          txn.category!,
                          style: TextStyle(
                            color: txn.accentColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.edit_outlined,
                          size: 13,
                          color: txn.accentColor,
                        ),
                      ] else ...[
                        const Icon(
                          Icons.add_circle_outline_rounded,
                          size: 14,
                          color: DpcColors.accentLevel,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Add Category',
                          style: TextStyle(
                            color: DpcColors.accentLevel,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Horizontal strip of 1-tap quick category presets when uncategorized
  Widget _buildQuickCategoryRow(BuildContext context, BankTransaction txn) {
    const quickPresets = [
      ('Food & Dining', '🍔', Color(0xFFFC8019)),
      ('Groceries', '🛒', Color(0xFF10B981)),
      ('Shopping', '🛍️', Color(0xFFA78BFA)),
      ('Transport', '🚗', Color(0xFF00C8FF)),
      ('Bills & Utilities', '⚡', Color(0xFFFBBF24)),
    ];

    return Padding(
      padding: const EdgeInsets.only(left: 90, bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: quickPresets.map((preset) {
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: InkWell(
                onTap: () {
                  ref
                      .read(transactionFeedProvider.notifier)
                      .updateTransactionCategory(
                        txnId: txn.txnId,
                        category: preset.$1,
                        applyToAllFromMerchant: false,
                        cleanMerchantName: txn.cleanMerchantName,
                      );
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: DpcColors.surfaceDark,
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      content: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_rounded,
                            color: DpcColors.accentPositive,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Categorized "${txn.cleanMerchantName}" as "${preset.$1}"',
                              style: const TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: preset.$3.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: preset.$3.withValues(alpha: 0.25),
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(preset.$2, style: const TextStyle(fontSize: 11)),
                      const SizedBox(width: 4),
                      Text(
                        preset.$1,
                        style: TextStyle(
                          color: preset.$3,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Opens the full Smart Category Picker modal
  void _showCategoryPickerModal(BuildContext context, BankTransaction txn) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (bottomSheetContext) {
        return _CategoryPickerSheet(
          txn: txn,
          onCategorySelected: (category) {
            ref
                .read(transactionFeedProvider.notifier)
                .updateTransactionCategory(
                  txnId: txn.txnId,
                  category: category,
                  applyToAllFromMerchant: false,
                  cleanMerchantName: txn.cleanMerchantName,
                );

            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: DpcColors.surfaceDark,
                behavior: SnackBarBehavior.floating,
                margin: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                content: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_rounded,
                      color: DpcColors.accentPositive,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Categorized as "$category"',
                        style: const TextStyle(
                          color: DpcColors.textPrimary,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }


}

class _CategoryPreset {
  final String name;
  final IconData icon;
  final Color color;

  const _CategoryPreset({
    required this.name,
    required this.icon,
    required this.color,
  });
}

class _CategoryPickerSheet extends StatefulWidget {
  final BankTransaction txn;
  final void Function(String category) onCategorySelected;

  const _CategoryPickerSheet({
    required this.txn,
    required this.onCategorySelected,
  });

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  late final TextEditingController _searchController;
  String _searchQuery = '';

  static const List<_CategoryPreset> _presets = [
    _CategoryPreset(
      name: 'Food & Dining',
      icon: Icons.restaurant_rounded,
      color: Color(0xFFFC8019),
    ),
    _CategoryPreset(
      name: 'Groceries',
      icon: Icons.shopping_cart_rounded,
      color: Color(0xFF10B981),
    ),
    _CategoryPreset(
      name: 'Shopping',
      icon: Icons.shopping_bag_rounded,
      color: Color(0xFFA78BFA),
    ),
    _CategoryPreset(
      name: 'Transport & Travel',
      icon: Icons.directions_car_rounded,
      color: Color(0xFF00C8FF),
    ),
    _CategoryPreset(
      name: 'Cafe & Coffee',
      icon: Icons.local_cafe_rounded,
      color: Color(0xFFD38D5F),
    ),
    _CategoryPreset(
      name: 'Entertainment',
      icon: Icons.movie_rounded,
      color: Color(0xFFFF2D55),
    ),
    _CategoryPreset(
      name: 'Bills & Utilities',
      icon: Icons.bolt_rounded,
      color: Color(0xFFFBBF24),
    ),
    _CategoryPreset(
      name: 'Health & Fitness',
      icon: Icons.fitness_center_rounded,
      color: Color(0xFF30B0C7),
    ),
    _CategoryPreset(
      name: 'Subscriptions & Tech',
      icon: Icons.devices_rounded,
      color: Color(0xFF5856D6),
    ),
    _CategoryPreset(
      name: 'Salary & Income',
      icon: Icons.account_balance_wallet_rounded,
      color: Color(0xFF34D399),
    ),
    _CategoryPreset(
      name: 'Transfers & UPI',
      icon: Icons.swap_horiz_rounded,
      color: Color(0xFF38BDF8),
    ),
    _CategoryPreset(
      name: 'Personal Care',
      icon: Icons.spa_rounded,
      color: Color(0xFFFF6482),
    ),
    _CategoryPreset(
      name: 'Education',
      icon: Icons.school_rounded,
      color: Color(0xFFFF9F0A),
    ),
    _CategoryPreset(
      name: 'Investments',
      icon: Icons.trending_up_rounded,
      color: Color(0xFF32D74B),
    ),
    _CategoryPreset(
      name: 'General / Other',
      icon: Icons.label_outline_rounded,
      color: Color(0xFF8E8E93),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _selectCategory(String category) {
    HapticFeedback.lightImpact();
    widget.onCategorySelected(category);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final query = _searchQuery.trim().toLowerCase();

    final filteredPresets = query.isEmpty
        ? _presets
        : _presets.where((p) => p.name.toLowerCase().contains(query)).toList();

    final exactMatch = _presets.any((p) => p.name.toLowerCase() == query);
    final showCustomOption = query.isNotEmpty && !exactMatch;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          left: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          right: BorderSide(color: DpcColors.surfaceBorder, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Grab handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 12),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceTrack,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: widget.txn.accentColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: widget.txn.accentColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Icon(
                        widget.txn.icon,
                        size: 20,
                        color: widget.txn.accentColor,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Categorize Transaction',
                            style: TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  widget.txn.cleanMerchantName,
                                  style: const TextStyle(
                                    color: DpcColors.textSecondary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1.5,
                                ),
                                decoration: BoxDecoration(
                                  color: (widget.txn.isCredit
                                          ? DpcColors.accentPositive
                                          : DpcColors.accentNegative)
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: (widget.txn.isCredit
                                            ? DpcColors.accentPositive
                                            : DpcColors.accentNegative)
                                        .withValues(alpha: 0.25),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      widget.txn.isCredit
                                          ? Icons.south_west_rounded
                                          : Icons.north_east_rounded,
                                      size: 10,
                                      color: widget.txn.isCredit
                                          ? DpcColors.accentPositive
                                          : DpcColors.accentNegative,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      widget.txn.isCredit
                                          ? '+ ${widget.txn.formattedAmount} Credited'
                                          : '- ${widget.txn.formattedAmount} Debited',
                                      style: TextStyle(
                                        color: widget.txn.isCredit
                                            ? DpcColors.accentPositive
                                            : DpcColors.accentNegative,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      color: DpcColors.textMuted,
                      onPressed: () => Navigator.of(context).pop(),
                      splashRadius: 20,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // Search & Custom category input
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: DpcColors.surfaceBorder,
                      width: 1,
                    ),
                  ),
                  child: TextField(
                    controller: _searchController,
                    onChanged: (val) {
                      setState(() => _searchQuery = val);
                    },
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 13,
                    ),
                    cursorColor: const Color(0xFFB8F5D8),
                    decoration: InputDecoration(
                      hintText: 'Search or type custom category...',
                      hintStyle: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 12.5,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: DpcColors.textMuted,
                        size: 18,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear_rounded, size: 16),
                              color: DpcColors.textMuted,
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Categories List / Grid
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  children: [
                    // Dynamic Custom Category creation pill if user typed custom text
                    if (showCustomOption) ...[
                      InkWell(
                        onTap: () => _selectCategory(_searchQuery.trim()),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB8F5D8).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0xFFB8F5D8).withValues(alpha: 0.4),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFB8F5D8)
                                      .withValues(alpha: 0.2),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add_rounded,
                                  size: 16,
                                  color: Color(0xFFB8F5D8),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    text: 'Add custom: ',
                                    style: const TextStyle(
                                      color: DpcColors.textSecondary,
                                      fontSize: 13,
                                    ),
                                    children: [
                                      TextSpan(
                                        text: '"${_searchQuery.trim()}"',
                                        style: const TextStyle(
                                          color: Color(0xFFB8F5D8),
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const Icon(
                                Icons.arrow_forward_ios_rounded,
                                size: 12,
                                color: Color(0xFFB8F5D8),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],

                    // Curated Presets Grid
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: filteredPresets.length,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                        childAspectRatio: 2.7,
                      ),
                      itemBuilder: (context, index) {
                        final preset = filteredPresets[index];
                        final isCurrent = widget.txn.category?.toLowerCase() ==
                            preset.name.toLowerCase();

                        return InkWell(
                          onTap: () => _selectCategory(preset.name),
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? preset.color.withValues(alpha: 0.12)
                                  : DpcColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isCurrent
                                    ? preset.color.withValues(alpha: 0.5)
                                    : DpcColors.surfaceBorder,
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: preset.color.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Icon(
                                    preset.icon,
                                    size: 15,
                                    color: preset.color,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    preset.name,
                                    style: TextStyle(
                                      color: isCurrent
                                          ? preset.color
                                          : DpcColors.textPrimary,
                                      fontSize: 11.5,
                                      fontWeight: isCurrent
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (isCurrent)
                                  Icon(
                                    Icons.check_rounded,
                                    size: 14,
                                    color: preset.color,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
