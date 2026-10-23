import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:rive/rive.dart';
export 'package:rive/rive.dart' show Fit;
import '../config/dpc_tokens.dart';

/// Dedicated Rive animation widget for Setthi AI Companion (.riv)
/// Used as the animated logo and icon across Setthi AI (dock, header, empty state, bubbles).
/// Automatically centers and zooms into the character face so it is large, crisp, and properly centered.
class AiCompanionRiveWidget extends StatefulWidget {
  final double? size;
  final double? height;
  final double? width;
  final Fit fit;
  final Alignment alignment;
  final double zoomScale;
  final bool autoCenter;

  const AiCompanionRiveWidget({
    super.key,
    this.size,
    this.height,
    this.width,
    this.fit = Fit.contain,
    this.alignment = Alignment.center,
    this.zoomScale = 1.95,
    this.autoCenter = true,
  });

  @override
  State<AiCompanionRiveWidget> createState() => _AiCompanionRiveWidgetState();
}

class _AiCompanionRiveWidgetState extends State<AiCompanionRiveWidget> {
  static FileLoader? _sharedLoader;
  static bool debugForceRive = false;

  static FileLoader get _loader {
    _sharedLoader ??= FileLoader.fromAsset(
      'assets/AI_Companian/ai_companion.riv',
      riveFactory: Factory.flutter,
    );
    return _sharedLoader!;
  }

  bool get _isTestEnv {
    if (debugForceRive) return false;
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  double get _effectiveWidth => widget.size ?? widget.width ?? 32.0;
  double get _effectiveHeight => widget.size ?? widget.height ?? 32.0;

  @override
  Widget build(BuildContext context) {
    final w = _effectiveWidth;
    final h = _effectiveHeight;

    if (_isTestEnv) {
      return SizedBox(
        key: const Key('ai_companion_rive_widget'),
        width: w,
        height: h,
        child: Center(
          child: Icon(
            Icons.auto_awesome_rounded,
            size: (h * 0.6).clamp(12.0, 36.0),
            color: DpcColors.textPrimary,
          ),
        ),
      );
    }

    // Artboard dimensions: 595.0 x 669.0.
    // True character circular bounds: diameter 348.0, center at (397.5, 477.5).
    // Scaling to s * 0.98 ensures the mascot and its 360-degree colorful gradient ring
    // fill the circular container edge-to-edge with zero awkward padding or clipping.
    final s = w < h ? w : h;
    final targetDiameter = s * 0.98;
    final k = targetDiameter / 348.0;
    final artboardW = 595.0 * k;
    final artboardH = 669.0 * k;
    final left = (w / 2.0) - (397.5 * k);
    final top = (h / 2.0) - (477.5 * k);

    return SizedBox(
      key: const Key('ai_companion_rive_widget'),
      width: w,
      height: h,
      child: ClipRect(
        child: RiveWidgetBuilder(
          fileLoader: _loader,
          builder: (context, state) {
            switch (state) {
              case RiveLoading():
                return SizedBox(
                  width: w,
                  height: h,
                  child: Center(
                    child: SizedBox(
                      width: (h * 0.4).clamp(10.0, 20.0),
                      height: (h * 0.4).clamp(10.0, 20.0),
                      child: const CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: DpcColors.textMuted,
                      ),
                    ),
                  ),
                );
              case RiveFailed():
                debugPrint('[AiCompanion] Rive load failed: ${state.error}');
                return SizedBox(
                  width: w,
                  height: h,
                  child: Center(
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: (h * 0.6).clamp(12.0, 36.0),
                      color: DpcColors.textPrimary,
                    ),
                  ),
                );
              case RiveLoaded():
                if (widget.autoCenter) {
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: left,
                        top: top,
                        width: artboardW,
                        height: artboardH,
                        child: RiveWidget(
                          controller: state.controller,
                          fit: Fit.fill,
                          alignment: Alignment.center,
                        ),
                      ),
                    ],
                  );
                }

                return RiveWidget(
                  controller: state.controller,
                  fit: widget.fit,
                  alignment: widget.alignment,
                );
            }
          },
        ),
      ),
    );
  }
}

