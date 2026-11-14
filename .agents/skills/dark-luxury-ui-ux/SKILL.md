---
name: dark-luxury-ui-ux
description: >-
  A complete design system and UI/UX blueprint based on the Obsidian Glass & Ambient Glow mobile aesthetic.
  Use this skill to architect, style, and review modern mobile and web interfaces requiring ultra-premium
  dark mode, glassmorphic elevation, high-contrast actions, and an adaptable color palette suitable for any domain.
---

# Obsidian Glass & Ambient Glow: Universal UI/UX Design System

This skill provides an authoritative design specification and implementation blueprint reverse-engineered from the state-of-the-art mobile onboarding and paywall experience shown in the reference interface ("Anything" AI app). It translates the visual cues, spatial hierarchy, typography, micro-interactions, and lighting into an adaptable design system applicable to **Fintech, SaaS, AI, Health, E-Commerce, and Developer Tools**.

---

## 1. Visual Philosophy & Core Pillars

The design system operates on four fundamental rules:
1. **The Void Foundation (True Black Canvas)**: Pure black (`#000000` / `#09090B`) is not just an aesthetic choice; it maximizes OLED power efficiency, renders bezels invisible, and allows content layers to float effortlessly.
2. **Glassmorphic Spatial Depth**: Elevation is achieved through translucent surfaces, 1px frosted borders, and multi-card z-index layering—never flat solid grey blocks.
3. **Stark High-Contrast Interaction**: Interactive primaries use stark inversion—bright solid white (`#FFFFFF`) with pure black typography (`#000000`) for undeniable visual hierarchy and instant tap affordance.
4. **Atmospheric Ambient Glow**: Color is treated as ambient light rather than solid fills. Soft, blurred radial glow zones behind focal cards create dimensionality and emotional resonance.

---

## 2. Universal Color Palette Tokens

This palette is engineered to be **industry-agnostic**. The neutral foundation remains constant across all applications, while the chromatic accent layer adapts to your domain (Fintech, Health, Social, or AI).

### 2.1 The Obsidian Neutral System (Base & Surfaces)

| Token Name | Hex Code | HSL / Opacity | Purpose |
| :--- | :--- | :--- | :--- |
| `void-canvas` | `#000000` | `hsl(0, 0%, 0%)` | Main screen background, status bar, screen baseline |
| `surface-base` | `#09090B` | `hsl(240, 10%, 4%)` | Scaffold background, root bottom sheets |
| `surface-elevated-1` | `#121215` | `hsl(240, 7%, 8%)` | Primary container cards, sheets, paywall background cards |
| `surface-elevated-2` | `#18181B` | `hsl(240, 5%, 10%)` | Active input containers, nested cards, popovers |
| `surface-elevated-3` | `#222226` | `hsl(240, 5%, 14%)` | Micro-pills, dropdown buttons, secondary interactive chips |
| `surface-glass-dark` | `rgba(24, 24, 27, 0.70)` | `backdrop-filter: blur(20px)` | Frosted glass modals, floating bottom docks, active prompts |
| `border-subtle` | `rgba(255, 255, 255, 0.08)` | 8% White | Structural card borders, card separators, inactive outlines |
| `border-active` | `rgba(255, 255, 255, 0.18)` | 18% White | Focused inputs, selected cards, prominent glass edges |

### 2.2 Stark Contrast Action Tokens

| Token Name | Hex Code | Purpose |
| :--- | :--- | :--- |
| `action-primary-bg` | `#FFFFFF` | Primary CTA button ("Continue", "Start Free Trial") |
| `action-primary-fg` | `#000000` | Label on primary button (ultra-legible, bold font) |
| `action-primary-hover`| `#E4E4E7` | Button pressed / active state |
| `action-secondary-bg`| `rgba(255, 255, 255, 0.08)` | Ghost pills ("Auto >", "Skip >", "+", category chips) |
| `action-secondary-fg`| `#D4D4D8` | Secondary button labels, micro-icons |

### 2.3 Typography & Text Contrast

| Token Name | Hex Code | Contrast Ratio | Usage |
| :--- | :--- | :--- | :--- |
| `text-primary` | `#FFFFFF` | 21:1 | Major headlines, numbers, total values, active titles |
| `text-secondary` | `#E4E4E7` | ~16:1 | Subtitles, input text, body copy, active chips |
| `text-muted` | `#8E8E93` | ~7:1 | Captions, secondary timestamps, skip buttons, inactive tabs |
| `text-faint` | `#52525B` | ~4.5:1 | Inactive pagination dots, placeholder hints, borders |

### 2.4 Chromatic Light & Functional Accents (Universal Domain Mapping)

| Domain | Accent Name | Primary Glow Hex | Soft Glow (20% Alpha) | Real-World Application |
| :--- | :--- | :--- | :--- | :--- |
| **All Apps** | `Atmospheric Dusk` | `#1E293B` to `#3B82F6` | `rgba(59, 130, 246, 0.18)` | Upper backdrop radial blur (Screens 2, 4, 6) |
| **Fintech & Growth** | `Emerald Mint` | `#10B981` / `#34D399` | `rgba(16, 185, 129, 0.20)` | Revenue graphs, positive balances, active badges (Screen 5) |
| **AI, Cloud & Tech** | `Electric Azure` | `#38BDF8` / `#0284C7` | `rgba(56, 189, 248, 0.22)` | App Store review, deployment aura, active prompt lights (Screen 4) |
| **Luxury & Commerce** | `Warm Amber` | `#F59E0B` / `#F97316` | `rgba(245, 158, 11, 0.18)` | Active subscription pill ("1,735"), highlights, ratings (Screen 5) |
| **Alerts & Warnings** | `Signal Coral` | `#EF4444` | `rgba(239, 68, 68, 0.20)` | Errors, failed card reviews, cancellation warnings |

---

## 3. UI Architecture & Screen Breakdown

### Screen 1: Minimalist Brand Arrival (Splash)
- **Structure**: Void canvas (`#000000`) with a single centered geometric logo icon in solid stark white (`#FFFFFF`).
- **Visual Goal**: Zero distraction, instant load impression, sets the tone of high luxury and precision engineering.
- **UX Rule**: 800ms duration, smooth scale-in (from 0.95 to 1.0) with ease-out curve.

### Screen 2: Interactive Prompt & Card Stacking (Core Value Prop)
- **Floating Input Component**:
  - Dark glass surface (`rgba(28, 28, 30, 0.85)` + 16px blur) with 1px border (`rgba(255, 255, 255, 0.12)`).
  - Multi-line conversational prompt in clear, bright typography.
  - Bottom micro-bar containing:
    - Attachment/Action pill (`+` icon inside rounded square).
    - Mode selector pill (`Auto >` inside semi-translucent chip).
    - Send button: Solid circular white button (`#FFFFFF`) with black directional arrow icon (`#000000`).
- **3D Card Depth Layering**:
  - Secondary frosted cards tucked behind the main active card, rotated slightly (-4° to 4°) with decreasing opacity (40% to 70%).
  - Communicates infinite modularity and dynamic generation without writing code.
- **Bottom Typography & Controls**:
  - Title: Large 26-28pt bold white headline with high letter-spacing quality.
  - Pagination: 4 dots. Active dot expands into an elongated pill (width 20px, white). Inactive dots are 6px circles (`#3F3F46`).
  - Button: 56px height, full-width pill button (`BorderRadius.circular(28)`), solid white background, bold black label "Continue".
  - Top Navigation: Minimalist "Skip >" text button top-right in muted neutral (`#A1A1AA`).

### Screen 3: Radial Ecosystem & Badge Typography (Integrations)
- **Top Brand Arc**:
  - Floating logo bubbles (ChatGPT, RevenueCat, Stripe, Supabase, Grok, etc.) floating in an organic arc above the input card.
  - Connects the abstract feature ("integrations") to tangible recognizable tools.
- **Micro-Typography Flourish ("100+ integrations")**:
  - Enclosed in an elliptical pill border.
  - Uses an editorial serif italic typeface (`Playfair Display` or `New York`) alongside modern sans-serifs, communicating artisanal craft.

### Screen 4: Visual Workflow Pipelines (Deployment & Live State)
- **Node-to-Node Visual Flow**:
  - Top action pill: "Publish on App Store" with Apple blue emblem and interactive cursor indicator.
  - Vertical connecting bezier line (`#3B82F6` with 2px stroke and subtle glow).
  - Intermediate status node: "Running app review" with a yellow warning tag ("Few minor errors found!") transitioning into a green resolution badge ("✓ Debugged successfully").
  - Target destination card: "Your app is Live on App Store".
- **Volumetric Blue Glow**:
  - A diffuse radial background glow behind the live card (`rgba(56, 189, 248, 0.25)`, blur: 40px) that gives the impression of light emitting from the screen.

### Screen 5: Growth Analytics & Translucent Data Graphs (MRR & Metrics)
- **Multi-Card Deck**:
  - Stacked cards with app identity (e.g. "Group Study App", "Foodly App" with 5 golden stars).
- **Chart Presentation**:
  - Dark container (`#121215`) with a luminous emerald curve (`#10B981`, stroke width 2.5px).
  - Smooth cubic bezier splines with a subtle vertical gradient fill below the curve (15% emerald to 0% transparent).
- **Pinned Data Badges**:
  - Left chip: "Active Subscription: 1,735" in a dark warm frosted pill.
  - Floating highlight chip: "Monthly Recurring Revenue: $21,032.32" with bright green text and dark frosted surface.

### Screen 6: Premium Paywall (Tier Conversion)
- **Atmospheric Sky Horizon**:
  - Upper 35% features a dark moody cloud/twilight atmospheric gradient fading into deep obsidian.
- **Brand Hero & Title**:
  - Centered app icon within a rounded square.
  - Hybrid brand typography: Editorial serif italic ("Anything") + Heavy sans ("MAX").
- **Glass Tier Container**:
  - Nested translucent panel with border stroke.
  - Plan title: "MAX - For building large, popular, or many apps:".
  - Credits selector pill: "990K credits/mo v" dropdown.
  - Hero price: Large bold "$899.00/mo".
  - Full-width "Start 3 day free trial" white pill button.
  - Feature checklist: Circular checkmark icons (`Icons.check_circle_outline`) with concise value propositions.
- **Bottom Switch / Footnote**:
  - Floating tier switch ("Pro") for transparent comparison.

---

## 4. Universal Typography Pairing Rules

To achieve this aesthetic, combine a **Modern Geometric Sans-Serif** with an **Editorial Serif**:

1. **Primary Interface Font (Sans-Serif)**:
   - *Options*: `Inter`, `SF Pro Display`, `Plus Jakarta Sans`, `Satoshi`
   - *Headlines*: 24px - 28px, Weight 700 (Bold), Letter-spacing: -0.5px
   - *Body Copy*: 14px - 16px, Weight 400 (Regular), Color: `#A1A1AA`
   - *Button Labels*: 16px, Weight 700 (Bold), Color: `#000000`

2. **Editorial Accent Font (Serif - used for badges & brand titles)**:
   - *Options*: `Playfair Display`, `Newsreader`, `Instrument Serif`
   - *Styling*: Italicized, medium weight, used sparingly (e.g., *100+ integrations*, brand signature logos).

---

## 5. Flutter Implementation Patterns

### 5.1 Glassmorphic Surface Container

```dart
Widget buildGlassCard({
  required Widget child,
  double borderRadius = 20,
  EdgeInsetsGeometry padding = const EdgeInsets.all(16),
  Color? glowColor,
}) {
  return Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      boxShadow: glowColor != null
          ? [
              BoxShadow(
                color: glowColor.withValues(alpha: 0.18),
                blurRadius: 32,
                spreadRadius: 2,
                offset: const Offset(0, 4),
              ),
            ]
          : null,
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xFF18181B).withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.10),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    ),
  );
}
```

### 5.2 High-Contrast Primary Pill Button

```dart
Widget buildPrimaryPillButton({
  required String label,
  required VoidCallback onPressed,
  bool isLoading = false,
}) {
  return SizedBox(
    width: double.infinity,
    height: 56,
    child: ElevatedButton(
      onPressed: isLoading ? null : onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
        shape: const StadiumBorder(), // Full pill shape (BorderRadius 9999px)
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      child: isLoading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
            )
          : Text(label),
    ),
  );
}
```

### 5.3 Morphing Pill Pagination Indicator

```dart
Widget buildPaginationDots({
  required int totalSteps,
  required int activeIndex,
}) {
  return Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: List.generate(totalSteps, (index) {
      final isActive = index == activeIndex;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: isActive ? 22 : 6,
        height: 6,
        decoration: BoxDecoration(
          color: isActive ? Colors.white : const Color(0xFF3F3F46),
          borderRadius: BorderRadius.circular(3),
        ),
      );
    }),
  );
}
```

---

## 6. How to Apply this Design System to Other Apps

### Example A: Fintech & Wealth App
- **Background**: True Black `#000000`.
- **Surface**: Translucent dark cards with 1px border (`rgba(255, 255, 255, 0.08)`).
- **Accent Glow**: Emerald Mint (`#10B981`) behind the net worth portfolio chart.
- **Buttons**: Stark white "Transfer Funds" or "Invest Now" pill button.

### Example B: Health & Fitness Tracker
- **Background**: Obsidian `#09090B`.
- **Surface**: Stacked frosted cards showing workout routines and biometric data.
- **Accent Glow**: Vibrant Sunset Amber (`#F59E0B`) or Cyan (`#06B6D4`) behind activity rings.
- **Buttons**: White pill "Start Workout" with black bold typography.

### Example C: E-Commerce / Luxury Goods
- **Background**: Deep Onyx `#08080A`.
- **Surface**: Minimalist product cards floating over atmospheric lighting.
- **Typography**: Clean Sans-Serif numbers paired with Playfair Display italic headings.
- **Buttons**: Stark white "Add to Bag" pill.

---

## 7. Design Checklist & Quality Assurance

Before releasing an interface built with this design system, verify:
- [ ] Canvas is pure OLED black (`#000000`) or deep obsidian (`#09090B`).
- [ ] No solid harsh gray containers are used; all surfaces have 60-80% opacity with `BackdropFilter` blur.
- [ ] Every card has a 1px boundary stroke (`rgba(255, 255, 255, 0.08)` to `0.14`).
- [ ] Primary buttons use stark inversion (Solid White background + Pure Black text).
- [ ] Accent color is localized to icons, charts, and soft diffuse background glows (never raw overwhelming fills).
- [ ] Pagination uses an active expanded pill rather than static equal-sized dots.
- [ ] Corner radii remain cohesive: Buttons are 28px/Pill, Cards are 18px-24px, Micro-chips are 6px-10px.
