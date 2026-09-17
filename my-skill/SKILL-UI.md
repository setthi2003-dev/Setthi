---
name: dark-pastel-contrast-design-system
description: UI/UX design system specification based on pure OLED dark surfaces, pastel hero feature cards, and micro-telemetry data visualization. Suitable for gaming, fintech, productivity, and fitness apps.
version: 1.0.0
tags: [design-system, ui-ux, dark-mode, mobile-ui, telemetry, components]
---

# Dark-Pastel Contrast (DPC) Mobile UI Design System

A mobile interface architecture blending a true-black (OLED) low-light backdrop with high-contrast pastel hero cards and high-density telemetry dashboards. Designed to maximize visual hierarchy, reduce visual fatigue, and provide instant scannability for data-intensive and action-driven applications.

---

## 1. Color Palette & Visual Tokens

| Token Role | Hex / Value | Usage & Application |
|---|---|---|
| **Background (OLED)** | `#000000` | Primary app canvas; minimizes battery consumption and maximizes contrast. |
| **Surface Dark (Card Base)** | `#0D0D11` | Metric cards, telemetry containers, and secondary containers. |
| **Surface Border** | `#1F1F24` (1px solid) | Subtle hairline outlines defining card perimeters on pure black. |
| **Hero Pastel 1 (Mint/Teal)** | Linear: `#B8F5D8` → `#86E3CE` | Primary action or default game/feature carousel card. |
| **Hero Pastel 2 (Lilac/Purple)** | Linear: `#E0C3FC` → `#8EC5FC` | Secondary mode, AI interaction, or special event cards. |
| **Hero Pastel 3 (Peach/Rose)** | Linear: `#FFD1DC` → `#FBC4AB` | Tier-based rooms, community spaces, or promotional cards. |
| **Hero Pastel 4 (Warm Cream)** | Linear: `#FFF1C5` → `#B8E1D9` | Social hubs, casual tiers, or storefront items. |
| **Text Primary (Dark Canvas)** | `#FFFFFF` | Core metrics, screen titles, and primary numerical readouts. |
| **Text Secondary (Dark Canvas)** | `#8E8E93` | Meta labels, stat titles, subheadings, and inactive states. |
| **Text Contrast (Pastel Cards)** | `#121214` | Titles and subtitles inside bright pastel carousel cards. |
| **Accent Positive / Win** | `#34D399` | Positive metric bars, success states, and win rates. |
| **Accent Negative / Loss** | `#F43F5E` | Low win rates, deficit trends, and alert indicators. |
| **Accent Primary / Currency** | `#38BDF8` | In-app balances, utility tokens, and primary chips. |
| **Accent Level / Trophy** | `#F59E0B` | Radial progression arcs, badges, ranks, and medals. |

---

## 2. Typography & Hierarchy Rules

* **Display Metric (`36pt - 44pt`, Semi-Bold/Bold):** Used for single key aggregates (e.g., token balance, total distance, net worth) floating freely without container constraints.
* **Hero Card Title (`20pt - 24pt`, Semi-Bold, `#121214`):** High contrast against pastel backgrounds for immediate thumb-reach scanning.
* **Telemetry Metric (`28pt - 32pt`, Medium/Bold, `#FFFFFF`):** High-impact numbers positioned inside dark modular telemetry cards.
* **Component Labels (`12pt - 14pt`, Regular, `#8E8E93`):** Descriptive metadata (e.g., "Win rate", "Played", "Aggression frequency").
* **Badge / Inline Tag (`10pt - 11pt`, Semi-Bold, Uppercase):** Status descriptors positioned directly adjacent to icons or gauge rings.

---

## 3. Structural Layout & Content Hierarchy

### Screen A: Dashboard & Hero Carousel
1. **Utility Navigation Bar (Top):**
   * **Left:** Pill-shaped currency/resource badge with a 3D or flat icon (`#38BDF8`) and numeric counter.
   * **Right:** Circular level/tier indicator enclosed in an active radial progress arc (`#F59E0B`) tracking current milestone progress.
2. **Prominent Hero Aggregate:**
   * A single, massive numerical metric centered or left-aligned on the true-black canvas, anchored directly above the carousel.
3. **Floating Horizontal Hero Carousel:**
   * **Card Specifications:** Corner radius `28px`, minimum height `220px`, horizontal snapping (`scroll-snap-type: x mandatory`).
   * **Card Content:** 
     * Top section: Stylized 3D or vector asset (globe, avatar, hub, building).
     * Bottom section: Left-aligned bold heading (`#121214`) over an explanatory one-line subtitle (`#3A3A3C`).
   * **Peeking State:** Next and previous cards peek into the viewport by `16px–24px` to signal horizontal affordance.
4. **Vertical Social/Rankings List:**
   * Section header with title on the left and rank/trophy icon on the right.
   * Row items featuring rank ribbons (Gold `1`, Silver `2`, Bronze `3`), user avatar, username (`#FFFFFF`), and score value (`#8E8E93`).
5. **Floating Bottom Navigation Dock:**
   * Dark floating island navigation container elevated from the bottom edge.
   * Minimalist line-art navigation icons with notification dots and active page pill indicators.

### Screen B: Telemetry & Analytics Dashboard
1. **Segmented Filter Bar:**
   * Horizontally scrollable pill tabs. 
   * Active tab: Solid dark gray background (`#27272A`) with white text.
   * Inactive tabs: Transparent background with `#8E8E93` text.
2. **2x2 Telemetry Grid Cards:**
   * Card containers with `16px` border-radius and `1px` subtle stroke (`#1F1F24`).
   * **Visual Pattern:**
     * Header: Trailing inline category icon + title + info tooltip icon (`?`).
     * Body: Large percentage reading (e.g., `65%`) paired with a segmented progress bar (5 discrete blocks displaying color-coded status).
     * Footer: Persona or trait classification tag (e.g., "Fish", "Mouse", "Aggressive").
3. **Split Telemetry Cards:**
   * **Left Column:** Circular/radial gauge arc displaying single-metric distribution (e.g., Win Rate `18%`, Aggression `10%`).
   * **Vertical Divider:** Thin `1px` line (`#1F1F24`).
   * **Right Column:** Key-value telemetry pairs (e.g., "Played: 418", "Won: 74") stacked vertically.
4. **Liquid Volume Cards:**
   * 3-column metric cards utilizing subtle wavy liquid fills to indicate relative percentage volumes behind the numbers.
5. **Phase-Based Multi-Gauge Cards:**
   * 4-column breakdown using thin circular radial mini-gauges to track stage-specific completion or drop-off rates across stages (e.g., Preflop, Flop, Turn, River).

---

## 4. Reusable Cross-Industry Adaptations

| Component | Gaming / Poker App (Original) | FinTech / Investment App | Fitness / Health App | E-Commerce / SaaS App |
|---|---|---|---|---|
| **Top Counter** | Chips / Tokens (`4,764`) | Net Portfolio Balance (`$4,764`) | Daily Caloric Deficit / Burn (`4,764 kcal`) | Loyalty Reward Points (`4,764 pts`) |
| **Pastel Carousel** | Game Lobbies (Cash, AI, Pub) | Account Types (Crypto, Stocks, Cash) | Workout Plans (Cardio, HIIT, Strength) | Featured Collections / Workspaces |
| **Segmented Cards** | VPIP / PFR (Play style classification) | Risk Tolerance / Asset Volatility Score | Intensity Zone / Heart-Rate Segment | Usage Limits / API Quota Consumption |
| **Multi-Gauge Split** | Hands Won vs. Hands Played | Profitable Trades vs. Closed Positions | Completed Reps vs. Target Reps | Converted Leads vs. Contacts |
| **Stage Radial Row** | Fold frequency across street rounds | Expense distribution across quarters | Activity progression across daily split | Funnel drop-off across checkout steps |

---

## 5. Implementation Rules for Engineers

* **Use Pure Black for Surfaces:** Keep canvas `background-color: #000000` to prevent OLED gray-banding.
* **Component Elevation without Drop Shadows:** Do not use heavy drop shadows on dark mode. Separate elevations using a `1px` border token (`#1F1F24`) and surface shifts (`#0D0D11`).
* **Dynamic Content Foreground Inversion:** Whenever rendering child elements inside the pastel carousel, force text and icon tokens to dark tones (`#121214`) to preserve accessibility contrast ratios above 4.5:1.
* **Gauge Arc Render Engine:** Render circular and donut gauges using SVG stroke-dasharray animations or lightweight canvas paths. Inactive track color: `#27272A`; active indicator: dynamic semantic token (`#34D399`, `#F43F5E`, or `#38BDF8`).