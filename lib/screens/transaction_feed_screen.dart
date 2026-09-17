import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/auth_providers.dart';
import '../providers/transaction_providers.dart';
import '../widgets/dpc_floating_dock.dart';
import '../widgets/dpc_gauges.dart';
import '../widgets/dpc_hero_carousel.dart';
import '../widgets/dpc_telemetry_cards.dart';
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
    final balance = ref.watch(latestBalanceProvider);

    return AppBar(
      elevation: 0,
      backgroundColor: DpcColors.bgOled,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 18,
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Pill-shaped currency/resource badge with icon (#38BDF8)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: DpcColors.surfaceDark,
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
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: DpcColors.accentPrimary.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Text(
                      '₹',
                      style: TextStyle(
                        color: DpcColors.accentPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  BankTransaction.formatRupees(balance),
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),

          // Center: Setthi Brand
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  gradient: DpcColors.heroPastel1,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.bolt_rounded,
                  color: DpcColors.textContrast,
                  size: 15,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Setthi',
                style: TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                ),
              ),
            ],
          ),

          // Right: Circular level/tier indicator enclosed in active radial progress arc (#F59E0B)
          InkWell(
            onTap: () => _showProfileBottomSheet(context, ref),
            borderRadius: BorderRadius.circular(20),
            child: DpcMiniGauge(
              progress: hasActiveConsent ? 1.0 : 0.4,
              size: 34,
              activeColor: hasActiveConsent
                  ? DpcColors.accentPositive
                  : DpcColors.accentLevel,
              center: Icon(
                hasActiveConsent
                    ? Icons.verified_user_rounded
                    : Icons.person_rounded,
                size: 15,
                color: hasActiveConsent
                    ? DpcColors.accentPositive
                    : DpcColors.accentLevel,
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
    final grouped = ref.watch(groupedTransactionsProvider);

    return CustomScrollView(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Prominent Hero Aggregate (Free-floating Display Metric)
                _buildHeroAggregate(balance, hasActiveConsent),
                const SizedBox(height: 18),

                // 2. Floating Horizontal Hero Carousel (Pastel cards with #121214 text)
                _buildHeroCarouselSection(
                  context,
                  ref,
                  hasActiveConsent,
                  weeklyStats,
                ),
                const SizedBox(height: 20),

                // 3. Setu AA Gateway Action Bar
                _buildActionBar(context, ref, isSyncing, hasActiveConsent),
                if (transactions.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  // 4. Spent vs Inflow Snapshot Strip
                  _buildWeeklySnapshotStrip(weeklyStats.spent, weeklyStats.inflow),
                  const SizedBox(height: 20),

                  // 5. Section Header for Feed
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'TRANSACTION FEED',
                        style: DpcTypography.badgeTag,
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceDark,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${transactions.length} Total',
                          style: const TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
              ],
            ),
          ),
        ),

        // Transactions Feed or Empty State
        if (transactions.isEmpty)
          SliverToBoxAdapter(
            child: _buildEmptyState(context, ref, hasActiveConsent, isSyncing),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final groupKeys = grouped.keys.toList();
                  final groupTitle = groupKeys[index];
                  final items = grouped[groupTitle]!;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 14, bottom: 8),
                        child: Row(
                          children: [
                            Text(
                              groupTitle.toUpperCase(),
                              style: const TextStyle(
                                color: DpcColors.textSecondary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
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
                            Text(
                              '${items.length} txns',
                              style: const TextStyle(
                                color: DpcColors.textMuted,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: DpcDecorations.cardBase(radius: 18),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: items.length,
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
                              items[itemIdx],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
                childCount: grouped.keys.length,
              ),
            ),
          ),
        const SliverToBoxAdapter(
          child: SizedBox(height: 100), // padding for floating dock
        ),
      ],
    );
  }

  /// 1. Prominent Hero Aggregate:
  /// Free-floating without container constraints as per DPC Rule.
  Widget _buildHeroAggregate(double balance, bool hasActiveConsent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: hasActiveConsent
                    ? DpcColors.accentPositive.withValues(alpha: 0.12)
                    : DpcColors.surfaceDark,
                borderRadius: BorderRadius.circular(12),
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
                      shape: BoxShape.circle,
                      color: hasActiveConsent
                          ? DpcColors.accentPositive
                          : DpcColors.accentLevel,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    hasActiveConsent ? 'LIVE FEED' : 'SETUP REQUIRED',
                    style: TextStyle(
                      color: hasActiveConsent
                          ? DpcColors.accentPositive
                          : DpcColors.accentLevel,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ],
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
      ],
    );
  }

  /// 2. Floating Horizontal Hero Carousel
  /// Cards with corner radius 28px, min height 220px, horizontal snapping, 16-24px peeking, #121214 text.
  Widget _buildHeroCarouselSection(
    BuildContext context,
    WidgetRef ref,
    bool hasActiveConsent,
    ({double spent, double inflow}) weeklyStats,
  ) {
    final items = [
      // Hero Pastel 1: Mint/Teal (Bank Connection & AA Sync)
      DpcHeroCardItem(
        title: hasActiveConsent ? 'Bank Feed Active' : 'Link Bank Account',
        subtitle: hasActiveConsent
            ? 'Real-time financial feed verified through Setu ReBIT AA Gateway.'
            : 'Connect your savings account via RBI-regulated Account Aggregator.',
        badgeText: hasActiveConsent ? 'Verified' : 'Connect',
        icon: Icons.account_balance_rounded,
        gradient: DpcColors.heroPastel1,
        actionLabel: hasActiveConsent ? 'Sync Latest' : 'Link Now',
        onTap: () {
          if (!hasActiveConsent) {
            _showLinkBankBottomSheet(context, ref);
          } else {
            ref.read(transactionFeedProvider.notifier).syncTransactions();
          }
        },
      ),

      // Hero Pastel 2: Lilac/Purple (AI Insights & Spend Velocity)
      DpcHeroCardItem(
        title: 'Spend Intelligence',
        subtitle:
            'Weekly spend: ${BankTransaction.formatRupees(weeklyStats.spent)} vs ${BankTransaction.formatRupees(weeklyStats.inflow)} inflow.',
        badgeText: 'Analytics',
        icon: Icons.insights_rounded,
        gradient: DpcColors.heroPastel2,
        actionLabel: 'Sync Feed',
        onTap: () => _handleSyncAction(context, ref),
      ),

      // Hero Pastel 3: Peach/Rose (Cash Flow Velocity)
      DpcHeroCardItem(
        title: 'Cash Flow Velocity',
        subtitle: weeklyStats.inflow >= weeklyStats.spent
            ? 'Positive cash flow trajectory! Outflow safely managed.'
            : 'Caution: Outflow velocity exceeding inflow over the last 7 days.',
        badgeText: 'Cash Flow',
        icon: Icons.speed_rounded,
        gradient: DpcColors.heroPastel3,
        actionLabel: 'Refresh',
        onTap: () => _handleSyncAction(context, ref),
      ),

      // Hero Pastel 4: Warm Cream (Security & ReBIT)
      DpcHeroCardItem(
        title: '256-bit AA Shield',
        subtitle:
            'End-to-end encrypted financial information provider consent architecture.',
        badgeText: 'Encrypted',
        icon: Icons.shield_rounded,
        gradient: DpcColors.heroPastel4,
        actionLabel: 'Security Info',
        onTap: () => _showProfileBottomSheet(context, ref),
      ),
    ];

    return DpcHeroCarousel(items: items, height: 210);
  }

  /// 3. Action Bar: Setu AA ReBIT Gateway Status & Sync Action
  Widget _buildActionBar(
    BuildContext context,
    WidgetRef ref,
    bool isSyncing,
    bool hasActiveConsent,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: DpcDecorations.cardBase(radius: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: () => _showLinkBankBottomSheet(context, ref),
            borderRadius: BorderRadius.circular(10),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (hasActiveConsent
                            ? DpcColors.accentPositive
                            : DpcColors.accentPrimary)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    hasActiveConsent
                        ? Icons.verified_rounded
                        : Icons.account_balance_outlined,
                    size: 18,
                    color: hasActiveConsent
                        ? DpcColors.accentPositive
                        : DpcColors.accentPrimary,
                  ),
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Setu AA ReBIT Gateway',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      hasActiveConsent
                          ? 'Consent Active • Live AA Sync'
                          : 'Tap to Link Bank Account',
                      style: TextStyle(
                        color: hasActiveConsent
                            ? DpcColors.accentPositive
                            : DpcColors.textSecondary,
                        fontSize: 10,
                        fontWeight: hasActiveConsent
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: isSyncing ? null : () => _handleSyncAction(context, ref),
            style: ElevatedButton.styleFrom(
              backgroundColor: hasActiveConsent
                  ? DpcColors.surfaceTrack
                  : DpcColors.accentPositive,
              foregroundColor: hasActiveConsent
                  ? DpcColors.textPrimary
                  : DpcColors.textContrast,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: hasActiveConsent
                    ? const BorderSide(color: DpcColors.surfaceBorder)
                    : BorderSide.none,
              ),
            ),
            icon: isSyncing
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: hasActiveConsent
                          ? DpcColors.textPrimary
                          : DpcColors.textContrast,
                    ),
                  )
                : Icon(
                    hasActiveConsent ? Icons.sync_rounded : Icons.link_rounded,
                    size: 16,
                  ),
            label: Text(
              isSyncing
                  ? 'Syncing...'
                  : hasActiveConsent
                      ? 'Sync Feed'
                      : 'Link Bank',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 4. Weekly Snapshot Strip (Spent vs Inflow)
  Widget _buildWeeklySnapshotStrip(double spent, double inflow) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: DpcDecorations.cardBase(radius: 16),
      child: Row(
        children: [
          // Spent
          Expanded(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: DpcColors.accentNegative.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_upward_rounded,
                    size: 14,
                    color: DpcColors.accentNegative,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Spent this week',
                        style: DpcTypography.componentLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        BankTransaction.formatRupees(spent),
                        style: const TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 32,
            color: DpcColors.surfaceBorder,
          ),
          const SizedBox(width: 14),
          // Inflow
          Expanded(
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: DpcColors.accentPositive.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_downward_rounded,
                    size: 14,
                    color: DpcColors.accentPositive,
                  ),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Total Inflow',
                        style: DpcTypography.componentLabel,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        BankTransaction.formatRupees(inflow),
                        style: const TextStyle(
                          color: DpcColors.accentPositive,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 5. Individual Transaction Row in DPC Card Base
  Widget _buildTransactionTile(BuildContext context, BankTransaction txn) {
    final isDebit = txn.isDebit;
    final amountColor =
        isDebit ? DpcColors.accentNegative : DpcColors.accentPositive;

    return InkWell(
      onTap: () => _showTransactionDetailsModal(context, txn),
      borderRadius: BorderRadius.circular(14),
      splashColor: DpcColors.surfaceTrack.withValues(alpha: 0.3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            // Category Icon with subtle tinted circle
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: (isDebit ? DpcColors.accentPrimary : DpcColors.accentPositive)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: (isDebit ? DpcColors.accentPrimary : DpcColors.accentPositive)
                      .withValues(alpha: 0.25),
                  width: 1,
                ),
              ),
              child: Icon(
                txn.icon,
                color: isDebit ? DpcColors.accentPrimary : DpcColors.accentPositive,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // Merchant name & Narration
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          txn.cleanMerchantName,
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceDark,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          txn.mode,
                          style: const TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    txn.narration,
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 11,
                      overflow: TextOverflow.ellipsis,
                    ),
                    maxLines: 1,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    txn.formattedDate,
                    style: const TextStyle(
                      color: DpcColors.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Amount & Running Balance
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isDebit ? '- ' : '+ '}${txn.formattedAmount}',
                  style: TextStyle(
                    color: amountColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Bal: ${txn.formattedBalance}',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
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
                color: DpcColors.surfaceBorder,
                width: 1,
              ),
            ),
            child: Icon(
              hasActiveConsent
                  ? Icons.receipt_long_rounded
                  : Icons.account_balance_rounded,
              size: 44,
              color: hasActiveConsent
                  ? DpcColors.accentPrimary
                  : DpcColors.accentPositive,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            hasActiveConsent
                ? 'No Transactions Found'
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
                ? 'No recent transactions were found for this linked account.'
                : 'Connect your bank account via Setu Account Aggregator to view real-time transactions and balance.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 13,
              height: 1.4,
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
            ElevatedButton.icon(
              onPressed: isSyncing
                  ? null
                  : () => ref
                      .read(transactionFeedProvider.notifier)
                      .syncTransactions(),
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.accentPositive,
                foregroundColor: DpcColors.textContrast,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
              ),
              icon: isSyncing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: DpcColors.textContrast,
                      ),
                    )
                  : const Icon(Icons.sync_rounded, size: 18),
              label: Text(
                isSyncing ? 'Syncing...' : 'Sync Transactions',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: DpcColors.accentNegative.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                color: DpcColors.accentNegative,
                size: 38,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Failed to Load Transactions',
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () =>
                  ref.read(transactionFeedProvider.notifier).syncTransactions(),
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.surfaceTrack,
                foregroundColor: DpcColors.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: DpcColors.surfaceBorder),
                ),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // BOTTOM SHEETS & MODALS (DPC OLED STYLED)
  // ==========================================
  Future<void> _handleSyncAction(BuildContext context, WidgetRef ref) async {
    final hasActiveConsent = ref.read(hasActiveConsentProvider);
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

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: DpcColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
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
                      const Column(
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
                              color: DpcColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Registered Mobile Number',
                    style: TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    autofocus: true,
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: DpcColors.bgOled,
                      prefixIcon: const Icon(
                        Icons.phone_iphone_rounded,
                        color: DpcColors.accentPrimary,
                        size: 20,
                      ),
                      hintText: 'Enter 10-digit mobile number',
                      hintStyle: const TextStyle(color: DpcColors.textMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: DpcColors.accentPositive),
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

                                if (modalContext.mounted) {
                                  Navigator.of(modalContext).pop();
                                }

                                if (context.mounted) {
                                  final approved =
                                      await Navigator.of(context).push<bool>(
                                    MaterialPageRoute(
                                      builder: (_) => SetuConsentWebView(
                                        consentUrl: consentUrl,
                                        consentId: consentId,
                                        aaService: aaService,
                                      ),
                                    ),
                                  );

                                  if (approved == true && context.mounted) {
                                    await ref
                                        .read(transactionFeedProvider.notifier)
                                        .setConsentAndSync(consentId);
                                  }
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
