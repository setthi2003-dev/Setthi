import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/widgets/ai_companion_rive_widget.dart';

void main() {
  group('AiCompanionRiveWidget Tests', () {
    testWidgets('mounts properly and has correct dimensions', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AiCompanionRiveWidget(
                size: 96,
              ),
            ),
          ),
        ),
      );

      final finder = find.byType(AiCompanionRiveWidget);
      expect(finder, findsOneWidget);

      final renderBox = tester.renderObject(finder) as RenderBox;
      expect(renderBox.size.width, 96.0);
      expect(renderBox.size.height, 96.0);
    });
  });
}
