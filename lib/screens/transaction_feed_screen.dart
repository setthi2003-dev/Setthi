import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../config/navigation_keys.dart';
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
import '../widgets/ai_companion_rive_widget.dart';
import '../providers/chat_providers.dart';
import '../widgets/profile_completion_dialog.dart';
import '../widgets/dpc_safe_to_spend_card.dart';
import '../widgets/setthi_onboarding_flow.dart';
import '../widgets/dpc_pdf_statement_sheet.dart';
import '../providers/pdf_statement_provider.dart';
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
  // 0: AI Page (Primary), 1: Spending Insights & Transactions (Merged), 4: Profile
  int _activeNavIndex = 0;
  bool _hasPromptedProfileCompletion = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(activeConsentIdProvider.notifier).refreshFromBackend();
      final currentProfile = ref.read(userProfileProvider).value;
      if (currentProfile != null) {
        _checkAndPromptProfileCompletion(currentProfile);
      }
    });
  }

  void _checkAndPromptProfileCompletion(Map<String, dynamic>? profile) {
    if (_hasPromptedProfileCompletion || !mounted) return;

    final user = ref.read(currentUserProvider);
    if (user == null) return;

    final rawName = profile?['full_name'] as String?;
    final metaName =
        (user.userMetadata?['full_name'] as String? ??
                user.userMetadata?['name'] as String?)
            ?.trim();

    final bool hasValidName =
        (rawName != null &&
            rawName.trim().isNotEmpty &&
            rawName.trim() != 'Setthi Member') ||
        (metaName != null &&
            metaName.trim().isNotEmpty &&
            metaName.trim() != 'Setthi Member');

    final bool hasDob = profile?['date_of_birth'] != null;
    final bool hasGender =
        profile?['gender'] != null &&
        (profile?['gender'] as String).trim().isNotEmpty;

    // Pop dialog if user does not have a complete profile (all 3 fields are compulsory)
    if (!hasValidName || !hasDob || !hasGender) {
      _hasPromptedProfileCompletion = true;

      DateTime? initialDob;
      final rawDob = profile?['date_of_birth'] as String?;
      if (rawDob != null) {
        try {
          initialDob = DateTime.parse(rawDob);
        } catch (_) {}
      }

      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final completed = await ProfileCompletionDialog.show(
          context,
          initialName: hasValidName ? (rawName ?? metaName) : null,
          initialDob: initialDob,
          initialGender: profile?['gender'] as String?,
          isMandatory: true,
        );

        if (completed == true && mounted) {
          final hasTransactions =
              ref.read(transactionFeedProvider).value?.isNotEmpty ?? false;
          final hasConsent = ref.read(hasActiveConsentProvider);
          if (!hasTransactions && !hasConsent) {
            SetthiOnboardingFlow.show(
              context,
              initialPage: 1,
              onComplete: () {
                setState(() => _activeNavIndex = 0);
              },
            );
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_activeNavIndex == 0 || _activeNavIndex == 4) return;
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
    ref.listen<AsyncValue<Map<String, dynamic>?>>(userProfileProvider, (
      previous,
      next,
    ) {
      next.whenData((profile) {
        _checkAndPromptProfileCompletion(profile);
      });
    });

    final transactionFeedAsync = ref.watch(transactionFeedProvider);
    final hasActiveConsent = ref.watch(hasActiveConsentProvider);
    final isSyncing = transactionFeedAsync.isLoading;

    final hasKeyboard = MediaQuery.viewInsetsOf(context).bottom > 0;

    return Scaffold(
      backgroundColor: DpcColors.bgOled,
      appBar: _buildDpcAppBar(context, ref, hasActiveConsent, isSyncing),
      extendBody: _activeNavIndex != 0,
      body: RefreshIndicator(
        notificationPredicate: (notification) =>
            _activeNavIndex != 0 &&
            defaultScrollNotificationPredicate(notification),
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
            if (hasActiveConsent) {
              return const DpcSyncingWaitingView();
            }
            return _buildSkeletonLoader();
          },
          error: (err, stack) {
            if (_activeNavIndex == 0) {
              return const SetthiAiSheet(isFullScreenPage: true);
            }
            if (_activeNavIndex == 1) {
              return _buildTelemetryScreen(context, ref, const []);
            }
            if (_activeNavIndex == 4) {
              return _buildProfileScreen(context, ref);
            }
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
      bottomNavigationBar: hasKeyboard
          ? null
          : DpcFloatingNavDock(
              activeIndex: _activeNavIndex,
              onAiTap: () {
                setState(() => _activeNavIndex = 0);
              },
              onTelemetryTap: () {
                if (ref.read(transactionFeedProvider).hasError) {
                  ref
                      .read(transactionFeedProvider.notifier)
                      .dismissErrorAndGoHome();
                }
                if (_activeNavIndex != 1 && _activeNavIndex != 2) {
                  setState(() => _activeNavIndex = 1);
                } else if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
              onTransactionsTap: () {
                if (ref.read(transactionFeedProvider).hasError) {
                  ref
                      .read(transactionFeedProvider.notifier)
                      .dismissErrorAndGoHome();
                }
                if (_activeNavIndex != 1 && _activeNavIndex != 2) {
                  setState(() => _activeNavIndex = 1);
                } else if (_scrollController.hasClients) {
                  _scrollController.animateTo(
                    0,
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                  );
                }
              },
              // [COMMENTED OUT FROM UI - DO NOT REMOVE]
              // onBankTap: () => _showLinkBankBottomSheet(context, ref),
              onProfileTap: () {
                setState(() => _activeNavIndex = 4);
              },
              onSyncTap: () => _handleSyncAction(context, ref),
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
    bool isSyncing,
  ) {
    if (_activeNavIndex == 0) {
      // Setthi AI Full Page AppBar
      final credits = ref.watch(aiCreditsProvider);
      return AppBar(
        elevation: 0,
        backgroundColor: DpcColors.bgOled,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 12,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: DpcColors.surfaceDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DpcColors.surfaceBorder, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: const AiCompanionRiveWidget(size: 30),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Flexible(
                        child: Text(
                          'Setthi AI',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 5,
                        height: 5,
                        decoration: const BoxDecoration(
                          color: DpcColors.accentPositive,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const Text(
                    'Smart Finance Companion',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: DpcColors.textMuted, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: DpcColors.surfaceBorder, width: 1),
            ),
            child: Text(
              '$credits credits',
              style: const TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            key: const Key('delete_conversation_button'),
            icon: const Icon(
              Icons.delete_sweep_outlined,
              size: 20,
              color: DpcColors.textSecondary,
            ),
            tooltip: 'Delete Conversation',
            onPressed: () => showDeleteConversationConfirmation(context, ref),
          ),
          const SizedBox(width: 6),
        ],
      );
    }

    if (_activeNavIndex == 1 || _activeNavIndex == 2) {
      // Merged Spending Insights AppBar
      return AppBar(
        elevation: 0,
        backgroundColor: DpcColors.bgOled,
        surfaceTintColor: Colors.transparent,
        titleSpacing: 18,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: DpcColors.textPrimary,
          ),
          tooltip: 'Back to AI Chat',
          onPressed: () => setState(() => _activeNavIndex = 0),
        ),
        title: const Text(
          'Spending Insights',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.6,
          ),
        ),
        actions: [
          IconButton(
            icon: isSyncing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DpcColors.accentPositive,
                    ),
                  )
                : const Icon(Icons.sync_rounded, color: DpcColors.textSecondary),
            tooltip: 'Sync Statement Data',
            onPressed: isSyncing ? null : () => _handleSyncAction(context, ref),
          ),
          const SizedBox(width: 6),
        ],
      );
    }

    if (_activeNavIndex == 4) {
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

    // Home AppBar (Page 3: Total Balance & Home)
    return AppBar(
      elevation: 0,
      backgroundColor: DpcColors.bgOled,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 18,
      title: Row(
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
                  Icons.account_balance_wallet_rounded,
                  color: DpcColors.textContrast,
                  size: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 9),
          const Flexible(
            child: Text(
              'Setthi',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: isSyncing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: DpcColors.accentPositive,
                  ),
                )
              : const Icon(
                  Icons.sync_rounded,
                  color: DpcColors.textSecondary,
                  size: 20,
                ),
          tooltip: 'Sync Transactions',
          onPressed: isSyncing ? null : () => _handleSyncAction(context, ref),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildBodyContent(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
    bool hasActiveConsent,
    bool isSyncing,
  ) {
    if (_activeNavIndex == 0) {
      // Primary: Dedicated Setthi AI Full Page
      return const SetthiAiSheet(isFullScreenPage: true);
    }
    if (_activeNavIndex == 4) {
      // Dedicated Profile Screen
      return _buildProfileScreen(context, ref);
    }
    // Merged Screen: Spending Insights & Transactions
    return _buildSpendingInsightsScreen(
      context,
      ref,
      transactions,
      hasActiveConsent,
      isSyncing,
    );
  }

  static String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final parts = iso.split('-');
      if (parts.length == 3) {
        final y = parts[0];
        final m = int.tryParse(parts[1]) ?? 1;
        final d = int.tryParse(parts[2]) ?? 1;
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        final mStr = (m >= 1 && m <= 12) ? months[m - 1] : '';
        return '$d $mStr $y';
      }
    } catch (_) {}
    return iso;
  }

  /// Extracts category spend items from telemetry data or falls back to transaction grouping
  List<CategorySpendItem> _extractCategorySpendItems(
    Map<String, dynamic>? telemetryData,
    List<BankTransaction> transactions,
  ) {
    final rawCategories = telemetryData?['category_distribution'];
    final List<dynamic> categoryList = rawCategories is List
        ? rawCategories
        : [];
    final List<CategorySpendItem> categoryItems = [];
    if (categoryList.isNotEmpty) {
      for (final cat in categoryList) {
        if (cat is Map) {
          final name = cat['category']?.toString() ?? 'Uncategorized';
          final amt = ((cat['amount'] ?? 0.0) as num).toDouble();
          final count = ((cat['count'] ?? 0) as num).toInt();
          final pct = ((cat['percentage'] ?? 0.0) as num).toDouble();
          if (amt > 0) {
            categoryItems.add(
              CategorySpendItem(
                category: name,
                amount: amt,
                count: count,
                percentage: pct,
                color: getCategorySpendColor(name),
                icon: getCategorySpendIcon(name),
              ),
            );
          }
        }
      }
    } else if (transactions.isNotEmpty) {
      // Local fallback calculated from loaded transactions (offline or prior to network response)
      final debitTxns = transactions.where((t) => t.isDebit).toList();
      final Map<String, List<BankTransaction>> grouped = {};
      double fallbackTotal = 0;
      for (final t in debitTxns) {
        final cat = (t.category != null && t.category!.trim().isNotEmpty)
            ? t.category!.trim()
            : 'Uncategorized';
        grouped.putIfAbsent(cat, () => []).add(t);
        fallbackTotal += t.amount;
      }
      final sortedEntries = grouped.entries.toList()
        ..sort((a, b) {
          final sumA = a.value.fold<double>(
            0,
            (acc, item) => acc + item.amount,
          );
          final sumB = b.value.fold<double>(
            0,
            (acc, item) => acc + item.amount,
          );
          return sumB.compareTo(sumA);
        });

      for (final entry in sortedEntries) {
        final catSum = entry.value.fold<double>(
          0,
          (acc, item) => acc + item.amount,
        );
        if (catSum > 0) {
          categoryItems.add(
            CategorySpendItem(
              category: entry.key,
              amount: catSum,
              count: entry.value.length,
              percentage: fallbackTotal > 0
                  ? ((catSum / fallbackTotal) * 100)
                  : 0.0,
              color: getCategorySpendColor(entry.key),
              icon: getCategorySpendIcon(entry.key),
            ),
          );
        }
      }
    }
    return categoryItems;
  }

  // ==========================================
  // SCREEN: SPENDING INSIGHTS & TRANSACTIONS (MERGED)
  // ==========================================
  Widget _buildSpendingInsightsScreen(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
    bool hasActiveConsent,
    bool isSyncing,
  ) {
    final balanceAsync = ref.watch(balanceProvider);
    final telemetryAsync = ref.watch(telemetryMetricsProvider);
    final telemetryData = telemetryAsync.value;

    // Category Distribution from backend, fallback to local category extraction
    final rawCategories = telemetryData?['category_distribution'];
    final List<dynamic> categoryList =
        rawCategories is List ? rawCategories : [];
    final categoryItems = _extractCategorySpendItems(
      telemetryData,
      transactions,
    );
    // ignore: unused_local_variable
    final effectiveCategories = categoryList.isNotEmpty
        ? categoryList
        : categoryItems.map((item) => {
            'category': item.category,
            'amount': item.amount,
            'count': item.count,
            'percentage': item.percentage,
          }).toList();

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
          // 1. Total Available Balance Hero Aggregate
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
              child: _buildHeroAggregate(
                balanceAsync,
                hasActiveConsent,
                isSyncing: isSyncing,
              ),
            ),
          ),

          // 2. Daily Safe Limit Card
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: DpcSafeToSpendCard(),
            ),
          ),

          // 4. Single Unified Spending by Category list (temporarily commented out from UI)
          /*
          if (effectiveCategories.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SPENDING BY CATEGORY',
                      style: DpcTypography.badgeTag,
                    ),
                    const SizedBox(height: 10),
                    ...effectiveCategories.map((catItem) {
                      final cat = catItem is Map<String, dynamic>
                          ? catItem
                          : (catItem is Map
                              ? Map<String, dynamic>.from(catItem)
                              : <String, dynamic>{});
                      final catName =
                          cat['category']?.toString() ?? 'Uncategorized';
                      final amt = ((cat['amount'] ?? 0.0) as num).toDouble();
                      final count = ((cat['count'] ?? 0) as num).toInt();
                      final pct =
                          ((cat['percentage'] ?? 0.0) as num).toDouble();

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: DpcDecorations.cardBase(radius: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    catName,
                                    style: const TextStyle(
                                      color: DpcColors.textPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  BankTransaction.formatRupees(amt),
                                  style: const TextStyle(
                                    color: DpcColors.textPrimary,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(
                                      value: (pct / 100.0).clamp(0.0, 1.0),
                                      backgroundColor:
                                          DpcColors.surfaceElevated,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        DpcColors.accentPrimary
                                            .withValues(alpha: 0.8),
                                      ),
                                      minHeight: 4,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  count > 0
                                      ? '$count payments • ${pct.toStringAsFixed(1)}%'
                                      : '${pct.toStringAsFixed(1)}%',
                                  style: const TextStyle(
                                    color: DpcColors.textSecondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          */

          // 5. Timeline Filter & Sort Bar
          if (transactions.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'TRANSACTIONS',
                      style: DpcTypography.badgeTag,
                    ),
                    const SizedBox(height: 10),
                    _buildFilterAndSortBar(
                      context,
                      ref,
                      totalTransactions: transactions.length,
                      matchingTransactions: totalMatchingTxns,
                      sortOrder: sortOrder,
                      typeFilter: typeFilter,
                      selectedYear: selectedYear,
                      availableYears: availableYears,
                    ),
                  ],
                ),
              ),
            ),

          // Transactions Feed or Empty State
          if (transactions.isEmpty)
            SliverToBoxAdapter(
              child: _buildEmptyState(
                context,
                ref,
                hasActiveConsent,
                isSyncing,
              ),
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
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 24,
                ),
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
                                  color: DpcColors.accentPositive.withValues(
                                    alpha: 0.15,
                                  ),
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
                  border: Border.all(color: DpcColors.surfaceBorder, width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      sortOrder == TransactionSortOrder.latestFirst
                          ? Icons.south_rounded
                          : Icons.north_rounded,
                      size: 12,
                      color: DpcColors.textPrimary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      sortOrder == TransactionSortOrder.latestFirst
                          ? 'Latest'
                          : 'Oldest',
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
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
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.debitOnly,
          ),
          const SizedBox(width: 6),

          // 4. Flow: Credits
          _buildFilterChip(
            label: 'Credits ↑',
            isSelected: typeFilter == TransactionTypeFilter.creditOnly,
            onTap: () =>
                ref.read(transactionTypeFilterProvider.notifier).state =
                    TransactionTypeFilter.creditOnly,
          ),
          const SizedBox(width: 6),

          // 5. Flow: Untagged (both credits & debits)
          _buildFilterChip(
            label: 'Untagged',
            isSelected: typeFilter == TransactionTypeFilter.untagged,
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
  }) {
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
                ? DpcColors.surfaceElevated
                : DpcColors.surfaceDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected
                  ? DpcColors.textPrimary.withValues(alpha: 0.35)
                  : DpcColors.surfaceBorder,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? DpcColors.textPrimary
                  : DpcColors.textSecondary,
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
            padding: const EdgeInsets.only(top: 6, bottom: 6),
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
  // [COMMENTED OUT FROM UI - DO NOT REMOVE]
  // ignore: unused_element
  List<DpcHeroCardItem> _buildHeroCarouselItems(
    BuildContext context,
    WidgetRef ref, {
    required bool hasActiveConsent,
    required dynamic weeklyStats,
    required bool isSyncing,
  }) {
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

    // Card 2: Money Flow Overview
    final card2 = DpcHeroCardItem(
      title: 'Money Flow Overview',
      subtitle: weeklyStats.isLive
          ? '${BankTransaction.formatRupees(weeklyStats.spent)} spent • ${BankTransaction.formatRupees(weeklyStats.inflow)} received this week'
          : '${BankTransaction.formatRupees(weeklyStats.spent)} spent • ${BankTransaction.formatRupees(weeklyStats.inflow)} received (${weeklyStats.periodLabel})',
      badgeText: 'INSIGHTS',
      icon: Icons.insights_rounded,
      gradient: DpcColors.heroPastel2,
      actionLabel: 'View Insights',
      onTap: () => setState(() => _activeNavIndex = 1),
    );

    // Card 3: Smart Categorization
    final card3 = DpcHeroCardItem(
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
    );

    final card4 = DpcHeroCardItem(
      title: 'Security & Vault',
      subtitle:
          'Zero-secret on-device architecture secured with bank-grade encryption',
      badgeText: 'ENCRYPTED',
      icon: Icons.lock_rounded,
      gradient: DpcColors.heroPastel4,
      actionLabel: 'Profile & Settings',
      onTap: () => setState(() => _activeNavIndex = 4),
    );

    return [card1, card2, card3, card4];
  }

  /// 1. Prominent Hero Aggregate:
  /// Free-floating without container constraints as per DPC Rule.
  Widget _buildHeroAggregate(
    AsyncValue<Map<String, dynamic>?> balanceAsync,
    bool hasActiveConsent, {
    bool isSyncing = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Expanded(
              child: Text(
                'BALANCE',
                style: TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            // Import PDF button in the right corner
            InkWell(
              onTap: () => DpcPdfStatementSheet.show(context),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DpcColors.surfaceBorder, width: 1),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.picture_as_pdf_outlined,
                      size: 13,
                      color: DpcColors.accentPositive,
                    ),
                    SizedBox(width: 4),
                    Text(
                      'Import PDF',
                      style: TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        balanceAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: DpcColors.accentPositive,
              ),
            ),
          ),
          error: (err, stack) => Row(
            children: [
              const Text(
                'Could not load balance',
                style: TextStyle(
                  color: DpcColors.accentNegative,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => ref.invalidate(balanceProvider),
                child: const Text(
                  'Retry',
                  style: TextStyle(
                    color: DpcColors.accentPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
          data: (balData) {
            final bool available = balData != null && balData['available'] == true;
            if (!available) {
              final bool hasTransactions =
                  ref.watch(transactionFeedProvider).asData?.value.isNotEmpty == true;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasTransactions
                        ? 'Balance not available from this statement'
                        : 'No statement imported yet',
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    hasTransactions
                        ? 'We could not verify the balance in this PDF.'
                        : 'Import a PDF statement to see your verified balance.',
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              );
            }

            final double currentBal =
                ((balData['current_balance'] ?? 0.0) as num).toDouble();
            final String? asOfDate = balData['as_of_date']?.toString();
            final int? daysAgo = balData['days_since_statement_end'] is num
                ? (balData['days_since_statement_end'] as num).toInt()
                : null;
            final bool isStale = balData['stale'] == true;
            final formattedDate = _formatDate(asOfDate);

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      BankTransaction.formatRupees(currentBal),
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
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      'as of $formattedDate${daysAgo != null ? ' · $daysAgo days ago' : ''}',
                      style: const TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (isStale) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: DpcColors.accentLevel.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'may have changed since',
                          style: TextStyle(
                            color: DpcColors.accentLevel,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
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
                        '${txn.istFormattedDate} • ${txn.mode}',
                        style: const TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (txn.displayKindLabel != null) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: DpcColors.surfaceTrack,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: DpcColors.surfaceBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Text(
                            txn.displayKindLabel!,
                            style: const TextStyle(
                              color: DpcColors.textSecondary,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
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
                              txn.displayCategory,
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
    final profileAsync = ref.watch(userProfileProvider);
    final profile = profileAsync.value;

    final profileName = (profile?['full_name'] as String?)?.trim();
    final metaName =
        (user?.userMetadata?['full_name'] as String? ??
                user?.userMetadata?['name'] as String?)
            ?.trim();
    final fullName = (profileName != null && profileName.isNotEmpty)
        ? profileName
        : ((metaName != null && metaName.isNotEmpty)
              ? metaName
              : 'Setthi Member');

    final userEmail = user?.email?.trim();
    final profileEmail = (profile?['email'] as String?)?.trim();
    final email = (userEmail != null && userEmail.isNotEmpty)
        ? userEmail
        : ((profileEmail != null && profileEmail.isNotEmpty)
              ? profileEmail
              : null);

    final hasActiveConsent = ref.watch(hasActiveConsentProvider);
    final activeConsentId = ref.watch(activeConsentIdProvider);
    final aiCredits = ref.watch(aiCreditsProvider);
    final balanceAsync = ref.watch(balanceProvider);

    int? displayAge;
    if (profile?['date_of_birth'] != null) {
      try {
        final dob = DateTime.parse(profile!['date_of_birth'].toString());
        final nowUtc = DateTime.now().toUtc();
        final nowIst = nowUtc.add(const Duration(hours: 5, minutes: 30));
        int a = nowIst.year - dob.year;
        if (nowIst.month < dob.month ||
            (nowIst.month == dob.month && nowIst.day < dob.day)) {
          a--;
        }
        displayAge = a;
      } catch (_) {}
    }
    displayAge ??= profile?['age'] is num
        ? (profile!['age'] as num).toInt()
        : null;

    final avatarLetter = (fullName != 'Setthi Member' && fullName.isNotEmpty)
        ? fullName[0].toUpperCase()
        : (email != null && email.isNotEmpty ? email[0].toUpperCase() : 'S');

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
                      avatarLetter,
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
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              fullName,
                              style: const TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.4,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _showEditNameDialog(
                              context,
                              ref,
                              fullName,
                              profile: profile,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 6, right: 2),
                              child: Icon(
                                Icons.edit_outlined,
                                color: DpcColors.textSecondary,
                                size: 16,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (email != null && email.isNotEmpty) ...[
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
                      ],
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: DpcColors.surfaceTrack,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: DpcColors.surfaceBorder,
                                width: 1,
                              ),
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
                          if (displayAge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: DpcColors.surfaceTrack,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: DpcColors.surfaceBorder,
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                'Age: $displayAge',
                                style: const TextStyle(
                                  color: DpcColors.textSecondary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          if (profile?['gender'] != null &&
                              (profile?['gender'] as String).isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: DpcColors.surfaceTrack,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: DpcColors.surfaceBorder,
                                  width: 1,
                                ),
                              ),
                              child: Text(
                                '${profile?['gender']}',
                                style: const TextStyle(
                                  color: DpcColors.textSecondary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          GestureDetector(
                            onTap: () => _showEditNameDialog(
                              context,
                              ref,
                              fullName,
                              profile: profile,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (profile?['income_type'] != null &&
                                        (profile!['income_type'] as String)
                                            .isNotEmpty)
                                    ? DpcColors.surfaceTrack
                                    : DpcColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color:
                                      (profile?['income_type'] != null &&
                                          (profile!['income_type'] as String)
                                              .isNotEmpty)
                                      ? DpcColors.surfaceBorder
                                      : DpcColors.accentPositive.withValues(
                                          alpha: 0.4,
                                        ),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (profile?['income_type'] == null ||
                                      (profile!['income_type'] as String)
                                          .isEmpty) ...[
                                    const Icon(
                                      Icons.add_rounded,
                                      size: 11,
                                      color: DpcColors.accentPositive,
                                    ),
                                    const SizedBox(width: 3),
                                  ],
                                  Text(
                                    (profile?['income_type'] != null &&
                                            (profile!['income_type'] as String)
                                                .isNotEmpty)
                                        ? '${profile['income_type']}'
                                        : 'Add Income Type',
                                    style: TextStyle(
                                      color:
                                          (profile?['income_type'] != null &&
                                              (profile!['income_type']
                                                      as String)
                                                  .isNotEmpty)
                                          ? DpcColors.accentPositive
                                          : DpcColors.accentPositive,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => _showEditNameDialog(
                              context,
                              ref,
                              fullName,
                              profile: profile,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color:
                                    (profile?['expected_monthly_income'] !=
                                            null &&
                                        ((profile!['expected_monthly_income']
                                                    is num &&
                                                profile['expected_monthly_income'] >
                                                    0) ||
                                            (double.tryParse(
                                                      profile['expected_monthly_income']
                                                          .toString(),
                                                    ) !=
                                                    null &&
                                                double.parse(
                                                      profile['expected_monthly_income']
                                                          .toString(),
                                                    ) >
                                                    0)))
                                    ? DpcColors.surfaceTrack
                                    : DpcColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color:
                                      (profile?['expected_monthly_income'] !=
                                              null &&
                                          ((profile!['expected_monthly_income']
                                                      is num &&
                                                  profile['expected_monthly_income'] >
                                                      0) ||
                                              (double.tryParse(
                                                        profile['expected_monthly_income']
                                                            .toString(),
                                                      ) !=
                                                      null &&
                                                  double.parse(
                                                        profile['expected_monthly_income']
                                                            .toString(),
                                                      ) >
                                                      0)))
                                      ? DpcColors.surfaceBorder
                                      : DpcColors.surfaceBorder,
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (profile?['expected_monthly_income'] ==
                                          null ||
                                      ((profile!['expected_monthly_income']
                                                  is num &&
                                              profile['expected_monthly_income'] <=
                                                  0) ||
                                          (double.tryParse(
                                                    profile['expected_monthly_income']
                                                        .toString(),
                                                  ) !=
                                                  null &&
                                              double.parse(
                                                    profile['expected_monthly_income']
                                                        .toString(),
                                                  ) <=
                                                  0))) ...[
                                    const Icon(
                                      Icons.add_rounded,
                                      size: 11,
                                      color: DpcColors.textSecondary,
                                    ),
                                    const SizedBox(width: 3),
                                  ],
                                  Text(
                                    (profile?['expected_monthly_income'] !=
                                                null &&
                                            ((profile!['expected_monthly_income']
                                                        is num &&
                                                    profile['expected_monthly_income'] >
                                                        0) ||
                                                (double.tryParse(
                                                          profile['expected_monthly_income']
                                                              .toString(),
                                                        ) !=
                                                        null &&
                                                    double.parse(
                                                          profile['expected_monthly_income']
                                                              .toString(),
                                                        ) >
                                                        0)))
                                        ? 'Baseline: ${BankTransaction.formatRupees(profile['expected_monthly_income'] is num ? (profile['expected_monthly_income'] as num).toDouble() : double.parse(profile['expected_monthly_income'].toString()))}/mo'
                                        : 'Add Baseline Income',
                                    style: TextStyle(
                                      color:
                                          (profile?['expected_monthly_income'] !=
                                                  null &&
                                              ((profile!['expected_monthly_income']
                                                          is num &&
                                                      profile['expected_monthly_income'] >
                                                          0) ||
                                                  (double.tryParse(
                                                            profile['expected_monthly_income']
                                                                .toString(),
                                                          ) !=
                                                          null &&
                                                      double.parse(
                                                            profile['expected_monthly_income']
                                                                .toString(),
                                                          ) >
                                                          0)))
                                          ? DpcColors.textPrimary
                                          : DpcColors.textSecondary,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                    ),
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
                  children: [
                    const Icon(
                      Icons.auto_awesome_rounded,
                      color: DpcColors.textPrimary,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Financial Intelligence',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: DpcColors.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: DpcColors.surfaceTrack,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      child: const Text(
                        'ACTIVE',
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
                  'Ask questions, check your habits, and get simple answers about your money anytime.',
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
                            text: aiCredits == 1
                                ? 'credit remaining'
                                : 'credits remaining',
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
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 7,
                        ),
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
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
                      ? 'Connected via RBI-regulated Setu Account Aggregator.${balanceAsync.value?['current_balance'] != null ? ' Balance: ${BankTransaction.formatRupees((balanceAsync.value!['current_balance'] as num).toDouble())}' : ''}'
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
                // [COMMENTED OUT FROM UI - DO NOT REMOVE]
                // SizedBox(
                //   width: double.infinity,
                //   child: ElevatedButton.icon(
                //     onPressed: () => _showLinkBankBottomSheet(context, ref),
                //     icon: Icon(
                //       hasActiveConsent ? Icons.sync_rounded : Icons.link_rounded,
                //       size: 16,
                //       color: DpcColors.textContrast,
                //     ),
                //     label: Text(
                //       hasActiveConsent ? 'Manage Bank Consent' : 'Connect Bank Account',
                //       style: const TextStyle(
                //         color: DpcColors.textContrast,
                //         fontSize: 13,
                //         fontWeight: FontWeight.w700,
                //       ),
                //     ),
                //     style: ElevatedButton.styleFrom(
                //       backgroundColor: DpcColors.accentPositive,
                //       elevation: 0,
                //       shape: RoundedRectangleBorder(
                //         borderRadius: BorderRadius.circular(14),
                //       ),
                //       padding: const EdgeInsets.symmetric(vertical: 12),
                //     ),
                //   ),
                // ),
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
                final authService = ref.read(authServiceProvider);
                ref.read(pdfStatementImportProvider.notifier).reset();
                ref.read(lastParsedPdfResultProvider.notifier).clear();
                ref.read(authBypassProvider.notifier).reset();
                ActiveConsentIdNotifier.deletePersistedConsent();
                ref.invalidate(currentUserProvider);
                ref.invalidate(userProfileProvider);
                ref.invalidate(cashflowRhythmProvider);
                ref.invalidate(recurringCommitmentsProvider);
                ref.invalidate(transactionFeedProvider);
                ref.invalidate(telemetryMetricsProvider);
                ref.invalidate(activeConsentIdProvider);
                ref.invalidate(hasActiveConsentProvider);
                ref.invalidate(chatMessagesProvider);
                ref.invalidate(setthiIcebreakerProvider);
                await authService.signOut();
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
              onPressed: () =>
                  _showDeleteAccountConfirmationModal(context, ref),
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
                backgroundColor: DpcColors.accentNegative.withValues(
                  alpha: 0.06,
                ),
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

  /// Displays dialog allowing user to edit and save their profile (Name, Date of Birth, Gender)
  Future<void> _showEditNameDialog(
    BuildContext context,
    WidgetRef ref,
    String currentName, {
    Map<String, dynamic>? profile,
  }) async {
    DateTime? initialDob;
    final rawDob = profile?['date_of_birth'] as String?;
    if (rawDob != null) {
      try {
        initialDob = DateTime.parse(rawDob);
      } catch (_) {}
    }

    double? initialMonthlyIncome;
    final rawIncome = profile?['expected_monthly_income'];
    if (rawIncome != null) {
      if (rawIncome is num) {
        initialMonthlyIncome = rawIncome.toDouble();
      } else {
        initialMonthlyIncome = double.tryParse(rawIncome.toString());
      }
    }

    await ProfileCompletionDialog.show(
      context,
      initialName: currentName == 'Setthi Member' ? null : currentName,
      initialDob: initialDob,
      initialGender: profile?['gender'] as String?,
      initialIncomeType: profile?['income_type'] as String?,
      initialMonthlyIncome: initialMonthlyIncome,
      isMandatory: false,
    );
  }

  /// Displays the confirmation bottom sheet for irreversible account and data deletion
  void _showDeleteAccountConfirmationModal(
    BuildContext context,
    WidgetRef ref,
  ) {
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
                          color: DpcColors.accentNegative.withValues(
                            alpha: 0.15,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: DpcColors.accentNegative.withValues(
                              alpha: 0.3,
                            ),
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
                        _buildPurgeBullet(
                          'All synced bank transactions and balance logs',
                        ),
                        _buildPurgeBullet(
                          'All Setu Account Aggregator consents and links',
                        ),
                        _buildPurgeBullet(
                          'Custom merchant categorizations and rules',
                        ),
                        _buildPurgeBullet(
                          'Setthi AI chat logs, prompt history, and nudges',
                        ),
                        _buildPurgeBullet(
                          'User profile credentials and active sessions',
                        ),
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
                          valueColor: AlwaysStoppedAnimation<Color>(
                            DpcColors.accentNegative,
                          ),
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
                            // 1. Purge account and database records without signing out immediately
                            final success = await ref
                                .read(authServiceProvider)
                                .deleteAccount(signOutAfter: false);

                            if (success) {
                              // 2. Dismiss the modal bottom sheet immediately while context is still valid
                              if (modalContext.mounted &&
                                  Navigator.of(modalContext).canPop()) {
                                Navigator.of(modalContext).pop();
                              } else if (context.mounted &&
                                  Navigator.of(
                                    context,
                                    rootNavigator: true,
                                  ).canPop()) {
                                Navigator.of(
                                  context,
                                  rootNavigator: true,
                                ).pop();
                              }

                              // 3. Clear local storage cache & provider states
                              ref.read(pdfStatementImportProvider.notifier).reset();
                              ref.read(lastParsedPdfResultProvider.notifier).clear();
                              ref.read(authBypassProvider.notifier).reset();
                              ActiveConsentIdNotifier.deletePersistedConsent();
                              ref.invalidate(currentUserProvider);
                              ref.invalidate(userProfileProvider);
                              ref.invalidate(cashflowRhythmProvider);
                              ref.invalidate(recurringCommitmentsProvider);
                              ref.invalidate(transactionFeedProvider);
                              ref.invalidate(telemetryMetricsProvider);
                              ref.invalidate(activeConsentIdProvider);
                              ref.invalidate(hasActiveConsentProvider);
                              ref.invalidate(chatMessagesProvider);
                              ref.invalidate(setthiIcebreakerProvider);

                              // 4. Show confirmation snackbar on the root messenger
                              rootScaffoldMessengerKey.currentState?.showSnackBar(
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
                                  content: const Row(
                                    children: [
                                      Icon(
                                        Icons.check_circle_rounded,
                                        color: DpcColors.accentPositive,
                                        size: 18,
                                      ),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Account and associated data deleted permanently.',
                                          style: TextStyle(
                                            color: DpcColors.textPrimary,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );

                              // 5. Sign out, which cleanly transitions SetthiApp to AuthScreen with NO modals open
                              await ref.read(authServiceProvider).signOut();
                            }
                          } catch (e) {
                            setModalState(() => isDeleting = false);
                            final errorMsg = e.toString().replaceFirst(
                              RegExp(r'^Exception:\s*'),
                              '',
                            );
                            rootScaffoldMessengerKey.currentState?.showSnackBar(
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
                                      Icons.error_outline_rounded,
                                      color: DpcColors.accentNegative,
                                      size: 18,
                                    ),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Failed to delete account: $errorMsg',
                                        style: const TextStyle(
                                          color: DpcColors.textPrimary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(
                          Icons.delete_forever_rounded,
                          size: 18,
                        ),
                        label: const Text(
                          'Permanently Delete Account',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: DpcColors.accentNegative,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
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
    return _buildSpendingInsightsScreen(
      context,
      ref,
      transactions,
      false,
      false,
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
    if (isSyncing) {
      return const DpcSyncingWaitingView();
    }

    if (!hasActiveConsent) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Setthi Mascot with Glowing pedestal
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: DpcColors.surfaceElevated,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: DpcColors.accentPositive.withValues(alpha: 0.15),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: const ClipOval(child: AiCompanionRiveWidget(size: 96)),
              ),
              const SizedBox(height: 18),

              // Persona Tag
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: DpcColors.surfaceBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: DpcColors.accentPositive,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'CONNECT YOUR BANK',
                      style: TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // Connect Your Bank Headline
              const Text(
                'Connect your bank to unlock Setthi.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                'Upload your bank statement PDF to get instant on-device cashflow analysis, daily safe limits, and AI insights.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 13,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 24),

              // Connect Your Bank CTA Button
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () {
                    SetthiOnboardingFlow.show(
                      context,
                      initialPage: 1,
                      onComplete: () {
                        // Immediately navigate into Setthi AI Chat with icebreaker ready
                        setState(() => _activeNavIndex = 0);
                      },
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DpcColors.accentPositive,
                    foregroundColor: DpcColors.textContrast,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Connect Your Bank',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      SizedBox(width: 8),
                      Icon(Icons.arrow_forward_rounded, size: 18),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Direct PDF Statement Link
              TextButton.icon(
                onPressed: () {
                  SetthiOnboardingFlow.show(
                    context,
                    initialPage: 1,
                    onComplete: () {
                      setState(() => _activeNavIndex = 0);
                    },
                  );
                },
                icon: const Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 16,
                  color: DpcColors.accentPositive,
                ),
                label: const Text(
                  'Import Bank Statement (PDF)',
                  style: TextStyle(
                    color: DpcColors.accentPositive,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

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
                color: DpcColors.accentPositive.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: const Icon(
              Icons.account_balance_rounded,
              size: 44,
              color: DpcColors.accentPositive,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Bank Connected Successfully',
            style: TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your Account Aggregator consent is active. Slide below to authorize Setthi to fetch and display your transactions.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),
          DpcSlideToConfirm(
            label: 'Slide to Fetch Transactions  ››',
            completedLabel: 'Authorizing & Fetching Records...',
            onConfirmed: () async {
              await ref
                  .read(transactionFeedProvider.notifier)
                  .syncTransactions();
            },
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () {
              SetthiOnboardingFlow.show(
                context,
                initialPage: 1,
                onComplete: () {
                  setState(() => _activeNavIndex = 0);
                },
              );
            },
            icon: const Icon(
              Icons.picture_as_pdf_outlined,
              size: 16,
              color: DpcColors.accentPositive,
            ),
            label: const Text(
              'Or Import Statement (PDF)',
              style: TextStyle(
                color: DpcColors.accentPositive,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
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
                // [COMMENTED OUT FROM UI - DO NOT REMOVE]
                // SizedBox(
                //   width: double.infinity,
                //   height: 46,
                //   child: ElevatedButton.icon(
                //     onPressed: () {
                //       ActiveConsentIdNotifier.deletePersistedConsent();
                //       ref.read(activeConsentIdProvider.notifier).clear();
                //       _showLinkBankBottomSheet(context, ref);
                //     },
                //     style: ElevatedButton.styleFrom(
                //       backgroundColor: DpcColors.accentPositive,
                //       foregroundColor: DpcColors.textContrast,
                //       elevation: 0,
                //       shape: RoundedRectangleBorder(
                //         borderRadius: BorderRadius.circular(14),
                //       ),
                //     ),
                //     icon: const Icon(Icons.add_link_rounded, size: 18),
                //     label: const Text(
                //       'Connect Bank Account',
                //       style: TextStyle(
                //         fontSize: 14,
                //         fontWeight: FontWeight.w700,
                //       ),
                //     ),
                //   ),
                // ),
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
                // [COMMENTED OUT FROM UI - DO NOT REMOVE]
                // SizedBox(
                //   width: double.infinity,
                //   height: 42,
                //   child: OutlinedButton(
                //     onPressed: () => _showLinkBankBottomSheet(context, ref),
                //     style: OutlinedButton.styleFrom(
                //       foregroundColor: DpcColors.textSecondary,
                //       side: const BorderSide(color: DpcColors.surfaceBorder),
                //       shape: RoundedRectangleBorder(
                //         borderRadius: BorderRadius.circular(14),
                //       ),
                //     ),
                //     child: const Text(
                //       'Link Different Bank',
                //       style: TextStyle(
                //         fontSize: 13,
                //         fontWeight: FontWeight.w600,
                //       ),
                //     ),
                //   ),
                // ),
              ],
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 42,
                child: TextButton.icon(
                  key: const Key('error_state_go_home_button'),
                  onPressed: () {
                    setState(() => _activeNavIndex = 2);
                    ref
                        .read(transactionFeedProvider.notifier)
                        .dismissErrorAndGoHome();
                  },
                  icon: const Icon(
                    Icons.home_outlined,
                    color: DpcColors.accentPositive,
                    size: 18,
                  ),
                  label: const Text(
                    'Go Back to Home',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
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

  // ==========================================
  // BOTTOM SHEETS & MODALS (DPC OLED STYLED)
  // ==========================================
  Future<void> _handleSyncAction(BuildContext context, WidgetRef ref) async {
    var hasActiveConsent = ref.read(hasActiveConsentProvider);
    if (!hasActiveConsent) {
      try {
        final user = ref.read(currentUserProvider);
        final dbService = ref.read(supabaseDbServiceProvider);
        final activeConsent = await dbService.fetchActiveConsent(userId: user?.id);
        if (activeConsent != null && activeConsent['consent_id'] != null) {
          final cid = activeConsent['consent_id'] as String;
          final aaService = ref.read(setuAaServiceProvider);
          final status = await aaService.checkConsentStatus(cid);
          if (status == 'ACTIVE') {
            ref.read(activeConsentIdProvider.notifier).setConsentId(cid);
            hasActiveConsent = true;
          } else {
            await dbService.updateConsentStatus(consentId: cid, status: status);
            ref.read(activeConsentIdProvider.notifier).clear();
          }
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
    }

    // Always perform a clean refresh of data without popping up any modal
    await ref.read(transactionFeedProvider.notifier).syncTransactions();
  }

  /// DPC Styled Link Bank Bottom Sheet
  // ignore: unused_element
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

    // Verify backend status to ensure consent is genuinely ACTIVE before opening permission sheet
    bool isApproved = false;
    if (approved == true) {
      try {
        final status = await aaService.checkConsentStatus(consentId);
        isApproved = (status == 'ACTIVE');
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 800));
        try {
          final retryStatus = await aaService.checkConsentStatus(consentId);
          isApproved = (retryStatus == 'ACTIVE');
        } catch (_) {
          isApproved = false;
        }
      }
    } else {
      try {
        final status = await aaService.checkConsentStatus(consentId);
        isApproved = (status == 'ACTIVE');
      } catch (_) {
        isApproved = false;
      }
    }

    if (!isApproved) {
      ref.read(pendingConsentIdProvider.notifier).clear();
      try {
        await ref
            .read(supabaseDbServiceProvider)
            .updateConsentStatus(consentId: consentId, status: 'CANCELLED');
      } catch (_) {}

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: DpcColors.surfaceDark,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: DpcColors.surfaceBorder),
            ),
            content: const Row(
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  color: DpcColors.textSecondary,
                  size: 18,
                ),
                SizedBox(width: 8),
                Text(
                  'Bank connection was cancelled',
                  style: TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    if (context.mounted) {
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
                            txn.isDebit ? 'Money Out (Debit)' : 'Money In (Credit)',
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
    final quickPresets = [
      if (txn.isCredit)
        (
          'Income',
          Icons.account_balance_wallet_rounded,
          const Color(0xFF22C55E),
        ),
      (
        'Eating out, tea & snacks',
        Icons.restaurant_rounded,
        const Color(0xFFFC8019),
      ),
      (
        'Groceries & daily needs',
        Icons.local_grocery_store_rounded,
        const Color(0xFF10B981),
      ),
      (
        'Local shops & stalls',
        Icons.store_rounded,
        const Color(0xFF3B82F6),
      ),
      (
        'Fuel',
        Icons.local_gas_station_rounded,
        const Color(0xFFF59E0B),
      ),
      (
        'Bills & recharge',
        Icons.receipt_long_rounded,
        const Color(0xFFEAB308),
      ),
      (
        'Shopping',
        Icons.shopping_bag_rounded,
        const Color(0xFFA855F7),
      ),
      (
        'Subscriptions & tools',
        Icons.subscriptions_rounded,
        const Color(0xFFEC4899),
      ),
      if (!txn.isCredit)
        (
          'Income',
          Icons.account_balance_wallet_rounded,
          const Color(0xFF22C55E),
        ),
      ('Custom', Icons.tune_rounded, const Color(0xFFB8F5D8)),
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
                  if (preset.$1 == 'Custom') {
                    Navigator.of(context).pop();
                    _showCategoryPickerModal(context, txn);
                    return;
                  }
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
                      Icon(preset.$2, size: 12, color: preset.$3),
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
      name: 'Custom',
      icon: Icons.tune_rounded,
      color: Color(0xFFB8F5D8),
    ),
    _CategoryPreset(
      name: 'Eating out, tea & snacks',
      icon: Icons.restaurant_rounded,
      color: Color(0xFFFC8019),
    ),
    _CategoryPreset(
      name: 'Groceries & daily needs',
      icon: Icons.local_grocery_store_rounded,
      color: Color(0xFF10B981),
    ),
    _CategoryPreset(
      name: 'Fuel',
      icon: Icons.local_gas_station_rounded,
      color: Color(0xFFF59E0B),
    ),
    _CategoryPreset(
      name: 'Gaming',
      icon: Icons.sports_esports_rounded,
      color: Color(0xFF8B5CF6),
    ),
    _CategoryPreset(
      name: 'Subscriptions & tools',
      icon: Icons.subscriptions_rounded,
      color: Color(0xFFEC4899),
    ),
    _CategoryPreset(
      name: 'Travel & transport',
      icon: Icons.directions_car_rounded,
      color: Color(0xFF06B6D4),
    ),
    _CategoryPreset(
      name: 'Movies & fun',
      icon: Icons.movie_rounded,
      color: Color(0xFFF43F5E),
    ),
    _CategoryPreset(
      name: 'Medical & pharmacy',
      icon: Icons.local_pharmacy_rounded,
      color: Color(0xFF14B8A6),
    ),
    _CategoryPreset(
      name: 'Bills & recharge',
      icon: Icons.receipt_long_rounded,
      color: Color(0xFFEAB308),
    ),
    _CategoryPreset(
      name: 'Shopping',
      icon: Icons.shopping_bag_rounded,
      color: Color(0xFFA855F7),
    ),
    _CategoryPreset(
      name: 'Pan shops & small stalls',
      icon: Icons.storefront_rounded,
      color: Color(0xFFFB923C),
    ),
    _CategoryPreset(
      name: 'Local shops & stalls',
      icon: Icons.store_rounded,
      color: Color(0xFF3B82F6),
    ),
    _CategoryPreset(
      name: 'Local shops',
      icon: Icons.shopping_cart_rounded,
      color: Color(0xFF6366F1),
    ),
    _CategoryPreset(
      name: 'Income',
      icon: Icons.account_balance_wallet_rounded,
      color: Color(0xFF22C55E),
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

  bool _isCustomActive(String? category) {
    if (category == null || category.trim().isEmpty) return false;
    final catLower = category.trim().toLowerCase();
    final isPreset = _presets
        .where((p) => p.name != 'Custom')
        .any((p) => p.name.toLowerCase() == catLower);
    return !isPreset;
  }

  void _selectCategory(String category) {
    HapticFeedback.lightImpact();
    widget.onCategorySelected(category);
    Navigator.of(context).pop();
  }

  void _showCustomCategoryDialog(BuildContext context) {
    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (dialogCtx) => _CustomCategoryDialog(
        merchantName: widget.txn.cleanMerchantName,
        initialValue: _isCustomActive(widget.txn.category)
            ? widget.txn.category
            : null,
        onApply: (category) {
          _selectCategory(category);
        },
      ),
    );
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
    final isCustomActive = _isCustomActive(widget.txn.category);

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
                                  color:
                                      (widget.txn.isCredit
                                              ? DpcColors.accentPositive
                                              : DpcColors.accentNegative)
                                          .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color:
                                        (widget.txn.isCredit
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

              const SizedBox(height: 12),

              // Dedicated "Custom" Category action bar (when search query is empty)
              if (_searchQuery.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: InkWell(
                    onTap: () => _showCustomCategoryDialog(context),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: isCustomActive
                            ? const Color(0xFFB8F5D8).withValues(alpha: 0.12)
                            : DpcColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isCustomActive
                              ? const Color(0xFFB8F5D8).withValues(alpha: 0.5)
                              : DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFB8F5D8,
                              ).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.tune_rounded,
                              size: 16,
                              color: Color(0xFFB8F5D8),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Custom Category',
                                      style: TextStyle(
                                        color: Color(0xFFB8F5D8),
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (isCustomActive &&
                                        widget.txn.category != null) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(
                                            0xFFB8F5D8,
                                          ).withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          widget.txn.category!,
                                          style: const TextStyle(
                                            color: Color(0xFFB8F5D8),
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isCustomActive && widget.txn.category != null
                                      ? 'Tap to edit or set another custom category'
                                      : 'Customly add a unique category name',
                                  style: const TextStyle(
                                    color: DpcColors.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.add_circle_outline_rounded,
                            size: 18,
                            color: Color(0xFFB8F5D8),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

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
                            color: const Color(
                              0xFFB8F5D8,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(
                                0xFFB8F5D8,
                              ).withValues(alpha: 0.4),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFFB8F5D8,
                                  ).withValues(alpha: 0.2),
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
                        final isCustom = preset.name == 'Custom';
                        final isCurrent = isCustom
                            ? isCustomActive
                            : widget.txn.category?.toLowerCase() ==
                                  preset.name.toLowerCase();

                        return InkWell(
                          onTap: () {
                            if (isCustom) {
                              _showCustomCategoryDialog(context);
                            } else {
                              _selectCategory(preset.name);
                            }
                          },
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
                                    isCustom &&
                                            isCustomActive &&
                                            widget.txn.category != null
                                        ? 'Custom (${widget.txn.category})'
                                        : preset.name,
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

/// Custom Category Dialog allowing user to customly add or edit a category
class _CustomCategoryDialog extends StatefulWidget {
  final String? initialValue;
  final String merchantName;
  final void Function(String category) onApply;

  const _CustomCategoryDialog({
    this.initialValue,
    required this.merchantName,
    required this.onApply,
  });

  @override
  State<_CustomCategoryDialog> createState() => _CustomCategoryDialogState();
}

class _CustomCategoryDialogState extends State<_CustomCategoryDialog> {
  late final TextEditingController _controller;
  bool _canSave = false;

  static const List<String> _popularSuggestions = [
    'Pet Care',
    'Fitness & Gym',
    'Freelance',
    'Gifts & Donations',
    'Rent & Maintenance',
    'Taxes & Legal',
    'Travel & Hotel',
    'Home Improvement',
  ];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue ?? '');
    _canSave = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final isValid = _controller.text.trim().isNotEmpty;
      if (isValid != _canSave) {
        setState(() => _canSave = isValid);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.lightImpact();
    Navigator.of(context).pop();
    widget.onApply(text);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: DpcColors.surfaceDark,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: const BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFB8F5D8).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFFB8F5D8).withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: const Icon(
                    Icons.tune_rounded,
                    size: 20,
                    color: Color(0xFFB8F5D8),
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Custom Category',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
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
            const SizedBox(height: 6),
            Text(
              'Set a personalized category for "${widget.merchantName}"',
              style: const TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 18),

            // Text Input
            Container(
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: _canSave
                      ? const Color(0xFFB8F5D8).withValues(alpha: 0.5)
                      : DpcColors.surfaceBorder,
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  const Icon(
                    Icons.label_outline_rounded,
                    color: DpcColors.textMuted,
                    size: 18,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      onSubmitted: (_) => _submit(),
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      cursorColor: const Color(0xFFB8F5D8),
                      decoration: const InputDecoration(
                        hintText: 'Enter category name...',
                        hintStyle: TextStyle(
                          color: DpcColors.textMuted,
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  if (_controller.text.isNotEmpty)
                    IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 16),
                      color: DpcColors.textMuted,
                      onPressed: () {
                        _controller.clear();
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Suggestions
            const Text(
              'SUGGESTIONS',
              style: TextStyle(
                color: DpcColors.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _popularSuggestions.map((suggestion) {
                final isSelected =
                    _controller.text.trim().toLowerCase() ==
                    suggestion.toLowerCase();
                return InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    _controller.text = suggestion;
                    _controller.selection = TextSelection.fromPosition(
                      TextPosition(offset: suggestion.length),
                    );
                  },
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFFB8F5D8).withValues(alpha: 0.15)
                          : DpcColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFFB8F5D8).withValues(alpha: 0.5)
                            : DpcColors.surfaceBorder,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      suggestion,
                      style: TextStyle(
                        color: isSelected
                            ? const Color(0xFFB8F5D8)
                            : DpcColors.textSecondary,
                        fontSize: 11.5,
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 22),

            // Action Buttons
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _canSave ? _submit : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB8F5D8),
                      disabledBackgroundColor: const Color(
                        0xFFB8F5D8,
                      ).withValues(alpha: 0.2),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      'Save Category',
                      style: TextStyle(
                        color: _canSave
                            ? Colors.black
                            : Colors.white.withValues(alpha: 0.3),
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Rich OLED Animated Bank Syncing & Decryption Waiting View
class DpcSyncingWaitingView extends StatefulWidget {
  const DpcSyncingWaitingView({super.key});

  @override
  State<DpcSyncingWaitingView> createState() => _DpcSyncingWaitingViewState();
}

class _DpcSyncingWaitingViewState extends State<DpcSyncingWaitingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  Timer? _stepTimer;
  int _currentStepIndex = 0;

  static const List<Map<String, String>> _steps = [
    {
      'title': 'Contacting Bank Gateway',
      'subtitle': 'Connecting via RBI Regulated Account Aggregator...',
    },
    {
      'title': 'Connecting Securely',
      'subtitle': 'Connecting with bank-level encryption...',
    },
    {
      'title': 'Fetching Transactions',
      'subtitle': 'Retrieving transactions and account balance...',
    },
    {
      'title': 'Organizing Your Transactions',
      'subtitle': 'Sorting merchants and calculating your budget...',
    },
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _stepTimer = Timer.periodic(const Duration(milliseconds: 2800), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_currentStepIndex < _steps.length - 1) {
        setState(() {
          _currentStepIndex++;
        });
      }
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    _stepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = _steps[_currentStepIndex];

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Container(
          padding: const EdgeInsets.all(26),
          decoration: DpcDecorations.cardBase(radius: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pulsing / Spinning Animated Halo
              Stack(
                alignment: Alignment.center,
                children: [
                  AnimatedBuilder(
                    animation: _animController,
                    builder: (context, child) {
                      return Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: DpcColors.accentPositive.withValues(
                              alpha: 0.15 + 0.25 * (1 - _animController.value),
                            ),
                            width: 1.5,
                          ),
                        ),
                      );
                    },
                  ),
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: DpcColors.accentPositive.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: DpcColors.accentPositive.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    child: RotationTransition(
                      turns: _animController,
                      child: const Icon(
                        Icons.sync_rounded,
                        color: DpcColors.accentPositive,
                        size: 30,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),

              // Title
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(
                  step['title']!,
                  key: ValueKey(step['title']),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 8),

              // Subtitle
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(
                  step['subtitle']!,
                  key: ValueKey(step['subtitle']),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 13,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Indeterminate Smooth Linear Progress
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: const LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: DpcColors.surfaceTrack,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    DpcColors.accentPositive,
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Security & Reassurance Tag
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: DpcColors.bgOled,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: DpcColors.surfaceBorder),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      color: DpcColors.accentPositive,
                      size: 14,
                    ),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'RBI Regulated AA • 256-Bit Encrypted Data',
                        style: TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
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
