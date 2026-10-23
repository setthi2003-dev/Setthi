import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('AuthService.deleteAccount tests', () {
    test('Throws AuthException when currentUser is null', () async {
      // Mock / unconfigured client where currentUser returns null
      final authService = AuthService();
      expect(
        () => authService.deleteAccount(),
        throwsA(isA<AuthException>()),
      );
    });
  });
}
