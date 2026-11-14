import '../models/merchant_category_model.dart';
import '../models/transaction_model.dart';
import 'gmail_api_service.dart';

/// Structured financial transaction extracted from a Gmail alert
class ExtractedEmailTransaction {
  final String gmailMessageId;
  final double amount;
  final String currency;
  final String merchantName;
  final String? cardLast4;
  final String bankOrIssuer;
  final DateTime transactionDate;
  final TransactionType type;
  final String narration;
  final String? category;
  final bool isRecurring;

  final String paymentMode;
  final bool isStatement;
  final String? statementPdfPath;
  final String? statementPeriod;
  final DateTime? statementDueDate;
  final double? statementTotalDue;
  final double? statementMinDue;

  const ExtractedEmailTransaction({
    required this.gmailMessageId,
    required this.amount,
    required this.currency,
    required this.merchantName,
    this.cardLast4,
    required this.bankOrIssuer,
    required this.transactionDate,
    required this.type,
    required this.narration,
    this.category,
    this.isRecurring = false,
    this.paymentMode = 'CARD',
    this.isStatement = false,
    this.statementPdfPath,
    this.statementPeriod,
    this.statementDueDate,
    this.statementTotalDue,
    this.statementMinDue,
  });

  ExtractedEmailTransaction copyWith({
    bool? isStatement,
    String? statementPdfPath,
    String? statementPeriod,
    DateTime? statementDueDate,
    double? statementTotalDue,
    double? statementMinDue,
  }) {
    return ExtractedEmailTransaction(
      gmailMessageId: gmailMessageId,
      amount: amount,
      currency: currency,
      merchantName: merchantName,
      cardLast4: cardLast4,
      bankOrIssuer: bankOrIssuer,
      transactionDate: transactionDate,
      type: type,
      narration: narration,
      category: category,
      isRecurring: isRecurring,
      paymentMode: paymentMode,
      isStatement: isStatement ?? this.isStatement,
      statementPdfPath: statementPdfPath ?? this.statementPdfPath,
      statementPeriod: statementPeriod ?? this.statementPeriod,
      statementDueDate: statementDueDate ?? this.statementDueDate,
      statementTotalDue: statementTotalDue ?? this.statementTotalDue,
      statementMinDue: statementMinDue ?? this.statementMinDue,
    );
  }

  /// Converts this extracted email transaction into Setthi's standard `BankTransaction`
  BankTransaction toBankTransaction() {
    final match = MerchantCategoryRegistry.instance.findMatch(narration);
    final resolvedCategory = category ?? match?.category;

    return BankTransaction(
      txnId: 'gmail_$gmailMessageId',
      type: type,
      mode: paymentMode,
      amount: amount,
      currentBalance: 0.0,
      transactionTimestamp: transactionDate,
      narration: narration,
      category: resolvedCategory,
      precomputedMerchantName: merchantName,
      isRecurring: isRecurring,
      tagSource: 'gmail_sync',
    );
  }

  Map<String, dynamic> toMap() => {
        'gmail_message_id': gmailMessageId,
        'amount': amount,
        'currency': currency,
        'merchant_name': merchantName,
        'card_last4': cardLast4,
        'bank_or_issuer': bankOrIssuer,
        'transaction_date': transactionDate.toIso8601String(),
        'type': type.value.toUpperCase(),
        'narration': narration,
        'category': category,
        'is_recurring': isRecurring,
        'payment_mode': paymentMode,
        'is_statement': isStatement,
        'statement_pdf_path': statementPdfPath,
        'statement_period': statementPeriod,
        'statement_due_date': statementDueDate?.toIso8601String(),
        'statement_total_due': statementTotalDue,
        'statement_min_due': statementMinDue,
      };
}

/// Structured subscription/recurring commitment extracted from a Gmail alert or invoice
class ExtractedEmailSubscription {
  final String serviceName;
  final double expectedAmount;
  final String currency;
  final int typicalDueDay;
  final String frequency; // 'MONTHLY' or 'YEARLY'
  final DateTime billingDate;
  final String? cardLast4;
  final String category;

  const ExtractedEmailSubscription({
    required this.serviceName,
    required this.expectedAmount,
    required this.currency,
    required this.typicalDueDay,
    required this.frequency,
    required this.billingDate,
    this.cardLast4,
    this.category = 'Subscription',
  });

  Map<String, dynamic> toMap() => {
        'service_name': serviceName,
        'expected_amount': expectedAmount,
        'currency': currency,
        'typical_due_day': typicalDueDay,
        'frequency': frequency,
        'billing_date': billingDate.toIso8601String(),
        'card_last4': cardLast4,
        'category': category,
      };

  Map<String, dynamic> toCommitmentPayload({required String userId}) {
    return {
      'user_id': userId,
      'merchant_name': serviceName,
      'expected_amount': expectedAmount,
      'category': category,
      'frequency': frequency,
      'typical_due_day': typicalDueDay,
      'is_confirmed': true,
      'is_active': true,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }
}

/// Output wrapper containing any detected transaction and/or subscription
class EmailParseOutput {
  final ExtractedEmailTransaction? transaction;
  final ExtractedEmailSubscription? subscription;

  const EmailParseOutput({this.transaction, this.subscription});

  bool get hasData => transaction != null || subscription != null;
}

/// Granular diagnostic result of an email parsing run
class DetailedEmailParseResult {
  final EmailParseOutput output;
  final bool isNoise;
  final String? noiseReason;
  final String detectedIssuer;
  final String? detectedCardLast4;
  final double? detectedAmount;
  final String? detectedCurrency;
  final String? detectedMerchant;
  final bool isSubscriptionSignal;
  final String? subscriptionBrand;
  final String? subscriptionFrequency;
  final String? detectedPaymentMode;

  const DetailedEmailParseResult({
    required this.output,
    required this.isNoise,
    this.noiseReason,
    required this.detectedIssuer,
    this.detectedCardLast4,
    this.detectedAmount,
    this.detectedCurrency,
    this.detectedMerchant,
    required this.isSubscriptionSignal,
    this.subscriptionBrand,
    this.subscriptionFrequency,
    this.detectedPaymentMode,
  });

  bool get isFlaggedAsTransaction => output.transaction != null;
  bool get isFlaggedAsSubscription => output.subscription != null;
  bool get isFlaggedAsStatement => output.transaction?.isStatement == true;
  ExtractedEmailTransaction? get transaction => output.transaction;
  ExtractedEmailSubscription? get subscription => output.subscription;
}

/// Parser that runs on-device to transform decoded Gmail messages into Setthi records.
class EmailTransactionParser {
  // Common subscription brand catalog for precision detection
  static const Map<String, String> _subscriptionCatalog = {
    'netflix': 'Netflix',
    'spotify': 'Spotify',
    'apple': 'Apple Services',
    'itunes': 'Apple Services',
    'google one': 'Google One',
    'youtube premium': 'YouTube Premium',
    'google play': 'Google Play',
    'amazon prime': 'Amazon Prime',
    'prime video': 'Amazon Prime',
    'hotstar': 'Disney+ Hotstar',
    'chatgpt': 'ChatGPT / OpenAI',
    'openai': 'ChatGPT / OpenAI',
    'claude': 'Claude / Anthropic',
    'anthropic': 'Claude / Anthropic',
    'microsoft 365': 'Microsoft 365',
    'office 365': 'Microsoft 365',
    'adobe': 'Adobe Creative Cloud',
    'cult.fit': 'Cult.fit',
    'cult pass': 'Cult.fit',
    'swiggy one': 'Swiggy One',
    'zomato gold': 'Zomato Gold',
    'midjourney': 'Midjourney',
    'github': 'GitHub',
    'canva': 'Canva',
    'notion': 'Notion',
    'figma': 'Figma',
    'linkedin': 'LinkedIn Premium',
    'duolingo': 'Duolingo Plus',
    'sonyliv': 'SonyLIV',
    'zee5': 'Zee5',
    'jiocinema': 'JioCinema',
    'uber one': 'Uber One',
    'blinkit black': 'Blinkit',
    'airtel': 'Airtel',
    'jio': 'Jio',
    'vodafone': 'Vi',
    'vi ': 'Vi',
    'act fibernet': 'ACT Fibernet',
    'tata play': 'Tata Play',
    'tata sky': 'Tata Play',
    'grt jewels': 'GRT Jewellers (JPS)',
    'grt jps': 'GRT Jewellers (JPS)',
    'tanishq': 'Tanishq (Golden Harvest)',
    'golden harvest': 'Tanishq (Golden Harvest)',
    'malabar gold': 'Malabar Gold',
    'joyalukkas': 'Joyalukkas',
    'kalyan jewellers': 'Kalyan Jewellers',
  };

  /// Parses a raw Gmail message on-device and returns structured transaction and subscription data.
  EmailParseOutput parseMessage(GmailRawMessage message) {
    return parseMessageWithDiagnostics(message).output;
  }

  /// Full diagnostic parsing method exposing detailed classification and decision reasons.
  DetailedEmailParseResult parseMessageWithDiagnostics(GmailRawMessage message) {
    final text = '${message.subject}\n${message.bodyText}'.trim();
    final lower = text.toLowerCase();

    // Extract original sender if this is a forwarded email
    final effectiveFrom = _extractEffectiveSender(message.from, message.bodyText);

    // 1. Detect if this is an official Credit Card e-Statement or periodic Account Statement
    final isStatement = _isCreditCardStatement(
      subject: message.subject,
      bodyText: message.bodyText,
      from: effectiveFrom,
      attachments: message.attachments,
    );

    if (isStatement) {
      return _parseStatementEmail(message, text, lower, effectiveFrom: effectiveFrom);
    }

    // 2. Noise Filter: Disqualify OTPs, security codes, failed transactions, free trials, and newsletters
    final noiseReason = _detectNoiseReason(
      lower: lower,
      from: effectiveFrom,
      subject: message.subject,
    );
    if (noiseReason != null) {
      return DetailedEmailParseResult(
        output: const EmailParseOutput(),
        isNoise: true,
        noiseReason: noiseReason,
        detectedIssuer: 'None',
        isSubscriptionSignal: false,
      );
    }

    // 3. Extract Bank / Issuer
    final issuer = _detectBankOrIssuer(effectiveFrom, lower);
    final isBankAlertSender = _isBankSender(effectiveFrom);

    // 4. For non-bank senders, ensure it is an actual confirmed transaction, order, or receipt
    if (!isBankAlertSender && !_isConfirmedPaymentOrReceipt(lower)) {
      return DetailedEmailParseResult(
        output: const EmailParseOutput(),
        isNoise: true,
        noiseReason: 'Not a confirmed payment, order confirmation, or receipt (Non-bank sender)',
        detectedIssuer: issuer,
        isSubscriptionSignal: false,
      );
    }

    // 5. Extract Amount & Currency
    final amountInfo = _extractAmountAndCurrency(text);
    if (amountInfo == null) {
      return DetailedEmailParseResult(
        output: const EmailParseOutput(),
        isNoise: true,
        noiseReason: 'No currency amount found matching financial patterns',
        detectedIssuer: issuer,
        isSubscriptionSignal: false,
      );
    }

    final double amount = amountInfo.amount;
    final String currency = amountInfo.currency;

    // 5. Extract Card Last 4
    final cardLast4 = _extractCardLast4(text);

    // 6. Detect Transaction Type (Debit vs Credit / Refund)
    final type = _detectTransactionType(lower);

    // 7. Detect Subscription / Recurring / Systematic Scheme Status
    final subscriptionBrand = _matchSubscriptionBrand(lower);

    final isJewelleryScheme = lower.contains('jewellery purchase plan') ||
        lower.contains('jewellery purchase') ||
        lower.contains('scheme amount') ||
        lower.contains('gold scheme') ||
        lower.contains('grt jps') ||
        lower.contains('golden harvest');

    final isTelecomOrUtilityRecurring = lower.contains('payment confirmation for your airtel account') ||
        lower.contains('towards your airtel account') ||
        lower.contains('towards your jio account') ||
        (lower.contains('payment confirmation for your') &&
            (lower.contains('account') || lower.contains('broadband') || lower.contains('mobile')));

    final isInsuranceRecurring = lower.contains('insurance premium') ||
        lower.contains('policy renewal') ||
        lower.contains('premium paid') ||
        (lower.contains('premium') && lower.contains('policy'));

    final hasExplicitRecurringSignal = subscriptionBrand != null ||
        isJewelleryScheme ||
        isTelecomOrUtilityRecurring ||
        isInsuranceRecurring ||
        lower.contains('subscription renewed') ||
        lower.contains('membership renewed') ||
        lower.contains('recurring charge') ||
        lower.contains('recurring payment') ||
        lower.contains('recurring billing') ||
        lower.contains('auto-pay debited') ||
        lower.contains('mandate debited') ||
        lower.contains('plan renewed') ||
        lower.contains('monthly membership') ||
        lower.contains('annual membership');

    // 8. Extract Merchant / Payee Name (sender-aware)
    String merchantName;
    if (isJewelleryScheme) {
      if (lower.contains('grt')) {
        merchantName = 'GRT Jewellers (JPS)';
      } else if (lower.contains('tanishq')) {
        merchantName = 'Tanishq (Golden Harvest)';
      } else if (lower.contains('malabar')) {
        merchantName = 'Malabar Gold (Smart Buy)';
      } else if (lower.contains('joyalukkas')) {
        merchantName = 'Joyalukkas';
      } else {
        merchantName = 'Jewellery Purchase Plan';
      }
    } else if (isTelecomOrUtilityRecurring) {
      if (lower.contains('airtel')) {
        merchantName = 'Airtel';
      } else if (lower.contains('jio')) {
        merchantName = 'Jio';
      } else if (lower.contains('vodafone') || lower.contains('vi ')) {
        merchantName = 'Vi';
      } else {
        merchantName = _resolveMerchantName(
          from: effectiveFrom,
          subject: message.subject,
          bodyText: message.bodyText,
          issuer: issuer,
          subscriptionBrand: subscriptionBrand,
        );
      }
    } else {
      merchantName = _resolveMerchantName(
        from: effectiveFrom,
        subject: message.subject,
        bodyText: message.bodyText,
        issuer: issuer,
        subscriptionBrand: subscriptionBrand,
      );
    }

    final isSubscriptionSignal = hasExplicitRecurringSignal &&
        (subscriptionBrand != null || isJewelleryScheme || isTelecomOrUtilityRecurring || isInsuranceRecurring || !lower.contains('order confirmation'));

    String resolvedCategory = 'Subscription';
    if (isJewelleryScheme) {
      resolvedCategory = 'Savings & Schemes';
    } else if (isTelecomOrUtilityRecurring || lower.contains('airtel') || lower.contains('jio') || lower.contains('broadband') || lower.contains('electricity')) {
      resolvedCategory = 'Bills & Utilities';
    } else if (isInsuranceRecurring) {
      resolvedCategory = 'Insurance';
    }

    // 9. Detect Payment Mode (DEBIT_CARD, CREDIT_CARD, UPI, CASH, NET_BANKING, CARD)
    final paymentMode = _detectPaymentMode(
      text: text,
      cardLast4: cardLast4,
      issuer: issuer,
    );

    // 10. Build ExtractedEmailTransaction
    final cleanNarration = _buildCleanNarration(
      issuer: isTelecomOrUtilityRecurring || isJewelleryScheme ? merchantName : issuer,
      merchant: merchantName,
      cardLast4: cardLast4,
      amount: amount,
      currency: currency,
    );

    final transaction = ExtractedEmailTransaction(
      gmailMessageId: message.id,
      amount: amount,
      currency: currency,
      merchantName: merchantName,
      cardLast4: cardLast4,
      bankOrIssuer: isTelecomOrUtilityRecurring || isJewelleryScheme ? merchantName : issuer,
      transactionDate: message.date,
      type: type,
      narration: cleanNarration,
      category: isSubscriptionSignal ? resolvedCategory : null,
      isRecurring: isSubscriptionSignal,
      paymentMode: paymentMode,
    );

    // 11. If recurring / subscription / systematic scheme, build ExtractedEmailSubscription
    ExtractedEmailSubscription? subscription;
    String? frequency;
    if (isSubscriptionSignal && amount > 0) {
      frequency = (lower.contains('annual') ||
              lower.contains('yearly') ||
              lower.contains('per year') ||
              lower.contains('/year') ||
              lower.contains('12 months') ||
              merchantName.toLowerCase().contains('godaddy') ||
              merchantName.toLowerCase().contains('namecheap') ||
              (isInsuranceRecurring && !lower.contains('monthly')))
          ? 'YEARLY'
          : 'MONTHLY';

      subscription = ExtractedEmailSubscription(
        serviceName: merchantName,
        expectedAmount: amount,
        currency: currency,
        typicalDueDay: message.date.day,
        frequency: frequency,
        billingDate: message.date,
        cardLast4: cardLast4,
        category: resolvedCategory,
      );
    }

    return DetailedEmailParseResult(
      output: EmailParseOutput(
        transaction: transaction,
        subscription: subscription,
      ),
      isNoise: false,
      detectedIssuer: issuer,
      detectedCardLast4: cardLast4,
      detectedAmount: amount,
      detectedCurrency: currency,
      detectedMerchant: merchantName,
      isSubscriptionSignal: isSubscriptionSignal,
      subscriptionBrand: subscriptionBrand,
      subscriptionFrequency: frequency,
      detectedPaymentMode: paymentMode,
    );
  }

  String? _detectNoiseReason({
    required String lower,
    required String from,
    required String subject,
  }) {
    final lowerFrom = from.toLowerCase();
    final lowerSub = subject.toLowerCase();

    // 1. Newsletters, substacks, creator broadcasts, and editorial blogs
    if (lowerFrom.contains('simon squibb') ||
        lowerFrom.contains('helpbnk') ||
        lowerFrom.contains('substack.com') ||
        lowerFrom.contains('beehiiv.com') ||
        lowerFrom.contains('medium.com') ||
        lower.contains('view this post on the web at') ||
        (lower.contains('view in browser') && lower.contains('unsubscribe'))) {
      // Allow through only if it contains an unequivocal order number or tax invoice
      final hasStrictReceiptProof = lower.contains('order number') ||
          lower.contains('tax invoice') ||
          lower.contains('invoice number') ||
          lower.contains('receipt #');
      if (!hasStrictReceiptProof) {
        return 'Newsletter / Article Publication / Creator Broadcast (Non-transactional)';
      }
    }

    // (Statements & periodic account summaries are processed as first-class statements in step 1 above)

    // 2. Savings Bank Account Statements and Interest payouts (Non-credit card)
    if (lowerSub.contains('savings bank account statement') ||
        lowerSub.contains('savings account statement') ||
        lower.contains('savings bank account statement') ||
        lower.contains('savings account statement') ||
        (lower.contains('interest') && lower.contains('earned'))) {
      return 'Savings Account Statement / Interest Notification (Non-credit card)';
    }

    // 3. Bank charge / Non-Maintenance charge intimations (not completed debits)
    if (lower.contains('will be debited from your account') ||
        lower.contains('will be debited towards') ||
        lower.contains('charge will be debited') ||
        lower.contains('charges will be debited')) {
      return 'Bank Fee / Charge Intimation (Not a completed debit)';
    }

    // 4. OTPs & verification codes
    if (lowerSub.contains('one time password') ||
        lowerSub.contains('otp') ||
        lowerSub.contains('verification code') ||
        lowerSub.contains('password reset') ||
        lowerSub.contains('login alert')) {
      return 'OTP / Verification Code / Security Alert';
    }

    if (lower.contains('one time password') ||
        lower.contains('otp is') ||
        lower.contains('is your otp') ||
        lower.contains('your otp for') ||
        lower.contains('your verification code is') ||
        lower.contains('verification code is') ||
        lower.contains('is your verification code') ||
        lower.contains('your security code is') ||
        lower.contains('login alert') ||
        lower.contains('password reset')) {
      final isSuccessTxn = lowerSub.contains('transaction success') ||
          lowerSub.contains('successful') ||
          lowerSub.contains('debited') ||
          lowerSub.contains('credit alert');

      if (!isSuccessTxn ||
          lower.contains('otp is') ||
          lower.contains('is your otp') ||
          lower.contains('your otp for')) {
        return 'OTP / Verification Code / Security Alert';
      }
    }

    // 5. Failed transactions
    if (lower.contains('transaction failed') ||
        lower.contains('payment failed') ||
        lower.contains('declined') ||
        lower.contains('unsuccessful') ||
        lower.contains('could not be processed')) {
      return 'Failed / Declined Transaction';
    }

    // 6. Free trials and non-billed promos (no actual charge)
    if (lower.contains('trial has started') ||
        lower.contains('trial is ready') ||
        lower.contains('start your trial') ||
        lower.contains('free trial') ||
        lower.contains('trial will end') ||
        lower.contains('trial ends') ||
        lower.contains('no card was needed') ||
        lower.contains('no card needed') ||
        lower.contains('won’t be charged') ||
        lower.contains("won't be charged") ||
        lower.contains('will not be charged') ||
        lower.contains('have not been charged') ||
        lower.contains('no payment needed') ||
        lower.contains('lifetime access is') ||
        lower.contains('if you decide to') ||
        lower.contains('plans start at') ||
        lower.contains('starting at ₹') ||
        lower.contains('starting from ₹')) {
      return 'Free Trial / Pre-purchase Offer (No payment charged)';
    }

    // 7. General marketing & pre-order coupons with no actual transaction confirmation
    if (lower.contains('flat 50%') ||
        lower.contains('discount coupon') ||
        lower.contains('apply now for credit card') ||
        lower.contains('pre-approved loan') ||
        lower.contains('exclusive offers end soon') ||
        lower.contains('offers end soon') ||
        lower.contains('special offers when you') ||
        lower.contains('exclusive coupon code') ||
        lower.contains('instant discount of') ||
        lower.contains('pre-order now') ||
        lower.contains('pre-order the new') ||
        lower.contains('ready for pre-order') ||
        (lower.contains('get ₹') &&
            (lower.contains('off with') ||
                lower.contains('off on') ||
                lower.contains('coupon')))) {
      return 'Promotional Marketing / Pre-purchase Offer';
    }

    return null;
  }

  /// Verifies if an email is an official Credit Card e-Statement or periodic Account Statement
  bool _isCreditCardStatement({
    required String subject,
    required String bodyText,
    required String from,
    List<GmailAttachmentInfo> attachments = const [],
  }) {
    final lowerSub = subject.toLowerCase();
    final lowerBody = bodyText.toLowerCase();
    final lower = '$lowerSub\n$lowerBody';

    // Exclude savings account statements and interest payouts (they are not credit card statements)
    if (lowerSub.contains('savings bank account statement') ||
        lowerSub.contains('savings account statement') ||
        lower.contains('savings bank account statement') ||
        lower.contains('savings account statement') ||
        (lower.contains('earned') && lower.contains('in interest'))) {
      return false;
    }

    final hasPdfAttachment = attachments.any((a) => a.isPdf);
    final hasPdfStatementAttachment = attachments.any(
      (a) => a.isPdf && (a.filename.toLowerCase().contains('statement') || a.filename.toLowerCase().contains('estmt') || a.filename.toLowerCase().contains('bill')),
    );

    // 1. Credit Card Statements
    final hasStatementKeyword = hasPdfStatementAttachment ||
        lowerSub.contains('credit card statement') ||
        lowerSub.contains('e-statement') ||
        lowerSub.contains('estatement') ||
        lowerSub.contains('statement is ready') ||
        lowerSub.contains('statement for your credit card') ||
        lowerSub.contains('statement for card') ||
        lowerSub.contains('billing statement') ||
        lowerSub.contains('monthly statement') ||
        (lowerSub.contains('statement') && (lowerSub.contains('credit') || lowerSub.contains('card'))) ||
        lower.contains('credit card statement for the period') ||
        lower.contains('e-statement for your credit card') ||
        (lower.contains('total amount due') && lower.contains('minimum amount due'));

    if (hasStatementKeyword) return true;

    // 2. Telecom & Utility Bills (e.g. Airtel Mobile, JioFiber, BESCOM)
    final isTelecomOrUtilityBill = (lowerSub.contains('bill for your') ||
            lowerSub.contains('e-bill') ||
            lowerSub.contains('ebill') ||
            lowerSub.contains('mobile bill') ||
            lowerSub.contains('broadband bill') ||
            lowerSub.contains('electricity bill')) &&
        (hasPdfAttachment || lower.contains('amount due') || lower.contains('bill amount') || lower.contains('total amount'));

    return isTelecomOrUtilityBill;
  }

  /// Parses a statement or bill email extracting issuer/provider, last4, due date, total due, and min due
  DetailedEmailParseResult _parseStatementEmail(
    GmailRawMessage message,
    String text,
    String lower, {
    String? effectiveFrom,
  }) {
    final sender = effectiveFrom ?? message.from;
    final lowerSub = message.subject.toLowerCase();
    final issuer = _detectBankOrIssuer(sender, lower);
    final cardLast4 = _extractCardLast4(text);

    final isTelecomOrUtility = lower.contains('airtel') ||
        lower.contains('jio') ||
        lower.contains('vodafone') ||
        lower.contains('vi ') ||
        lower.contains('broadband') ||
        lower.contains('electricity') ||
        lower.contains('telecom') ||
        lower.contains('bescom') ||
        lowerSub.contains('mobile') ||
        lowerSub.contains('bill for your');

    String provider = issuer;
    if (lower.contains('airtel') || lowerSub.contains('airtel')) {
      provider = 'Airtel';
    } else if (lower.contains('jio') || lowerSub.contains('jio')) {
      provider = 'Jio';
    } else if (lower.contains('vodafone') || lower.contains('vi ') || lowerSub.contains('vi ')) {
      provider = 'Vi';
    } else if (lower.contains('bescom') || lowerSub.contains('bescom')) {
      provider = 'BESCOM';
    }

    final category = isTelecomOrUtility ? 'Bills & Utilities' : 'Credit Card Bill';
    final paymentMode = isTelecomOrUtility ? 'ONLINE' : 'CREDIT_CARD';
    final merchantName = isTelecomOrUtility ? provider : '$issuer Credit Card';

    // Extract Total Due Amount
    double totalDue = 0.0;
    final totalDueRegex = RegExp(
      r'(?:total\s+amount\s+due|total\s+due|statement\s+amount|bill\s+amount|amount\s+due|current\s+dues?|balance\s+due)\s*[:\-]?\s*(?:INR|Rs\.?|₹|\$)?\s*([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    );
    final totalDueMatch = totalDueRegex.firstMatch(text);
    if (totalDueMatch != null) {
      final raw = totalDueMatch.group(1)?.replaceAll(',', '').trim();
      if (raw != null) totalDue = double.tryParse(raw) ?? 0.0;
    }

    // Extract Minimum Amount Due
    double? minDue;
    final minDueRegex = RegExp(
      r'(?:minimum\s+amount\s+due|min\s+amount\s+due|minimum\s+due|min\.?\s+due)\s*[:\-]?\s*(?:INR|Rs\.?|₹|\$)?\s*([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    );
    final minDueMatch = minDueRegex.firstMatch(text);
    if (minDueMatch != null) {
      final raw = minDueMatch.group(1)?.replaceAll(',', '').trim();
      if (raw != null) minDue = double.tryParse(raw);
    }

    // Fallback amount if totalDue regex didn't catch it
    if (totalDue == 0.0) {
      final generalAmount = _extractAmountAndCurrency(text);
      if (generalAmount != null) {
        totalDue = generalAmount.amount;
      }
    }

    // Extract Payment Due Date (handles "Due date: 5 Nov '26" or "05/11/2026")
    DateTime? dueDate;
    final dueRegex = RegExp(
      r"""(?:payment\s+due\s+date|due\s+date|pay\s+by)\s*[:\-]?\s*([0-9]{1,2}[\/\-\.][0-9]{1,2}[\/\-\.][0-9]{2,4}|[0-9]{1,2}\s+[A-Za-z]{3,9},?\s+['’]?[0-9]{2,4})""",
      caseSensitive: false,
    );
    final dueMatch = dueRegex.firstMatch(text);
    if (dueMatch != null) {
      final rawDate = dueMatch.group(1)?.trim();
      if (rawDate != null) {
        dueDate = _parseFlexibleDate(rawDate);
      }
    }

    // Extract Statement Billing Period
    String? period;
    final periodRegex = RegExp(
      r'(?:statement\s+period|billing\s+cycle|period)\s*[:\-]?\s*([A-Za-z0-9\s,\-\/]{5,40})',
      caseSensitive: false,
    );
    final periodMatch = periodRegex.firstMatch(text);
    if (periodMatch != null) {
      period = periodMatch.group(1)?.trim();
    }

    // Clean narration
    final cardSuffix = cardLast4 != null ? ' (••$cardLast4)' : '';
    final cleanNarration = isTelecomOrUtility
        ? '$provider Bill Statement'
        : '$issuer$cardSuffix Credit Card Statement';

    final transaction = ExtractedEmailTransaction(
      gmailMessageId: message.id,
      amount: totalDue,
      currency: 'INR',
      merchantName: merchantName,
      cardLast4: cardLast4,
      bankOrIssuer: isTelecomOrUtility ? provider : issuer,
      transactionDate: message.date,
      type: TransactionType.debit,
      narration: cleanNarration,
      category: category,
      isRecurring: false,
      paymentMode: paymentMode,
      isStatement: true,
      statementPeriod: period,
      statementDueDate: dueDate,
      statementTotalDue: totalDue,
      statementMinDue: minDue,
    );

    return DetailedEmailParseResult(
      output: EmailParseOutput(transaction: transaction),
      isNoise: false,
      detectedIssuer: issuer,
      detectedCardLast4: cardLast4,
      detectedAmount: totalDue,
      detectedCurrency: 'INR',
      detectedMerchant: '$issuer Credit Card',
      isSubscriptionSignal: false,
      detectedPaymentMode: 'CREDIT_CARD',
    );
  }

  /// Parses date formats commonly found in Indian bank statements (DD/MM/YYYY, DD-MMM-YYYY)
  DateTime? _parseFlexibleDate(String raw) {
    try {
      final clean = raw.replaceAll("'", '').replaceAll('’', '').trim();
      final parts = clean.split(RegExp(r'[\/\-\.\s]+'));
      if (parts.length >= 3) {
        final day = int.tryParse(parts[0]);
        var year = int.tryParse(parts[2]);
        if (year != null && year < 100) year += 2000;

        int? month;
        month = int.tryParse(parts[1]);
        if (month == null) {
          const months = [
            'jan', 'feb', 'mar', 'apr', 'may', 'jun',
            'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
          ];
          final mIndex = months.indexWhere((m) => parts[1].toLowerCase().startsWith(m));
          if (mIndex >= 0) month = mIndex + 1;
        }

        if (day != null && month != null && year != null) {
          return DateTime(year, month, day);
        }
      }
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Verifies if a non-bank email confirms a completed order or payment receipt
  bool _isConfirmedPaymentOrReceipt(String lower) {
    return lower.contains('order confirmation') ||
        lower.contains('order confirmed') ||
        lower.contains('order number') ||
        lower.contains('thank you for your order') ||
        lower.contains('thanks for your order') ||
        lower.contains('thanks for buying') ||
        lower.contains('thank you for your purchase') ||
        lower.contains('payment successful') ||
        lower.contains('payment received') ||
        lower.contains('payment confirmation') ||
        lower.contains('payment receipt') ||
        lower.contains('transaction was successful') ||
        lower.contains('advance payment') ||
        lower.contains('jewellery purchase plan') ||
        lower.contains('scheme amount') ||
        lower.contains('receipt of your payment') ||
        lower.contains('towards your airtel account') ||
        lower.contains('towards your jio account') ||
        lower.contains('bill for your') ||
        lower.contains('premium receipt') ||
        lower.contains('premium paid') ||
        lower.contains('policy renewal') ||
        lower.contains('invoice') ||
        lower.contains('receipt') ||
        lower.contains('bill details') ||
        lower.contains('amount billed') ||
        lower.contains('amount charged') ||
        lower.contains('total paid') ||
        lower.contains('thanks for riding') ||
        lower.contains('trip with uber') ||
        lower.contains('subscription renewed') ||
        lower.contains('membership renewed') ||
        lower.contains('membership has renewed') ||
        lower.contains('subscribing to') ||
        lower.contains('auto-pay debited') ||
        lower.contains('auto-debit successful');
  }

  /// Extracts financial amount and currency from text
  _AmountInfo? _extractAmountAndCurrency(String text) {
    // Priority regex patterns for transaction amounts in order receipts and bank emails
    final patterns = [
      // 1. Explicit invoice/order totals / scheme amounts: "Total: ₹ 116.82", "Scheme Amount : 5000.", "Payment of Rs. 513.53"
      RegExp(
        r'\b(?:total|total\s+amount|total\s+paid|grand\s+total|amount\s+billed|final\s+amount|total\s+charged|scheme\s+amount|amount\s+paid|payment\s+of)\s*[:\-]?\s*(?:INR|Rs\.?|₹|\$)?\s*([\d,]+(?:\.\d{1,2})?)',
        caseSensitive: false,
      ),
      // 2. Explicit bank debits / spends / scheme advance: "debited with 5000", "spent INR 1,499.00", "advance payment of Rs 5000"
      RegExp(
        r'(?:debited\s+(?:for|with|by)|spent|charged\s+for|amount\s+of|advance\s+payment\s+of|payment\s+for)\s*(?:INR|Rs\.?|₹|\$)?\s*([\d,]+(?:\.\d{1,2})?)',
        caseSensitive: false,
      ),
      // 3. Currency patterns: "INR 1,250.00" or "Rs. 1,250.50" or "₹1,250"
      RegExp(r'(?:\bINR\b|\bRs\.?|₹)\s*([\d,]+(?:\.\d{1,2})?)', caseSensitive: false),
      // 4. "$ 15.99" or "USD 20.00"
      RegExp(r'(?:\$|USD)\s*([\d,]+(?:\.\d{1,2})?)', caseSensitive: false),
    ];

    for (final regex in patterns) {
      final matches = regex.allMatches(text);
      for (final match in matches) {
        // Skip future auto-renewal quotes: e.g. "Auto-renews on ... for ₹ 899.00"
        final fullMatch = match.group(0) ?? '';
        final startPos = match.start;
        final prefix = text.substring(startPos > 40 ? startPos - 40 : 0, startPos).toLowerCase();
        if (prefix.contains('auto-renew') ||
            prefix.contains('renews for') ||
            prefix.contains('renews at') ||
            prefix.contains('renews on')) {
          continue;
        }

        final rawNum = match.group(1)?.replaceAll(',', '').trim();
        if (rawNum != null && rawNum.isNotEmpty) {
          final amt = double.tryParse(rawNum);
          if (amt != null && amt > 0 && amt < 50000000) {
            String currency = 'INR';
            if (fullMatch.contains('\$') || fullMatch.toUpperCase().contains('USD') || text.substring(startPos > 10 ? startPos - 10 : 0, startPos + fullMatch.length).contains('\$')) {
              currency = 'USD';
            }
            return _AmountInfo(amount: amt, currency: currency);
          }
        }
      }
    }

    return null;
  }

  /// Extracts card last 4 digits (e.g. "ending in 1234", "XX1234", "*1234")
  String? _extractCardLast4(String text) {
    final patterns = [
      RegExp(r'ending\s+(?:in\s+)?(\d{4})\b', caseSensitive: false),
      RegExp(r'(?:card|acct?|a/c)\s*(?:no\.?)?\s*[:\s]*[xX*]*(\d{4})\b', caseSensitive: false),
      RegExp(r'\b(?:XX|x{2,}|\*{2,})(\d{4})\b'),
      RegExp(r'card\s+(\d{4})\b', caseSensitive: false),
    ];

    for (final regex in patterns) {
      final match = regex.firstMatch(text);
      if (match != null) {
        return match.group(1);
      }
    }
    return null;
  }

  /// Extracts the original counterparty or bank sender if the email is a forwarded message
  String _extractEffectiveSender(String originalFrom, String bodyText) {
    final fwdRegex = RegExp(
      r'(?:---------- Forwarded message ---------|Begin forwarded message:?|---+ Forwarded message ---+)\s*(?:[\r\n]+)?From:\s*([^\r\n]+)',
      caseSensitive: false,
    );
    final match = fwdRegex.firstMatch(bodyText);
    if (match != null) {
      final innerFrom = match.group(1)?.trim();
      if (innerFrom != null && innerFrom.contains('@')) {
        return innerFrom;
      }
    }
    return originalFrom;
  }

  /// Checks if an email sender address belongs to a banking or card entity
  bool _isBankSender(String from) {
    final lower = from.toLowerCase();
    return lower.contains('bank') ||
        lower.contains('card') ||
        lower.contains('hdfc') ||
        lower.contains('icici') ||
        lower.contains('axis') ||
        lower.contains('kotak') ||
        lower.contains('slice') ||
        lower.contains('sbi') ||
        lower.contains('onecard') ||
        lower.contains('rbl') ||
        lower.contains('indusind') ||
        lower.contains('standard chartered') ||
        lower.contains('@sc.com') ||
        lower.contains('idfc') ||
        lower.contains('citi');
  }

  /// Detects bank or card issuer from sender address or email text
  String _detectBankOrIssuer(String from, String lowerText) {
    final lowerFrom = from.toLowerCase();
    final lower = lowerText.toLowerCase();

    // 1. Direct sender match (strongest signal)
    if (lowerFrom.contains('hdfc')) return 'HDFC Bank';
    if (lowerFrom.contains('icici')) return 'ICICI Bank';
    if (lowerFrom.contains('sbicard') ||
        lowerFrom.contains('sbi card') ||
        lowerFrom.contains('state bank of india')) {
      return 'SBI Card';
    }
    if (lowerFrom.contains('axis')) return 'Axis Bank';
    if (lowerFrom.contains('kotak')) return 'Kotak Bank';
    if (lowerFrom.contains('slice.bank') ||
        lowerFrom.contains('slice account') ||
        lowerFrom.contains('slice')) {
      return 'Slice Bank';
    }
    if (lowerFrom.contains('american express') || lowerFrom.contains('amex')) return 'American Express';
    if (lowerFrom.contains('onecard')) return 'OneCard';
    if (lowerFrom.contains('rbl')) return 'RBL Bank';
    if (lowerFrom.contains('indusind')) return 'IndusInd Bank';
    if (lowerFrom.contains('standard chartered') || lowerFrom.contains('@sc.com')) return 'Standard Chartered';
    if (lowerFrom.contains('federal bank')) return 'Federal Bank';
    if (lowerFrom.contains('idfc')) return 'IDFC FIRST Bank';
    if (lowerFrom.contains('citi') || lowerFrom.contains('citibank')) return 'Citibank';

    // 2. Body text match ONLY if accompanied by financial account/card keywords
    final hasBankContext = lower.contains('card ending') ||
        lower.contains('debit card') ||
        lower.contains('credit card') ||
        lower.contains('bank account') ||
        lower.contains('debited from your') ||
        lower.contains('credited to your') ||
        lower.contains('standing instruction') ||
        lower.contains('spent on your') ||
        lower.contains('used for a transaction');

    if (hasBankContext) {
      if (lower.contains('hdfc')) return 'HDFC Bank';
      if (lower.contains('icici')) return 'ICICI Bank';
      if (lower.contains('sbicard') ||
          lower.contains('sbi card') ||
          lower.contains('state bank of india')) {
        return 'SBI Card';
      }
      if (lower.contains('axis')) return 'Axis Bank';
      if (lower.contains('kotak')) return 'Kotak Bank';
      if (lower.contains('slice')) return 'Slice Bank';
      if (lower.contains('american express') || lower.contains('amex')) return 'American Express';
      if (lower.contains('onecard')) return 'OneCard';
      if (lower.contains('rbl')) return 'RBL Bank';
      if (lower.contains('indusind')) return 'IndusInd Bank';
      if (lower.contains('standard chartered')) return 'Standard Chartered';
      if (lower.contains('federal bank')) return 'Federal Bank';
      if (lower.contains('idfc')) return 'IDFC FIRST Bank';
      if (lower.contains('citi') || lower.contains('citibank')) return 'Citibank';
    }

    return 'Bank Card';
  }

  /// Detects whether the transaction is debit or credit (refund / reversal)
  TransactionType _detectTransactionType(String lower) {
    // If it's an order confirmation, invoice, purchase, or bill, it is a DEBIT (expense)
    if (lower.contains('order confirmation') ||
        lower.contains('order confirmed') ||
        lower.contains('your order') ||
        lower.contains('thanks for buying') ||
        lower.contains('invoice') ||
        lower.contains('tax invoice') ||
        lower.contains('receipt') ||
        lower.contains('bill details') ||
        lower.contains('payment received') ||
        lower.contains('charged') ||
        lower.contains('debited')) {
      // Unless it is specifically an explicit refund receipt
      if (lower.contains('refund of') ||
          lower.contains('refund processed') ||
          lower.contains('refund confirmed') ||
          lower.contains('reversal of')) {
        return TransactionType.credit;
      }
      return TransactionType.debit;
    }

    // Bank alert refund / reversal / credit indicators
    if (lower.contains('refund of') ||
        lower.contains('refund processed') ||
        lower.contains('reversed') ||
        lower.contains('cashback of') ||
        lower.contains('has been credited') ||
        lower.contains('credited to your')) {
      return TransactionType.credit;
    }

    return TransactionType.debit;
  }

  /// Detects the payment instrument / mode (DEBIT_CARD, CREDIT_CARD, UPI, CASH, NET_BANKING, CARD)
  String _detectPaymentMode({
    required String text,
    required String? cardLast4,
    required String issuer,
  }) {
    final lower = text.toLowerCase();

    // 1. UPI
    if (lower.contains('via upi') ||
        lower.contains('upi ref') ||
        lower.contains('vpa') ||
        lower.contains('qr_code') ||
        lower.contains('qr code') ||
        lower.contains('@okaxis') ||
        lower.contains('@okhdfcbank') ||
        lower.contains('@okicici') ||
        lower.contains('@oksbi') ||
        lower.contains('@paytm') ||
        lower.contains('@upi')) {
      return 'UPI';
    }

    // 2. Explicit Debit Card
    if (lower.contains('debit card') ||
        lower.contains('debit-card') ||
        lower.contains('dc ending') ||
        lower.contains('dc xx') ||
        lower.contains('debit card xx')) {
      return 'DEBIT_CARD';
    }

    // 3. Cash receipts (e.g. Uber Cash rides)
    if (RegExp(r'\b(?:payments?|paid|method)?\s*cash\b', caseSensitive: false).hasMatch(text)) {
      return 'CASH';
    }

    // 4. Netbanking / Direct Bank transfers (NEFT / IMPS / RTGS / Account Credits)
    if (lower.contains('neft') ||
        lower.contains('imps') ||
        lower.contains('rtgs') ||
        lower.contains('netbanking') ||
        (cardLast4 == null &&
            (lower.contains('account has been credited') ||
                lower.contains('account has been debited') ||
                lower.contains('account number')))) {
      return 'ACCOUNT_TRANSFER';
    }

    // 5. Explicit Credit Card (requires card context to avoid footer promo links)
    final hasCardContext = cardLast4 != null ||
        lower.contains('credit card ending') ||
        lower.contains('credit card xx') ||
        lower.contains('on your credit card') ||
        lower.contains('credit card transaction') ||
        issuer == 'OneCard' ||
        issuer == 'SBI Card' ||
        issuer == 'American Express';

    if (hasCardContext &&
        (lower.contains('credit card') ||
            lower.contains('credit-card') ||
            lower.contains('cc ending') ||
            lower.contains('cc xx') ||
            issuer == 'OneCard' ||
            issuer == 'SBI Card' ||
            issuer == 'American Express')) {
      return 'CREDIT_CARD';
    }

    // 6. Generic card fallback if last 4 digits were extracted
    if (cardLast4 != null) {
      return 'CARD';
    }

    // 7. General account transfer fallback
    if (lower.contains('account number') ||
        lower.contains('account has been credited') ||
        lower.contains('account has been debited') ||
        lower.contains('bank account')) {
      return 'ACCOUNT_TRANSFER';
    }

    return 'ONLINE';
  }

  /// Matches known subscription service brands
  String? _matchSubscriptionBrand(String lower) {
    for (final entry in _subscriptionCatalog.entries) {
      if (lower.contains(entry.key)) {
        return entry.value;
      }
    }
    return null;
  }

  /// Resolves the true merchant name using sender display name/domain for vendor emails
  /// and narration parsing for bank alerts.
  String _resolveMerchantName({
    required String from,
    required String subject,
    required String bodyText,
    required String issuer,
    String? subscriptionBrand,
  }) {
    if (subscriptionBrand != null && subscriptionBrand.isNotEmpty) {
      return subscriptionBrand;
    }

    final lowerFrom = from.toLowerCase();
    final lowerSub = subject.toLowerCase();

    // 1. Direct override for PlayStation sender
    if (lowerFrom.contains('playstation') ||
        lowerFrom.contains('sony@txn-email') ||
        lowerSub.contains('playstation store')) {
      return 'PlayStation';
    }

    final isBankAlertSender = _isBankSender(from);
    final senderMerchant = _extractSenderMerchant(from);

    // 2. If it's a non-bank sender (e.g. GoDaddy, Netflix, Apple, Uber, PlayStation),
    // the merchant is the sender service itself, even if a bank card was used!
    if (!isBankAlertSender && senderMerchant != null && senderMerchant.isNotEmpty) {
      return _cleanMerchantName(senderMerchant);
    }

    // 3. If it's a bank alert, extract counterparty merchant from narration text
    final text = '$subject\n$bodyText';
    final patterns = [
      // Slice UPI: "To NEW BIGG BASKET SHO RRN 628580608304"
      RegExp(r'\bTo\s+([A-Za-z0-9\s\*\-_&]{2,32}?)(?:\s+(?:RRN|UPI|Ref|via)|[\.,\n]|$)', caseSensitive: false),
      // Credit alerts: "Sender Name: JAYADEV PATIL" or "Remitter Name: ..."
      RegExp(r'\b(?:Sender|Remitter|Payer)(?:\s+Name)?\s*[:\-]\s*([A-Za-z0-9\s\.\-_&]{2,32}?)(?=(?:\s+(?:Sender|Remitter|Account|A\/c|Amount|Details|Date|Txn|Ref|RRN)|[\.,\n\r]|$))', caseSensitive: false),
      // "credited by JAYADEV PATIL" or "received from JAYADEV PATIL"
      RegExp(r'\b(?:received from|credited by|transfer from)\s+([A-Za-z0-9\s\.\-_&]{2,32}?)(?:\s+(?:on|using|via|with|ref|avl|avail|bal|txn|a/c)|[\.,\n]|$)', caseSensitive: false),
      // "at ZOMATO.", "at AMAZON on", "at UBER via"
      RegExp(r'\bat\s+([A-Za-z0-9\s\*\-_&]{2,32}?)(?:\s+(?:on|using|via|with|ref|avl|avail|bal|txn|card)|[\.,\n]|$)', caseSensitive: false),
      // "towards FLIPKART."
      RegExp(r'\btowards\s+([A-Za-z0-9\s\*\-_&]{2,32}?)(?:\s+(?:on|using|via|with|ref|avl|avail|bal|txn|card)|[\.,\n]|$)', caseSensitive: false),
      // "paid to SWIGGY.", "sent to UBER."
      RegExp(r'\b(?:paid|sent|transferred)\s+to\s+([A-Za-z0-9\s\*\-_&]{2,32}?)(?:\s+(?:on|using|via|with|ref|avl|avail|bal|txn|card)|[\.,\n]|$)', caseSensitive: false),
      // "Info: MERCH*NAME"
      RegExp(r'\binfo\s*[:\-]\s*([A-Za-z0-9\s\.\*\-_&]{2,32})', caseSensitive: false),
      // "Merchant: AMAZON"
      RegExp(r'\bmerchant\s*[:\-]\s*([A-Za-z0-9\s\.\*\-_&]{2,32})', caseSensitive: false),
      // "VPA merchant@upi"
      RegExp(r'\b(?:vpa|upi)\s*[:\-]?\s*([a-zA-Z0-9.\-_]{2,32}@[a-zA-Z]{2,10})', caseSensitive: false),
    ];

    for (final regex in patterns) {
      final match = regex.firstMatch(text);
      if (match != null) {
        final candidate = match.group(1)?.trim();
        if (candidate != null && _isValidMerchantCandidate(candidate)) {
          return _cleanMerchantName(candidate);
        }
      }
    }

    // Fallback to sender display name (if not a bank) or issuer
    if (!isBankAlertSender && senderMerchant != null && senderMerchant.isNotEmpty) {
      return _cleanMerchantName(senderMerchant);
    }

    return issuer;
  }

  /// Extracts clean merchant name from sender string (e.g. `"GoDaddy <donotreply@godaddy.com>"`)
  String? _extractSenderMerchant(String from) {
    final lowerFrom = from.toLowerCase();
    if (lowerFrom.contains('playstation') || lowerFrom.contains('sony')) {
      return 'PlayStation';
    }

    final displayMatch = RegExp(r'^"?([^"<]+)"?\s*<([^>]+)>').firstMatch(from.trim());
    if (displayMatch != null) {
      var displayName = displayMatch.group(1)?.trim() ?? '';
      displayName = displayName
          .replaceAll(
            RegExp(r'\s+(?:receipts?|billing|team|alerts?|support|notifications?|mailer|orders?|updates?)$',
                caseSensitive: false),
            '',
          )
          .trim();

      final lowerDisplay = displayName.toLowerCase();
      if (displayName.isNotEmpty &&
          !lowerDisplay.contains('bank') &&
          !lowerDisplay.contains('card') &&
          !lowerDisplay.contains('security') &&
          !lowerDisplay.contains('alert') &&
          displayName.length >= 2) {
        return displayName;
      }
    }

    // Check sender domain
    final domainMatch = RegExp(r'@(?:[\w-]+\.)*([\w-]+)\.[a-z]{2,}').firstMatch(from.toLowerCase());
    if (domainMatch != null) {
      final brandDomain = domainMatch.group(1)?.toLowerCase();
      const genericDomains = {
        'gmail', 'yahoo', 'outlook', 'hotmail', 'icloud', 'notify', 'mailer', 'email', 'support'
      };
      if (brandDomain != null &&
          !genericDomains.contains(brandDomain) &&
          !brandDomain.contains('bank') &&
          !brandDomain.contains('card')) {
        if (brandDomain == 'godaddy') return 'GoDaddy';
        if (brandDomain == 'sitepeel') return 'Sitepeel';
        if (brandDomain == 'netflix') return 'Netflix';
        if (brandDomain == 'spotify') return 'Spotify';
        return brandDomain[0].toUpperCase() + brandDomain.substring(1);
      }
    }

    return null;
  }

  static const Set<String> _merchantBlacklist = {
    'keep',
    'put it to work',
    'learn more',
    'view',
    'see details',
    'click here',
    'your',
    'our',
    'the',
    'account',
    'card',
    'credit card',
    'bank',
    'customer',
    'support',
    'service',
    'services',
    'you',
    'use',
    'activate',
    'start',
    'get started',
    'login',
    'manage',
    'other users',
    'other user',
    'users',
    'user',
    'someone',
    'this message',
    'this email',
    'this mail',
    'mail address',
    'email address',
    'this message or mail address',
  };

  bool _isValidMerchantCandidate(String candidate) {
    final lower = candidate.toLowerCase().trim();
    if (lower.length < 2) return false;
    if (_merchantBlacklist.contains(lower)) return false;
    if (lower.contains('this message') ||
        lower.contains('mail address') ||
        lower.contains('email address') ||
        lower.contains('do not reply') ||
        lower.contains('contact us')) {
      return false;
    }
    for (final black in _merchantBlacklist) {
      if (lower.startsWith('$black ') || lower == black) return false;
    }
    return true;
  }

  /// Normalizes and cleans extracted merchant strings
  String _cleanMerchantName(String raw) {
    var name = raw.replaceAll(RegExp(r'^(at|to|towards)\s+', caseSensitive: false), '').trim();
    name = name.replaceAll(RegExp(r'[\r\n\t]+'), ' ');
    name = name.replaceAll(RegExp(r'\s{2,}'), ' ');
    // Remove trailing dots or hyphens
    name = name.replaceAll(RegExp(r'[\.\-]+$'), '').trim();

    if (name.isEmpty) return 'Credit Card Payee';
    return name;
  }

  /// Builds a clean user-facing narration
  String _buildCleanNarration({
    required String issuer,
    required String merchant,
    required String? cardLast4,
    required double amount,
    required String currency,
  }) {
    final cardSuffix = cardLast4 != null ? ' (Card ending $cardLast4)' : '';
    final currSymbol = currency == 'USD' ? '\$' : '₹';
    if (issuer == 'Bank Card') {
      return '$merchant: $currSymbol${amount.toStringAsFixed(2)}';
    }
    return '$issuer$cardSuffix: $currSymbol${amount.toStringAsFixed(2)} at $merchant';
  }
}

class _AmountInfo {
  final double amount;
  final String currency;
  const _AmountInfo({required this.amount, required this.currency});
}
