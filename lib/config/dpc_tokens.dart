import 'package:flutter/material.dart';

/// Dark-Pastel Contrast (DPC) Mobile UI Design Tokens
/// Based on the DPC Design System specification in `SKILL-UI.md`.
class DpcColors {
  DpcColors._();

  // Pure OLED Canvas
  static const Color bgOled = Color(0xFF000000);

  // Surface Dark (Card Base)
  static const Color surfaceDark = Color(0xFF0D0D11);

  // Surface Border (Subtle 1px hairline outline)
  static const Color surfaceBorder = Color(0xFF1F1F24);

  // Surface Inactive / Track Gray
  static const Color surfaceTrack = Color(0xFF27272A);

  // Secondary elevated card surface
  static const Color surfaceElevated = Color(0xFF141419);

  // Hero Pastel Gradients
  // Hero Pastel 1 (Mint/Teal) - Primary action / default carousel card
  static const LinearGradient heroPastel1 = LinearGradient(
    colors: [Color(0xFFB8F5D8), Color(0xFF86E3CE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Hero Pastel 2 (Lilac/Purple) - Secondary mode / AI / Insights
  static const LinearGradient heroPastel2 = LinearGradient(
    colors: [Color(0xFFE0C3FC), Color(0xFF8EC5FC)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Hero Pastel 3 (Peach/Rose) - Tier / Budget / Velocity
  static const LinearGradient heroPastel3 = LinearGradient(
    colors: [Color(0xFFFFD1DC), Color(0xFFFBC4AB)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Hero Pastel 4 (Warm Cream) - Social / Security / Hub
  static const LinearGradient heroPastel4 = LinearGradient(
    colors: [Color(0xFFFFF1C5), Color(0xFFB8E1D9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // Canvas Text Hierarchy
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFF8E8E93);
  static const Color textMuted = Color(0xFF636366);

  // Inverted Contrast Text (inside bright pastel cards)
  static const Color textContrast = Color(0xFF121214);
  static const Color textContrastSecondary = Color(0xFF3A3A3C);

  // Semantic Accents
  static const Color accentPositive = Color(0xFF34D399); // Positive metric / Inflow / Success
  static const Color accentNegative = Color(0xFFF43F5E); // Loss / Deficit / Alert
  static const Color accentPrimary = Color(0xFF38BDF8);  // Currency / Balances / Chips
  static const Color accentLevel = Color(0xFFF59E0B);    // Radial progress / Trophy / Badges
}

class DpcTypography {
  DpcTypography._();

  // Display Metric (36pt - 44pt, Semi-Bold/Bold, freely floating without container)
  static const TextStyle displayMetric = TextStyle(
    color: DpcColors.textPrimary,
    fontSize: 40,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    height: 1.1,
  );

  // Hero Card Title (20pt - 24pt, Semi-Bold, #121214)
  static const TextStyle heroCardTitle = TextStyle(
    color: DpcColors.textContrast,
    fontSize: 22,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.2,
  );

  // Hero Card Subtitle (#3A3A3C)
  static const TextStyle heroCardSubtitle = TextStyle(
    color: DpcColors.textContrastSecondary,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
    height: 1.3,
  );

  // Telemetry Metric (28pt - 32pt, Medium/Bold, #FFFFFF)
  static const TextStyle telemetryMetric = TextStyle(
    color: DpcColors.textPrimary,
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
  );

  // Component Labels (12pt - 14pt, Regular, #8E8E93)
  static const TextStyle componentLabel = TextStyle(
    color: DpcColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.2,
  );

  // Badge / Inline Tag (10pt - 11pt, Semi-Bold, Uppercase)
  static const TextStyle badgeTag = TextStyle(
    color: DpcColors.textSecondary,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.0,
  );
}

class DpcDecorations {
  DpcDecorations._();

  // Standard Dark Card Base (#0D0D11 with 1px #1F1F24 border)
  static BoxDecoration cardBase({
    double radius = 16,
    Color? border,
    Color? background,
  }) {
    return BoxDecoration(
      color: background ?? DpcColors.surfaceDark,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: border ?? DpcColors.surfaceBorder,
        width: 1,
      ),
    );
  }

  // Floating dock container
  static BoxDecoration floatingDock = BoxDecoration(
    color: DpcColors.surfaceDark.withValues(alpha: 0.94),
    borderRadius: BorderRadius.circular(32),
    border: Border.all(
      color: DpcColors.surfaceBorder,
      width: 1,
    ),
    boxShadow: const [
      BoxShadow(
        color: Color(0x7F000000),
        blurRadius: 24,
        offset: Offset(0, 8),
      ),
    ],
  );
}
