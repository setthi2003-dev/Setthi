import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';
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
    case 'savings retention':
      return 'How much of the money that came in you actually kept. For example, 40% means for every ₹100 received, you kept ₹40 as savings.';
    case 'discretionary ratio':
      return 'The share of your spending that went to "wants" (food delivery, shopping, outings) instead of "needs" (bills, rent, groceries).';
    case 'daily velocity':
      return 'How fast you spend money each day on average. It shows your daily cash burn rate so you can pace yourself.';
    case 'financial health':
      return 'Your overall money fitness score from 0 to 100. It checks if you are saving enough, keeping impulse spending low, and holding a safe balance.';
    default:
      return 'Telemetry metric tracking your financial performance and spending habits.';
  }
}

String _getDefaultFormula(String title) {
  switch (title.toLowerCase().trim()) {
    case 'savings retention':
      return '(Total Inflow - Total Outflow) / Total Inflow';
    case 'discretionary ratio':
      return 'Discretionary Outflow / Total Outflow';
    case 'daily velocity':
      return 'Total Outflow / Active Period Days';
    case 'financial health':
      return 'Weighted composite (Savings Rate + Spend Discipline + Balance Runway)';
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
                      'FINANCIAL TELEMETRY METRIC',
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
