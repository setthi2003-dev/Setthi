import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../config/supabase_config.dart';
import '../models/reminder_model.dart';
import '../models/transaction_model.dart';
import '../providers/auth_providers.dart';
import '../providers/gmail_sync_provider.dart';
import '../providers/supabase_provider.dart';
import '../providers/transaction_providers.dart';
import '../services/email_transaction_parser.dart';
import '../services/slice_credit_card_pdf_parser_service.dart';
import '../services/supabase_db_service.dart';

/// Dedicated full screen for connecting Gmail and viewing on-device financial sync status,
/// extracted credit card statements, and discovered recurring subscriptions.
class GmailSyncScreen extends ConsumerStatefulWidget {
  final VoidCallback? onBackToInsights;

  const GmailSyncScreen({
    super.key,
    this.onBackToInsights,
  });

  @override
  ConsumerState<GmailSyncScreen> createState() => _GmailSyncScreenState();
}

class _GmailSyncScreenState extends ConsumerState<GmailSyncScreen> {
  bool _forceFullScan = false;
  int _selectedPreviewTab = 0; // 0: Statements, 1: Subscriptions

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(currentUserProvider);
      if (user != null) {
        ref.read(supabaseDbServiceProvider).clearLegacyExtractedSubscriptions(userId: user.id);
        ref.invalidate(remindersProvider);
        ref.invalidate(recurringCommitmentsProvider);
      }
    });
  }

  String _formatDateTime(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds >= 0 && diff.inSeconds < 60) {
      return 'just now';
    }
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final amPm = dt.hour >= 12 ? 'PM' : 'AM';
    final minute = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour:$minute $amPm';
  }

  String _formatDateOnly(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(gmailSyncProvider);
    final user = ref.watch(currentUserProvider);
    final isSyncing = syncState.isSyncing;
    final canGoBack =
        Navigator.canPop(context) || widget.onBackToInsights != null;

    // Listen for sync completion to provide instant tactile & visual feedback via a single floating HUD toast
    ref.listen<GmailSyncState>(gmailSyncProvider, (previous, next) {
      if (previous?.isSyncing == true && !next.isSyncing) {
        if (next.status == GmailSyncStatus.completed) {
          HapticFeedback.lightImpact();
          final newCount = (next.newlySavedRemindersCount ?? 0) + (next.newlySavedTransactionsCount ?? 0);
          final hasNew = newCount > 0;
          final msg = hasNew
              ? 'Sync complete! $newCount new financial item${newCount == 1 ? '' : 's'} added.'
              : 'All caught up! No new financial emails found.';

          if (mounted) {
            // Trigger single sleek floating HUD toast above floating dock
            ScaffoldMessenger.of(context).clearSnackBars();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFF16161A),
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                elevation: 6,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(
                    color: hasNew
                        ? DpcColors.accentPositive.withValues(alpha: 0.35)
                        : const Color(0x26FFFFFF),
                    width: 1,
                  ),
                ),
                content: Row(
                  children: [
                    Icon(
                      hasNew ? Icons.check_circle_rounded : Icons.task_alt_rounded,
                      color: DpcColors.accentPositive,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        msg,
                        style: const TextStyle(
                          color: DpcColors.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
        }
      }
    });

    return Scaffold(
      backgroundColor: DpcColors.bgOled,
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: 130, // Margin above the floating navigation dock
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (canGoBack) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      if (widget.onBackToInsights != null) {
                        widget.onBackToInsights!();
                      } else if (Navigator.canPop(context)) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Unified Luxury Hero Header
              _buildUnifiedHeroHeader(syncState, user?.email, isSyncing),
              const SizedBox(height: 28),

              // Live Syncing Progress Card
              if (isSyncing) ...[
                _buildSyncingProgressCard(syncState),
                const SizedBox(height: 20),
              ] else if (syncState.errorMessage != null) ...[
                _buildErrorCard(syncState.errorMessage!),
                const SizedBox(height: 20),
              ],

              // Synced Activity Section (Unboxed, clean obsidian cards)
              _buildExtractedActivitySection(syncState),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnifiedHeroHeader(
    GmailSyncState syncState,
    String? email,
    bool isSyncing,
  ) {
    final isConnected = syncState.isConnected;
    final displayEmail = syncState.connectedEmail ?? email;

    return Column(
      children: [
        const SizedBox(height: 8),

        // Gmail squircle emblem
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFFEA4335),
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFEA4335).withValues(alpha: 0.25),
                blurRadius: 14,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Center(
            child: Icon(
              Icons.mark_email_read_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Bold, modern title
        const Text(
          'Gmail Sync',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),

        // Account status pill
        if (isConnected)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(20),
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
                    boxShadow: [
                      BoxShadow(
                        color: DpcColors.accentPositive,
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    displayEmail ?? 'Google Account',
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: isSyncing ? null : () => _confirmDisconnect(context),
                  borderRadius: BorderRadius.circular(10),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: DpcColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          const Text(
            'Sync credit card alerts & subscriptions privately',
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 13,
            ),
          ),

        const SizedBox(height: 22),

        // Primary High-Contrast Stark Action Button (White Pill)
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: isSyncing
                ? null
                : () {
                    ref.read(gmailSyncProvider.notifier).syncGmailTransactions(
                          forceFullSync: _forceFullScan,
                        );
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              disabledBackgroundColor: const Color(0xFF18181C),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            child: isSyncing
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Syncing with Gmail...',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isConnected ? Icons.sync_rounded : Icons.add_link_rounded,
                        size: 20,
                        color: Colors.black,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isConnected ? 'Sync Transactions' : 'Connect Gmail Account',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 12),

        // Sub-controls / Metadata row
        if (isConnected)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (syncState.lastSyncTime != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 12,
                        color: DpcColors.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Synced ${_formatDateTime(syncState.lastSyncTime!)}',
                        style: const TextStyle(
                          color: DpcColors.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),

                // [COMMENTED OUT FROM UI - DO NOT REMOVE LOGIC]
                // Full 90d scan toggle UI
                /*
                InkWell(
                  onTap: isSyncing
                      ? null
                      : () {
                          setState(() {
                            _forceFullScan = !_forceFullScan;
                          });
                        },
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: Checkbox(
                            value: _forceFullScan,
                            onChanged: isSyncing
                                ? null
                                : (v) {
                                    setState(() {
                                      _forceFullScan = v ?? false;
                                    });
                                  },
                            activeColor: Colors.white,
                            checkColor: Colors.black,
                            side: const BorderSide(
                              color: DpcColors.textMuted,
                              width: 1.2,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Full 90d scan',
                          style: TextStyle(
                            color: DpcColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                */
              ],
            ),
          )
        else
          const Center(
            child: Text(
              'Read-only • 100% on-device parsing • Bank-grade privacy',
              style: TextStyle(
                color: DpcColors.textMuted,
                fontSize: 11.5,
              ),
            ),
          ),
      ],
    );
  }


  Widget _buildSyncingProgressCard(GmailSyncState syncState) {
    final hasMetrics = syncState.totalFound > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111114),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0x1AFFFFFF),
          width: 1,
        ),
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

  Widget _buildErrorCard(String errorMessage) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DpcColors.accentNegative.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DpcColors.accentNegative.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, size: 18, color: DpcColors.accentNegative),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              errorMessage,
              style: const TextStyle(color: DpcColors.accentNegative, fontSize: 12, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }


  void _confirmDisconnect(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DpcColors.surfaceDark,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: DpcColors.surfaceBorder),
        ),
        title: const Text(
          'Disconnect Gmail?',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: const Text(
          'Setthi will stop syncing transactions and subscriptions from your Gmail. Already saved records will remain in your account.',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              'Cancel',
              style: TextStyle(color: DpcColors.textMuted),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              ref.read(gmailSyncProvider.notifier).disconnectGmail();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: DpcColors.accentNegative.withValues(alpha: 0.2),
              foregroundColor: DpcColors.accentNegative,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Disconnect',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildExtractedActivitySection(GmailSyncState syncState) {
    // Watch reminders strictly from Supabase ML pipeline (GLiClass + GLiNER)
    final remindersAsync = ref.watch(remindersProvider);
    final remindersList = remindersAsync.asData?.value ?? syncState.savedReminders;

    // Partition exclusively by ML classification labels
    final mlReminders = remindersList.where((r) => r.type == ReminderType.trialEnding).toList();
    final mlStatements = remindersList.where((r) => r.type == ReminderType.creditCardStatement).toList();
    final mlSubs = remindersList.where((r) => r.type == ReminderType.subscription).toList();

    final reminderCount = mlReminders.length;
    final stmtCount = mlStatements.length;
    final subCount = mlSubs.length;
    final totalRecords = reminderCount + stmtCount + subCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section Header Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'SYNCED ACTIVITY',
              style: TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.3,
              ),
            ),
            if (totalRecords > 0)
              Text(
                '$totalRecords records',
                style: const TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 11,
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),

        // Segmented Stadium Tabs: Reminders, Statements & Subscriptions
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: _buildTabButton(
                  title: 'Reminders ($reminderCount)',
                  isSelected: _selectedPreviewTab == 0,
                  onTap: () => setState(() => _selectedPreviewTab = 0),
                ),
              ),
              Expanded(
                child: _buildTabButton(
                  title: 'Statements ($stmtCount)',
                  isSelected: _selectedPreviewTab == 1,
                  onTap: () => setState(() => _selectedPreviewTab = 1),
                ),
              ),
              Expanded(
                child: _buildTabButton(
                  title: 'Subs ($subCount)',
                  isSelected: _selectedPreviewTab == 2,
                  onTap: () => setState(() => _selectedPreviewTab = 2),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        if (_selectedPreviewTab == 0) ...[
          if (mlReminders.isNotEmpty)
            ...mlReminders.map((r) => _buildReminderCard(r))
          else
            _buildEmptyState('No trial ending reminders detected yet. Tap Sync above to scan alerts.'),
        ] else if (_selectedPreviewTab == 1) ...[
          if (mlStatements.isNotEmpty)
            ...mlStatements.map((r) => _buildReminderCard(r))
          else
            _buildEmptyState('No credit card statements found yet. Tap Sync above to scan.'),
        ] else ...[
          if (mlSubs.isNotEmpty)
            ...mlSubs.map((r) => _buildReminderCard(r))
          else
            _buildEmptyState('No recurring subscriptions detected.'),
        ],
      ],
    );
  }

  String _formatCleanProvider(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return 'Notice';
    if (s.toLowerCase() == 'slice') return 'Slice';
    if (s.toLowerCase().contains('godaddy')) return 'GoDaddy';
    if (s.toLowerCase().contains('linkedin')) {
      final parts = s.split(':');
      return parts.first.trim();
    }
    if (s == s.toLowerCase() && s.length > 1) {
      return s[0].toUpperCase() + s.substring(1);
    }
    return s;
  }

  String _formatCleanAmount(double? amount) {
    if (amount == null) return '--';
    return BankTransaction.formatRupees(amount, showDecimals: true);
  }

  Widget _buildReminderCard(ReminderModel reminder) {
    final title = _formatCleanProvider(reminder.provider);
    final amountStr = _formatCleanAmount(reminder.amount);
    final dueDateStr = reminder.dueDate != null
        ? _formatDateOnly(reminder.dueDate!)
        : null;

    String subtitle;
    switch (reminder.type) {
      case ReminderType.creditCardStatement:
        subtitle = dueDateStr != null ? 'Statement • Due $dueDateStr' : 'Credit Card Statement';
        break;
      case ReminderType.trialEnding:
        subtitle = dueDateStr != null ? 'Free Trial • Ends $dueDateStr' : 'Free Trial';
        break;
      case ReminderType.subscription:
        subtitle = dueDateStr != null ? 'Subscription • Renews $dueDateStr' : 'Active Subscription';
        break;
    }

    final isStatement = reminder.type == ReminderType.creditCardStatement;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111114),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.07),
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: isStatement
              ? () => _showCreditCardTransactionsSheet(
                    context,
                    reminder.metadata?['card_last4']?.toString(),
                    title,
                    reminder.metadata?['billing_cycle']?.toString(),
                    reminder.metadata?['statement_pdf_path']?.toString(),
                    reminder.metadata?['statement_id']?.toString() ?? reminder.reminderId,
                    reminder.dueDate,
                  )
              : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Row: Clean Title on Left, Formatted Amount on Right
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              color: Color(0xFF8E8E93),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          amountStr,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        if (reminder.countdownText.isNotEmpty &&
                            reminder.countdownText.toLowerCase() != 'undated') ...[
                          const SizedBox(height: 3),
                          Text(
                            reminder.countdownText,
                            style: TextStyle(
                              color: reminder.countdownText.contains('ago')
                                  ? const Color(0xFF71717A)
                                  : const Color(0xFFA1A1AA),
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),

                // Statement Primary Action Bar (Only for credit card statements)
                if (isStatement) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                        width: 1,
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 14,
                          color: Colors.white70,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'View Extracted Transactions',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_ios_rounded,
                          size: 11,
                          color: Color(0xFF71717A),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 14),

                // Hairline Divider
                Divider(
                  height: 1,
                  thickness: 1,
                  color: Colors.white.withValues(alpha: 0.04),
                ),

                const SizedBox(height: 10),

                // Bottom Footer: Source / Trust Note on Left, Subtle Actions on Right
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left: Source Proof & Review Indicator
                    InkWell(
                      onTap: () {
                        showModalBottomSheet(
                          context: context,
                          isScrollControlled: true,
                          backgroundColor: Colors.transparent,
                          builder: (_) => _SourceEmailsSheet(reminder: reminder),
                        );
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mail_outline_rounded,
                              size: 12,
                              color: reminder.review
                                  ? const Color(0xFFF59E0B).withValues(alpha: 0.8)
                                  : const Color(0xFF71717A),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              reminder.sourceMessageIds.length > 1
                                  ? '${reminder.sourceMessageIds.length} emails'
                                  : '1 email',
                              style: TextStyle(
                                color: reminder.review
                                    ? const Color(0xFFF59E0B).withValues(alpha: 0.9)
                                    : const Color(0xFF8E8E93),
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (reminder.review) ...[
                              const SizedBox(width: 5),
                              Text(
                                '• Unverified',
                                style: TextStyle(
                                  color: const Color(0xFFF59E0B).withValues(alpha: 0.8),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),

                    // Right: Actions (Dismiss & Mark Done)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          onTap: () async {
                            final dbService = ref.read(supabaseDbServiceProvider);
                            await dbService.dismissReminder(reminder.reminderId);
                            ref.invalidate(remindersProvider);
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Text(
                              'Dismiss',
                              style: TextStyle(
                                color: Color(0xFF71717A),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        InkWell(
                          onTap: () async {
                            final dbService = ref.read(supabaseDbServiceProvider);
                            await dbService.toggleReminderActioned(
                              reminder.reminderId,
                              isActioned: !reminder.isActioned,
                            );
                            ref.invalidate(remindersProvider);
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (reminder.isActioned) ...[
                                  const Icon(
                                    Icons.check_rounded,
                                    size: 13,
                                    color: Color(0xFF34D399),
                                  ),
                                  const SizedBox(width: 3),
                                ],
                                Text(
                                  reminder.isActioned ? 'Done' : 'Mark done',
                                  style: TextStyle(
                                    color: reminder.isActioned
                                        ? const Color(0xFF34D399)
                                        : const Color(0xFFA1A1AA),
                                    fontSize: 12,
                                    fontWeight: reminder.isActioned
                                        ? FontWeight.w600
                                        : FontWeight.w500,
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabButton({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Center(
          child: Text(
            title,
            style: TextStyle(
              color: isSelected ? Colors.black : DpcColors.textSecondary,
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }




  void _showCreditCardTransactionsSheet(
    BuildContext context, [
    String? cardLast4,
    String? bank,
    String? period,
    String? statementPdfPath,
    String? statementId,
    DateTime? dueDate,
  ]) {
    final effectiveLast4 = (cardLast4 != null && cardLast4.isNotEmpty) ? cardLast4 : '';
    final effectiveBank = (bank != null && bank.isNotEmpty) ? bank : 'Credit Card';
    final user = ref.read(currentUserProvider);
    final userId = user?.id ?? SupabaseConfig.client.auth.currentUser?.id;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CreditCardBreakdownSheet(
        userId: userId,
        cardLast4: effectiveLast4,
        bankName: effectiveBank,
        period: period,
        statementPdfPath: statementPdfPath,
        statementId: statementId,
        dueDate: dueDate,
        dbService: ref.read(supabaseDbServiceProvider),
      ),
    );
  }

  // ignore: unused_element
  Widget _buildDatabaseStatementItem(Map<String, dynamic> row) {
    final merchant = row['merchant_name']?.toString() ?? 'Credit Card Statement';
    final bank = row['bank_or_issuer']?.toString() ?? 'Bank';
    final last4 = row['card_last4']?.toString();
    final totalDue = (row['statement_total_due'] as num?)?.toDouble() ??
        (row['amount'] as num?)?.toDouble() ??
        0.0;
    final minDue = (row['statement_min_due'] as num?)?.toDouble();
    final period = row['statement_period']?.toString();

    final dueDateStr = row['statement_due_date']?.toString();
    DateTime? dueDate;
    if (dueDateStr != null) {
      dueDate = DateTime.tryParse(dueDateStr)?.toLocal();
    }

    final txDateStr = row['transaction_date']?.toString();
    DateTime? txDate;
    if (txDateStr != null) {
      txDate = DateTime.tryParse(txDateStr)?.toLocal();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF101014),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.credit_card_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      bank.isNotEmpty ? '$bank Credit Card' : merchant,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${last4 != null ? "Card ending ••$last4  •  " : ""}${period != null && period.isNotEmpty ? period : (txDate != null ? _formatDateTime(txDate).split(',')[0] : "Monthly Statement")}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 11,
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
                    BankTransaction.formatRupees(totalDue, showDecimals: false),
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (minDue != null && minDue > 0)
                    Text(
                      'Min: ${BankTransaction.formatRupees(minDue, showDecimals: false)}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 10.5,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Color(0xFF1D1D22), height: 1),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.event_outlined,
                      size: 13,
                      color: dueDate != null ? const Color(0xFFF59E0B) : DpcColors.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        dueDate != null
                            ? 'Due: ${dueDate.day} ${_formatDateTime(dueDate).split(',')[0].split(' ').skip(1).join(' ')}'
                            : 'Periodic Statement',
                        style: TextStyle(
                          color: dueDate != null ? const Color(0xFFF59E0B) : DpcColors.textMuted,
                          fontSize: 11,
                          fontWeight: dueDate != null ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => _showCreditCardTransactionsSheet(
                  context,
                  last4 ?? '2254',
                  bank,
                  period,
                  row['statement_pdf_path']?.toString(),
                  row['id']?.toString() ?? row['statement_id']?.toString(),
                  dueDate,
                ),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_rounded, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text(
                        'Breakdown',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
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
    );
  }

  // ignore: unused_element
  Widget _buildDatabaseSubscriptionItem(Map<String, dynamic> row) {
    final service = row['merchant_name']?.toString() ?? 'Subscription';
    final amountNum = (row['amount'] as num?)?.toDouble() ?? 0.0;
    final freq = row['recurring_frequency']?.toString() ?? 'MONTHLY';
    final dueDay = row['typical_due_day'];
    final cardLast4 = row['card_last4']?.toString();
    final txDateStr = row['transaction_date']?.toString();
    DateTime? txDate;
    if (txDateStr != null) {
      txDate = DateTime.tryParse(txDateStr)?.toLocal();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF101014),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DpcColors.accentPositive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.all_inclusive_rounded,
                  size: 18,
                  color: DpcColors.accentPositive,
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
                            service,
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: DpcColors.accentPositive.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(
                              color: DpcColors.accentPositive,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$freq${dueDay != null ? " • Typical due day $dueDay" : ""}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                BankTransaction.formatRupees(amountNum, showDecimals: false),
                style: const TextStyle(
                  color: DpcColors.accentPositive,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (txDate != null || (cardLast4 != null && cardLast4.isNotEmpty)) ...[
            const SizedBox(height: 10),
            const Divider(color: Color(0xFF1D1D22), height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                if (txDate != null) ...[
                  const Icon(Icons.history_rounded, size: 12, color: DpcColors.textMuted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Last billed: ${_formatDateTime(txDate).split(',')[0]}',
                      style: const TextStyle(color: DpcColors.textMuted, fontSize: 10.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const Spacer(),
                if (cardLast4 != null && cardLast4.isNotEmpty) ...[
                  const Icon(Icons.credit_card_rounded, size: 12, color: DpcColors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    'Ending ••$cardLast4',
                    style: const TextStyle(color: DpcColors.textMuted, fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ignore: unused_element
  Widget _buildStatementItem(ExtractedEmailTransaction t) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF101014),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.credit_card_rounded,
                  size: 20,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.bankOrIssuer.isNotEmpty ? '${t.bankOrIssuer} Credit Card' : t.merchantName,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${t.cardLast4 != null ? "Card ending ••${t.cardLast4}  •  " : ""}${t.statementPeriod != null && t.statementPeriod!.isNotEmpty ? t.statementPeriod! : _formatDateTime(t.transactionDate).split(',')[0]}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 11,
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
                    BankTransaction.formatRupees(
                      t.statementTotalDue ?? t.amount,
                      showDecimals: false,
                    ),
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (t.statementMinDue != null && t.statementMinDue! > 0)
                    Text(
                      'Min: ${BankTransaction.formatRupees(t.statementMinDue!, showDecimals: false)}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 10.5,
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Color(0xFF1D1D22), height: 1),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.event_outlined,
                      size: 13,
                      color: t.statementDueDate != null ? const Color(0xFFF59E0B) : DpcColors.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        t.statementDueDate != null
                            ? 'Due: ${t.statementDueDate!.day} ${_formatDateTime(t.statementDueDate!).split(',')[0].split(' ').skip(1).join(' ')}'
                            : 'Periodic Statement',
                        style: TextStyle(
                          color: t.statementDueDate != null ? const Color(0xFFF59E0B) : DpcColors.textMuted,
                          fontSize: 11,
                          fontWeight: t.statementDueDate != null ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => _showCreditCardTransactionsSheet(
                  context,
                  t.cardLast4 ?? '2254',
                  t.bankOrIssuer,
                  t.statementPeriod,
                  t.statementPdfPath,
                  t.gmailMessageId,
                  t.statementDueDate,
                ),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.receipt_long_rounded, size: 12, color: Colors.white),
                      SizedBox(width: 4),
                      Text(
                        'Breakdown',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
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
    );
  }

  // ignore: unused_element
  Widget _buildSubscriptionItem(dynamic sub) {
    final String service = sub.serviceName;
    final double amount = (sub.expectedAmount as num).toDouble();
    final String freq = sub.frequency;
    final int? dueDay = sub.typicalDueDay;
    final String? cardLast4 = sub.cardLast4;
    final DateTime? billingDate = sub.billingDate;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xFF101014),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: DpcColors.accentPositive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.all_inclusive_rounded,
                  size: 18,
                  color: DpcColors.accentPositive,
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
                            service,
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: DpcColors.accentPositive.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'ACTIVE',
                            style: TextStyle(
                              color: DpcColors.accentPositive,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$freq${dueDay != null ? " • Typical due day $dueDay" : ""}',
                      style: const TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                BankTransaction.formatRupees(amount, showDecimals: false),
                style: const TextStyle(
                  color: DpcColors.accentPositive,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          if (billingDate != null || (cardLast4 != null && cardLast4.isNotEmpty)) ...[
            const SizedBox(height: 10),
            const Divider(color: Color(0xFF1D1D22), height: 1),
            const SizedBox(height: 8),
            Row(
              children: [
                if (billingDate != null) ...[
                  const Icon(Icons.history_rounded, size: 12, color: DpcColors.textMuted),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Last billed: ${_formatDateTime(billingDate).split(',')[0]}',
                      style: const TextStyle(color: DpcColors.textMuted, fontSize: 10.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                const Spacer(),
                if (cardLast4 != null && cardLast4.isNotEmpty) ...[
                  const Icon(Icons.credit_card_rounded, size: 12, color: DpcColors.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    'Ending ••$cardLast4',
                    style: const TextStyle(color: DpcColors.textMuted, fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.mark_email_read_outlined,
                size: 20,
                color: DpcColors.textMuted,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              style: const TextStyle(
                color: DpcColors.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _CreditCardBreakdownSheet extends ConsumerStatefulWidget {
  final String? userId;
  final String cardLast4;
  final String bankName;
  final String? period;
  final String? statementPdfPath;
  final String? statementId;
  final DateTime? dueDate;
  final SupabaseDbService dbService;

  const _CreditCardBreakdownSheet({
    required this.userId,
    required this.cardLast4,
    required this.bankName,
    this.period,
    this.statementPdfPath,
    this.statementId,
    this.dueDate,
    required this.dbService,
  });

  @override
  ConsumerState<_CreditCardBreakdownSheet> createState() => _CreditCardBreakdownSheetState();
}

class _CreditCardBreakdownSheetState extends ConsumerState<_CreditCardBreakdownSheet> {
  bool _isLoading = true;
  bool _isUnlocking = false;
  bool _isPasswordProtected = false;
  bool _showPassword = false;
  String? _errorMessage;
  final TextEditingController _passwordController = TextEditingController();
  List<Map<String, dynamic>> _transactions = [];
  int _selectedFilter = 0; // 0: All, 1: Spends, 2: Refunds/Credits

  @override
  void initState() {
    super.initState();
    _fetchTransactions();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _fetchTransactions() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final uid = widget.userId ?? SupabaseConfig.client.auth.currentUser?.id;
      if (uid == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'User session not found. Please log in.';
        });
        return;
      }

      // 1. Primary query from Supabase credit_card_transactions table
      var list = await widget.dbService.fetchCreditCardTransactions(
        userId: uid,
        cardLast4: widget.cardLast4.isNotEmpty ? widget.cardLast4 : null,
        limit: 200,
      );

      // 2. Fallback: if card_last4 didn't match, fetch all credit card transactions for this user
      if (list.isEmpty) {
        list = await widget.dbService.fetchCreditCardTransactions(
          userId: uid,
          limit: 200,
        );
      }

      // 3. If no itemized transactions found yet and a statement PDF exists, inspect whether it is password protected
      bool isProtected = false;
      if (list.isEmpty && widget.statementPdfPath != null && widget.statementPdfPath!.isNotEmpty) {
        try {
          final pdfBytes = await widget.dbService.downloadStatementPdfFromStorage(
            storagePath: widget.statementPdfPath!,
          );
          if (pdfBytes != null && pdfBytes.isNotEmpty) {
            final sliceParser = ref.read(sliceCreditCardPdfParserServiceProvider);
            final testParse = await sliceParser.parsePdfBytes(
              pdfBytes,
              fileName: widget.statementPdfPath!.split('/').last,
            );
            if (testParse.isPasswordProtected) {
              isProtected = true;
            } else if (testParse.success && testParse.transactions.isNotEmpty) {
              // Not encrypted: auto-save transactions
              await widget.dbService.saveCreditCardTransactions(
                transactions: testParse.transactions,
                userId: uid,
                statementId: widget.statementId,
                statementPdfPath: widget.statementPdfPath,
                cardLast4: testParse.summary.cardLast4 ?? widget.cardLast4,
                billingCycle: testParse.summary.billingCycle ?? widget.period,
                dueDate: testParse.summary.dueDate ?? widget.dueDate,
              );
              list = await widget.dbService.fetchCreditCardTransactions(
                userId: uid,
                cardLast4: widget.cardLast4.isNotEmpty ? widget.cardLast4 : null,
                limit: 200,
              );
            }
          }
        } catch (e) {
          debugPrint('[CreditCardBreakdown] Pre-inspection error: $e');
        }
      }

      if (mounted) {
        setState(() {
          _transactions = list;
          _isPasswordProtected = isProtected;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Failed to load from Supabase: $e';
        });
      }
    }
  }

  Future<void> _submitUnlockPassword() async {
    final pwd = _passwordController.text.trim();
    if (pwd.isEmpty) {
      HapticFeedback.mediumImpact();
      setState(() {
        _errorMessage = 'Please enter the statement password.';
      });
      return;
    }

    if (widget.statementPdfPath == null || widget.statementPdfPath!.isEmpty) {
      setState(() {
        _errorMessage = 'Statement PDF file not found.';
      });
      return;
    }

    setState(() {
      _isUnlocking = true;
      _errorMessage = null;
    });

    try {
      final res = await ref.read(gmailSyncProvider.notifier).unlockCreditCardStatement(
        statementPdfPath: widget.statementPdfPath!,
        password: pwd,
        statementId: widget.statementId,
        cardLast4: widget.cardLast4,
        billingCycle: widget.period,
        dueDate: widget.dueDate,
      );

      if (res.isPasswordProtected) {
        HapticFeedback.mediumImpact();
        if (mounted) {
          setState(() {
            _isUnlocking = false;
            _errorMessage = 'Incorrect password. Please try again.';
          });
        }
        return;
      }

      if (res.success && res.transactions.isNotEmpty) {
        HapticFeedback.lightImpact();
        final uid = widget.userId ?? SupabaseConfig.client.auth.currentUser?.id;
        final updatedList = await widget.dbService.fetchCreditCardTransactions(
          userId: uid ?? '',
          cardLast4: widget.cardLast4.isNotEmpty ? widget.cardLast4 : null,
          limit: 200,
        );

        ref.invalidate(transactionFeedProvider);
        ref.invalidate(balanceProvider);

        if (mounted) {
          setState(() {
            _isUnlocking = false;
            _isPasswordProtected = false;
            _transactions = updatedList.isNotEmpty
                ? updatedList
                : res.transactions.map((t) => t.toMap(userId: uid ?? '')).toList();
            _errorMessage = null;
          });
        }
      } else {
        HapticFeedback.mediumImpact();
        if (mounted) {
          setState(() {
            _isUnlocking = false;
            _errorMessage = res.errorMessage ?? 'Failed to extract transactions from statement.';
          });
        }
      }
    } catch (e) {
      HapticFeedback.mediumImpact();
      if (mounted) {
        setState(() {
          _isUnlocking = false;
          _errorMessage = 'Error unlocking statement: $e';
        });
      }
    }
  }

  double get _totalSpends => _transactions
      .where((t) => t['transaction_type'] != 'CREDIT')
      .fold(0.0, (sum, t) => sum + ((t['amount'] as num?)?.toDouble() ?? 0.0));

  double get _totalCredits => _transactions
      .where((t) => t['transaction_type'] == 'CREDIT')
      .fold(0.0, (sum, t) => sum + ((t['amount'] as num?)?.toDouble() ?? 0.0));

  List<Map<String, dynamic>> get _filteredTransactions {
    if (_selectedFilter == 1) {
      return _transactions.where((t) => t['transaction_type'] != 'CREDIT').toList();
    } else if (_selectedFilter == 2) {
      return _transactions.where((t) => t['transaction_type'] == 'CREDIT').toList();
    }
    return _transactions;
  }

  String _formatTxDate(dynamic txDateRaw) {
    if (txDateRaw == null) return '';
    final dt = DateTime.tryParse(txDateRaw.toString())?.toLocal();
    if (dt == null) return '';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${dt.day} ${months[dt.month - 1]} ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredTransactions;
    final spendCount = _transactions.where((t) => t['transaction_type'] != 'CREDIT').length;
    final creditCount = _transactions.where((t) => t['transaction_type'] == 'CREDIT').length;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: DpcColors.surfaceElevated,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: DpcColors.surfaceBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // Top Header: Title & Close & Refresh
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${widget.bankName} Statement',
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.cardLast4.isNotEmpty
                              ? 'Card ending ••${widget.cardLast4}${widget.period != null && widget.period!.isNotEmpty ? "  •  ${widget.period}" : ""}'
                              : (widget.period != null && widget.period!.isNotEmpty
                                  ? widget.period!
                                  : 'Statement Transactions'),
                          style: const TextStyle(
                            color: DpcColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, color: DpcColors.textSecondary, size: 20),
                    tooltip: 'Refresh',
                    onPressed: _isLoading ? null : _fetchTransactions,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: DpcColors.textSecondary, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            if (_isPasswordProtected)
              Expanded(child: _buildPasswordProtectedView())
            else ...[
              // Summary Totals Strip
              if (!_isLoading && _transactions.isNotEmpty)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: DpcColors.surfaceBorder),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'SPENDS',
                            style: TextStyle(
                              color: DpcColors.textMuted,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '₹${_totalSpends.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(width: 1, height: 28, color: DpcColors.surfaceBorder),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'REFUNDS/CASHBACK',
                              style: TextStyle(
                                color: DpcColors.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '+₹${_totalCredits.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: DpcColors.accentPositive,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Container(width: 1, height: 28, color: DpcColors.surfaceBorder),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'NET DUE',
                              style: TextStyle(
                                color: DpcColors.textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.8,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '₹${(_totalSpends - _totalCredits).toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Segmented Filter Tabs
            if (!_isLoading && _transactions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Row(
                  children: [
                    _buildFilterChip('All (${_transactions.length})', 0),
                    const SizedBox(width: 8),
                    _buildFilterChip('Spends ($spendCount)', 1),
                    const SizedBox(width: 8),
                    _buildFilterChip('Refunds ($creditCount)', 2),
                  ],
                ),
              ),

            const Divider(color: DpcColors.surfaceBorder, height: 16),

            // Itemized Transaction List or Loading/Empty State
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: DpcColors.accentPositive,
                            strokeWidth: 2.5,
                          ),
                          SizedBox(height: 16),
                          Text(
                            'Fetching live from Supabase credit_card_transactions...',
                            style: TextStyle(color: DpcColors.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  : _errorMessage != null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline_rounded, color: Colors.orangeAccent, size: 36),
                              const SizedBox(height: 12),
                              Text(
                                _errorMessage!,
                                style: const TextStyle(color: DpcColors.textMuted, fontSize: 12.5),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton(
                                onPressed: _fetchTransactions,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: DpcColors.accentPositive,
                                  foregroundColor: Colors.black,
                                ),
                                child: const Text('Retry Fetch'),
                              ),
                            ],
                          ),
                        )
                      : filtered.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.receipt_long_outlined, color: DpcColors.textMuted, size: 36),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'No transactions found in credit_card_transactions.',
                                    style: TextStyle(color: DpcColors.textMuted, fontSize: 13),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      OutlinedButton(
                                        onPressed: _fetchTransactions,
                                        child: const Text('Refresh'),
                                      ),
                                      if (widget.statementPdfPath != null &&
                                          widget.statementPdfPath!.isNotEmpty) ...[
                                        const SizedBox(width: 10),
                                        ElevatedButton.icon(
                                          onPressed: () => setState(() => _isPasswordProtected = true),
                                          icon: const Icon(Icons.lock_open_rounded, size: 16),
                                          label: const Text('Unlock with Password'),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: DpcColors.accentPositive,
                                            foregroundColor: Colors.black,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                              itemCount: filtered.length,
                              separatorBuilder: (_, _) => const Divider(
                                color: DpcColors.surfaceBorder,
                                height: 1,
                              ),
                              itemBuilder: (_, index) {
                                final item = filtered[index];
                                final isCredit = item['transaction_type'] == 'CREDIT';
                                final amt = (item['amount'] as num?)?.toDouble() ?? 0.0;
                                final rawMerchant = item['clean_merchant_name'] ?? item['merchant_name'] ?? 'Merchant';
                                final merchant = rawMerchant.toString().trim();
                                final category = item['category']?.toString() ?? 'Spend';
                                final mode = item['payment_mode']?.toString() ?? 'Card';
                                final dateStr = _formatTxDate(item['transaction_date']);

                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 11),
                                  child: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: isCredit
                                              ? DpcColors.accentPositive.withValues(alpha: 0.14)
                                              : DpcColors.surfaceDark,
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Icon(
                                          isCredit
                                              ? Icons.arrow_downward_rounded
                                              : (mode.toLowerCase() == 'upi'
                                                  ? Icons.qr_code_scanner_rounded
                                                  : Icons.credit_card_rounded),
                                          size: 16,
                                          color: isCredit ? DpcColors.accentPositive : DpcColors.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              merchant,
                                              style: const TextStyle(
                                                color: DpcColors.textPrimary,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$category • $mode${dateStr.isNotEmpty ? " • $dateStr" : ""}',
                                              style: const TextStyle(
                                                color: DpcColors.textMuted,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '${isCredit ? "+" : "-"}₹${amt.toStringAsFixed(2)}',
                                        style: TextStyle(
                                          color: isCredit ? DpcColors.accentPositive : DpcColors.textPrimary,
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ],
      ),
    ),
  );
}

  Widget _buildPasswordProtectedView() {
    final hasError = _errorMessage != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: DpcColors.bgOled,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: hasError ? DpcColors.accentNegative.withValues(alpha: 0.5) : DpcColors.surfaceBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: (hasError ? DpcColors.accentNegative : DpcColors.accentLevel).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Icon(
                  hasError ? Icons.lock_clock_rounded : Icons.lock_outline_rounded,
                  color: hasError ? DpcColors.accentNegative : DpcColors.accentLevel,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Password Protected Statement',
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Enter the password to open this statement (often your PAN in UPPERCASE or Date of Birth in DDMMYYYY format).',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _passwordController,
              obscureText: !_showPassword,
              autofocus: true,
              enabled: !_isUnlocking,
              style: const TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 14,
              ),
              onChanged: (_) {
                if (_errorMessage != null) {
                  setState(() => _errorMessage = null);
                }
              },
              decoration: InputDecoration(
                hintText: 'Enter statement password',
                hintStyle: const TextStyle(color: DpcColors.textMuted),
                filled: true,
                fillColor: DpcColors.surfaceDark,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: hasError ? DpcColors.accentNegative : DpcColors.surfaceBorder,
                    width: hasError ? 1.5 : 1.0,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: hasError ? DpcColors.accentNegative : DpcColors.surfaceBorder,
                    width: hasError ? 1.5 : 1.0,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(
                    color: hasError ? DpcColors.accentNegative : DpcColors.accentPositive,
                    width: 1.5,
                  ),
                ),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                    color: DpcColors.textMuted,
                    size: 18,
                  ),
                  onPressed: () => setState(() => _showPassword = !_showPassword),
                ),
              ),
              onSubmitted: (_) => _submitUnlockPassword(),
            ),
            if (hasError) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: DpcColors.accentNegative,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(
                        color: DpcColors.accentNegative,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton(
                onPressed: _isUnlocking ? null : _submitUnlockPassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: DpcColors.accentPositive,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                child: _isUnlocking
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Unlock & View Breakdown',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, int index) {
    final isSelected = _selectedFilter == index;
    return InkWell(
      onTap: () => setState(() => _selectedFilter = index),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? DpcColors.accentPositive.withValues(alpha: 0.15) : DpcColors.surfaceDark,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? DpcColors.accentPositive : DpcColors.surfaceBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? DpcColors.accentPositive : DpcColors.textMuted,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet displaying all source email notices deduplicated into a single financial obligation.
class _SourceEmailsSheet extends StatelessWidget {
  final ReminderModel reminder;

  const _SourceEmailsSheet({required this.reminder});

  @override
  Widget build(BuildContext context) {
    final sourceEmails = (reminder.metadata?['source_emails'] as List?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList() ?? [];

    final messageIds = reminder.sourceMessageIds;
    final totalCount = sourceEmails.isNotEmpty ? sourceEmails.length : messageIds.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: DpcColors.surfaceElevated,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            // Drag handle
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: DpcColors.surfaceBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Source Emails ($totalCount)',
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 16.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${reminder.provider} • Grouped Obligation',
                          style: const TextStyle(
                            color: DpcColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: DpcColors.textSecondary, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(color: DpcColors.surfaceBorder, height: 16),
            Expanded(
              child: ListView.separated(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                itemCount: sourceEmails.isNotEmpty ? sourceEmails.length : messageIds.length,
                separatorBuilder: (context, index) => const SizedBox(height: 8),
                itemBuilder: (ctx, index) {
                  if (sourceEmails.isNotEmpty) {
                    final email = sourceEmails[index];
                    final subject = email['subject']?.toString() ?? 'Notification';
                    final dateStr = email['date']?.toString();
                    DateTime? dt;
                    if (dateStr != null) {
                      dt = DateTime.tryParse(dateStr)?.toLocal();
                    }
                    final formattedDate = dt != null
                        ? '${dt.day} ${_monthName(dt.month)} ${dt.year}, ${_formatTime(dt)}'
                        : (dateStr ?? 'Unknown date');
                    final amount = email['amount'];
                    final msgId = email['message_id']?.toString() ?? '';

                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF101014),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  'NOTICE #${index + 1}',
                                  style: const TextStyle(
                                    color: Color(0xFF818CF8),
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (amount != null)
                                Text(
                                  '₹${amount is num ? amount.toStringAsFixed(2) : amount}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            subject,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              const Icon(Icons.access_time_rounded, size: 11, color: DpcColors.textMuted),
                              const SizedBox(width: 4),
                              Text(
                                formattedDate,
                                style: const TextStyle(color: DpcColors.textMuted, fontSize: 11),
                              ),
                              if (msgId.isNotEmpty) ...[
                                const Spacer(),
                                Text(
                                  'ID: ${msgId.length > 8 ? msgId.substring(0, 8) : msgId}',
                                  style: const TextStyle(
                                    color: DpcColors.textMuted,
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    );
                  } else {
                    final msgId = messageIds[index];
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF101014),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.email_outlined, color: DpcColors.textSecondary, size: 16),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Gmail Message ID: $msgId',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _monthName(int month) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    if (month >= 1 && month <= 12) return months[month - 1];
    return '';
  }

  static String _formatTime(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $ampm';
  }
}

