import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Gmail Auth Independence Tests', () {
    test('connectAndGetGmailAccessToken returns error without prompting if expectedEmail is null and unauthenticated', () async {
      final authService = AuthService();
      final result = await authService.connectAndGetGmailAccessToken(
        promptIfUnauthenticated: false,
        expectedEmail: null,
      );

      expect(result.isSuccess, isFalse);
      expect(result.accessToken, isNull);
      expect(result.errorMessage, contains('Gmail is not connected'));
    });

    test('connectAndGetGmailAccessToken returns error without prompting if expectedEmail is empty string', () async {
      final authService = AuthService();
      final result = await authService.connectAndGetGmailAccessToken(
        promptIfUnauthenticated: false,
        expectedEmail: '',
      );

      expect(result.isSuccess, isFalse);
      expect(result.accessToken, isNull);
      expect(result.errorMessage, contains('Gmail is not connected'));
    });
  });
}

