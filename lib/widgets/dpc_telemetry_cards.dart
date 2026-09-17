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

  const DpcTelemetryMetricData({
    required this.title,
    required this.icon,
    required this.valueText,
    required this.fraction,
    required this.traitTag,
    this.accentColor = DpcColors.accentPositive,
  });
}

class DpcTelemetryCard extends StatelessWidget {
  final DpcTelemetryMetricData data;

  const DpcTelemetryCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
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
              Icon(
                Icons.help_outline_rounded,
                size: 13,
                color: DpcColors.textSecondary.withValues(alpha: 0.6),
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
