import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/dpc_tokens.dart';

/// A premium, silky-smooth Slide-to-Confirm action slider widget
/// adhering to the Dark-Pastel Contrast (DPC) design system.
class DpcSlideToConfirm extends StatefulWidget {
  final Future<void> Function() onConfirmed;
  final String label;
  final String completedLabel;
  final double height;
  final IconData icon;

  const DpcSlideToConfirm({
    super.key,
    required this.onConfirmed,
    this.label = 'Slide to Fetch Transactions',
    this.completedLabel = 'Syncing Transactions...',
    this.height = 58.0,
    this.icon = Icons.arrow_forward_rounded,
  });

  @override
  State<DpcSlideToConfirm> createState() => _DpcSlideToConfirmState();
}

class _DpcSlideToConfirmState extends State<DpcSlideToConfirm>
    with SingleTickerProviderStateMixin {
  double _dragPosition = 0.0;
  bool _isConfirmed = false;
  bool _isLoading = false;
  late AnimationController _resetController;
  late Animation<double> _resetAnimation;

  @override
  void initState() {
    super.initState();
    _resetController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _resetController.addListener(() {
      setState(() {
        _dragPosition = _resetAnimation.value;
      });
    });
  }

  @override
  void dispose() {
    _resetController.dispose();
    super.dispose();
  }

  void _handleDragUpdate(DragUpdateDetails details, double maxDrag) {
    if (_isConfirmed || _isLoading) return;
    setState(() {
      _dragPosition = (_dragPosition + details.delta.dx).clamp(0.0, maxDrag);
    });
  }

  void _handleDragEnd(DragEndDetails details, double maxDrag) {
    if (_isConfirmed || _isLoading) return;
    if (_dragPosition >= maxDrag * 0.78) {
      _completeSlide(maxDrag);
    } else {
      _resetSlide();
    }
  }

  void _resetSlide() {
    _resetAnimation = Tween<double>(
      begin: _dragPosition,
      end: 0.0,
    ).animate(
      CurvedAnimation(parent: _resetController, curve: Curves.easeOutCubic),
    );
    _resetController.forward(from: 0.0);
  }

  Future<void> _completeSlide(double maxDrag) async {
    setState(() {
      _dragPosition = maxDrag;
      _isConfirmed = true;
      _isLoading = true;
    });

    HapticFeedback.mediumImpact();

    try {
      await widget.onConfirmed();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isConfirmed = false;
          _isLoading = false;
        });
        _resetSlide();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumbSize = widget.height - 8;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final maxDrag = (totalWidth - thumbSize - 8).clamp(0.0, totalWidth);
        final dragPercent = maxDrag > 0 ? (_dragPosition / maxDrag).clamp(0.0, 1.0) : 0.0;

        return Container(
          width: totalWidth,
          height: widget.height,
          decoration: BoxDecoration(
            color: DpcColors.surfaceDark,
            borderRadius: BorderRadius.circular(widget.height / 2),
            border: Border.all(
              color: Color.lerp(
                DpcColors.surfaceBorder,
                const Color(0xFF86E3CE),
                dragPercent * 0.6,
              )!,
              width: 1,
            ),
            boxShadow: [
              if (dragPercent > 0.1)
                BoxShadow(
                  color: const Color(0xFF86E3CE).withValues(alpha: 0.12 * dragPercent),
                  blurRadius: 16,
                  spreadRadius: 2,
                ),
            ],
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Filled track progress behind thumb
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: _dragPosition + thumbSize + 4,
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.height / 2),
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFFB8F5D8).withValues(alpha: 0.15),
                        const Color(0xFF86E3CE).withValues(alpha: 0.25),
                      ],
                    ),
                  ),
                ),
              ),

              // Centered Shimmering Hint Label
              Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 150),
                  opacity: _isLoading ? 1.0 : (1.0 - dragPercent * 1.4).clamp(0.0, 1.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_isLoading) ...[
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: DpcColors.accentPositive,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        _isLoading ? widget.completedLabel : widget.label,
                        style: TextStyle(
                          color: _isLoading
                              ? DpcColors.accentPositive
                              : DpcColors.textPrimary.withValues(alpha: 0.85),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Draggable Slider Thumb Button
              Positioned(
                left: 4 + _dragPosition,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) =>
                      _handleDragUpdate(details, maxDrag),
                  onHorizontalDragEnd: (details) =>
                      _handleDragEnd(details, maxDrag),
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: DpcColors.heroPastel1,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF86E3CE).withValues(alpha: 0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: DpcColors.textContrast,
                              ),
                            )
                          : Icon(
                              _isConfirmed
                                  ? Icons.check_rounded
                                  : widget.icon,
                              color: DpcColors.textContrast,
                              size: 20,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
