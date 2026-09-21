import 'package:flutter/foundation.dart';
import 'supabase_config.dart';

/// Configuration class reading Setu AA Gateway credentials from `--dart-define`
/// and `--dart-define-from-file`, with fallback to Supabase Vault.
class SetuConfig {
  static const String baseUrl = String.fromEnvironment(
    'SETU_BASE_URL',
    defaultValue: 'https://fiu-sandbox.setu.co',
  );

  static const String clientId = String.fromEnvironment(
    'SETU_CLIENT_ID',
    defaultValue: '',
  );

  static const String clientSecret = String.fromEnvironment(
    'SETU_CLIENT_SECRET',
    defaultValue: '',
  );

  static const String productInstanceId = String.fromEnvironment(
    'SETU_PRODUCT_INSTANCE_ID',
    defaultValue: '',
  );

  static const String redirectUrl = String.fromEnvironment(
    'SETU_REDIRECT_URL',
    defaultValue: 'https://www.joinmandala.in/',
  );

  /// Standard Setu ReBIT AA Gateway authentication headers
  static Map<String, String> get authHeaders => {
        'Content-Type': 'application/json',
        'x-client-id': clientId,
        'x-client-secret': clientSecret,
        'x-product-instance-id': productInstanceId,
      };

  /// Indicates if live/sandbox client credentials were provided or managed via Supabase Vault
  static bool get isConfigured =>
      (clientId.isNotEmpty &&
          clientSecret.isNotEmpty &&
          productInstanceId.isNotEmpty) ||
      SupabaseConfig.isConfigured;

  /// Logs the configuration state to the console
  static void logStatus() {
    if (!isConfigured) {
      debugPrint(
        '[SetuConfig] Warning: Setu AA credentials not configured.',
      );
    } else if (clientId.isNotEmpty && clientSecret.isNotEmpty) {
      debugPrint('[SetuConfig] Setu AA credentials loaded from local environment.');
    } else {
      debugPrint('[SetuConfig] Setu AA credentials managed securely via Supabase Vault.');
    }
  }
}
