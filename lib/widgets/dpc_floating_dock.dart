import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';

/// Floating Bottom Navigation Dock
/// Elevated dark island dock providing quick actions (Home, AI, Sync, Bank, Profile).
/// Clean, icon-only layout preventing any RenderFlex overflows on all device sizes.
class DpcFloatingNavDock extends StatelessWidget {
  final int activeIndex;
  final VoidCallback onHomeTap;
  final VoidCallback onSyncTap;
  final VoidCallback onBankTap;
  final VoidCallback? onAiChatTap;
  final VoidCallback? onProfileTap;
  final bool isSyncing;
  final bool hasActiveConsent;

  const DpcFloatingNavDock({
    super.key,
    this.activeIndex = 0,
    required this.onHomeTap,
    required this.onSyncTap,
    required this.onBankTap,
    this.onAiChatTap,
    this.onProfileTap,
    this.isSyncing = false,
    this.hasActiveConsent = false,
  });

  @override
  Widget build(BuildContext context) {
    final isHomeActive = activeIndex == 0;
    final isProfileActive = activeIndex == 1;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: DpcDecorations.floatingDock,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // 1. Home Button (replaces Feed)
          Tooltip(
            message: 'Home',
            child: InkWell(
              onTap: onHomeTap,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isHomeActive ? DpcColors.surfaceTrack : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: isHomeActive
                      ? Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        )
                      : null,
                ),
                child: Icon(
                  Icons.home_rounded,
                  size: 20,
                  color: isHomeActive
                      ? DpcColors.accentPositive
                      : DpcColors.textSecondary,
                ),
              ),
            ),
          ),

          // 2. Setthi AI Trigger
          if (onAiChatTap != null)
            Tooltip(
              message: 'Setthi AI',
              child: InkWell(
                onTap: onAiChatTap,
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.auto_awesome_rounded,
                    size: 20,
                    color: DpcColors.textSecondary,
                  ),
                ),
              ),
            ),

          // 3. Center Sync Button
          Tooltip(
            message: 'Sync Transactions',
            child: GestureDetector(
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
          ),

          // 4. Link Bank / Accounts
          Tooltip(
            message: hasActiveConsent ? 'Bank Feed Active' : 'Link Bank',
            child: InkWell(
              onTap: onBankTap,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hasActiveConsent
                      ? DpcColors.accentPositive.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  hasActiveConsent
                      ? Icons.verified_rounded
                      : Icons.account_balance_rounded,
                  size: 20,
                  color: hasActiveConsent
                      ? DpcColors.accentPositive
                      : DpcColors.textSecondary,
                ),
              ),
            ),
          ),

          // 5. Profile Button (navigates to Profile Page)
          if (onProfileTap != null)
            Tooltip(
              message: 'Profile & Account',
              child: InkWell(
                onTap: onProfileTap,
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isProfileActive ? DpcColors.surfaceTrack : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: isProfileActive
                        ? Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          )
                        : null,
                  ),
                  child: Icon(
                    isProfileActive
                        ? Icons.person_rounded
                        : Icons.person_outline_rounded,
                    size: 20,
                    color: isProfileActive
                        ? DpcColors.accentPrimary
                        : DpcColors.textSecondary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

