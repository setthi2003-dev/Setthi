import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/supabase_provider.dart';

/// Statement-anchored Daily Safe Limit card for the Telemetry & Dashboard pages.
/// Displays safe spending per day until the horizon end date without client-side math.
class DpcSafeToSpendCard extends ConsumerWidget {
  const DpcSafeToSpendCard({super.key});

  static String _formatDate(String? isoDate) {
    if (isoDate == null || isoDate.isEmpty) return '';
    try {
      final parts = isoDate.split('-');
      if (parts.length == 3) {
        final year = parts[0];
        final monthIdx = int.tryParse(parts[1]) ?? 1;
        final day = int.tryParse(parts[2]) ?? 1;
        const months = [
          'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        final monthStr = (monthIdx >= 1 && monthIdx <= 12) ? months[monthIdx - 1] : '';
        return '$day $monthStr $year';
      }
    } catch (_) {}
    return isoDate;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rhythmAsync = ref.watch(cashflowRhythmProvider);
    if (rhythmAsync.isLoading && !rhythmAsync.hasValue) {
      return Container(
        height: 90,
        decoration: DpcDecorations.cardBase(radius: 20),
        padding: const EdgeInsets.all(18),
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
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

    // Hide card completely when balance/statement is unavailable
    final bool available = rhythm['available'] == true;
    if (!available) {
      return const SizedBox.shrink();
    }

    final num? rawSafePerDay = rhythm['safe_per_day'];
    final double safePerDay = rawSafePerDay != null ? rawSafePerDay.toDouble() : 0.0;

    final horizon = rhythm['horizon'] as Map<String, dynamic>?;
    final int? horizonDays = horizon?['days'] is num
        ? (horizon!['days'] as num).toInt()
        : (rhythm['days_remaining'] is num ? (rhythm['days_remaining'] as num).toInt() : null);
    final String? horizonEndDate = horizon?['end_date']?.toString();
    final formattedEndDate = _formatDate(horizonEndDate);

    final String? rawHealthStatus = rhythm['health_status']?.toString();
    String? statusLabel;
    Color? statusColor;

    if (rawHealthStatus == 'DEFICIT') {
      statusLabel = 'Tight';
      statusColor = DpcColors.accentNegative;
    } else if (rawHealthStatus == 'CAUTION') {
      statusLabel = 'Be careful';
      statusColor = DpcColors.accentLevel;
    } else if (rawHealthStatus == 'HEALTHY') {
      statusLabel = 'On track';
      statusColor = DpcColors.accentPositive;
    }

    String subline = '';
    if (formattedEndDate.isNotEmpty && horizonDays != null) {
      subline = 'until $formattedEndDate ($horizonDays days)';
    } else if (formattedEndDate.isNotEmpty) {
      subline = 'until $formattedEndDate';
    } else if (horizonDays != null) {
      subline = 'for next $horizonDays days';
    }

    return Container(
      decoration: DpcDecorations.cardBase(radius: 20),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Status Dot, Title, and Status Badge (if status exists)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (statusColor != null) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const Text(
                    'Daily safe limit',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
              if (statusLabel != null && statusColor != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          // Main Metric: Amount + "a day"
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                BankTransaction.formatRupees(safePerDay),
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.8,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'a day',
                style: TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          if (subline.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subline,
              style: const TextStyle(
                color: DpcColors.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
