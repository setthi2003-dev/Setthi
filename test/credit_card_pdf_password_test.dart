import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/services/slice_credit_card_pdf_parser_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  group('Credit Card PDF Password Protection Tests', () {
    late Uint8List protectedPdfBytes;
    const testPassword = 'TEST_PASSWORD_123';

    setUpAll(() {
      // Create an encrypted PDF in-memory using Syncfusion PDF Security
      final document = PdfDocument();
      document.security.userPassword = testPassword;

      final page = document.pages.add();
      final graphics = page.graphics;
      final font = PdfStandardFont(PdfFontFamily.helvetica, 12);
      graphics.drawString(
        'Slice Credit Card Statement',
        font,
        bounds: const Rect.fromLTWH(0, 0, 500, 30),
      );

      final bytes = document.saveSync();
      document.dispose();
      protectedPdfBytes = Uint8List.fromList(bytes);
    });

    test('detects password-protected credit card statement when no password is provided', () async {
      final parser = SliceCreditCardPdfParserService();
      final result = await parser.parsePdfBytes(
        protectedPdfBytes,
        fileName: 'slice_cc_statement_oct2026.pdf',
      );

      expect(result.success, isFalse);
      expect(result.isPasswordProtected, isTrue);
      expect(result.errorMessage, contains('password-protected'));
    });

    test('detects password-protected credit card statement when incorrect password is provided', () async {
      final parser = SliceCreditCardPdfParserService();
      final result = await parser.parsePdfBytes(
        protectedPdfBytes,
        fileName: 'slice_cc_statement_oct2026.pdf',
        password: 'INCORRECT_PASSWORD',
      );

      expect(result.success, isFalse);
      expect(result.isPasswordProtected, isTrue);
      expect(result.errorMessage, contains('password-protected'));
    });

    test('unlocks statement when correct password is provided', () async {
      final parser = SliceCreditCardPdfParserService();
      final result = await parser.parsePdfBytes(
        protectedPdfBytes,
        fileName: 'slice_cc_statement_oct2026.pdf',
        password: testPassword,
      );

      // Successfully unlocked: isPasswordProtected must be false
      expect(result.isPasswordProtected, isFalse);
    });
  });
}
