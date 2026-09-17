import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';

/// Floating Bottom Navigation Dock
/// Elevated dark island dock providing quick actions (Feed, Live Sync, Link Bank).
class DpcFloatingNavDock extends StatelessWidget {
  final VoidCallback onFeedTap;
  final VoidCallback onSyncTap;
  final VoidCallback onBankTap;
  final bool isSyncing;
  final bool hasActiveConsent;

  const DpcFloatingNavDock({
    super.key,
    required this.onFeedTap,
    required this.onSyncTap,
    required this.onBankTap,
    this.isSyncing = false,
    this.hasActiveConsent = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: DpcDecorations.floatingDock,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: Feed / Transactions
          InkWell(
            onTap: onFeedTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: DpcColors.surfaceTrack,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.receipt_long_rounded,
                    size: 18,
                    color: DpcColors.textPrimary,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'Feed',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Center: Sync Button
          GestureDetector(
            onTap: onSyncTap,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                gradient: DpcColors.heroPastel1,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF86E3CE).withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: isSyncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: DpcColors.textContrast,
                      ),
                    )
                  : const Icon(
                      Icons.sync_rounded,
                      size: 20,
                      color: DpcColors.textContrast,
                    ),
            ),
          ),

          // Right: Link Bank / Accounts
          InkWell(
            onTap: onBankTap,
            borderRadius: BorderRadius.circular(20),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: hasActiveConsent
                    ? DpcColors.accentPositive.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasActiveConsent
                        ? Icons.verified_rounded
                        : Icons.account_balance_rounded,
                    size: 18,
                    color: hasActiveConsent
                        ? DpcColors.accentPositive
                        : DpcColors.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    hasActiveConsent ? 'Linked' : 'Link Bank',
                    style: TextStyle(
                      color: hasActiveConsent
                          ? DpcColors.accentPositive
                          : DpcColors.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
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
}
