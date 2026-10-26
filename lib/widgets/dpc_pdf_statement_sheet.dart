import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/pdf_statement_provider.dart';
import '../services/pdf_statement_parser_service.dart';

/// Interactive modal sheet to pick a bank statement PDF, extract tabular transactions,
/// and generate/preview the Supabase-compliant CSV file saved to the root directory.
class DpcPdfStatementSheet extends ConsumerStatefulWidget {
  const DpcPdfStatementSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (modalContext) => const DpcPdfStatementSheet(),
    );
  }

  @override
  ConsumerState<DpcPdfStatementSheet> createState() => _DpcPdfStatementSheetState();
}

class _DpcPdfStatementSheetState extends ConsumerState<DpcPdfStatementSheet> {
  late final TextEditingController _passwordController;
  bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _passwordController = TextEditingController();
    Future.microtask(() {
      if (mounted) {
        ref.read(pdfStatementImportProvider.notifier).reset();
      }
    });
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final importState = ref.watch(pdfStatementImportProvider);
    final result = importState.result;

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
        maxHeight: MediaQuery.of(context).size.height * 0.88,
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
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: DpcColors.accentPositive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Center(
                  child: Icon(
                    Icons.picture_as_pdf_rounded,
                    color: DpcColors.accentPositive,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Import Bank Statement',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.4,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Securely import and organize your transactions',
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
                icon: const Icon(
                  Icons.close_rounded,
                  color: DpcColors.textMuted,
                  size: 20,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // Main Content
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (importState.isPasswordProtected) ...[
                    _buildPasswordPrompt(importState),
                  ] else if (importState.isProcessing) ...[
                    _buildLoadingCard(importState.statusMessage ?? 'Processing statement...'),
                  ] else if (result != null && result.success) ...[
                    _buildSuccessResult(result),
                  ] else ...[
                    _buildUploadPrompt(importState.errorMessage),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPasswordPrompt(PdfStatementImportState importState) {
    final isUnlocking = importState.isProcessing;
    final hasError = importState.errorMessage != null;

    Future<void> submitPassword() async {
      final pwd = _passwordController.text.trim();
      if (pwd.isEmpty) {
        HapticFeedback.mediumImpact();
        ref.read(pdfStatementImportProvider.notifier).setError('Please enter the statement password.');
        return;
      }
      final parseRes = await ref
          .read(pdfStatementImportProvider.notifier)
          .unlockWithPassword(pwd);
      if (parseRes != null && parseRes.success) {
        HapticFeedback.lightImpact();
      } else {
        HapticFeedback.mediumImpact();
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
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
              Text(
                'Enter the password to open "${importState.pendingFileName ?? 'this statement'}" (often your PAN in UPPERCASE or Date of Birth in DDMMYYYY format).',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: _passwordController,
                obscureText: !_showPassword,
                autofocus: true,
                enabled: !isUnlocking,
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 14,
                ),
                onChanged: (_) {
                  if (importState.errorMessage != null) {
                    ref.read(pdfStatementImportProvider.notifier).clearError();
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
                onSubmitted: (_) => submitPassword(),
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
                        importState.errorMessage!,
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
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: isUnlocking
                    ? null
                    : () {
                        _passwordController.clear();
                        ref.read(pdfStatementImportProvider.notifier).reset();
                      },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: DpcColors.surfaceBorder),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Cancel', style: TextStyle(color: DpcColors.textSecondary)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: isUnlocking ? null : submitPassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: DpcColors.accentPositive,
                  foregroundColor: DpcColors.textContrast,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: isUnlocking
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: DpcColors.textContrast,
                        ),
                      )
                    : const Text('Unlock', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUploadPrompt(String? errorMessage) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    errorMessage,
                    style: const TextStyle(
                      color: DpcColors.accentNegative,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Dotted picker container
        GestureDetector(
          onTap: () => ref.read(pdfStatementImportProvider.notifier).pickAndParsePdf(),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
            decoration: BoxDecoration(
              color: DpcColors.bgOled,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: DpcColors.surfaceBorder,
                width: 1.5,
              ),
            ),
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceTrack,
                    shape: BoxShape.circle,
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.upload_file_rounded,
                      color: DpcColors.accentPositive,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Select Bank Statement PDF',
                  style: TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Supports HDFC, SBI, ICICI, Axis, Kotak & standard statements',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceTrack,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 13,
                        color: DpcColors.accentPositive,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Read-only & encrypted on your device',
                        style: TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton.icon(
            onPressed: () => ref.read(pdfStatementImportProvider.notifier).pickAndParsePdf(),
            style: ElevatedButton.styleFrom(
              backgroundColor: DpcColors.accentPositive,
              foregroundColor: DpcColors.textContrast,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            icon: const Icon(Icons.folder_open_rounded, size: 20),
            label: const Text(
              'Choose PDF File',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingCard(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
      decoration: BoxDecoration(
        color: DpcColors.bgOled,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: DpcColors.surfaceBorder),
      ),
      child: Column(
        children: [
          const SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: DpcColors.accentPositive,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Reading transactions and calculating cash flow cadence...',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessResult(PdfStatementParseResult result) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Success Header Badge
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: DpcColors.accentPositive.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: DpcColors.accentPositive.withValues(alpha: 0.25),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.check_circle_rounded,
                    color: DpcColors.accentPositive,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${result.totalCount} Transactions Imported Successfully',
                      style: const TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Metrics Breakdown
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _buildStatPill('Debits', '${result.debitCount} (${BankTransaction.formatRupees(result.totalDebitAmount)})'),
                  _buildStatPill('Credits', '${result.creditCount} (${BankTransaction.formatRupees(result.totalCreditAmount)})'),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Synchronization Status Card
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: DpcColors.bgOled,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: DpcColors.surfaceBorder),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                color: DpcColors.accentPositive,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Account Feed Updated',
                      style: TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${result.totalCount} transactions verified and organized into your feed',
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        // Transactions Preview
        const Text(
          'Transactions Preview',
          style: TextStyle(
            color: DpcColors.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),

        Container(
          decoration: BoxDecoration(
            color: DpcColors.bgOled,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DpcColors.surfaceBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: min(result.transactions.length, 8),
              separatorBuilder: (ctx, i) => const Divider(
                color: DpcColors.surfaceBorder,
                height: 1,
              ),
              itemBuilder: (context, idx) {
                final t = result.transactions[idx];
                final isCr = t.type == TransactionType.credit;
                final dateStr = '${t.transactionTimestamp.day.toString().padLeft(2, '0')}/${t.transactionTimestamp.month.toString().padLeft(2, '0')}/${t.transactionTimestamp.year}';

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                        decoration: BoxDecoration(
                          color: isCr
                              ? DpcColors.accentPositive.withValues(alpha: 0.12)
                              : DpcColors.accentNegative.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          isCr ? 'CR' : 'DR',
                          style: TextStyle(
                            color: isCr ? DpcColors.accentPositive : DpcColors.accentNegative,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.cleanMerchantName,
                              style: const TextStyle(
                                color: DpcColors.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '$dateStr • ${t.category ?? 'Uncategorized'}',
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
                            BankTransaction.formatRupees(t.amount),
                            style: TextStyle(
                              color: isCr ? DpcColors.accentPositive : DpcColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (t.currentBalance > 0) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Bal: ${BankTransaction.formatRupees(t.currentBalance)}',
                              style: const TextStyle(
                                color: DpcColors.textMuted,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        const SizedBox(height: 18),

        // Action Buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  ref.read(pdfStatementImportProvider.notifier).reset();
                },
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: DpcColors.surfaceBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  'Upload Another',
                  style: TextStyle(
                    color: DpcColors.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: () {
                  ref.read(pdfStatementImportProvider.notifier).reset();
                  Navigator.of(context).pop();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: DpcColors.accentPositive,
                  foregroundColor: DpcColors.textContrast,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text(
                  'View Transactions',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatPill(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: DpcColors.surfaceTrack,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $value',
        style: const TextStyle(
          color: DpcColors.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
