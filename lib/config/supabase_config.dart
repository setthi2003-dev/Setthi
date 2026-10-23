import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Configuration class reading Supabase credentials from `--dart-define`
/// and `--dart-define-from-file` (e.g., `secrets.json`).
class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://lqvzhffsqspwmahiajfm.supabase.co',
  );

  static const String anonKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: String.fromEnvironment(
      'SUPABASE_ANON_KEY',
      defaultValue:
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxxdnpoZmZzcXNwd21haGlhamZtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODk0Njg5MjIsImV4cCI6MjEwNTA0NDkyMn0.BOjbq_tp3OxqMR2tKhmRcmofjpnoU741u85B8poMHK0',
    ),
  );

  static String get publishableKey => anonKey;

  /// Indicates whether valid Supabase credentials were provided
  static bool get isConfigured => url.isNotEmpty && anonKey.isNotEmpty;

  /// Returns the global [SupabaseClient] instance once initialized
  static SupabaseClient get client => Supabase.instance.client;

  /// Initializes Supabase client if credentials are configured
  static Future<void> initialize() async {
    if (!isConfigured) {
      debugPrint(
        '[SupabaseConfig] Warning: Supabase credentials not found. Pass SUPABASE_URL and SUPABASE_ANON_KEY via secrets.json.',
      );
      return;
    }

    try {
      await Supabase.initialize(
        url: url,
        publishableKey: anonKey.isNotEmpty ? anonKey : null,
      );
      debugPrint('[SupabaseConfig] Supabase initialized successfully.');
    } catch (e) {
      debugPrint('[SupabaseConfig] Failed to initialize Supabase: $e');
    }
  }

  /// Logs the configuration state to the console
  static void logStatus() {
    if (!isConfigured) {
      debugPrint(
        '[SupabaseConfig] Warning: Supabase credentials not configured in secrets.json.',
      );
    } else {
      debugPrint('[SupabaseConfig] Supabase credentials loaded (URL: $url).');
    }
  }
}
