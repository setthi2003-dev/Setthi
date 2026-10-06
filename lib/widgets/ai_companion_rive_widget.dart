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

  static FileLoader get _loader {
    _sharedLoader ??= FileLoader.fromAsset(
      'assets/AI_Companian/ai_companion.riv',
      riveFactory: Factory.flutter,
    );
    return _sharedLoader!;
  }

  bool get _isTestEnv {
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
    final scale = widget.zoomScale;
    final shiftX = -0.14833 * w * scale;
    final shiftY = -0.21333 * h * scale;

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
                return Transform.translate(
                  offset: widget.autoCenter
                      ? Offset(shiftX, shiftY)
                      : Offset.zero,
                  child: Transform.scale(
                    scale: widget.autoCenter ? scale : 1.0,
                    child: RiveWidget(
                      controller: state.controller,
                      fit: widget.fit,
                      alignment: widget.alignment,
                    ),
                  ),
                );
            }
          },
        ),
      ),
    );
  }
}

