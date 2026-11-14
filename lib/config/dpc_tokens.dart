import 'package:flutter/material.dart';

/// Dark-Pastel Contrast (DPC) Mobile UI Design Tokens
/// Based on the DPC Design System specification in `SKILL-UI.md`.
class DpcColors {
  DpcColors._();

  // ========================================================
  // OBSIDIAN GLASS & AMBIENT GLOW SYSTEM TOKENS
  // Based on the dark-luxury-ui-ux skill specification.
  // ========================================================

  // Pure OLED Void Canvas
  static const Color bgOled = Color(0xFF000000);
  static const Color voidCanvas = Color(0xFF000000);
  static const Color surfaceBase = Color(0xFF09090B);

  // Elevated Obsidian Surfaces
  static const Color surfaceDark = Color(0xFF121215);
  static const Color surfaceElevated1 = Color(0xFF121215);
  static const Color surfaceElevated = Color(0xFF18181B);
  static const Color surfaceElevated2 = Color(0xFF18181B);
  static const Color surfaceElevated3 = Color(0xFF222226);
  static const Color surfaceTrack = Color(0xFF222226);

  // Translucent Glass Surfaces
  static const Color surfaceGlassDark = Color(0xB8141418); // 72% Translucent Obsidian Glass
  static const Color surfaceGlassInput = Color(0xCC1A1A1E); // 80% Translucent Input Glass

  // Delicate Translucent Hairline Borders
  static const Color surfaceBorder = Color(0x1AFFFFFF); // 10% white hairline outline
  static const Color borderSubtle = Color(0x14FFFFFF);  // 8% white hairline
  static const Color borderActive = Color(0x2EFFFFFF);  // 18% white hairline
  static const Color borderProminent = Color(0x3DFFFFFF); // 24% white hairline

  // Stark High-Contrast Action Tokens
  static const Color actionPrimaryBg = Color(0xFFFFFFFF);
  static const Color actionPrimaryFg = Color(0xFF000000);
  static const Color actionSecondaryBg = Color(0x14FFFFFF);
  static const Color actionSecondaryFg = Color(0xFFD4D4D8);

  // Atmospheric Ambient Glow Tokens (Light treat as illumination, not solid fill)
  static const Color glowEmerald = Color(0x2910B981); // 16% Emerald glow for positive metrics
  static const Color glowAzure = Color(0x2B38BDF8);   // 17% Azure glow for AI/pipelines
  static const Color glowDusk = Color(0x243B82F6);    // 14% Dusk twilight glow
  static const Color glowAmber = Color(0x26F59E0B);   // 15% Amber glow for badges/alerts

  // Hero Pastel Gradients (Kept for compatibility)
  static const LinearGradient heroPastel1 = LinearGradient(
    colors: [Color(0xFFB8F5D8), Color(0xFF86E3CE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroPastel2 = LinearGradient(
    colors: [Color(0xFFE2E8F0), Color(0xFF94A3B8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroPastel3 = LinearGradient(
    colors: [Color(0xFFFFD1DC), Color(0xFFFBC4AB)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroPastel4 = LinearGradient(
    colors: [Color(0xFFFFF1C5), Color(0xFFB8E1D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Canvas Text Hierarchy
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textMuted = Color(0xFF6B7280);

  // Inverted Contrast Text
  static const Color textContrast = Color(0xFF121214);
  static const Color textContrastSecondary = Color(0xFF3A3A3C);

  // Semantic Accents
  static const Color accentPositive = Color(0xFF10B981); // Emerald Mint
  static const Color accentNegative = Color(0xFFEF4444); // Signal Coral
  static const Color accentPrimary = Color(0xFF38BDF8);  // Electric Azure
  static const Color accentLevel = Color(0xFFF59E0B);    // Warm Amber
}

class DpcTypography {
  DpcTypography._();

  // Display Metric (38pt - 44pt, Bold, freely floating with generous breathing room)
  static const TextStyle displayMetric = TextStyle(
    color: DpcColors.textPrimary,
    fontSize: 38,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    height: 1.15,
  );

  // Hero Card Title
  static const TextStyle heroCardTitle = TextStyle(
    color: DpcColors.textContrast,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.2,
  );

  // Hero Card Subtitle
  static const TextStyle heroCardSubtitle = TextStyle(
    color: DpcColors.textContrastSecondary,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.3,
  );

  // Telemetry Metric
  static const TextStyle telemetryMetric = TextStyle(
    color: DpcColors.textPrimary,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
  );

  // Component Labels
  static const TextStyle componentLabel = TextStyle(
    color: DpcColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  // Badge / Inline Tag
  static const TextStyle badgeTag = TextStyle(
    color: DpcColors.textSecondary,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2,
  );
}

class DpcDecorations {
  DpcDecorations._();

  // Standard Elevated Obsidian Card Base with subtle translucent hairline border
  static BoxDecoration cardBase({
    double radius = 18,
    Color? border,
    Color? background,
  }) {
    return BoxDecoration(
      color: background ?? DpcColors.surfaceElevated1,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: border ?? DpcColors.surfaceBorder,
        width: 1,
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x3D000000),
          blurRadius: 18,
          offset: Offset(0, 4),
        ),
      ],
    );
  }

  // Floating dock container with dark glass feel
  static BoxDecoration floatingDock = BoxDecoration(
    color: const Color(0xB8121216),
    borderRadius: BorderRadius.circular(32),
    border: Border.all(
      color: const Color(0x1FFFFFFF),
      width: 1,
    ),
    boxShadow: const [
      BoxShadow(
        color: Color(0x8C000000),
        blurRadius: 30,
        offset: Offset(0, 10),
      ),
    ],
  );

  // Stark High-Contrast Primary Pill Button
  static BoxDecoration primaryPillButton = BoxDecoration(
    color: DpcColors.actionPrimaryBg,
    borderRadius: BorderRadius.circular(28),
    boxShadow: const [
      BoxShadow(
        color: Color(0x33FFFFFF),
        blurRadius: 16,
        offset: Offset(0, 2),
      ),
    ],
  );

  // Ambient Glow Backdrop Decoration
  static BoxDecoration ambientGlowBackdrop(Color glowColor) {
    return BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        colors: [
          glowColor,
          glowColor.withValues(alpha: 0.0),
        ],
        radius: 0.8,
      ),
    );
  }
}
