import 'dart:ui';
import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';
import 'ai_companion_rive_widget.dart';

/// Floating Bottom Navigation Dock
/// Elevated dark island dock providing quick actions (AI, Insights, Gmail Sync, Profile).
/// Frosted glass aesthetic with generous negative space and micro-blur depth.
class DpcFloatingNavDock extends StatelessWidget {
  final int activeIndex;
  final VoidCallback? onAiTap;
  final VoidCallback? onTelemetryTap;
  final VoidCallback? onHomeTap;
  final VoidCallback? onTransactionsTap;
  final VoidCallback? onBankTap;
  final VoidCallback? onProfileTap;
  final VoidCallback? onSyncTap;
  final VoidCallback? onAiChatTap;
  final VoidCallback? onGmailTap;
  final bool isSyncing;
  final bool hasActiveConsent;
  final bool isGmailConnected;

  const DpcFloatingNavDock({
    super.key,
    this.activeIndex = 0,
    this.onAiTap,
    this.onTelemetryTap,
    this.onHomeTap,
    this.onTransactionsTap,
    this.onBankTap,
    this.onProfileTap,
    this.onSyncTap,
    this.onAiChatTap,
    this.onGmailTap,
    this.isSyncing = false,
    this.hasActiveConsent = false,
    this.isGmailConnected = false,
  });

  @override
  Widget build(BuildContext context) {
    final isAiActive = activeIndex == 0;
    final isTelemetryActive = activeIndex == 1;
    final isTransactionsActive = activeIndex == 2;
    // ignore: unused_local_variable
    final isBankActive = activeIndex == 3;
    final isGmailActive = activeIndex == 3;
    final isProfileActive = activeIndex == 4;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

          // 2. Spending Insights & Activity Page (Merged)
          Tooltip(
            message: 'Insights & Activity',
            child: InkWell(
              onTap: onTelemetryTap ?? onTransactionsTap ?? onHomeTap,
              borderRadius: BorderRadius.circular(16),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (isTelemetryActive || isTransactionsActive)
                      ? DpcColors.surfaceElevated
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  border: (isTelemetryActive || isTransactionsActive)
                      ? Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        )
                      : null,
                ),
                child: Icon(
                  Icons.insights_rounded,
                  size: 20,
                  color: (isTelemetryActive || isTransactionsActive)
                      ? DpcColors.textPrimary
                      : DpcColors.textSecondary,
                ),
              ),
            ),
          ),

          // 3. Gmail Financial Sync Page
          if (onGmailTap != null)
            Tooltip(
              message: 'Gmail Sync',
              child: InkWell(
                onTap: onGmailTap,
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: isGmailActive ? DpcColors.surfaceElevated : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                    border: isGmailActive
                        ? Border.all(
                            color: DpcColors.surfaceBorder,
                            width: 1,
                          )
                        : null,
                  ),
                  child: Icon(
                    isGmailActive
                        ? Icons.mail_rounded
                        : Icons.mail_outline_rounded,
                    size: 20,
                    color: isGmailActive
                        ? DpcColors.textPrimary
                        : DpcColors.textSecondary,
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
    ),
  ),
),
);
  }
}

