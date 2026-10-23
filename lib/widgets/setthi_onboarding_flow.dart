import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import '../providers/auth_providers.dart';
import '../providers/chat_providers.dart';
import '../providers/pdf_statement_provider.dart';
import '../providers/supabase_provider.dart';
import '../providers/transaction_providers.dart';
import '../services/pdf_statement_parser_service.dart';
import 'ai_companion_rive_widget.dart';

/// 3-Minute Cleo-Style Onboarding & Bank Linking Experience for PDF Statements.
/// 
/// Step 1: Meet Setthi (Witty Persona & Hook intro)
/// Step 2: Connect Your Bank (Encrypted, read-only PDF statement ingestion)
/// Step 3: Confirm Your Payday (Automated salary deposit detection & Safe-to-Spend calibration)
/// Completion: Seeds the spending icebreaker hook and navigates directly to Setthi AI Chat.
class SetthiOnboardingFlow extends ConsumerStatefulWidget {
  final VoidCallback? onComplete;
  final int initialPage;

  const SetthiOnboardingFlow({
    super.key,
    this.onComplete,
    this.initialPage = 1,
  });

  static Future<void> show(
    BuildContext context, {
    VoidCallback? onComplete,
    int initialPage = 1,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      enableDrag: false,
      builder: (_) => SetthiOnboardingFlow(
        onComplete: onComplete,
        initialPage: initialPage,
      ),
    );
  }

  @override
  ConsumerState<SetthiOnboardingFlow> createState() => _SetthiOnboardingFlowState();
}

class _SetthiOnboardingFlowState extends ConsumerState<SetthiOnboardingFlow> {
  late final PageController _pageController;
  late int _currentPage;

  // Payday & Inflow Calibration State
  int _selectedPayday = 28;
  double _selectedSalaryAmount = 50000.0;
  bool _detectedSalaryAutomatically = false;
  String? _detectedEmployerOrNarration;
  String _selectedIncomeType = 'Salaried';
  bool _isConfirmingPayday = false;
  PdfStatementParseResult? _cachedParseResult;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _pageController = PageController(initialPage: widget.initialPage);
    _cachedParseResult = null;
    Future.microtask(() {
      if (mounted) {
        ref.read(pdfStatementImportProvider.notifier).reset();
      }
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _nextPage() {
    HapticFeedback.lightImpact();
    if (_currentPage < 2) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  void _previousPage() {
    HapticFeedback.lightImpact();
    if (_currentPage > widget.initialPage) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  String _getOrdinal(int day) {
    if (day >= 11 && day <= 13) return '${day}th';
    switch (day % 10) {
      case 1:
        return '${day}st';
      case 2:
        return '${day}nd';
      case 3:
        return '${day}rd';
      default:
        return '${day}th';
    }
  }

  /// Automatically calibrates the user's primary income / allowance cadence from parsed transactions
  void _calibratePaydayFromTransactions(List<BankTransaction> transactions) {
    if (transactions.isEmpty) return;

    final credits = transactions.where((t) => t.isCredit).toList();
    if (credits.isEmpty) return;

    final salaryKeywords = [
      'SALARY',
      'PAYROLL',
      'STIPEND',
      'SAL CR',
      'DIRECT DEP',
      'ACH CR',
      'SALARY CR',
      'NEFT-SAL',
    ];

    BankTransaction? detectedTxn;
    bool isExplicitSalary = false;

    // 1. Keyword search in credit transactions
    for (final txn in credits) {
      final combined = '${txn.narration} ${txn.cleanMerchantName}'.toUpperCase();
      if (salaryKeywords.any((kw) => combined.contains(kw))) {
        detectedTxn = txn;
        isExplicitSalary = true;
        break;
      }
    }

    // 2. Fallback to highest monthly deposit (typical for salaried or allowance accounts)
    if (detectedTxn == null) {
      credits.sort((a, b) => b.amount.compareTo(a.amount));
      if (credits.first.amount >= 5000) {
        detectedTxn = credits.first;
      }
    }

    if (detectedTxn != null) {
      final rawName = detectedTxn.cleanMerchantName.trim();
      final hasMeaningfulName = rawName.isNotEmpty && rawName != 'Transaction';

      setState(() {
        _selectedPayday = detectedTxn!.transactionTimestamp.day.clamp(1, 31);
        _selectedSalaryAmount = detectedTxn.amount;
        _detectedSalaryAutomatically = true;
        _selectedIncomeType = isExplicitSalary ? 'Salaried' : 'Allowance';
        _detectedEmployerOrNarration = hasMeaningfulName ? rawName : null;
      });
    }
  }

  /// Cleo-style customized icebreaker data generated based on parsed transactions and archetype
  SetthiIcebreakerData _buildIcebreakerData(
    List<BankTransaction> transactions, {
    String? primaryArchetype,
  }) {
    final debits = transactions.where((t) => t.isDebit).toList();

    // Group debits by category
    final Map<String, double> categoryTotals = {};
    for (final t in debits) {
      final cat = t.category?.trim().isNotEmpty == true ? t.category!.trim() : 'Other';
      categoryTotals[cat] = (categoryTotals[cat] ?? 0.0) + t.amount;
    }

    // Identify food/dining spend
    double foodAmount = 0.0;
    categoryTotals.forEach((cat, amt) {
      final upper = cat.toUpperCase();
      if (upper.contains('FOOD') || upper.contains('DINING') || upper.contains('RESTAURANT')) {
        foodAmount += amt;
      }
    });

    if (foodAmount == 0.0) {
      for (final t in debits) {
        final n = t.narration.toUpperCase();
        if (n.contains('SWIGGY') ||
            n.contains('ZOMATO') ||
            n.contains('STARBUCKS') ||
            n.contains('MCDONALD') ||
            n.contains('BLINKIT') ||
            n.contains('ZEPTO')) {
          foodAmount += t.amount;
        }
      }
    }

    // Identify top non-transfer category
    String? topCategory;
    double topCategoryAmount = 0.0;
    categoryTotals.forEach((cat, amt) {
      final upper = cat.toUpperCase();
      if (!upper.contains('TRANSFER') && amt > topCategoryAmount) {
        topCategoryAmount = amt;
        topCategory = cat;
      }
    });

    String spendingSubject = 'food delivery';
    if (foodAmount > 0) {
      spendingSubject = 'food delivery (₹${BankTransaction.formatRupees(foodAmount, showDecimals: false)})';
    } else if (topCategory != null) {
      spendingSubject = '${topCategory!.toLowerCase()} (₹${BankTransaction.formatRupees(topCategoryAmount, showDecimals: false)})';
    }

    final archetypeHook = primaryArchetype != null
        ? " Looks like your money archetype is the **$primaryArchetype**."
        : "";

    final greeting =
        "I've finished looking through your transactions.$archetypeHook Want me to tell you how much you spent on $spendingSubject last month, or should I just roast you right now?";

    final chips = [
      if (primaryArchetype != null) 'Explain my $primaryArchetype archetype',
      foodAmount > 0 ? 'How much on food?' : 'Top spending areas',
      'Roast my spending right now',
      'What is my daily safe limit?',
    ];

    return SetthiIcebreakerData(
      greeting: greeting,
      promptChips: chips,
      topCategory: topCategory,
      topCategoryAmount: topCategoryAmount,
      totalDebitAmount: debits.fold<double>(0.0, (double sum, t) => sum + t.amount),
    );
  }

  /// Confirms payday / allowance baseline and finishes onboarding flow
  Future<void> _handleConfirmPayday() async {
    setState(() => _isConfirmingPayday = true);
    HapticFeedback.mediumImpact();

    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      final user = ref.read(currentUserProvider);

      if (user != null) {
        await dbService.upsertProfile(
          userId: user.id,
          email: user.email ?? '',
          incomeType: _selectedIncomeType,
          expectedMonthlyIncome: _selectedSalaryAmount,
        );
        ref.invalidate(userProfileProvider);
      }

      final commitmentName = _selectedIncomeType == 'Allowance'
          ? 'Monthly Allowance'
          : (_selectedIncomeType == 'Freelancer'
              ? 'Freelance Income'
              : 'Monthly Salary / Payday');

      await dbService.upsertRecurringCommitment(
        merchantName: commitmentName,
        expectedAmount: _selectedSalaryAmount,
        typicalDueDay: _selectedPayday,
        category: 'Income',
        frequency: 'MONTHLY',
        isConfirmed: true,
      );

      // Invalidate relevant providers across the application
      ref.invalidate(cashflowRhythmProvider);
      ref.invalidate(recurringCommitmentsProvider);
      ref.invalidate(transactionFeedProvider);
      ref.invalidate(telemetryMetricsProvider);
      ref.invalidate(habitProfileProvider);

      // Fetch newly computed habit profile and archetype from Supabase
      String? primaryArchetype;
      try {
        final habitData = await dbService.fetchHabitProfile();
        final archetypeMap = habitData?['archetype'] as Map<String, dynamic>?;
        primaryArchetype = archetypeMap?['primary']?['name']?.toString();
      } catch (_) {}

      // Seed the Cleo-style Icebreaker Prompt
      final transactions = _cachedParseResult?.transactions ?? [];
      final icebreakerData = _buildIcebreakerData(
        transactions,
        primaryArchetype: primaryArchetype,
      );

      ref.read(setthiIcebreakerProvider.notifier).setIcebreaker(icebreakerData);
      ref.read(chatMessagesProvider.notifier).seedIcebreakerMessage(icebreakerData.greeting);

      if (mounted) {
        Navigator.of(context).pop();
        widget.onComplete?.call();
      }
    } catch (e) {
      debugPrint('[SetthiOnboarding] Error saving payday: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save payday: $e'),
            backgroundColor: DpcColors.accentNegative,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isConfirmingPayday = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.90,
      ),
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          left: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          right: BorderSide(color: DpcColors.surfaceBorder, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            children: [
              // Drag & progress header
              _buildTopHeader(),

              // Page content
              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    _buildStep1MeetSetthi(),
                    _buildStep2ConnectBank(),
                    _buildStep3ConfirmPayday(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
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
          const SizedBox(height: 14),

          // Steps indicator
          Row(
            children: [
              if (_currentPage > widget.initialPage)
                IconButton(
                  onPressed: _previousPage,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 16),
                  color: DpcColors.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                )
              else
                const SizedBox(width: 32),
              const Spacer(),
              // Step indicator pills
              Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(
                  widget.initialPage == 1 ? 2 : 3,
                  (index) {
                    final displayStep = widget.initialPage == 1 ? index + 1 : index;
                    final isActive = displayStep == _currentPage;
                    final isDone = displayStep < _currentPage;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      width: isActive ? 24 : 8,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isActive
                            ? DpcColors.accentPositive
                            : (isDone
                                ? DpcColors.accentPositive.withValues(alpha: 0.5)
                                : DpcColors.surfaceBorder),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  },
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 20),
                color: DpcColors.textMuted,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ==========================================
  // STEP 1: MEET SETTHI (HOOK & PERSONA INTRO)
  // ==========================================
  Widget _buildStep1MeetSetthi() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        children: [
          const SizedBox(height: 12),

          // Animated Mascot with subtle circular pedestal
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(
                color: DpcColors.surfaceBorder,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: DpcColors.accentPositive.withValues(alpha: 0.12),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const ClipOval(
              child: AiCompanionRiveWidget(
                size: 110,
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Cleo Persona Tag
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: DpcColors.surfaceBorder),
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
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'MEET SETTHI',
                  style: TextStyle(
                    color: DpcColors.accentPositive,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Main Headline & Cleo Hook
          const Text(
            'Your AI money coach that won\'t bore you to tears.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'The money coach you can actually talk to — here to help you get your shit together without corporate banking BS or painful spreadsheets.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 13,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 24),

          // Feature Highlights
          _buildFeatureRow(
            icon: Icons.chat_bubble_outline_rounded,
            title: 'Talks like a real human',
            subtitle: 'Ask about food orders, balance checks, or your spending in plain English.',
          ),
          const SizedBox(height: 12),
          _buildFeatureRow(
            icon: Icons.shield_outlined,
            title: '100% on-device & read-only',
            subtitle: 'Direct statement import. We can never move or touch your money.',
          ),
          const SizedBox(height: 12),
          _buildFeatureRow(
            icon: Icons.speed_rounded,
            title: 'Daily safe limit',
            subtitle: 'Know exactly how much you can spend each day without running out of money.',
          ),
          const SizedBox(height: 32),

          // CTA Button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _nextPage,
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.accentPositive,
                foregroundColor: DpcColors.textContrast,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Get Started',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward_rounded, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureRow({
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DpcColors.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: DpcColors.surfaceBorder, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: DpcColors.surfaceDark,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: DpcColors.accentPositive, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 11.5,
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

  // ==========================================
  // STEP 2: CONNECT YOUR BANK (PDF INGESTION)
  // ==========================================
  Widget _buildStep2ConnectBank() {
    final importState = ref.watch(pdfStatementImportProvider);
    final result = _cachedParseResult;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          const Text(
            'Connect Your Bank',
            style: TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Upload your official bank statement PDF. We read your transactions privately on your device.',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),

          // Security Trust Badges
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DpcColors.surfaceBorder),
            ),
            child: const Row(
              children: [
                Icon(Icons.lock_outline_rounded, color: DpcColors.accentPositive, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Encrypted & Read-only • 90-day instant balance & transaction pull',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Interactive PDF Ingestion Box
          if (importState.isProcessing) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: DpcColors.accentPositive.withValues(alpha: 0.3)),
              ),
              child: Column(
                children: [
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: DpcColors.accentPositive,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    importState.statusMessage ?? 'Parsing bank statement...',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Reading statement & calculating cashflow rhythm...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: DpcColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ] else if (result != null && result.success) ...[
            // Success Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: DpcColors.accentPositive.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: DpcColors.accentPositive.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      color: DpcColors.accentPositive,
                      size: 28,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Statement Added Successfully',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Extracted ${result.totalCount} transactions from ${result.fileName}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _buildMiniBadge(
                        label: '${result.transactions.where((t) => t.isCredit).length} Credits',
                        color: DpcColors.accentPositive,
                      ),
                      _buildMiniBadge(
                        label: '${result.transactions.where((t) => t.isDebit).length} Debits',
                        color: DpcColors.textSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () {
                  _cachedParseResult = result;
                  _calibratePaydayFromTransactions(result.transactions);
                  _nextPage();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: DpcColors.accentPositive,
                  foregroundColor: DpcColors.textContrast,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Continue to Payday Calibration',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                    SizedBox(width: 8),
                    Icon(Icons.arrow_forward_rounded, size: 18),
                  ],
                ),
              ),
            ),
          ] else ...[
            // Prompt Card
            if (importState.errorMessage != null) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 16),
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
                    const Icon(Icons.error_outline_rounded, color: DpcColors.accentNegative, size: 18),
                    const SizedBox(width: 10),
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
              ),
            ],

            GestureDetector(
              onTap: () async {
                final parseRes = await ref.read(pdfStatementImportProvider.notifier).pickAndParsePdf();
                if (parseRes != null && parseRes.success && mounted) {
                  setState(() => _cachedParseResult = parseRes);
                  _calibratePaydayFromTransactions(parseRes.transactions);
                  _nextPage();
                }
              },
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1.5,
                  ),
                ),
                child: Column(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: DpcColors.accentPositive.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.picture_as_pdf_rounded,
                          color: DpcColors.accentPositive,
                          size: 28,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
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
                      'Supports HDFC, ICICI, SBI, Axis, Kotak & standard netbanking exports',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 18),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: DpcColors.surfaceDark,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: DpcColors.surfaceBorder),
                      ),
                      child: const Text(
                        'Encrypted & processed securely on-device',
                        style: TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final parseRes = await ref.read(pdfStatementImportProvider.notifier).pickAndParsePdf();
                  if (parseRes != null && parseRes.success && mounted) {
                    setState(() => _cachedParseResult = parseRes);
                    _calibratePaydayFromTransactions(parseRes.transactions);
                    _nextPage();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: DpcColors.accentPositive,
                  foregroundColor: DpcColors.textContrast,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.folder_open_rounded, size: 20),
                label: const Text(
                  'Choose PDF Statement',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMiniBadge({required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  // ==========================================
  // STEP 3: CONFIRM YOUR PAYDAY (AUTOMATED CALIBRATION)
  // ==========================================
  Widget _buildStep3ConfirmPayday() {
    final ordinalDay = _getOrdinal(_selectedPayday);
    final formattedAmount = BankTransaction.formatRupees(_selectedSalaryAmount, showDecimals: false);

    final title = _selectedIncomeType == 'Allowance'
        ? 'Confirm Your Allowance'
        : (_selectedIncomeType == 'Freelancer'
            ? 'Confirm Inflow Rhythm'
            : 'Confirm Your Payday');

    final subtitle = _selectedIncomeType == 'Allowance'
        ? (_detectedSalaryAutomatically
            ? 'We spotted an allowance transfer on the $ordinalDay ($formattedAmount). Is that when you usually receive it?'
            : 'Select the day you usually receive your allowance or pocket money.')
        : (_selectedIncomeType == 'Freelancer'
            ? 'Select your primary monthly settlement or regular inflow day.'
            : (_detectedSalaryAutomatically
                ? 'We spotted a salary deposit on the $ordinalDay ($formattedAmount). Is that your payday?'
                : 'Select the day of the month you usually get paid to set your daily spending limit.'));

    final badgeLabel = _selectedIncomeType == 'Allowance'
        ? 'From: ${_detectedEmployerOrNarration ?? 'Family / Pocket Money'}'
        : (_selectedIncomeType == 'Salaried'
            ? 'Employer: ${_detectedEmployerOrNarration ?? 'Salary'}'
            : 'Source: ${_detectedEmployerOrNarration ?? 'Direct Inflow'}');

    final noteText = _selectedIncomeType == 'Allowance'
        ? 'Helps calculate how much you can safely spend each day until your next allowance.'
        : 'Helps calculate how much money you can safely spend each day until your next payday.';

    final buttonLabel = _selectedIncomeType == 'Allowance'
        ? 'Yes, confirm allowance'
        : (_selectedIncomeType == 'Freelancer'
            ? 'Yes, confirm rhythm'
            : 'Yes, confirm payday');

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          Text(
            title,
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 6),

          // Adaptive Subtitle
          Text(
            subtitle,
            style: const TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),

          // Income Type Selector
          const Text(
            'INCOME TYPE',
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _buildIncomeTypeChoiceChip('Allowance', 'Allowance'),
              const SizedBox(width: 8),
              _buildIncomeTypeChoiceChip('Salaried', 'Salary'),
              const SizedBox(width: 8),
              _buildIncomeTypeChoiceChip('Freelancer', 'Flexible'),
            ],
          ),
          const SizedBox(height: 16),

          // Main Inflow Display & Stepper Card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: DpcColors.surfaceBorder, width: 1.5),
            ),
            child: Column(
              children: [
                if (_detectedEmployerOrNarration != null && _detectedEmployerOrNarration!.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: DpcColors.surfaceDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: DpcColors.surfaceBorder),
                    ),
                    child: Text(
                      badgeLabel,
                      style: const TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Big Day Display
                Text(
                  ordinalDay,
                  style: const TextStyle(
                    color: DpcColors.accentPositive,
                    fontSize: 48,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
                const Text(
                  'of every month',
                  style: TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),

                // Stepper Buttons (- and +)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.filled(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        setState(() {
                          _selectedPayday = _selectedPayday > 1 ? _selectedPayday - 1 : 31;
                        });
                      },
                      style: IconButton.styleFrom(
                        backgroundColor: DpcColors.surfaceDark,
                        foregroundColor: DpcColors.textPrimary,
                        side: const BorderSide(color: DpcColors.surfaceBorder),
                      ),
                      icon: const Icon(Icons.remove_rounded, size: 20),
                    ),
                    const SizedBox(width: 24),
                    const Text(
                      'Adjust Day',
                      style: TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 24),
                    IconButton.filled(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        setState(() {
                          _selectedPayday = _selectedPayday < 31 ? _selectedPayday + 1 : 1;
                        });
                      },
                      style: IconButton.styleFrom(
                        backgroundColor: DpcColors.surfaceDark,
                        foregroundColor: DpcColors.textPrimary,
                        side: const BorderSide(color: DpcColors.surfaceBorder),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Common quick-pick day chips
          const Text(
            'QUICK SELECT',
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [1, 7, 15, 25, 28, 30, 31].map((day) {
                final isSelected = day == _selectedPayday;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_getOrdinal(day)),
                    selected: isSelected,
                    onSelected: (selected) {
                      if (selected) {
                        HapticFeedback.selectionClick();
                        setState(() => _selectedPayday = day);
                      }
                    },
                    selectedColor: DpcColors.accentPositive,
                    backgroundColor: DpcColors.surfaceElevated,
                    labelStyle: TextStyle(
                      color: isSelected ? DpcColors.textContrast : DpcColors.textPrimary,
                      fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                      fontSize: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(
                        color: isSelected ? DpcColors.accentPositive : DpcColors.surfaceBorder,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 20),

          // Informational note
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: DpcColors.surfaceBorder),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline_rounded, color: DpcColors.accentPositive, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    noteText,
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Primary CTA Button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _isConfirmingPayday ? null : _handleConfirmPayday,
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.accentPositive,
                foregroundColor: DpcColors.textContrast,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _isConfirmingPayday
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: DpcColors.textContrast,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          buttonLabel,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.arrow_forward_rounded, size: 18),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncomeTypeChoiceChip(String typeId, String label) {
    final isSelected = _selectedIncomeType == typeId;
    return Expanded(
      child: ChoiceChip(
        label: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? DpcColors.textContrast : DpcColors.textPrimary,
              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
        selected: isSelected,
        onSelected: (selected) {
          if (selected) {
            HapticFeedback.selectionClick();
            setState(() => _selectedIncomeType = typeId);
          }
        },
        selectedColor: DpcColors.accentPositive,
        backgroundColor: DpcColors.surfaceElevated,
        showCheckmark: false,
        padding: const EdgeInsets.symmetric(vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isSelected ? DpcColors.accentPositive : DpcColors.surfaceBorder,
          ),
        ),
      ),
    );
  }
}
