import 'package:flutter/material.dart';
import '../config/dpc_tokens.dart';

/// Data model representing a hero feature card in the DPC carousel
class DpcHeroCardItem {
  final String title;
  final String subtitle;
  final String badgeText;
  final IconData icon;
  final LinearGradient gradient;
  final VoidCallback? onTap;
  final String? actionLabel;

  const DpcHeroCardItem({
    required this.title,
    required this.subtitle,
    required this.badgeText,
    required this.icon,
    required this.gradient,
    this.onTap,
    this.actionLabel,
  });
}

/// Floating Horizontal Hero Carousel as specified in DPC Screen A.
/// Features:
/// - Corner radius `28px`, min height `220px`
/// - Snapping horizontal scroll
/// - 16-24px peeking affordance (`viewportFraction: 0.88`)
/// - Dynamic Foreground Inversion (`#121214` dark text/icons on pastel)
class DpcHeroCarousel extends StatefulWidget {
  final List<DpcHeroCardItem> items;
  final double height;
  final ValueChanged<int>? onPageChanged;

  const DpcHeroCarousel({
    super.key,
    required this.items,
    this.height = 225,
    this.onPageChanged,
  });

  @override
  State<DpcHeroCarousel> createState() => _DpcHeroCarouselState();
}

class _DpcHeroCarouselState extends State<DpcHeroCarousel> {
  late final PageController _pageController;
  int _currentPage = 0;

  @override
  void initState() {
    super.initState();
    // viewportFraction 0.88 allows ~20px peeking on left and right edges
    _pageController = PageController(viewportFraction: 0.88);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        SizedBox(
          height: widget.height,
          child: PageView.builder(
            controller: _pageController,
            itemCount: widget.items.length,
            physics: const BouncingScrollPhysics(),
            onPageChanged: (index) {
              setState(() => _currentPage = index);
              widget.onPageChanged?.call(index);
            },
            itemBuilder: (context, index) {
              final item = widget.items[index];
              final isCurrent = _currentPage == index;

              return AnimatedPadding(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: isCurrent ? 0 : 6,
                ),
                child: _buildHeroCard(item),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        // Minimalist dot indicators
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(widget.items.length, (index) {
            final isSelected = index == _currentPage;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: isSelected ? 20 : 6,
              height: 4,
              decoration: BoxDecoration(
                color: isSelected
                    ? DpcColors.textPrimary
                    : DpcColors.surfaceTrack,
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _buildHeroCard(DpcHeroCardItem item) {
    return GestureDetector(
      onTap: item.onTap,
      child: Container(
        decoration: BoxDecoration(
          gradient: item.gradient,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Top Section: Vector icon badge + Status tag (strictly #121214)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: DpcColors.textContrast.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: DpcColors.textContrast.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                  child: Icon(
                    item.icon,
                    color: DpcColors.textContrast,
                    size: 26,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: DpcColors.textContrast.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: DpcColors.textContrast.withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    item.badgeText.toUpperCase(),
                    style: const TextStyle(
                      color: DpcColors.textContrast,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
            // Bottom Section: Left-aligned bold heading (#121214) over explanatory subtitle
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: DpcTypography.heroCardTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  item.subtitle,
                  style: DpcTypography.heroCardSubtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (item.actionLabel != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        item.actionLabel!,
                        style: const TextStyle(
                          color: DpcColors.textContrast,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        color: DpcColors.textContrast,
                        size: 14,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
