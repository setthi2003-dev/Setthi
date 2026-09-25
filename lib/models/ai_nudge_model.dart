/// Represents a proactive insight / warning nudge for the home screen carousel
class AiNudge {
  final String id;
  final String headline;
  final String body;
  final String badgeText;
  final String cardStyle;
  final String? actionLabel;
  final String? metricTag;
  final bool isDismissed;
  final DateTime createdAt;

  const AiNudge({
    required this.id,
    required this.headline,
    required this.body,
    this.badgeText = 'INSIGHT',
    this.cardStyle = 'heroPastel2',
    this.actionLabel,
    this.metricTag,
    this.isDismissed = false,
    required this.createdAt,
  });

  factory AiNudge.fromJson(Map<String, dynamic> json) {
    return AiNudge(
      id: json['id']?.toString() ?? '',
      headline: json['headline']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      badgeText: json['badge_text']?.toString() ?? json['badgeText']?.toString() ?? 'INSIGHT',
      cardStyle: json['card_style']?.toString() ?? json['cardStyle']?.toString() ?? 'heroPastel2',
      actionLabel: json['action_label']?.toString() ?? json['actionLabel']?.toString(),
      metricTag: json['metric_tag']?.toString() ?? json['metricTag']?.toString(),
      isDismissed: json['is_dismissed'] == true || json['is_dismissed'] == 'true',
      createdAt: json['created_at'] != null 
          ? DateTime.tryParse(json['created_at'].toString()) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'headline': headline,
      'body': body,
      'badge_text': badgeText,
      'card_style': cardStyle,
      if (actionLabel != null) 'action_label': actionLabel,
      if (metricTag != null) 'metric_tag': metricTag,
      'is_dismissed': isDismissed,
      'created_at': createdAt.toIso8601String(),
    };
  }

  AiNudge copyWith({
    String? id,
    String? headline,
    String? body,
    String? badgeText,
    String? cardStyle,
    String? actionLabel,
    String? metricTag,
    bool? isDismissed,
    DateTime? createdAt,
  }) {
    return AiNudge(
      id: id ?? this.id,
      headline: headline ?? this.headline,
      body: body ?? this.body,
      badgeText: badgeText ?? this.badgeText,
      cardStyle: cardStyle ?? this.cardStyle,
      actionLabel: actionLabel ?? this.actionLabel,
      metricTag: metricTag ?? this.metricTag,
      isDismissed: isDismissed ?? this.isDismissed,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
