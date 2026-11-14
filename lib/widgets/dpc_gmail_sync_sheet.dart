import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/gmail_sync_provider.dart';

/// Modal bottom sheet allowing users to connect Gmail and extract credit card
/// transactions and subscription invoices 100% on-device.
class DpcGmailSyncSheet extends ConsumerStatefulWidget {
  const DpcGmailSyncSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => const DpcGmailSyncSheet(),
    );
  }

  @override
  ConsumerState<DpcGmailSyncSheet> createState() => _DpcGmailSyncSheetState();
}

class _DpcGmailSyncSheetState extends ConsumerState<DpcGmailSyncSheet> {
  bool _forceFullScan = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) {
        ref.read(gmailSyncProvider.notifier).reset();
      }
    });
  }

  String _formatDateTime(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$minute $amPm';
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(gmailSyncProvider);
    final isSyncing = syncState.isSyncing;

    return Container(
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
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
        bottom: MediaQuery.of(context).padding.bottom + 20,
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: DpcColors.surfaceTrack,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFEA4335).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFFEA4335).withValues(alpha: 0.25),
                    width: 1,
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.mark_email_read_rounded,
                    color: Color(0xFFEA4335),
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gmail Sync',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Credit card charges & subscriptions',
                      style: TextStyle(
                        color: DpcColors.textSecondary.withValues(alpha: 0.9),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: isSyncing ? null : () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: DpcColors.textSecondary, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Content body
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Privacy Assurance Banner
                  _buildPrivacyBanner(),
                  const SizedBox(height: 14),

                  // If Syncing: Progress View
                  if (isSyncing) ...[
                    _buildSyncingProgress(syncState),
                  ] else if (syncState.status == GmailSyncStatus.completed) ...[
                    // Completed View
                    _buildCompletedSummary(syncState),
                  ] else ...[
                    // Idle or Error View
                    if (syncState.errorMessage != null) ...[
                      _buildErrorBanner(syncState.errorMessage!),
                      const SizedBox(height: 12),
                    ],
                    _buildIdleStatusCard(syncState),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Action Buttons
          _buildActionButtons(syncState),
        ],
      ),
    );
  }

  Widget _buildPrivacyBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DpcColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: DpcColors.accentPositive.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.lock_outline_rounded,
              size: 15,
              color: DpcColors.accentPositive,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '100% On-Device & Private',
                  style: TextStyle(
                    color: DpcColors.accentPositive,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Your raw email messages and Google authorization never leave this device. '
                  'Only extracted financial records are added to your personal account.',
                  style: TextStyle(
                    color: DpcColors.textSecondary.withValues(alpha: 0.85),
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdleStatusCard(GmailSyncState syncState) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DpcColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                syncState.isConnected
                    ? Icons.check_circle_rounded
                    : Icons.link_rounded,
                size: 16,
                color: syncState.isConnected
                    ? DpcColors.accentPositive
                    : DpcColors.accentPrimary,
              ),
              const SizedBox(width: 8),
              Text(
                syncState.isConnected ? 'Gmail Account Linked' : 'Connect Your Gmail',
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            syncState.isConnected
                ? 'Sync searches recent transaction alerts and subscription renewals to automatically keep your credit card expenses updated.'
                : 'Grant temporary read-only access to scan alerts from Indian banks (HDFC, ICICI, SBI, Axis, Amex, etc.) and popular subscription services.',
            style: const TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          const Divider(color: DpcColors.surfaceBorder, height: 1),
          const SizedBox(height: 12),

          // Last Sync details
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Last Synced',
                style: TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 12,
                ),
              ),
              Text(
                syncState.lastSyncTime != null
                    ? _formatDateTime(syncState.lastSyncTime!)
                    : 'Never',
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Full 90-day scan toggle
          InkWell(
            onTap: () {
              setState(() {
                _forceFullScan = !_forceFullScan;
              });
            },
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: _forceFullScan,
                      onChanged: (val) {
                        setState(() {
                          _forceFullScan = val ?? false;
                        });
                      },
                      activeColor: DpcColors.accentPositive,
                      checkColor: DpcColors.textContrast,
                      side: const BorderSide(color: DpcColors.surfaceTrack, width: 1.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Rescan past 90 days (ignores previous sync checkpoint)',
                      style: TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSyncingProgress(GmailSyncState syncState) {
    final hasMetrics = syncState.totalFound > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111114),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x1AFFFFFF), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  syncState.currentStepMessage ?? 'Scanning Gmail...',
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (hasMetrics)
                Text(
                  '${syncState.processedCount} of ${syncState.totalFound}',
                  style: const TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: syncState.status == GmailSyncStatus.fetching
                  ? syncState.progressRatio
                  : null,
              backgroundColor: const Color(0x0FFFFFFF),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
              minHeight: 2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompletedSummary(GmailSyncState syncState) {
    final txns = syncState.extractedTransactions;
    final subs = syncState.extractedSubscriptions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: DpcColors.surfaceElevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: DpcColors.accentPositive.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: DpcColors.accentPositive.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: DpcColors.accentPositive,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Sync Completed Successfully',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                syncState.currentStepMessage ?? 'All detected items have been saved.',
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),

              // Metric badges
              Row(
                children: [
                  Expanded(
                    child: _buildMetricTile(
                      icon: Icons.notifications_active_rounded,
                      label: 'ML Reminders',
                      value: '${syncState.newlySavedRemindersCount}',
                      color: const Color(0xFFF59E0B),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetricTile(
                      icon: Icons.credit_card_rounded,
                      label: 'Statements',
                      value: '${syncState.newlySavedTransactionsCount}',
                      color: DpcColors.accentPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildMetricTile(
                      icon: Icons.repeat_rounded,
                      label: 'Subs',
                      value: '${syncState.newlySavedSubscriptionsCount}',
                      color: DpcColors.accentPositive,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Preview list of detected transactions
        if (txns.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'EXTRACTED CREDIT CARD CHARGES',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          ...txns.take(5).map((t) => _buildTransactionPreviewItem(t)),
          if (txns.length > 5) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Center(
                child: Text(
                  '+ ${txns.length - 5} more transactions added to feed',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ),
          ],
        ],

        // Preview list of detected subscriptions
        if (subs.isNotEmpty) ...[
          const SizedBox(height: 16),
          const Text(
            'DISCOVERED SUBSCRIPTIONS',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          ...subs.map((s) => _buildSubscriptionPreviewItem(s)),
        ],
      ],
    );
  }

  Widget _buildMetricTile({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionPreviewItem(dynamic tx) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DpcColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: DpcColors.surfaceDark,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.credit_card,
              size: 14,
              color: DpcColors.accentPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.merchantName,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${tx.bankOrIssuer}${tx.cardLast4 != null ? " ••${tx.cardLast4}" : ""}',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Text(
            BankTransaction.formatRupees(tx.amount, showDecimals: false),
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionPreviewItem(dynamic sub) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DpcColors.surfaceElevated,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: DpcColors.accentPositive.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.all_inclusive_rounded,
              size: 14,
              color: DpcColors.accentPositive,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sub.serviceName,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${sub.frequency} • Typical day ${sub.typicalDueDay}',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          Text(
            BankTransaction.formatRupees(sub.expectedAmount, showDecimals: false),
            style: const TextStyle(
              color: DpcColors.accentPositive,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DpcColors.accentNegative.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: DpcColors.accentNegative.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 16,
            color: DpcColors.accentNegative,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: DpcColors.accentNegative,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons(GmailSyncState syncState) {
    final isSyncing = syncState.isSyncing;
    final isCompleted = syncState.status == GmailSyncStatus.completed;

    if (isCompleted) {
      return SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).pop(),
          style: ElevatedButton.styleFrom(
            backgroundColor: DpcColors.accentPositive,
            foregroundColor: DpcColors.textContrast,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            elevation: 0,
          ),
          child: const Text(
            'Done',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
      );
    }

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: isSyncing
                ? null
                : () {
                    ref.read(gmailSyncProvider.notifier).syncGmailTransactions(
                          forceFullSync: _forceFullScan,
                        );
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: DpcColors.accentPositive,
              foregroundColor: DpcColors.textContrast,
              disabledBackgroundColor: DpcColors.surfaceTrack,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              elevation: 0,
            ),
            child: isSyncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(DpcColors.textSecondary),
                    ),
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.sync_rounded, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        syncState.isConnected ? 'Sync Gmail Now' : 'Connect & Sync Gmail',
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        if (syncState.isConnected && !isSyncing) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: () {
                ref.read(gmailSyncProvider.notifier).disconnectGmail();
              },
              child: const Text(
                'Disconnect Gmail',
                style: TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
