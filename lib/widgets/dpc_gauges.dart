import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';

/// DPC Radial Gauge Engine using CustomPainter.
/// Follows DPC Rule: Inactive track `#27272A`, active indicator semantic token.
class DpcRadialGauge extends StatelessWidget {
  final double progress; // 0.0 to 1.0
  final double size;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final Widget? centerChild;
  final double startAngle;
  final double sweepAngle;

  const DpcRadialGauge({
    super.key,
    required this.progress,
    this.size = 72,
    this.strokeWidth = 6,
    this.activeColor = DpcColors.accentPositive,
    this.trackColor = DpcColors.surfaceTrack,
    this.centerChild,
    this.startAngle = -math.pi / 2, // starts at 12 o'clock
    this.sweepAngle = 2 * math.pi,   // full circle by default
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _DpcRadialPainter(
              progress: progress.clamp(0.0, 1.0),
              strokeWidth: strokeWidth,
              activeColor: activeColor,
              trackColor: trackColor,
              startAngle: startAngle,
              sweepAngle: sweepAngle,
            ),
          ),
          ?centerChild,
        ],
      ),
    );
  }
}

class _DpcRadialPainter extends CustomPainter {
  final double progress;
  final double strokeWidth;
  final Color activeColor;
  final Color trackColor;
  final double startAngle;
  final double sweepAngle;

  _DpcRadialPainter({
    required this.progress,
    required this.strokeWidth,
    required this.activeColor,
    required this.trackColor,
    required this.startAngle,
    required this.sweepAngle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;

    // Inactive track
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    // Active indicator arc
    if (progress > 0) {
      final activePaint = Paint()
        ..color = activeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * progress,
        false,
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DpcRadialPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.trackColor != trackColor;
  }
}

/// Compact Mini Gauge for Top App Bar & Stage Radial Rows
class DpcMiniGauge extends StatelessWidget {
  final double progress;
  final double size;
  final Color activeColor;
  final Widget? center;

  const DpcMiniGauge({
    super.key,
    required this.progress,
    this.size = 36,
    this.activeColor = DpcColors.accentLevel,
    this.center,
  });

  @override
  Widget build(BuildContext context) {
    return DpcRadialGauge(
      progress: progress,
      size: size,
      strokeWidth: 3,
      activeColor: activeColor,
      trackColor: DpcColors.surfaceTrack,
      centerChild: center,
    );
  }
}
