import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/transaction_model.dart';
import '../providers/transaction_providers.dart';
import '../services/setu_aa_service.dart';
import 'setu_consent_webview.dart';

class TransactionFeedScreen extends ConsumerWidget {
  const TransactionFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transactionFeedAsync = ref.watch(transactionFeedProvider);
    final hasActiveConsent = ref.watch(hasActiveConsentProvider);
    final isSyncing = transactionFeedAsync.isLoading;

    const bgColor = Color(0xFF0F1015);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: _buildAppBar(context, ref, isSyncing, hasActiveConsent),
      body: RefreshIndicator(
        onRefresh: () => _handleSyncAction(context, ref),
        color: const Color(0xFF00FFA3),
        backgroundColor: const Color(0xFF1E202B),
        child: transactionFeedAsync.when(
          data: (transactions) => _buildContent(
            context,
            ref,
            transactions,
            hasActiveConsent,
          ),
          loading: () {
            if (transactionFeedAsync.hasValue) {
              return _buildContent(
                context,
                ref,
                transactionFeedAsync.value!,
                hasActiveConsent,
              );
            }
            return _buildSkeletonLoader();
          },
          error: (err, stack) {
            if (transactionFeedAsync.hasValue &&
                transactionFeedAsync.value!.isNotEmpty) {
              return _buildContent(
                context,
                ref,
                transactionFeedAsync.value!,
                hasActiveConsent,
              );
            }
            return _buildErrorState(context, ref, err.toString());
          },
        ),
      ),
    );
  }

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
              backgroundColor: Color(0xFF171922),
              content: Row(
                children: [
                  Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFF00FFA3),
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Bank linked & transactions synced!',
                    style: TextStyle(color: Colors.white),
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

  PreferredSizeWidget _buildAppBar(
    BuildContext context,
    WidgetRef ref,
    bool isSyncing,
    bool hasActiveConsent,
  ) {
    return AppBar(
      elevation: 0,
      backgroundColor: const Color(0xFF0F1015),
      surfaceTintColor: Colors.transparent,
      titleSpacing: 20,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF8B5CF6), Color(0xFF00FFA3)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.bolt_rounded,
              color: Colors.black,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Setthi',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: hasActiveConsent
                          ? const Color(0xFF00FFA3)
                          : const Color(0xFFFFC107),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    isSyncing
                        ? 'Syncing Setu AA...'
                        : hasActiveConsent
                            ? 'Live Feed • AA Linked'
                            : 'Setu AA Gateway',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: hasActiveConsent ? 'Sync Transactions' : 'Link Bank & Sync',
          onPressed: isSyncing ? null : () => _handleSyncAction(context, ref),
          icon: isSyncing
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFF00FFA3),
                  ),
                )
              : const Icon(Icons.sync_rounded, color: Colors.white),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    WidgetRef ref,
    List<BankTransaction> transactions,
    bool hasActiveConsent,
  ) {
    final balance = ref.watch(latestBalanceProvider);
    final weeklyStats = ref.watch(weeklyStatsProvider);
    final grouped = ref.watch(groupedTransactionsProvider);
    final isSyncing = ref.watch(transactionFeedProvider).isLoading;

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              children: [
                _buildHeaderCard(
                  balance,
                  weeklyStats.spent,
                  weeklyStats.inflow,
                  hasActiveConsent,
                ),
                const SizedBox(height: 16),
                _buildActionBar(context, ref, isSyncing, hasActiveConsent),
              ],
            ),
          ),
        ),
        if (transactions.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF171922),
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0xFF262835)),
                    ),
                    child: Icon(
                      hasActiveConsent
                          ? Icons.receipt_long_rounded
                          : Icons.account_balance_rounded,
                      size: 40,
                      color: const Color(0xFF00FFA3),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    hasActiveConsent
                        ? 'No Transactions Found'
                        : 'No Bank Account Linked',
                    style: const TextStyle(
                      color: Colors.white,
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
                      color: Color(0xFF94A3B8),
                      fontSize: 13,
                    ),
                  ),
                  if (!hasActiveConsent) ...[
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => _showLinkBankBottomSheet(context, ref),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FFA3),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.link_rounded),
                      label: const Text(
                        'Link Bank Account',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 24),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        ElevatedButton.icon(
                          onPressed: isSyncing
                              ? null
                              : () => ref
                                  .read(transactionFeedProvider.notifier)
                                  .syncTransactions(),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FFA3),
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                          ),
                          icon: isSyncing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Icon(Icons.sync_rounded, size: 18),
                          label: Text(
                            isSyncing ? 'Syncing...' : 'Sync Transactions',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: () =>
                              _showLinkBankBottomSheet(context, ref),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF262835)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          icon: const Icon(
                            Icons.add_link_rounded,
                            size: 18,
                            color: Colors.white70,
                          ),
                          label: const Text(
                            'Re-link Account (Full History)',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                        padding: const EdgeInsets.only(top: 14, bottom: 10),
                        child: Row(
                          children: [
                            Text(
                              groupTitle.toUpperCase(),
                              style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Container(
                                height: 1,
                                color: const Color(0xFF262833),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${items.length} txns',
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF171922),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF262835),
                            width: 1,
                          ),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: items.length,
                          separatorBuilder: (context, _) => const Divider(
                            height: 1,
                            thickness: 1,
                            color: Color(0xFF222430),
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
          child: SizedBox(height: 32),
        ),
      ],
    );
  }

  Widget _buildHeaderCard(
    double balance,
    double spent,
    double inflow,
    bool hasActiveConsent,
  ) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF1E1B38),
            Color(0xFF171924),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFF3B2F63),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF8B5CF6).withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: (hasActiveConsent
                          ? const Color(0xFF00FFA3)
                          : const Color(0xFF8B5CF6))
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: (hasActiveConsent
                            ? const Color(0xFF00FFA3)
                            : const Color(0xFF8B5CF6))
                        .withValues(alpha: 0.35),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      hasActiveConsent
                          ? Icons.verified_rounded
                          : Icons.shield_outlined,
                      size: 13,
                      color: hasActiveConsent
                          ? const Color(0xFF00FFA3)
                          : const Color(0xFF8B5CF6),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      hasActiveConsent
                          ? 'Verified via Account Aggregator'
                          : 'Setu AA ReBIT Gateway',
                      style: TextStyle(
                        color: hasActiveConsent
                            ? const Color(0xFF00FFA3)
                            : const Color(0xFF8B5CF6),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.account_balance_outlined,
                color: Color(0xFF8B5CF6),
                size: 20,
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'TOTAL AVAILABLE BALANCE',
            style: TextStyle(
              color: Colors.grey[400],
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                BankTransaction.formatRupees(balance),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF262833),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'INR',
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF12131A).withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF262835),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF5C5C).withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_upward_rounded,
                          size: 14,
                          color: Color(0xFFFF5C5C),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Spent this week',
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              BankTransaction.formatRupees(spent),
                              style: const TextStyle(
                                color: Color(0xFFFF5C5C),
                                fontSize: 13,
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
                  color: const Color(0xFF262835),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00FFA3).withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_downward_rounded,
                          size: 14,
                          color: Color(0xFF00FFA3),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Total Inflow',
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              BankTransaction.formatRupees(inflow),
                              style: const TextStyle(
                                color: Color(0xFF00FFA3),
                                fontSize: 13,
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
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar(
    BuildContext context,
    WidgetRef ref,
    bool isSyncing,
    bool hasActiveConsent,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF171922),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF262835),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: () => _showLinkBankBottomSheet(context, ref),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                const Icon(
                  Icons.hub_rounded,
                  size: 16,
                  color: Color(0xFF8B5CF6),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Setu ReBIT Gateway',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      hasActiveConsent
                          ? 'Consent Active • Live AA'
                          : 'Tap to Link Bank',
                      style: TextStyle(
                        color: hasActiveConsent
                            ? const Color(0xFF00FFA3)
                            : Colors.grey[500],
                        fontSize: 10,
                        fontWeight: hasActiveConsent ? FontWeight.w600 : FontWeight.w400,
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
              backgroundColor: const Color(0xFF00FFA3),
              foregroundColor: Colors.black,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: isSyncing
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.black,
                    ),
                  )
                : Icon(
                    hasActiveConsent ? Icons.sync_rounded : Icons.link_rounded,
                    size: 16,
                    color: Colors.black,
                  ),
            label: Text(
              isSyncing
                  ? 'Syncing...'
                  : hasActiveConsent
                      ? 'Sync Transactions'
                      : 'Link Bank',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.1,
              ),
            ),
          ),
        ],
      ),
    );
  }

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
      backgroundColor: const Color(0xFF171922),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (modalContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: MediaQuery.of(modalContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2D3040),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00FFA3).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.account_balance_rounded,
                          color: Color(0xFF00FFA3),
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
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Text(
                            'Setu ReBIT Gateway (RBI Regulated)',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
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
                      color: Color(0xFF94A3B8),
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
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFF0F1015),
                      prefixIcon: const Icon(
                        Icons.phone_iphone_rounded,
                        color: Color(0xFF8B5CF6),
                        size: 20,
                      ),
                      hintText: 'Enter 10-digit mobile number',
                      hintStyle: const TextStyle(color: Colors.white38),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF262835)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF262835)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF00FFA3)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Setu AA will send a secure verification OTP to this mobile number.',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 11,
                    ),
                  ),
                  if (errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5C5C).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFFF5C5C).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFFFF5C5C),
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorMessage!,
                              style: const TextStyle(
                                color: Color(0xFFFF5C5C),
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      onPressed: isCreatingConsent
                          ? null
                          : () async {
                              final phone = phoneController.text.trim();
                              if (phone.length < 10) {
                                setModalState(() {
                                  errorMessage = 'Please enter a valid 10-digit mobile number';
                                });
                                return;
                              }

                              setModalState(() {
                                isCreatingConsent = true;
                                errorMessage = null;
                              });

                              try {
                                final aaService = ref.read(setuAaServiceProvider);
                                final consentResult = await aaService.createConsent(
                                  mobileNumber: phone,
                                );

                                final consentUrl = consentResult['url']!;
                                final consentId = consentResult['consentId']!;

                                if (modalContext.mounted) {
                                  Navigator.of(modalContext).pop();
                                }

                                if (context.mounted) {
                                  final approved = await Navigator.of(context).push<bool>(
                                    MaterialPageRoute(
                                      builder: (ctx) => SetuConsentWebView(
                                        consentUrl: consentUrl,
                                        consentId: consentId,
                                        aaService: aaService,
                                      ),
                                    ),
                                  );

                                  if (context.mounted) {
                                    await _finalizeBankConnection(
                                      context: context,
                                      ref: ref,
                                      consentId: consentId,
                                      aaService: aaService,
                                      wasApprovedInWebView: approved == true,
                                    );
                                  }
                                }
                              } catch (e) {
                                setModalState(() {
                                  isCreatingConsent = false;
                                  errorMessage = e.toString();
                                });
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FFA3),
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: isCreatingConsent
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : const Text(
                              'Connect Bank via Setu AA',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                  if (ref.read(pendingConsentIdProvider) != null) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: OutlinedButton.icon(
                        onPressed: isCreatingConsent
                            ? null
                            : () async {
                                final pendingId = ref.read(pendingConsentIdProvider)!;
                                setModalState(() {
                                  isCreatingConsent = true;
                                  errorMessage = null;
                                });
                                try {
                                  final success = await ref
                                      .read(transactionFeedProvider.notifier)
                                      .checkAndSyncConsent(pendingId);
                                  if (success) {
                                    if (modalContext.mounted) {
                                      Navigator.of(modalContext).pop();
                                    }
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          backgroundColor: Color(0xFF171922),
                                          content: Row(
                                            children: [
                                              Icon(
                                                Icons.check_circle_rounded,
                                                color: Color(0xFF00FFA3),
                                              ),
                                              SizedBox(width: 8),
                                              Text(
                                                'Consent active! Bank account linked & synced.',
                                                style: TextStyle(color: Colors.white),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                    }
                                  } else {
                                    final status = await ref
                                        .read(setuAaServiceProvider)
                                        .checkConsentStatus(pendingId);
                                    setModalState(() {
                                      isCreatingConsent = false;
                                      errorMessage =
                                          'Consent status is "$status". If you completed the OTP flow, Setu may take a few moments to activate, or try connecting again.';
                                    });
                                  }
                                } catch (e) {
                                  setModalState(() {
                                    isCreatingConsent = false;
                                    errorMessage = e.toString();
                                  });
                                }
                              },
                        icon: const Icon(
                          Icons.refresh_rounded,
                          size: 18,
                          color: Color(0xFF00FFA3),
                        ),
                        label: const Text(
                          'Check Status of Last Connected Bank',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF262835)),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
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

  /// Seamlessly finalizes bank connection upon returning from Setu AA flow.
  /// Displays a non-dismissible loading dialog with real-time feedback,
  /// verifies consent status, immediately fetches data, and updates UI state.
  Future<void> _finalizeBankConnection({
    required BuildContext context,
    required WidgetRef ref,
    required String consentId,
    required SetuAaService aaService,
    required bool wasApprovedInWebView,
  }) async {
    final statusNotifier = ValueNotifier<String>(
      wasApprovedInWebView
          ? 'Consent approved! Fetching bank transactions...'
          : 'Verifying Setu AA consent approval...',
    );

    // Show sleek, non-dismissible loading dialog with live status
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.75),
      builder: (dialogCtx) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: const Color(0xFF171922),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF262835)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00FFA3)),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Connecting Bank Feed',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                ValueListenableBuilder<String>(
                  valueListenable: statusNotifier,
                  builder: (context, statusText, _) => Text(
                    statusText,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    bool isApproved = wasApprovedInWebView;
    String? errorMessage;

    try {
      if (!isApproved) {
        // Poll for ACTIVE status up to 10 times (every 1.3s = ~13s total)
        for (int attempt = 0; attempt < 10; attempt++) {
          try {
            final status = await aaService.checkConsentStatus(consentId);
            if (status == 'ACTIVE') {
              isApproved = true;
              break;
            } else if (status == 'REJECTED' || status == 'EXPIRED') {
              errorMessage = 'Bank consent was $status.';
              break;
            }
          } catch (_) {}
          if (attempt < 9) {
            await Future.delayed(const Duration(milliseconds: 1300));
          }
        }
      }

      if (isApproved) {
        statusNotifier.value = 'Consent verified! Decrypting bank feed...';
        await ref
            .read(transactionFeedProvider.notifier)
            .setConsentAndSync(consentId);
      } else if (errorMessage == null) {
        ref.read(pendingConsentIdProvider.notifier).set(consentId);
      }
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }

    if (!context.mounted) return;

    if (isApproved && errorMessage == null) {
      final txnCount = ref.read(transactionFeedProvider).value?.length ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF171922),
          content: Row(
            children: [
              const Icon(Icons.check_circle_rounded, color: Color(0xFF00FFA3)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  txnCount > 0
                      ? 'Bank linked! $txnCount transactions synced.'
                      : 'Bank linked successfully!',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF171922),
          content: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: Color(0xFFFF5252)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  errorMessage,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF171922),
          content: Row(
            children: [
              Icon(Icons.hourglass_empty_rounded, color: Colors.amberAccent),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Bank approval is being processed. Pull down to refresh in a moment.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildTransactionTile(BuildContext context, BankTransaction txn) {
    final accent = txn.accentColor;
    final isDebit = txn.isDebit;

    return InkWell(
      onTap: () => _showTransactionDetailsModal(context, txn),
      borderRadius: BorderRadius.circular(12),
      splashColor: const Color(0xFF8B5CF6).withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: accent.withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
              child: Icon(
                txn.icon,
                color: accent,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
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
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
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
                          color: const Color(0xFF262835),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          txn.mode,
                          style: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    txn.narration,
                    style: TextStyle(
                      color: Colors.grey[500],
                      fontSize: 11,
                      overflow: TextOverflow.ellipsis,
                    ),
                    maxLines: 1,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    txn.formattedDate,
                    style: const TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${isDebit ? '- ' : '+ '}${txn.formattedAmount}',
                  style: TextStyle(
                    color: isDebit
                        ? const Color(0xFFFF5C5C)
                        : const Color(0xFF00FFA3),
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Bal: ${txn.formattedBalance}',
                  style: const TextStyle(
                    color: Color(0xFF64748B),
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

  void _showTransactionDetailsModal(BuildContext context, BankTransaction txn) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF171922),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2D3040),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: txn.accentColor.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(txn.icon, color: txn.accentColor, size: 22),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              txn.cleanMerchantName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              txn.type.value,
                              style: TextStyle(
                                color: txn.isDebit
                                    ? const Color(0xFFFF5C5C)
                                    : const Color(0xFF00FFA3),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Text(
                      '${txn.isDebit ? '-' : '+'}${txn.formattedAmount}',
                      style: TextStyle(
                        color: txn.isDebit
                            ? const Color(0xFFFF5C5C)
                            : const Color(0xFF00FFA3),
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F1015),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF262835)),
                  ),
                  child: Column(
                    children: [
                      _buildDetailRow('Txn ID', txn.txnId),
                      const Divider(color: Color(0xFF222430), height: 16),
                      _buildDetailRow('Payment Mode', txn.mode),
                      const Divider(color: Color(0xFF222430), height: 16),
                      _buildDetailRow(
                        'Timestamp',
                        txn.transactionTimestamp.toIso8601String(),
                      ),
                      const Divider(color: Color(0xFF222430), height: 16),
                      _buildDetailRow('Post-Txn Balance', txn.formattedBalance),
                      const Divider(color: Color(0xFF222430), height: 16),
                      _buildDetailRow('Raw Narration', txn.narration),
                    ],
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF64748B),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSkeletonLoader() {
    return ListView(
      padding: const EdgeInsets.all(16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        Container(
          height: 180,
          decoration: BoxDecoration(
            color: const Color(0xFF171922),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF262835)),
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 180,
                height: 20,
                decoration: BoxDecoration(
                  color: const Color(0xFF262835),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                width: 120,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFF262835),
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 200,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF262835),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        for (int i = 0; i < 5; i++) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF171922),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF262835),
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 120,
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF262835),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: 180,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFF222430),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 60,
                  height: 16,
                  decoration: BoxDecoration(
                    color: const Color(0xFF262835),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ],
            ),
          ),
        ],
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
            const Icon(
              Icons.cloud_off_rounded,
              size: 56,
              color: Color(0xFFFF5C5C),
            ),
            const SizedBox(height: 16),
            const Text(
              'AA Data Sync Failed',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: () => _handleSyncAction(context, ref),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00FFA3),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                  ),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text(
                    'Retry Sync',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _showLinkBankBottomSheet(context, ref),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF262835)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  icon: const Icon(Icons.link_rounded),
                  label: const Text('Link Bank'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
