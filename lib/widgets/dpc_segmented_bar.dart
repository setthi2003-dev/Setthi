import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';

/// 5-Segment discrete progress bar as specified in DPC Telemetry Cards.
class DpcSegmentedBar extends StatelessWidget {
  final int activeSegments; // 0 to 5
  final int totalSegments;
  final Color activeColor;
  final Color inactiveColor;
  final double height;
  final double spacing;

  const DpcSegmentedBar({
    super.key,
    required this.activeSegments,
    this.totalSegments = 5,
    this.activeColor = DpcColors.accentPositive,
    this.inactiveColor = DpcColors.surfaceTrack,
    this.height = 6,
    this.spacing = 4,
  });

  /// Factory helper computing active segments from a 0.0 - 1.0 fraction
  factory DpcSegmentedBar.fromFraction({
    Key? key,
    required double fraction,
    int totalSegments = 5,
    Color activeColor = DpcColors.accentPositive,
    Color inactiveColor = DpcColors.surfaceTrack,
    double height = 6,
    double spacing = 4,
  }) {
    final active = (fraction.clamp(0.0, 1.0) * totalSegments).round();
    return DpcSegmentedBar(
      key: key,
      activeSegments: active,
      totalSegments: totalSegments,
      activeColor: activeColor,
      inactiveColor: inactiveColor,
      height: height,
      spacing: spacing,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(totalSegments, (index) {
        final isActive = index < activeSegments;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(
              right: index < totalSegments - 1 ? spacing : 0,
            ),
            height: height,
            decoration: BoxDecoration(
              color: isActive ? activeColor : inactiveColor,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );
      }),
    );
  }
}
