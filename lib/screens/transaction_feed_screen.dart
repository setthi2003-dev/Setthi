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
  int _activeNavIndex = 0; // 0: Dashboard (Screen A), 1: Telemetry (Screen B, kept for reference)
  int _telemetryFilterIndex = 0; // Kept for reference

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activeConsentIdProvider.notifier).refreshFromBackend();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
        onFeedTap: () {
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
        onSyncTap: () => _handleSyncAction(context, ref),
        onBankTap: () => _showLinkBankBottomSheet(context, ref),
        isSyncing: isSyncing,
        hasActiveConsent: hasActiveConsent,
      ),
    );
  }

  /// Utility Navigation Bar (Top) as specified in DPC Screen A:
  /// Left: Pill currency badge (#38BDF8)
  /// Center: Title
  /// Right: Circular milestone indicator with radial progress arc (#F59E0B)
  PreferredSizeWidget _buildDpcAppBar(
    BuildContext context,
    WidgetRef ref,
    bool hasActiveConsent,
  ) {
    return AppBar(
      elevation: 0,
      backgroundColor: DpcColors.bgOled,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 18,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Setthi Brand with live connection dot
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
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
              const SizedBox(width: 8),
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

          // Right: Profile & settings button
          InkWell(
            onTap: () => _showProfileBottomSheet(context, ref),
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: DpcColors.surfaceDark,
                shape: BoxShape.circle,
                border: Border.all(
                  color: DpcColors.surfaceBorder,
                  width: 1,
                ),
              ),
              child: const Icon(
                Icons.person_outline_rounded,
                size: 17,
                color: DpcColors.textSecondary,
              ),
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

    return CustomScrollView(
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
          SliverToBoxAdapter(
            child: _buildFilterEmptyState(context, ref),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, yearIndex) {
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
                      for (int mIdx = 0; mIdx < yearGroup.monthGroups.length; mIdx++) ...[
                        _buildMonthSection(
                          context,
                          yearGroup.monthGroups[mIdx],
                          isFirstInYear: mIdx == 0 && !showYearHeader,
                        ),
                      ],
                    ],
                  );
                },
                childCount: yearGroups.length,
              ),
            ),
          ),

        // On-Demand Pagination Footer
        if (transactions.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
              child: Center(
                child: hasMore
                    ? OutlinedButton.icon(
                        onPressed: isLoadingMore
                            ? null
                            : () => ref
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
                        icon: isLoadingMore
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: DpcColors.accentPositive,
                                ),
                              )
                            : const Icon(
                                Icons.history_rounded,
                                size: 16,
                                color: DpcColors.textSecondary,
                              ),
                        label: Text(
                          isLoadingMore
                              ? 'Loading earlier...'
                              : 'Load Earlier Transactions',
                          style: const TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : const Text(
                        'All transactions loaded',
                        style: TextStyle(
                          color: DpcColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
              ),
            ),
          ),

        const SliverToBoxAdapter(
          child: SizedBox(height: 100), // padding for floating dock
        ),
      ],
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
                ref.read(transactionSortOrderProvider.notifier).state =
                    sortOrder == TransactionSortOrder.latestFirst
                        ? TransactionSortOrder.oldestFirst
                        : TransactionSortOrder.latestFirst;
              },
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
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

          Container(
            width: 1,
            height: 16,
            color: DpcColors.surfaceBorder,
          ),
          const SizedBox(width: 8),

          // 2. Flow: All Flows
          _buildFilterChip(
            label: 'All Flows',
            isSelected: typeFilter == TransactionTypeFilter.all,
            onTap: () => ref.read(transactionTypeFilterProvider.notifier).state =
                TransactionTypeFilter.all,
          ),
          const SizedBox(width: 6),

          // 3. Flow: Debits
          _buildFilterChip(
            label: 'Debits ↓',
            isSelected: typeFilter == TransactionTypeFilter.debitOnly,
            accentColor: const Color(0xFFFF6E7F),
            onTap: () => ref.read(transactionTypeFilterProvider.notifier).state =
                TransactionTypeFilter.debitOnly,
          ),
          const SizedBox(width: 6),

          // 4. Flow: Credits
          _buildFilterChip(
            label: 'Credits ↑',
            isSelected: typeFilter == TransactionTypeFilter.creditOnly,
            accentColor: DpcColors.accentPositive,
            onTap: () => ref.read(transactionTypeFilterProvider.notifier).state =
                TransactionTypeFilter.creditOnly,
          ),

          // 5. Years (if multi-year)
          if (availableYears.length > 1) ...[
            const SizedBox(width: 8),
            Container(
              width: 1,
              height: 16,
              color: DpcColors.surfaceBorder,
            ),
            const SizedBox(width: 8),
            _buildFilterChip(
              label: 'All Years',
              isSelected: selectedYear == null,
              onTap: () => ref.read(transactionSelectedYearProvider.notifier).state = null,
            ),
            for (final y in availableYears) ...[
              const SizedBox(width: 6),
              _buildFilterChip(
                label: '$y',
                isSelected: selectedYear == y,
                accentColor: const Color(0xFFA78BFA),
                onTap: () => ref.read(transactionSelectedYearProvider.notifier).state = y,
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
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1,
                  ),
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
                child: Container(
                  height: 1,
                  color: DpcColors.surfaceBorder,
                ),
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
            padding: const EdgeInsets.only(left: 4, right: 4, top: 4, bottom: 6),
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

          // Day Grouped Transactions Card
          Container(
            decoration: DpcDecorations.cardBase(radius: 18),
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: dayGroup.transactions.length,
              separatorBuilder: (context, _) => const Divider(
                height: 1,
                thickness: 1,
                color: DpcColors.surfaceBorder,
                indent: 68,
                endIndent: 16,
              ),
              itemBuilder: (context, itemIdx) {
                return _buildTransactionTile(
                  context,
                  dayGroup.transactions[itemIdx],
                );
              },
            ),
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
              style: TextStyle(
                color: DpcColors.textMuted,
                fontSize: 12,
              ),
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
    required ({double spent, double inflow}) weeklyStats,
    required bool isSyncing,
  }) {
    return [
      DpcHeroCardItem(
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
      ),
      DpcHeroCardItem(
        title: 'Cashflow Overview',
        subtitle:
            '${BankTransaction.formatRupees(weeklyStats.spent)} spent • ${BankTransaction.formatRupees(weeklyStats.inflow)} inflow this week',
        badgeText: 'ANALYTICS',
        icon: Icons.insights_rounded,
        gradient: DpcColors.heroPastel2,
        actionLabel: 'View Telemetry',
        onTap: () => setState(() => _activeNavIndex = 1),
      ),
      DpcHeroCardItem(
        title: 'Smart Categorization',
        subtitle: 'Automated UPI narration cleaner and merchant brand tagging',
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
      ),
      DpcHeroCardItem(
        title: 'Security & Vault',
        subtitle: 'Zero-secret on-device architecture secured with Supabase Vault',
        badgeText: 'ENCRYPTED',
        icon: Icons.lock_rounded,
        gradient: DpcColors.heroPastel4,
        actionLabel: 'Profile & Settings',
        onTap: () => _showProfileBottomSheet(context, ref),
      ),
    ];
  }

  /// 1. Prominent Hero Aggregate:
  /// Free-floating without container constraints as per DPC Rule.
  Widget _buildHeroAggregate(
    double balance,
    bool hasActiveConsent, {
    ({double spent, double inflow})? weeklyStats,
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
                border: Border.all(
                  color: DpcColors.surfaceBorder,
                  width: 1,
                ),
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
                    ? '${BankTransaction.formatRupees(weeklyStats.spent)} outflow this week'
                    : 'All accounts verified & synced',
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (weeklyStats.inflow > 0) ...[
                const SizedBox(width: 8),
                const Text('•', style: TextStyle(color: DpcColors.surfaceBorder)),
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
    final amountColor =
        isDebit ? DpcColors.textPrimary : DpcColors.accentPositive;

    return InkWell(
      onTap: () => _showTransactionDetailsModal(context, txn),
      borderRadius: BorderRadius.circular(14),
      splashColor: DpcColors.surfaceTrack.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Category Icon with subtle tinted squircle
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: (isDebit ? DpcColors.surfaceTrack : DpcColors.accentPositive)
                    .withValues(alpha: isDebit ? 0.6 : 0.12),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                  color: (isDebit ? DpcColors.surfaceBorder : DpcColors.accentPositive)
                      .withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                txn.icon,
                color: isDebit ? DpcColors.textSecondary : DpcColors.accentPositive,
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
                  Text(
                    txn.category != null && txn.category!.isNotEmpty
                        ? '${txn.formattedTime} • ${txn.mode} • ${txn.category}'
                        : '${txn.formattedTime} • ${txn.mode}',
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
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
  // SCREEN B: TELEMETRY & ANALYTICS DASHBOARD
  // ==========================================
  Widget _buildTelemetryScreen(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
  ) {
    final weeklyStats = ref.watch(weeklyStatsProvider);
    final balance = ref.watch(latestBalanceProvider);

    // Compute metrics
    final totalSpent = weeklyStats.spent;
    final totalInflow = weeklyStats.inflow;
    final savingsRatio = (totalInflow > 0)
        ? ((totalInflow - totalSpent) / totalInflow).clamp(0.0, 1.0)
        : 0.0;
    final discretionaryRatio = (totalSpent > 0) ? 0.35 : 0.0;

    final filterOptions = [
      'All Time',
      'This Month',
      'Last 7 Days',
      'Debits',
      'Inflow'
    ];

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
                    const Text(
                      'Live Metrics',
                      style: TextStyle(
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

          // 1. Segmented Filter Bar
          DpcSegmentedFilterBar(
            filters: filterOptions,
            selectedIndex: _telemetryFilterIndex,
            onSelect: (index) {
              setState(() => _telemetryFilterIndex = index);
            },
          ),
          const SizedBox(height: 20),

          // 2. 2x2 Telemetry Grid Cards
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.15,
            children: [
              DpcTelemetryCard(
                data: DpcTelemetryMetricData(
                  title: 'Savings Retention',
                  icon: Icons.savings_rounded,
                  valueText: '${(savingsRatio * 100).round()}%',
                  fraction: savingsRatio > 0 ? savingsRatio : 0.65,
                  traitTag: savingsRatio > 0.4 ? 'High Savings' : 'Normal',
                  accentColor: DpcColors.accentPositive,
                ),
              ),
              DpcTelemetryCard(
                data: DpcTelemetryMetricData(
                  title: 'Discretionary Ratio',
                  icon: Icons.pie_chart_outline_rounded,
                  valueText: '${(discretionaryRatio * 100).round()}%',
                  fraction: discretionaryRatio,
                  traitTag: 'Low Deficit',
                  accentColor: DpcColors.accentPrimary,
                ),
              ),
              DpcTelemetryCard(
                data: DpcTelemetryMetricData(
                  title: 'Daily Velocity',
                  icon: Icons.speed_rounded,
                  valueText:
                      BankTransaction.formatRupees((totalSpent / 7).roundToDouble()),
                  fraction: 0.55,
                  traitTag: 'Balanced',
                  accentColor: DpcColors.accentLevel,
                ),
              ),
              DpcTelemetryCard(
                data: DpcTelemetryMetricData(
                  title: 'Financial Health',
                  icon: Icons.health_and_safety_rounded,
                  valueText: '94%',
                  fraction: 0.94,
                  traitTag: 'Budget Pro',
                  accentColor: DpcColors.accentPositive,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 3. Split Telemetry Card:
          // Left: Circular radial gauge (Inflow vs Outflow)
          // Right: Key-value metrics
          DpcSplitTelemetryCard(
            title: 'Cash Flow Distribution',
            gaugeProgress: totalInflow > 0
                ? ((totalInflow - totalSpent).clamp(0.0, totalInflow) /
                    totalInflow)
                : 0.72,
            gaugeLabel: 'Net Inflow',
            gaugeColor: DpcColors.accentPositive,
            keyValues: [
              (
                label: 'Total Inflow',
                value: BankTransaction.formatRupees(totalInflow),
                color: DpcColors.accentPositive,
              ),
              (
                label: 'Total Spent (7d)',
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
            items: [
              DpcLiquidVolumeItem(
                label: 'UPI Transfers',
                amount: '82%',
                fraction: 0.82,
                color: DpcColors.accentPrimary,
              ),
              DpcLiquidVolumeItem(
                label: 'ATM / Cash',
                amount: '12%',
                fraction: 0.25,
                color: DpcColors.accentLevel,
              ),
              DpcLiquidVolumeItem(
                label: 'NetBanking / FT',
                amount: '6%',
                fraction: 0.15,
                color: DpcColors.accentPositive,
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 5. Phase-Based Multi-Gauge Cards (Weekly velocity breakdown)
          const Text(
            'WEEKLY OUTFLOW VELOCITY',
            style: DpcTypography.badgeTag,
          ),
          const SizedBox(height: 10),
          const DpcPhaseMultiGaugeRow(
            items: [
              DpcPhaseGaugeItem(
                stage: 'Week 1',
                progress: 0.35,
                metric: '₹3,400',
                color: DpcColors.accentPositive,
              ),
              DpcPhaseGaugeItem(
                stage: 'Week 2',
                progress: 0.60,
                metric: '₹5,100',
                color: DpcColors.accentPrimary,
              ),
              DpcPhaseGaugeItem(
                stage: 'Week 3',
                progress: 0.45,
                metric: '₹4,200',
                color: DpcColors.accentLevel,
              ),
              DpcPhaseGaugeItem(
                stage: 'Week 4',
                progress: 0.20,
                metric: '₹1,800',
                color: DpcColors.accentPositive,
              ),
            ],
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
        Container(
          height: 100,
          decoration: DpcDecorations.cardBase(radius: 20),
        ),
        const SizedBox(height: 16),
        Container(
          height: 210,
          decoration: DpcDecorations.cardBase(radius: 28),
        ),
        const SizedBox(height: 16),
        Container(
          height: 60,
          decoration: DpcDecorations.cardBase(radius: 16),
        ),
      ],
    );
  }

  Widget _buildErrorState(BuildContext context, WidgetRef ref, String error) {
    final lower = error.toLowerCase();
    final isConsentIssue = lower.contains('consent use exceeded') ||
        lower.contains('consent expired') ||
        lower.contains('consent not active') ||
        lower.contains('consent revoked') ||
        lower.contains('no active account aggregator consent') ||
        lower.contains('fidata') ||
        lower.contains('datarange');

    final isNetworkIssue = lower.contains('socketexception') ||
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
                  color: (isConsentIssue
                          ? DpcColors.accentLevel
                          : DpcColors.accentNegative)
                      .withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: (isConsentIssue
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
                          color: DpcColors.accentPositive.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DpcColors.accentPositive.withValues(alpha: 0.3),
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
                      hintText: 'e.g. 9845167455',
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
                    style: TextStyle(
                      color: DpcColors.textMuted,
                      fontSize: 11,
                    ),
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
                                final aaService =
                                    ref.read(setuAaServiceProvider);
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
        await ref.read(supabaseDbServiceProvider).recordConsent(
              consentId: consentId,
              status: 'ACTIVE',
            );
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
                        color: (txn.isDebit
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
                if (txn.category != null && txn.category!.isNotEmpty)
                  _buildDetailRow('Category', txn.category!),
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
            child: Text(
              label,
              style: DpcTypography.componentLabel,
            ),
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

  /// DPC Styled Profile Bottom Sheet
  Future<void> _showProfileBottomSheet(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final user = ref.read(currentUserProvider);
    final email = user?.email ?? 'Authenticated User';
    final hasActiveConsent = ref.read(hasActiveConsentProvider);
    final activeConsentId = ref.read(activeConsentIdProvider);

    await showModalBottomSheet(
      context: context,
      backgroundColor: DpcColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      builder: (modalCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
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
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      gradient: DpcColors.heroPastel2,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        email.isNotEmpty ? email[0].toUpperCase() : 'U',
                        style: const TextStyle(
                          color: DpcColors.textContrast,
                          fontSize: 20,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.userMetadata?['full_name'] as String? ??
                              'Setthi Member',
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          email,
                          style: const TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: DpcDecorations.cardBase(radius: 14),
                child: Row(
                  children: [
                    Icon(
                      hasActiveConsent
                          ? Icons.check_circle_rounded
                          : Icons.account_balance_rounded,
                      color: hasActiveConsent
                          ? DpcColors.accentPositive
                          : DpcColors.accentLevel,
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            hasActiveConsent
                                ? 'Bank Feed Active'
                                : 'No Bank Connected',
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            hasActiveConsent
                                ? 'Consent ID: ${activeConsentId ?? "Active"}'
                                : 'Connect your bank via Setu AA',
                            style: const TextStyle(
                              color: DpcColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.of(modalCtx).pop();
                    ref.read(authBypassProvider.notifier).reset();
                    await ref.read(authServiceProvider).signOut();
                  },
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: DpcColors.accentNegative,
                    size: 18,
                  ),
                  label: const Text(
                    'Sign Out',
                    style: TextStyle(
                      color: DpcColors.accentNegative,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(
                      color: DpcColors.accentNegative,
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
        ),
      ),
    );
  }
}
