import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';
import '../models/transaction_model.dart';
import 'dpc_gauges.dart';
import 'dpc_segmented_bar.dart';

/// 1. Segmented Filter Bar with Horizontally Scrollable Pills
class DpcSegmentedFilterBar extends StatelessWidget {
  final List<String> filters;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const DpcSegmentedFilterBar({
    super.key,
    required this.filters,
    required this.selectedIndex,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: List.generate(filters.length, (index) {
          final isSelected = index == selectedIndex;
          return Padding(
            padding: EdgeInsets.only(
              left: index == 0 ? 0 : 8,
              right: index == filters.length - 1 ? 0 : 0,
            ),
            child: InkWell(
              onTap: () => onSelect(index),
              borderRadius: BorderRadius.circular(20),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? DpcColors.surfaceTrack // #27272A
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isSelected
                        ? DpcColors.surfaceBorder
                        : DpcColors.surfaceBorder.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
                child: Text(
                  filters[index],
                  style: TextStyle(
                    color: isSelected
                        ? DpcColors.textPrimary
                        : DpcColors.textSecondary,
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// 2. Single Modular 2x2 Telemetry Card
class DpcTelemetryMetricData {
  final String title;
  final IconData icon;
  final String valueText;
  final double fraction; // 0.0 to 1.0 for the 5-segment bar
  final String traitTag;
  final Color accentColor;
  final String? definition;
  final String? formula;

  const DpcTelemetryMetricData({
    required this.title,
    required this.icon,
    required this.valueText,
    required this.fraction,
    required this.traitTag,
    this.accentColor = DpcColors.accentPositive,
    this.definition,
    this.formula,
  });
}

String _getDefaultDefinition(String title) {
  switch (title.toLowerCase().trim()) {
    case 'money saved':
    case 'savings retention':
      return 'How much of the money you received you kept as savings. For example, 40% means for every ₹100 received, you saved ₹40.';
    case 'extra spending':
    case 'discretionary ratio':
      return 'The share of your spending that went to wants (food delivery, shopping, outings) instead of essentials (bills, rent, groceries).';
    case 'daily pace':
    case 'daily velocity':
      return 'How much money you spend each day on average. It helps you pace your spending across the month.';
    case 'financial health':
      return 'A simple score from 0 to 100 showing how well you are balancing spending, saving, and your account balance.';
    default:
      return 'A simple summary to help you track your spending and savings.';
  }
}

String _getDefaultFormula(String title) {
  switch (title.toLowerCase().trim()) {
    case 'money saved':
    case 'savings retention':
      return '(Money In - Money Out) / Money In';
    case 'extra spending':
    case 'discretionary ratio':
      return 'Extra Spending / Total Spending';
    case 'daily pace':
    case 'daily velocity':
      return 'Total Spending / Number of Days';
    case 'financial health':
      return 'Based on your savings, spending habits, and account balance';
    default:
      return '';
  }
}

class DpcTelemetryCard extends StatelessWidget {
  final DpcTelemetryMetricData data;

  const DpcTelemetryCard({super.key, required this.data});

  void _showDefinition(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _DpcMetricDefinitionSheet(data: data),
    );
  }

  @override
  Widget build(BuildContext context) {
    final definition = data.definition ?? _getDefaultDefinition(data.title);

    return Container(
      decoration: DpcDecorations.cardBase(radius: 16),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Header: Category icon + title + info tooltip icon
          Row(
            children: [
              Icon(data.icon, size: 15, color: data.accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  data.title,
                  style: DpcTypography.componentLabel,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              GestureDetector(
                key: Key('help_icon_${data.title}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => _showDefinition(context),
                child: Tooltip(
                  message: definition,
                  child: Padding(
                    padding: const EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.help_outline_rounded,
                      size: 14,
                      color: DpcColors.textSecondary.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Body: Large numerical percentage / reading
          Text(
            data.valueText,
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          // Segmented progress bar (5 discrete blocks)
          DpcSegmentedBar.fromFraction(
            fraction: data.fraction,
            activeColor: data.accentColor,
            height: 5,
            spacing: 3,
          ),
          const SizedBox(height: 10),
          // Footer: Persona or trait classification tag
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: data.accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: data.accentColor.withValues(alpha: 0.25),
                width: 1,
              ),
            ),
            child: Text(
              data.traitTag.toUpperCase(),
              style: TextStyle(
                color: data.accentColor,
                fontSize: 9,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DpcMetricDefinitionSheet extends StatelessWidget {
  final DpcTelemetryMetricData data;

  const _DpcMetricDefinitionSheet({required this.data});

  @override
  Widget build(BuildContext context) {
    final definition = data.definition ?? _getDefaultDefinition(data.title);
    final formula = data.formula ?? _getDefaultFormula(data.title);

    return Container(
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: DpcColors.surfaceTrack,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Header: Icon + Title + Trait Tag
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: data.accentColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: data.accentColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Icon(data.icon, size: 20, color: data.accentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'SPENDING INSIGHT',
                      style: TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: data.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: data.accentColor.withValues(alpha: 0.25),
                  ),
                ),
                child: Text(
                  data.traitTag.toUpperCase(),
                  style: TextStyle(
                    color: data.accentColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // Current Value Callout Box
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: DpcColors.surfaceBorder),
            ),
            child: Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'CURRENT READING',
                      style: TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.valueText,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                SizedBox(
                  width: 90,
                  child: DpcSegmentedBar.fromFraction(
                    fraction: data.fraction,
                    activeColor: data.accentColor,
                    height: 6,
                    spacing: 3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Definition Section
          Text(
            'DEFINITION',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            definition,
            style: const TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 18),

          // Formula Section (if available)
          if (formula.isNotEmpty) ...[
            Text(
              'FORMULA',
              style: TextStyle(
                color: DpcColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DpcColors.surfaceBorder),
              ),
              child: Text(
                formula,
                style: const TextStyle(
                  color: DpcColors.accentPrimary,
                  fontSize: 12,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 22),
          ],

          // Got it button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: DpcColors.surfaceTrack,
                foregroundColor: DpcColors.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: DpcColors.surfaceBorder),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
                elevation: 0,
              ),
              child: const Text(
                'Got It',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 3. Split Telemetry Card:
/// Left: Radial gauge arc (e.g. Inflow vs Outflow ratio or Savings rate)
/// Vertical Divider: 1px line (#1F1F24)
/// Right: Key-value pairs stacked vertically
class DpcSplitTelemetryCard extends StatelessWidget {
  final String title;
  final double gaugeProgress;
  final String gaugeLabel;
  final Color gaugeColor;
  final List<({String label, String value, Color? color})> keyValues;

  const DpcSplitTelemetryCard({
    super.key,
    required this.title,
    required this.gaugeProgress,
    required this.gaugeLabel,
    this.gaugeColor = DpcColors.accentPositive,
    required this.keyValues,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: DpcDecorations.cardBase(radius: 20),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: DpcTypography.badgeTag,
              ),
              const Icon(
                Icons.insights_rounded,
                size: 16,
                color: DpcColors.accentPrimary,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              // Left Column: Radial gauge arc
              Expanded(
                flex: 4,
                child: Center(
                  child: DpcRadialGauge(
                    progress: gaugeProgress,
                    size: 88,
                    strokeWidth: 7,
                    activeColor: gaugeColor,
                    centerChild: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${(gaugeProgress * 100).round()}%',
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          gaugeLabel,
                          style: const TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Thin Vertical Divider
              Container(
                width: 1,
                height: 84,
                color: DpcColors.surfaceBorder,
                margin: const EdgeInsets.symmetric(horizontal: 14),
              ),
              // Right Column: Key-Value pairs
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: keyValues.map((kv) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            kv.label,
                            style: DpcTypography.componentLabel,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            kv.value,
                            style: TextStyle(
                              color: kv.color ?? DpcColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 4. Liquid / Volume Cards:
/// 3-column metric cards utilizing subtle volume fills behind the numbers
class DpcLiquidVolumeItem {
  final String label;
  final String amount;
  final double fraction; // 0.0 to 1.0
  final Color color;

  const DpcLiquidVolumeItem({
    required this.label,
    required this.amount,
    required this.fraction,
    required this.color,
  });
}

class DpcLiquidVolumeRow extends StatelessWidget {
  final List<DpcLiquidVolumeItem> items;

  const DpcLiquidVolumeRow({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items.map((item) {
        return Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            height: 94,
            decoration: DpcDecorations.cardBase(radius: 14),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // Liquid volume fill from the bottom
                Align(
                  alignment: Alignment.bottomCenter,
                  child: FractionallySizedBox(
                    heightFactor: item.fraction.clamp(0.05, 1.0),
                    widthFactor: 1.0,
                    child: Container(
                      decoration: BoxDecoration(
                        color: item.color.withValues(alpha: 0.16),
                        border: Border(
                          top: BorderSide(
                            color: item.color.withValues(alpha: 0.4),
                            width: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Foreground content
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        item.label,
                        style: DpcTypography.componentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.amount,
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${(item.fraction * 100).round()}% vol',
                            style: TextStyle(
                              color: item.color,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// 5. Phase-Based Multi-Gauge Cards:
/// 4-column breakdown using thin circular radial mini-gauges
class DpcPhaseGaugeItem {
  final String stage;
  final double progress;
  final String metric;
  final Color color;

  const DpcPhaseGaugeItem({
    required this.stage,
    required this.progress,
    required this.metric,
    this.color = DpcColors.accentPrimary,
  });
}

class DpcPhaseMultiGaugeRow extends StatelessWidget {
  final List<DpcPhaseGaugeItem> items;

  const DpcPhaseMultiGaugeRow({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: DpcDecorations.cardBase(radius: 16),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: items.map((item) {
          return Column(
            children: [
              DpcMiniGauge(
                progress: item.progress,
                size: 44,
                activeColor: item.color,
                center: Text(
                  '${(item.progress * 100).round()}%',
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                item.stage,
                style: const TextStyle(
                  color: DpcColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                item.metric,
                style: TextStyle(
                  color: item.color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}

/// Category spend item representing aggregated category metrics
class CategorySpendItem {
  final String category;
  final double amount;
  final int count;
  final double percentage;
  final Color color;
  final IconData icon;

  const CategorySpendItem({
    required this.category,
    required this.amount,
    required this.count,
    required this.percentage,
    required this.color,
    required this.icon,
  });
}

/// Helper returning cohesive, desaturated matte editorial tones for categories
/// Purged of AI-slop neon saturation in favor of balanced Scandinavian/architectural harmony
Color getCategorySpendColor(String category) {
  final cat = category.toLowerCase().trim();
  if (cat.contains('food') || cat.contains('dining') || cat.contains('cafe') || cat.contains('eat') || cat.contains('snack')) {
    return const Color(0xFFC88A58); // Matte Terracotta Clay
  } else if (cat.contains('grocer')) {
    return const Color(0xFF6F997A); // Soft Sage Green
  } else if (cat.contains('shop') || cat.contains('lifestyle') || cat.contains('entertainment')) {
    return const Color(0xFF988BA2); // Dusty Heather / Slate Mauve
  } else if (cat.contains('travel') || cat.contains('commute') || cat.contains('transport') || cat.contains('fuel')) {
    return const Color(0xFF68879B); // Nordic Steel Blue
  } else if (cat.contains('bill') || cat.contains('essential') || cat.contains('utilit') || cat.contains('recharge')) {
    return const Color(0xFFBAA174); // Warm Flax / Muted Ochre
  } else if (cat.contains('invest') || cat.contains('transfer') || cat.contains('upi') || cat.contains('people') || cat.contains('person')) {
    return const Color(0xFF749882); // Soft Sage / Eucalypt
  } else if (cat.contains('bank') || cat.contains('charge') || cat.contains('fee')) {
    return const Color(0xFFA57D6D); // Muted Copper / Editorial Rust
  } else if (cat.contains('stall') || cat.contains('local')) {
    return const Color(0xFF8DA399); // Muted Moss Slate
  } else if (cat.contains('income') || cat.contains('salary') || cat.contains('interest')) {
    return const Color(0xFF82A38E); // Quiet Willow / Muted Mint
  } else if (cat.contains('uncategorized') || cat.contains('unclear')) {
    return const Color(0xFF6E7681); // Muted Zinc Graphite
  }
  return const Color(0xFF949BA3); // Titanium Nickel for custom categories
}

/// Helper returning standard icons for categories
IconData getCategorySpendIcon(String category) {
  final cat = category.toLowerCase().trim();
  if (cat.contains('food') || cat.contains('dining') || cat.contains('cafe') || cat.contains('eat') || cat.contains('snack')) {
    return Icons.restaurant_rounded;
  } else if (cat.contains('grocer')) {
    return Icons.local_grocery_store_rounded;
  } else if (cat.contains('shop') || cat.contains('lifestyle') || cat.contains('entertainment')) {
    return Icons.shopping_bag_rounded;
  } else if (cat.contains('travel') || cat.contains('commute') || cat.contains('transport')) {
    return Icons.directions_car_rounded;
  } else if (cat.contains('fuel')) {
    return Icons.local_gas_station_rounded;
  } else if (cat.contains('bill') || cat.contains('essential') || cat.contains('utilit') || cat.contains('recharge')) {
    return Icons.receipt_long_rounded;
  } else if (cat.contains('people') || cat.contains('person')) {
    return Icons.people_alt_rounded;
  } else if (cat.contains('invest') || cat.contains('transfer') || cat.contains('upi')) {
    return Icons.trending_up_rounded;
  } else if (cat.contains('bank') || cat.contains('charge') || cat.contains('fee')) {
    return Icons.account_balance_rounded;
  } else if (cat.contains('stall') || cat.contains('local')) {
    return Icons.store_rounded;
  } else if (cat.contains('income') || cat.contains('salary') || cat.contains('interest')) {
    return Icons.account_balance_wallet_rounded;
  } else if (cat.contains('unclear')) {
    return Icons.help_outline_rounded;
  } else if (cat.contains('uncategorized')) {
    return Icons.label_off_rounded;
  }
  return Icons.tune_rounded;
}

/// 6. Premium OLED Donut Chart & Category Spend Breakdown Card
class DpcCategorySpendCard extends StatelessWidget {
  final List<CategorySpendItem> items;
  final double totalSpent;
  final String periodLabel;
  final bool showBackground;

  const DpcCategorySpendCard({
    super.key,
    required this.items,
    required this.totalSpent,
    required this.periodLabel,
    this.showBackground = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: showBackground ? DpcDecorations.cardBase(radius: 20) : null,
      padding: showBackground
          ? const EdgeInsets.all(20)
          : EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header Row: Precision Monochrome & Understated Pill
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: DpcColors.surfaceDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.pie_chart_outline_rounded,
                  color: DpcColors.textPrimary,
                  size: 17,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'SPEND BY CATEGORY',
                      style: DpcTypography.badgeTag,
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Category Outflows',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceDark,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                    width: 1,
                  ),
                ),
                child: Text(
                  totalSpent > 0 ? BankTransaction.formatRupees(totalSpent, showDecimals: false) : '₹0',
                  style: const TextStyle(
                    color: DpcColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Donut Ring Chart Centerpiece (Enlarged prominent centerpiece)
          Center(
            child: SizedBox(
              width: 224,
              height: 224,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CustomPaint(
                    size: const Size(216, 216),
                    painter: _CategoryDonutPainter(
                      items: items,
                      totalSpent: totalSpent,
                      strokeWidth: 15.0,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            totalSpent > 0
                                ? BankTransaction.formatRupees(totalSpent, showDecimals: false)
                                : '₹0',
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.6,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        items.isNotEmpty
                            ? '${items.length} categories'
                            : periodLabel,
                        style: const TextStyle(
                          color: DpcColors.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),

          // Category Breakdown List
          if (items.isEmpty || totalSpent <= 0) ...[
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No category outflows recorded for $periodLabel.',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ] else ...[
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: items.length,
              separatorBuilder: (context, index) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final item = items[index];
                final fraction = totalSpent > 0 ? (item.amount / totalSpent).clamp(0.0, 1.0) : 0.0;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: DpcColors.surfaceDark,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: DpcColors.surfaceBorder,
                              width: 1,
                            ),
                          ),
                          child: Icon(
                            item.icon,
                            size: 14,
                            color: item.color,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            item.category,
                            style: const TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          BankTransaction.formatRupees(item.amount),
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Progress Bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: Container(
                        height: 4,
                        width: double.infinity,
                        color: DpcColors.surfaceBorder,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: fraction.clamp(0.01, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: item.color,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),

                    // Subtitle: Transaction Count & Percentage
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '${item.count} ${item.count == 1 ? 'transaction' : 'transactions'}',
                          style: const TextStyle(
                            color: DpcColors.textMuted,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '${item.percentage.toStringAsFixed(1)}%',
                          style: TextStyle(
                            color: item.color,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// CustomPainter rendering a segmented OLED donut ring chart
class _CategoryDonutPainter extends CustomPainter {
  final List<CategorySpendItem> items;
  final double totalSpent;
  final double strokeWidth;

  _CategoryDonutPainter({
    required this.items,
    required this.totalSpent,
    this.strokeWidth = 15.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Draw background track ring
    final trackPaint = Paint()
      ..color = DpcColors.surfaceBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;

    canvas.drawCircle(center, radius, trackPaint);

    if (items.isEmpty || totalSpent <= 0) return;

    final rect = Rect.fromCircle(center: center, radius: radius);
    double startAngle = -math.pi / 2; // Start from 12 o'clock
    const gapAngle = 0.04; // Crisp precision hairline gap between segments

    for (final item in items) {
      final sweepAngle = (item.amount / totalSpent) * (2 * math.pi);
      if (sweepAngle <= 0.005) continue;

      final actualSweep = items.length > 1 ? math.max(0.01, sweepAngle - gapAngle) : sweepAngle;
      final paint = Paint()
        ..color = item.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt;

      canvas.drawArc(rect, startAngle + (gapAngle / 2), actualSweep, false, paint);
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _CategoryDonutPainter oldDelegate) {
    return oldDelegate.totalSpent != totalSpent ||
        oldDelegate.items != items ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}
