import 'package:flutter/foundation.dart';

/// The specific financial category of the detected reminder
enum ReminderType {
  trialEnding('trial_ending', 'Trial Ending'),
  subscription('subscription', 'Subscription'),
  creditCardStatement('credit_card_statement', 'Credit Card Statement');

  final String dbValue;
  final String label;

  const ReminderType(this.dbValue, this.label);

  static ReminderType fromString(String val) {
    switch (val.toLowerCase().trim()) {
      case 'trial_ending':
        return ReminderType.trialEnding;
      case 'subscription':
        return ReminderType.subscription;
      case 'credit_card_statement':
        return ReminderType.creditCardStatement;
      default:
        return ReminderType.subscription;
    }
  }
}

/// The temporal status of the reminder relative to the user's timezone
enum ReminderTiming {
  upcoming('upcoming', 'Upcoming'),
  today('today', 'Due Today'),
  past('past', 'Past Due'),
  unknown('unknown', 'Unknown');

  final String dbValue;
  final String label;

  const ReminderTiming(this.dbValue, this.label);

  static ReminderTiming fromString(String val) {
    switch (val.toLowerCase().trim()) {
      case 'upcoming':
        return ReminderTiming.upcoming;
      case 'today':
        return ReminderTiming.today;
      case 'past':
        return ReminderTiming.past;
      default:
        return ReminderTiming.unknown;
    }
  }
}

/// Represents a high-precision financial reminder or alert classified by the
/// Setthi Serverless ML pipeline (GLiClass + GLiNER) and persisted in Supabase.
@immutable
class ReminderModel {
  final String id;
  final String userId;
  final String reminderId;
  final ReminderType type;
  final String provider;
  final DateTime? dueDate;
  final ReminderTiming timing;
  final double? amount;
  final String currency;
  final String? amountSource;
  final Map<String, dynamic>? amountEvidence;
  final bool review;
  final bool reminderEligible;
  final List<String> sourceMessageIds;
  final bool isDismissed;
  final bool isActioned;
  final List<String> deliveredKeys;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ReminderModel({
    required this.id,
    required this.userId,
    required this.reminderId,
    required this.type,
    required this.provider,
    this.dueDate,
    this.timing = ReminderTiming.upcoming,
    this.amount,
    this.currency = 'INR',
    this.amountSource,
    this.amountEvidence,
    this.review = false,
    this.reminderEligible = true,
    this.sourceMessageIds = const [],
    this.isDismissed = false,
    this.isActioned = false,
    this.deliveredKeys = const [],
    this.metadata,
    required this.createdAt,
    required this.updatedAt,
  });

  /// Factory constructor to deserialize from a Supabase row
  factory ReminderModel.fromMap(Map<String, dynamic> map) {
    DateTime? parseDate(dynamic val) {
      if (val == null) return null;
      if (val is DateTime) return val;
      return DateTime.tryParse(val.toString());
    }

    double? parseAmount(dynamic val) {
      if (val == null) return null;
      if (val is num) return val.toDouble();
      return double.tryParse(val.toString());
    }

    List<String> parseStringList(dynamic val) {
      if (val == null) return const [];
      if (val is List) return val.map((e) => e.toString()).toList();
      return const [];
    }

    return ReminderModel(
      id: map['id']?.toString() ?? '',
      userId: map['user_id']?.toString() ?? '',
      reminderId: map['reminder_id']?.toString() ?? '',
      type: ReminderType.fromString(map['type']?.toString() ?? ''),
      provider: map['provider']?.toString() ?? 'Unknown Provider',
      dueDate: parseDate(map['due_date']),
      timing: ReminderTiming.fromString(map['timing']?.toString() ?? ''),
      amount: parseAmount(map['amount']),
      currency: map['currency']?.toString() ?? 'INR',
      amountSource: map['amount_source']?.toString(),
      amountEvidence: map['amount_evidence'] is Map<String, dynamic>
          ? map['amount_evidence'] as Map<String, dynamic>
          : (map['amount_evidence'] is Map ? Map<String, dynamic>.from(map['amount_evidence'] as Map) : null),
      review: map['review'] == true,
      reminderEligible: map['reminder_eligible'] ?? true,
      sourceMessageIds: parseStringList(map['source_message_ids']),
      isDismissed: map['is_dismissed'] == true,
      isActioned: map['is_actioned'] == true,
      deliveredKeys: parseStringList(map['delivered_keys']),
      metadata: map['metadata'] is Map<String, dynamic>
          ? map['metadata'] as Map<String, dynamic>
          : (map['metadata'] is Map ? Map<String, dynamic>.from(map['metadata'] as Map) : null),
      createdAt: parseDate(map['created_at']) ?? DateTime.now(),
      updatedAt: parseDate(map['updated_at']) ?? DateTime.now(),
    );
  }

  /// Serialize to a Supabase-compatible map
  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'reminder_id': reminderId,
      'type': type.dbValue,
      'provider': provider,
      'due_date': dueDate?.toIso8601String().split('T').first,
      'timing': timing.dbValue,
      'amount': amount,
      'currency': currency,
      'amount_source': amountSource,
      'amount_evidence': amountEvidence,
      'review': review,
      'reminder_eligible': reminderEligible,
      'source_message_ids': sourceMessageIds,
      'is_dismissed': isDismissed,
      'is_actioned': isActioned,
      'delivered_keys': deliveredKeys,
      if (metadata != null) 'metadata': metadata,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  ReminderModel copyWith({
    String? id,
    String? userId,
    String? reminderId,
    ReminderType? type,
    String? provider,
    DateTime? dueDate,
    ReminderTiming? timing,
    double? amount,
    String? currency,
    String? amountSource,
    Map<String, dynamic>? amountEvidence,
    bool? review,
    bool? reminderEligible,
    List<String>? sourceMessageIds,
    bool? isDismissed,
    bool? isActioned,
    List<String>? deliveredKeys,
    Map<String, dynamic>? metadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ReminderModel(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      reminderId: reminderId ?? this.reminderId,
      type: type ?? this.type,
      provider: provider ?? this.provider,
      dueDate: dueDate ?? this.dueDate,
      timing: timing ?? this.timing,
      amount: amount ?? this.amount,
      currency: currency ?? this.currency,
      amountSource: amountSource ?? this.amountSource,
      amountEvidence: amountEvidence ?? this.amountEvidence,
      review: review ?? this.review,
      reminderEligible: reminderEligible ?? this.reminderEligible,
      sourceMessageIds: sourceMessageIds ?? this.sourceMessageIds,
      isDismissed: isDismissed ?? this.isDismissed,
      isActioned: isActioned ?? this.isActioned,
      deliveredKeys: deliveredKeys ?? this.deliveredKeys,
      metadata: metadata ?? this.metadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Calculates days remaining until the due date
  int? get daysRemaining {
    if (dueDate == null) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(dueDate!.year, dueDate!.month, dueDate!.day);
    return target.difference(today).inDays;
  }

  /// Formatted days countdown badge text
  String get countdownText {
    final d = daysRemaining;
    if (d == null) return 'Undated';
    if (d < 0) return '${d.abs()}d ago';
    if (d == 0) return 'Today';
    if (d == 1) return 'Tomorrow';
    return 'In $d days';
  }

  /// Human-friendly display string for currency symbol
  String get currencySymbol {
    switch (currency.toUpperCase()) {
      case 'INR':
        return '₹';
      case 'USD':
        return '\$';
      case 'EUR':
        return '€';
      case 'GBP':
        return '£';
      default:
        return currency;
    }
  }

  /// Formatted amount string, e.g. "₹999.00"
  String get formattedAmount {
    if (amount == null) return 'Amount Pending';
    return '$currencySymbol${amount!.toStringAsFixed(2)}';
  }
}

