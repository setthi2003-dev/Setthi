import 'package:flutter/material.dart';
import 'merchant_category_model.dart';

/// Transaction type conforming to ReBIT deposit schema (DEBIT or CREDIT)
enum TransactionType {
  debit('DEBIT'),
  credit('CREDIT');

  final String value;
  const TransactionType(this.value);

  static TransactionType fromString(String val) {
    if (val.toUpperCase() == 'CREDIT') {
      return TransactionType.credit;
    }
    return TransactionType.debit;
  }
}

/// Represents a bank transaction conforming to Setu's ReBIT deposit schema
class BankTransaction {
  final String txnId;
  final TransactionType type;
  final String mode;
  final double amount;
  final double currentBalance;
  final DateTime transactionTimestamp;
  final String narration;
  final String? category;
  final String? precomputedMerchantName;

  const BankTransaction({
    required this.txnId,
    required this.type,
    required this.mode,
    required this.amount,
    required this.currentBalance,
    required this.transactionTimestamp,
    required this.narration,
    this.category,
    this.precomputedMerchantName,
  });

  bool get isCredit => type == TransactionType.credit;
  bool get isDebit => type == TransactionType.debit;

  /// Helper getter: Extracts recognizable merchant/counterparty names from
  /// cryptic Indian UPI/banking narrations dynamically using the database registry.
  String get cleanMerchantName {
    if (precomputedMerchantName != null && precomputedMerchantName!.trim().isNotEmpty) {
      return precomputedMerchantName!;
    }

    // 1. Dynamic lookup against MerchantCategoryRegistry (from Supabase table)
    final matchedRule = MerchantCategoryRegistry.instance.findMatch(narration);
    if (matchedRule != null) {
      return matchedRule.cleanName;
    }

    // Set of common banking mode and status codes to ignore as merchant names
    const ignoredTokens = {
      'UPI', 'CARD', 'CASH', 'NEFT', 'RTGS', 'IMPS', 'ATM', 'POS',
      'ACH', 'ECS', 'NACH', 'CR', 'DR', 'DE', 'WD', 'CW', 'FT',
      'P2A', 'P2P', 'TRF', 'BIL', 'INB', 'MB', 'MOB', 'REV', 'RET',
      'CHQ', 'CLR', 'PAYMENT', 'TRANSFER', 'PURCHASE', 'DEPOSIT',
      'WITHDRAWAL', 'SETU', 'REFUND', 'BANK',
    };

    // 2. Structured slash-separated Indian banking narrations:
    // e.g. "CARD/DE/995415932503/Amira Salvi/ANIJ/08764285"
    //      "CASH/CR/467366268432/Sara Dave/ZTAE/35521479"
    //      "UPI/4293021984/Swiggy/swiggy@icici/Payment"
    if (narration.contains('/')) {
      final segments = narration.split('/');
      for (final rawSegment in segments) {
        var candidate = rawSegment.trim();
        if (candidate.isEmpty) continue;
        if (RegExp(r'^[0-9]+$').hasMatch(candidate)) continue;
        if (ignoredTokens.contains(candidate.toUpperCase())) continue;

        // If it's a VPA handle like name@bank, extract the prefix
        if (candidate.contains('@')) {
          candidate = candidate.split('@').first.trim();
        }

        // Check if candidate contains alphabetic letters and is meaningful
        if (RegExp(r'[a-zA-Z]').hasMatch(candidate) && candidate.length >= 3) {
          return _capitalizeWords(candidate);
        }
      }
    }

    // 3. Fallback: clean up special characters and numbers, excluding banking codes
    final sanitized = narration
        .replaceAll(RegExp(r'[0-9]+'), '')
        .replaceAll(RegExp(r'[/_\-]'), ' ')
        .trim();
    if (sanitized.isNotEmpty) {
      final tokens = sanitized
          .split(RegExp(r'\s+'))
          .where((s) => s.length > 2 && !ignoredTokens.contains(s.toUpperCase()))
          .take(2)
          .join(' ');
      if (tokens.isNotEmpty) {
        return _capitalizeWords(tokens);
      }
    }

    return 'Transaction';
  }

  static String _capitalizeWords(String input) {
    return input.split(' ').map((word) {
      if (word.isEmpty) return '';
      return word[0].toUpperCase() + word.substring(1).toLowerCase();
    }).join(' ');
  }

  /// Helper getter: Human-friendly date (e.g., "Today, 4:30 PM", "Yesterday, 1:15 PM", "12 Mar, 8:45 PM")
  String get formattedDate {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final txnDate = DateTime(transactionTimestamp.year, transactionTimestamp.month, transactionTimestamp.day);
    final difference = today.difference(txnDate).inDays;

    final hour = transactionTimestamp.hour;
    final minute = transactionTimestamp.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final formattedHour = hour % 12 == 0 ? 12 : hour % 12;
    final timeStr = '$formattedHour:$minute $period';

    if (difference == 0) {
      return 'Today, $timeStr';
    } else if (difference == 1) {
      return 'Yesterday, $timeStr';
    } else {
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final monthStr = months[transactionTimestamp.month - 1];
      if (transactionTimestamp.year == now.year) {
        return '${transactionTimestamp.day} $monthStr, $timeStr';
      } else {
        return '${transactionTimestamp.day} $monthStr ${transactionTimestamp.year}, $timeStr';
      }
    }
  }

  /// Helper getter: Short time string e.g. "2:38 PM"
  String get formattedTime {
    final hour = transactionTimestamp.hour;
    final minute = transactionTimestamp.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final formattedHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$formattedHour:$minute $period';
  }

  /// Category or grouping key for Section Headers ("Today", "Yesterday", "Earlier this week", "Last week", "Earlier this month")
  String get dateGroup {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final txnDate = DateTime(transactionTimestamp.year, transactionTimestamp.month, transactionTimestamp.day);
    final diffDays = today.difference(txnDate).inDays;

    if (diffDays == 0) return 'Today';
    if (diffDays == 1) return 'Yesterday';
    if (diffDays <= 7) return 'Earlier this week';
    if (diffDays <= 14) return 'Last week';
    return 'Earlier this month';
  }

  /// Helper getter: Amount in Indian Rupee format (`₹X,XXX` or `₹X,XX,XXX`)
  String get formattedAmount {
    return formatRupees(amount);
  }

  /// Helper getter: Current balance in Indian Rupee format
  String get formattedBalance {
    return formatRupees(currentBalance);
  }

  /// Formats any double value into Indian numbering format: e.g. 125000 -> "₹1,25,000"
  static String formatRupees(double val) {
    final isNegative = val < 0;
    final absVal = val.abs();
    final rounded = absVal.toStringAsFixed(absVal.truncateToDouble() == absVal ? 0 : 2);
    final parts = rounded.split('.');
    final intPart = parts[0];
    final decPart = parts.length > 1 ? '.${parts[1]}' : '';

    if (intPart.length <= 3) {
      return '${isNegative ? '-' : ''}₹$intPart$decPart';
    }

    final lastThree = intPart.substring(intPart.length - 3);
    final otherNumbers = intPart.substring(0, intPart.length - 3);
    final regex = RegExp(r'(\d+?)(?=(\d\d)+$)');
    final formattedOther = otherNumbers.replaceAllMapped(regex, (m) => '${m[1]},');

    return '${isNegative ? '-' : ''}₹$formattedOther,$lastThree$decPart';
  }

  /// Merchant icon configuration
  IconData get icon {
    final lower = cleanMerchantName.toLowerCase();
    if (lower.contains('swiggy') || lower.contains('zomato')) return Icons.restaurant_rounded;
    if (lower.contains('zepto') || lower.contains('blinkit') || lower.contains('instamart')) {
      return Icons.shopping_basket_rounded;
    }
    if (lower.contains('spotify') || lower.contains('apple')) return Icons.music_note_rounded;
    if (lower.contains('netflix')) return Icons.movie_filter_rounded;
    if (lower.contains('uber') || lower.contains('rapido') || lower.contains('ola')) {
      return Icons.local_taxi_rounded;
    }
    if (lower.contains('splitwise')) return Icons.group_rounded;
    if (lower.contains('starbucks') || lower.contains('coffee')) return Icons.coffee_rounded;
    if (lower.contains('salary') || lower.contains('stipend')) return Icons.account_balance_wallet_rounded;
    if (lower.contains('amazon') || lower.contains('myntra')) return Icons.shopping_bag_rounded;
    if (lower.contains('cult')) return Icons.fitness_center_rounded;
    if (isCredit) return Icons.arrow_downward_rounded;
    return Icons.arrow_upward_rounded;
  }

  /// Merchant brand/category accent color
  Color get accentColor {
    final lower = cleanMerchantName.toLowerCase();
    if (lower.contains('swiggy')) return const Color(0xFFFC8019); // Swiggy Orange
    if (lower.contains('zomato')) return const Color(0xFFE23744); // Zomato Red
    if (lower.contains('zepto')) return const Color(0xFF8B5CF6); // Zepto Purple
    if (lower.contains('blinkit')) return const Color(0xFFF8CB46); // Blinkit Yellow
    if (lower.contains('spotify')) return const Color(0xFF1DB954); // Spotify Green
    if (lower.contains('netflix')) return const Color(0xFFE50914); // Netflix Red
    if (lower.contains('uber')) return const Color(0xFF00C8FF); // Uber Cyan
    if (lower.contains('rapido')) return const Color(0xFFFFC107); // Rapido Amber
    if (lower.contains('starbucks') || lower.contains('coffee')) return const Color(0xFF00704A);
    if (lower.contains('splitwise')) return const Color(0xFF5BC5A7); // Splitwise Teal
    if (lower.contains('salary') || lower.contains('stipend')) return const Color(0xFF00FFA3); // Neon Mint
    return isCredit ? const Color(0xFF00FFA3) : const Color(0xFFA78BFA);
  }

  static double _parseDouble(dynamic val) {
    if (val == null) return 0.0;
    if (val is num) return val.toDouble();
    if (val is String) {
      final sanitized = val.replaceAll(RegExp(r'[^\d.-]'), '');
      return double.tryParse(sanitized) ?? 0.0;
    }
    return 0.0;
  }

  static DateTime _parseDateTime(dynamic val) {
    if (val == null) return DateTime.now();
    if (val is DateTime) return val;
    if (val is String) {
      try {
        return DateTime.parse(val);
      } catch (_) {
        return DateTime.now();
      }
    }
    return DateTime.now();
  }

  /// JSON serialization matching ReBIT deposit schema
  factory BankTransaction.fromJson(
    Map<String, dynamic> json, {
    double? fallbackBalance,
  }) {
    final rawAmount = json['amount'] ?? json['Amount'] ?? json['amt'];
    final rawBalance = json['currentBalance'] ??
        json['CurrentBalance'] ??
        json['balance'] ??
        json['Balance'];
    final rawType = (json['type'] ?? json['Type'] ?? json['txnType'] ?? 'DEBIT').toString();
    final rawMode = (json['mode'] ?? json['Mode'] ?? 'UPI').toString();
    final rawTxnId = (json['txnId'] ??
            json['TxnId'] ??
            json['id'] ??
            json['Id'] ??
            json['reference'] ??
            '')
        .toString();
    final rawNarration = (json['narration'] ??
            json['Narration'] ??
            json['description'] ??
            json['Description'] ??
            json['remark'] ??
            '')
        .toString();
    final rawTime = json['transactionTimestamp'] ??
        json['TransactionTimestamp'] ??
        json['dateTime'] ??
        json['valueDate'] ??
        json['timestamp'];

    var balance = _parseDouble(rawBalance);
    if (balance == 0.0 && fallbackBalance != null && fallbackBalance > 0.0) {
      balance = fallbackBalance;
    }

    final matchedRule = MerchantCategoryRegistry.instance.findMatch(rawNarration);
    final parsedCategory = json['category'] ?? json['Category'];
    final finalCategory = parsedCategory != null
        ? parsedCategory.toString()
        : matchedRule?.category; // null if unmatched

    final parsedCleanName = json['clean_merchant_name'] ??
        json['cleanMerchantName'] ??
        json['clean_name'];
    final finalCleanName = parsedCleanName != null
        ? parsedCleanName.toString()
        : matchedRule?.cleanName;

    return BankTransaction(
      txnId: rawTxnId,
      type: TransactionType.fromString(rawType),
      mode: rawMode,
      amount: _parseDouble(rawAmount),
      currentBalance: balance,
      transactionTimestamp: _parseDateTime(rawTime),
      narration: rawNarration,
      category: finalCategory,
      precomputedMerchantName: finalCleanName,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'txnId': txnId,
      'type': type.value,
      'mode': mode,
      'amount': amount,
      'currentBalance': currentBalance,
      'transactionTimestamp': transactionTimestamp.toIso8601String(),
      'narration': narration,
      if (category != null) 'category': category,
      'clean_merchant_name': cleanMerchantName,
    };
  }

  BankTransaction copyWith({
    String? txnId,
    TransactionType? type,
    String? mode,
    double? amount,
    double? currentBalance,
    DateTime? transactionTimestamp,
    String? narration,
    String? category,
    String? precomputedMerchantName,
  }) {
    return BankTransaction(
      txnId: txnId ?? this.txnId,
      type: type ?? this.type,
      mode: mode ?? this.mode,
      amount: amount ?? this.amount,
      currentBalance: currentBalance ?? this.currentBalance,
      transactionTimestamp: transactionTimestamp ?? this.transactionTimestamp,
      narration: narration ?? this.narration,
      category: category ?? this.category,
      precomputedMerchantName: precomputedMerchantName ?? this.precomputedMerchantName,
    );
  }
}
