import 'dart:async';
import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';
import 'slide_to_confirm.dart';

/// Interactive sliding permission bottom sheet presented when a bank
/// account is linked via Account Aggregator, prompting the user for explicit
/// sliding confirmation to fetch and decrypt their transaction statements.
class BankSyncPermissionSheet extends StatefulWidget {
  final String consentId;
  final Future<void> Function() onSyncRequested;

  const BankSyncPermissionSheet({
    super.key,
    required this.consentId,
    required this.onSyncRequested,
  });

  /// Static helper to display the sheet modal
  static Future<bool?> show({
    required BuildContext context,
    required String consentId,
    required Future<void> Function() onSyncRequested,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: DpcColors.surfaceDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        side: BorderSide(color: DpcColors.surfaceBorder, width: 1),
      ),
      builder: (_) => BankSyncPermissionSheet(
        consentId: consentId,
        onSyncRequested: onSyncRequested,
      ),
    );
  }

  @override
  State<BankSyncPermissionSheet> createState() =>
      _BankSyncPermissionSheetState();
}

class _BankSyncPermissionSheetState extends State<BankSyncPermissionSheet> {
  int _currentStep = 0;
  bool _isSyncing = false;
  bool _isSuccess = false;
  String? _errorMessage;
  Timer? _stepTimer;

  final List<String> _syncSteps = [
    'Verifying active Account Aggregator consent...',
    'Creating secure data session with bank...',
    'Downloading & decrypting transactions...',
    'Organizing categories & computing analytics...',
  ];

  Future<void> _handleSliderConfirmed() async {
    setState(() {
      _currentStep = 0;
      _isSyncing = true;
      _errorMessage = null;
    });

    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(const Duration(milliseconds: 2500), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_currentStep < _syncSteps.length - 1) {
        setState(() => _currentStep++);
      }
    });

    try {
      await widget.onSyncRequested();
      _stepTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _isSyncing = false;
        _isSuccess = true;
      });
      await Future.delayed(const Duration(milliseconds: 700));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      _stepTimer?.cancel();
      if (mounted) {
        setState(() {
          _isSyncing = false;
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Drag Handle
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: DpcColors.surfaceTrack,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Top Header: Bank Badge + Status Tag
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    gradient: DpcColors.heroPastel1,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.account_balance_rounded,
                    color: DpcColors.textContrast,
                    size: 26,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: DpcColors.accentPositive.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: DpcColors.accentPositive.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified_rounded,
                        color: DpcColors.accentPositive,
                        size: 13,
                      ),
                      SizedBox(width: 5),
                      Text(
                        'CONSENT ACTIVE',
                        style: TextStyle(
                          color: DpcColors.accentPositive,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            // Title & Description
            const Text(
              'Bank Connected Successfully',
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Your bank account is approved. Slide below to authorize Setthi to fetch and organize your financial transactions.',
              style: TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 20),

            // Telemetry Security Features
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: DpcColors.bgOled,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: DpcColors.surfaceBorder),
              ),
              child: Column(
                children: [
                  _buildSecurityRow(
                    icon: Icons.lock_outline_rounded,
                    title: 'Read-Only Statement Access',
                    subtitle: 'Setthi cannot initiate payments or modify your account.',
                  ),
                  const Divider(color: DpcColors.surfaceBorder, height: 18),
                  _buildSecurityRow(
                    icon: Icons.shield_outlined,
                    title: 'RBI Regulated Gateway',
                    subtitle: 'Powered by licensed Setu Account Aggregator.',
                  ),
                  const Divider(color: DpcColors.surfaceBorder, height: 18),
                  _buildSecurityRow(
                    icon: Icons.security_rounded,
                    title: '256-Bit Encrypted Data',
                    subtitle: 'Credentials stored securely in Supabase Vault.',
                  ),
                ],
              ),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: DpcColors.accentNegative.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: DpcColors.accentNegative.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: DpcColors.accentNegative,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: DpcColors.accentNegative,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // Real-time step progress feedback if confirming
            if (_isSuccess)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: DpcColors.accentPositive.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: DpcColors.accentPositive.withValues(alpha: 0.5),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.check_circle_rounded,
                      color: DpcColors.accentPositive,
                      size: 20,
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Transactions Synced Successfully!',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            else if (_isSyncing)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: DpcColors.bgOled,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: DpcColors.accentPositive.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              DpcColors.accentPositive,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _syncSteps[_currentStep],
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: const LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: DpcColors.surfaceTrack,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          DpcColors.accentPositive,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              // Live step message indicator
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline_rounded,
                      color: DpcColors.textMuted,
                      size: 13,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _syncSteps[_currentStep],
                        style: const TextStyle(
                          color: DpcColors.textMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // The Sliding Action Slider
              DpcSlideToConfirm(
                label: 'Slide to Fetch Transactions  ››',
                completedLabel: 'Fetching & Decrypting...',
                onConfirmed: _handleSliderConfirmed,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSecurityRow({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: DpcColors.accentPositive, size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
