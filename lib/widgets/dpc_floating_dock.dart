import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';
import 'ai_companion_rive_widget.dart';

/// Floating Bottom Navigation Dock
/// Elevated dark island dock providing quick actions (Home, AI, Sync, Bank, Profile).
/// Clean, icon-only layout preventing any RenderFlex overflows on all device sizes.
class DpcFloatingNavDock extends StatelessWidget {
  final int activeIndex;
  final VoidCallback? onAiTap;
  final VoidCallback? onTelemetryTap;
  final VoidCallback onHomeTap;
  final VoidCallback onBankTap;
  final VoidCallback? onProfileTap;
  final VoidCallback? onSyncTap;
  final VoidCallback? onAiChatTap;
  final bool isSyncing;
  final bool hasActiveConsent;

  const DpcFloatingNavDock({
    super.key,
    this.activeIndex = 2,
    this.onAiTap,
    this.onTelemetryTap,
    required this.onHomeTap,
    required this.onBankTap,
    this.onProfileTap,
    this.onSyncTap,
    this.onAiChatTap,
    this.isSyncing = false,
    this.hasActiveConsent = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAiActive = activeIndex == 0;
    final isTelemetryActive = activeIndex == 1;
    final isHomeActive = activeIndex == 2;
    final isBankActive = activeIndex == 3;
    final isProfileActive = activeIndex == 4;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: DpcDecorations.floatingDock,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          // 1. Setthi AI Page (replaces Home icon in slot 1)
          Tooltip(
            message: 'Setthi AI',
            child: InkWell(
              onTap: onAiTap ?? onAiChatTap,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isAiActive ? DpcColors.surfaceElevated : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: isAiActive
                      ? Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        )
                      : null,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: const AiCompanionRiveWidget(
                    size: 24,
                  ),
                ),
              ),
            ),
          ),

          // 2. Telemetry & Analytics Page
          Tooltip(
            message: 'Telemetry & Analytics',
            child: InkWell(
              onTap: onTelemetryTap,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isTelemetryActive ? DpcColors.surfaceElevated : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: isTelemetryActive
                      ? Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        )
                      : null,
                ),
                child: Icon(
                  Icons.insights_rounded,
                  size: 20,
                  color: isTelemetryActive
                      ? DpcColors.textPrimary
                      : DpcColors.textSecondary,
                ),
              ),
            ),
          ),

          // 3. Present Homepage with Total Balance
          Tooltip(
            message: 'Home & Balance',
            child: InkWell(
              onTap: onHomeTap,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isHomeActive ? DpcColors.surfaceElevated : Colors.transparent,
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
                      ? DpcColors.textPrimary
                      : DpcColors.textSecondary,
                ),
              ),
            ),
          ),

          // 4. Link Bank / Accounts (forth page as it is)
          Tooltip(
            message: hasActiveConsent ? 'Bank Feed Active' : 'Link Bank',
            child: InkWell(
              onTap: onBankTap,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isBankActive ? DpcColors.surfaceElevated : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: isBankActive
                      ? Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        )
                      : null,
                ),
                child: Icon(
                  hasActiveConsent
                      ? Icons.verified_rounded
                      : Icons.account_balance_rounded,
                  size: 20,
                  color: isBankActive
                      ? DpcColors.textPrimary
                      : (hasActiveConsent ? DpcColors.textPrimary : DpcColors.textSecondary),
                ),
              ),
            ),
          ),

          // 5. Profile Button (fifth page as it is)
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
                    color: isProfileActive ? DpcColors.surfaceElevated : Colors.transparent,
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
                        ? DpcColors.textPrimary
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

