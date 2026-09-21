import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../services/supabase_db_service.dart';

/// Riverpod provider for accessing the [SupabaseClient] instance across the app
final supabaseClientProvider = Provider<SupabaseClient?>((ref) {
  if (!SupabaseConfig.isConfigured) return null;
  try {
    return SupabaseConfig.client;
  } catch (_) {
    return null;
  }
});

/// Riverpod provider for accessing the [SupabaseDbService] instance across the app
final supabaseDbServiceProvider = Provider<SupabaseDbService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseDbService(client: client);
});
