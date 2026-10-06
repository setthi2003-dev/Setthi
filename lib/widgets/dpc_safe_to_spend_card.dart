import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/supabase_provider.dart';

/// Interactive card rendering dynamic Safe-to-Spend (Today & This Week),
/// cashflow rhythm, and upcoming committed bills with interactive drill-down.
class DpcSafeToSpendCard extends ConsumerStatefulWidget {
  const DpcSafeToSpendCard({super.key});

  @override
  ConsumerState<DpcSafeToSpendCard> createState() => _DpcSafeToSpendCardState();
}

class _DpcSafeToSpendCardState extends ConsumerState<DpcSafeToSpendCard> {
  bool _isWeeklySelected = false;

  void _showCommitmentsSheet(BuildContext context, Map<String, dynamic> rhythm) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) => _RecurringCommitmentsSheet(initialRhythm: rhythm),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rhythmAsync = ref.watch(cashflowRhythmProvider);
    if (rhythmAsync.isLoading && !rhythmAsync.hasValue) {
      return Container(
        height: 140,
        decoration: DpcDecorations.cardBase(radius: 22),
        padding: const EdgeInsets.all(18),
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: DpcColors.accentPositive,
            ),
          ),
        ),
      );
    }

    final rhythm = rhythmAsync.value;
    if (rhythm == null) {
      return const SizedBox.shrink();
    }

    final double safeToday = ((rhythm['safe_to_spend_today'] ?? 0.0) as num).toDouble();
    final double safeWeek = ((rhythm['safe_to_spend_this_week'] ?? 0.0) as num).toDouble();
    final double spentToday = ((rhythm['spent_today'] ?? 0.0) as num).toDouble();
    final double spentThisWeek = ((rhythm['spent_this_week'] ?? 0.0) as num).toDouble();
    final double upcomingBillsTotal = ((rhythm['upcoming_bills_total'] ?? 0.0) as num).toDouble();
    final int upcomingBillsCount = ((rhythm['upcoming_bills_count'] ?? 0) as num).toInt();
    final int daysToInflow = ((rhythm['days_to_next_inflow'] ?? 30) as num).toInt();
    final String healthStatus = rhythm['health_status']?.toString() ?? 'HEALTHY';
    final int runwayDays = ((rhythm['runway_days'] ?? 999) as num).toInt();

    final activeAmount = _isWeeklySelected ? safeWeek : safeToday;
    final activeSpent = _isWeeklySelected ? spentThisWeek : spentToday;

    Color statusColor;
    String statusLabel;
    if (healthStatus == 'DEFICIT') {
      statusColor = DpcColors.accentNegative;
      statusLabel = 'Cash Crunch Warning';
    } else if (healthStatus == 'CAUTION' || activeAmount <= 150) {
      statusColor = DpcColors.accentLevel;
      statusLabel = 'Tight Cashflow';
    } else {
      statusColor = DpcColors.accentPositive;
      statusLabel = 'Healthy Rhythm';
    }

    return Container(
      decoration: DpcDecorations.cardBase(radius: 22),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Title & Switcher Pills
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Safe-to-Spend',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
              // Segmented Today vs This Week Pill
              Container(
                decoration: BoxDecoration(
                  color: DpcColors.surfaceTrack,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1,
                  ),
                ),
                padding: const EdgeInsets.all(2.5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildPillToggle(
                      label: 'Today',
                      isSelected: !_isWeeklySelected,
                      onTap: () => setState(() => _isWeeklySelected = false),
                    ),
                    _buildPillToggle(
                      label: 'This Week',
                      isSelected: _isWeeklySelected,
                      onTap: () => setState(() => _isWeeklySelected = true),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Main Metric & Subtitle
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                BankTransaction.formatRupees(activeAmount),
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _isWeeklySelected ? 'for next 7 days' : 'available today',
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Spend indicator / status text
          Row(
            children: [
              Text(
                activeSpent > 0
                    ? '${BankTransaction.formatRupees(activeSpent)} spent ${_isWeeklySelected ? 'this week' : 'today'}'
                    : 'Zero discretionary spend yet',
                style: const TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  statusLabel,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Divider
          Container(
            height: 1,
            color: DpcColors.surfaceBorder,
          ),
          const SizedBox(height: 12),

          // Contextual Rhythm Callouts (Upcoming bills & next inflow)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Bills reserved
              Expanded(
                child: InkWell(
                  onTap: () => _showCommitmentsSheet(context, rhythm),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.receipt_long_rounded,
                          size: 14,
                          color: DpcColors.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            upcomingBillsCount > 0
                                ? '${BankTransaction.formatRupees(upcomingBillsTotal)} for $upcomingBillsCount bills'
                                : 'No bills pending',
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right_rounded,
                          size: 14,
                          color: DpcColors.textMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Cycle Inflow / Runway
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.event_repeat_rounded,
                    size: 14,
                    color: DpcColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    runwayDays < 999
                        ? '$runwayDays d runway'
                        : 'Inflow in $daysToInflow d',
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPillToggle({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? DpcColors.surfaceElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? DpcColors.textPrimary : DpcColors.textMuted,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet modal to inspect, toggle, or add detected recurring commitments
class _RecurringCommitmentsSheet extends ConsumerStatefulWidget {
  final Map<String, dynamic> initialRhythm;
  const _RecurringCommitmentsSheet({required this.initialRhythm});

  @override
  ConsumerState<_RecurringCommitmentsSheet> createState() =>
      _RecurringCommitmentsSheetState();
}

class _RecurringCommitmentsSheetState
    extends ConsumerState<_RecurringCommitmentsSheet> {
  @override
  Widget build(BuildContext context) {
    final commitmentsAsync = ref.watch(recurringCommitmentsProvider);

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
        bottom: MediaQuery.of(context).padding.bottom + 20,
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

          // Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recurring Commitments',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    SizedBox(height: 3),
                    Text(
                      'Automatically reserved from your Safe-to-Spend pool',
                      style: TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: DpcColors.textSecondary, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // List of commitments
          commitmentsAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: CircularProgressIndicator(color: DpcColors.accentPositive),
              ),
            ),
            error: (e, _) => Center(
              child: Text('Error loading commitments: $e', style: const TextStyle(color: DpcColors.accentNegative)),
            ),
            data: (commitments) {
              if (commitments.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: DpcColors.bgOled,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Text(
                      'No recurring bills detected yet.\nThey will appear automatically as you sync bank records.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: DpcColors.textMuted, fontSize: 13, height: 1.4),
                    ),
                  ),
                );
              }

              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: ListView.separated(
                  shrinkWrap: true,
                  physics: const BouncingScrollPhysics(),
                  itemCount: commitments.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = commitments[index];
                    final String id = item['id'].toString();
                    final String name = item['merchant_name']?.toString() ?? 'Bill';
                    final String cat = item['category']?.toString() ?? 'Fixed';
                    final double amt = ((item['expected_amount'] ?? item['amount'] ?? 0.0) as num).toDouble();
                    final bool isActive = item['is_active'] == true;
                    final int? dueDay = (item['typical_due_day'] ?? item['billing_day'] ?? item['day_of_month']) as int?;

                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: DpcColors.bgOled,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: DpcColors.surfaceBorder),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: DpcColors.surfaceTrack,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.repeat_rounded,
                                size: 18,
                                color: DpcColors.accentPositive,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: TextStyle(
                                    color: isActive ? DpcColors.textPrimary : DpcColors.textMuted,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                    decoration: isActive ? null : TextDecoration.lineThrough,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  dueDay != null ? '$cat • Due around day $dueDay' : cat,
                                  style: const TextStyle(
                                    color: DpcColors.textSecondary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            BankTransaction.formatRupees(amt),
                            style: TextStyle(
                              color: isActive ? DpcColors.textPrimary : DpcColors.textMuted,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Switch.adaptive(
                            value: isActive,
                            activeTrackColor: DpcColors.accentPositive,
                            onChanged: (val) async {
                              final db = ref.read(supabaseDbServiceProvider);
                              await db.toggleRecurringCommitment(
                                commitmentId: id,
                                isActive: val,
                              );
                              ref.invalidate(recurringCommitmentsProvider);
                              ref.invalidate(cashflowRhythmProvider);
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
