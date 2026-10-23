/// Represents a known merchant keyword rule fetched from Supabase table `public.merchant_categories`.
class MerchantCategoryRule {
  final String keyword;
  final String cleanName;
  final String category;
  final String? icon;

  const MerchantCategoryRule({
    required this.keyword,
    required this.cleanName,
    required this.category,
    this.icon,
  });

  factory MerchantCategoryRule.fromJson(Map<String, dynamic> json) {
    return MerchantCategoryRule(
      keyword: (json['keyword'] ?? '').toString().toLowerCase().trim(),
      cleanName: (json['clean_name'] ?? '').toString().trim(),
      category: (json['category'] ?? '').toString().trim(),
      icon: json['icon']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'keyword': keyword,
        'clean_name': cleanName,
        'category': category,
        if (icon != null) 'icon': icon,
      };
}

/// Global in-memory registry that caches rules retrieved from Supabase
/// and performs instant matching on transaction narrations.
class MerchantCategoryRegistry {
  MerchantCategoryRegistry._();
  static final MerchantCategoryRegistry instance = MerchantCategoryRegistry._();

  /// Default fallback rules ensuring instant offline matching before Supabase syncs
  static final List<MerchantCategoryRule> _fallbackRules = [
    const MerchantCategoryRule(keyword: 'swiggy', cleanName: 'Swiggy', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'zomato', cleanName: 'Zomato', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'zepto', cleanName: 'Zepto', category: 'Groceries'),
    const MerchantCategoryRule(keyword: 'blinkit', cleanName: 'Blinkit', category: 'Groceries'),
    const MerchantCategoryRule(keyword: 'grofers', cleanName: 'Blinkit', category: 'Groceries'),
    const MerchantCategoryRule(keyword: 'instamart', cleanName: 'Instamart', category: 'Groceries'),
    const MerchantCategoryRule(keyword: 'netflix', cleanName: 'Netflix', category: 'Entertainment'),
    const MerchantCategoryRule(keyword: 'spotify', cleanName: 'Spotify', category: 'Entertainment'),
    const MerchantCategoryRule(keyword: 'bookmyshow', cleanName: 'BookMyShow', category: 'Entertainment'),
    const MerchantCategoryRule(keyword: 'uber', cleanName: 'Uber', category: 'Transport'),
    const MerchantCategoryRule(keyword: 'rapido', cleanName: 'Rapido', category: 'Transport'),
    const MerchantCategoryRule(keyword: 'ola', cleanName: 'Ola', category: 'Transport'),
    const MerchantCategoryRule(keyword: 'amazon', cleanName: 'Amazon', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'amzn', cleanName: 'Amazon', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'myntra', cleanName: 'Myntra', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'cult.fit', cleanName: 'Cult.fit', category: 'Health & Fitness'),
    const MerchantCategoryRule(keyword: 'curefit', cleanName: 'Cult.fit', category: 'Health & Fitness'),
    const MerchantCategoryRule(keyword: 'starbucks', cleanName: 'Starbucks', category: 'Cafe & Dining'),
    const MerchantCategoryRule(keyword: 'blue tokai', cleanName: 'Blue Tokai', category: 'Cafe & Dining'),
    const MerchantCategoryRule(keyword: 'bluetokai', cleanName: 'Blue Tokai', category: 'Cafe & Dining'),
    const MerchantCategoryRule(keyword: 'third wave', cleanName: 'Third Wave Coffee', category: 'Cafe & Dining'),
    const MerchantCategoryRule(keyword: 'apple', cleanName: 'Apple Services', category: 'Subscriptions & Tech'),
    const MerchantCategoryRule(keyword: 'google play', cleanName: 'Google Play', category: 'Subscriptions & Tech'),
    const MerchantCategoryRule(keyword: 'google cloud', cleanName: 'Google Cloud', category: 'Subscriptions & Tech'),
    const MerchantCategoryRule(keyword: 'play store', cleanName: 'Google Play', category: 'Subscriptions & Tech'),
    const MerchantCategoryRule(keyword: 'google', cleanName: 'Google', category: 'Subscriptions & Tech'),
    const MerchantCategoryRule(keyword: 'salary', cleanName: 'Salary / Stipend', category: 'Income'),
    const MerchantCategoryRule(keyword: 'payroll', cleanName: 'Salary / Stipend', category: 'Income'),
    const MerchantCategoryRule(keyword: 'stipend', cleanName: 'Salary / Stipend', category: 'Income'),
    const MerchantCategoryRule(keyword: 'meesho', cleanName: 'Meesho', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'nestasia', cleanName: 'Nestasia', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'nestasi', cleanName: 'Nestasia', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'reliance', cleanName: 'Reliance Retail', category: 'Shopping'),
    const MerchantCategoryRule(keyword: 'brik oven', cleanName: 'Brik Oven', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'glens bakehouse', cleanName: "Glen's Bakehouse", category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'glens bak', cleanName: "Glen's Bakehouse", category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'cream stone', cleanName: 'Cream Stone', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'cream sto', cleanName: 'Cream Stone', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'parijata', cleanName: 'Parijata', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'parijat ha', cleanName: 'Parijata', category: 'Food & Dining'),
    const MerchantCategoryRule(keyword: 'phonepe', cleanName: 'PhonePe', category: 'Bills & Utilities'),
    const MerchantCategoryRule(keyword: 'sms charges', cleanName: 'SMS Charges', category: 'Bank Charges'),
    const MerchantCategoryRule(keyword: 'sms alert', cleanName: 'SMS Alert', category: 'Bank Charges'),
    const MerchantCategoryRule(keyword: 'splitwise', cleanName: 'Splitwise', category: 'Transfers'),
  ];

  List<MerchantCategoryRule> _rules = List.of(_fallbackRules);
  bool _isInitializedFromRemote = false;

  List<MerchantCategoryRule> get rules => List.unmodifiable(_rules);
  bool get isInitializedFromRemote => _isInitializedFromRemote;

  /// Updates the cached rules from Supabase table rows
  void updateRules(List<MerchantCategoryRule> newRules) {
    if (newRules.isNotEmpty) {
      _rules = List.of(newRules);
      _isInitializedFromRemote = true;
    }
  }

  /// Adds or prepends a new rule dynamically to the in-memory registry
  void addRule(MerchantCategoryRule rule) {
    _rules.removeWhere((r) => r.keyword == rule.keyword.toLowerCase().trim());
    _rules.insert(0, rule);
  }

  /// Attempts to match a narration against known merchant rules using whole-word boundaries.
  /// Returns [MerchantCategoryRule] if a match is found, or `null` if unmatched.
  MerchantCategoryRule? findMatch(String narration) {
    for (final rule in _rules) {
      final pattern = RegExp(
        r'(?:^|[^a-zA-Z0-9])' + RegExp.escape(rule.keyword) + r'(?:$|[^a-zA-Z0-9])',
        caseSensitive: false,
      );
      if (pattern.hasMatch(narration)) {
        return rule;
      }
    }
    return null;
  }
}
