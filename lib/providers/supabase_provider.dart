import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import '../services/supabase_db_service.dart';
import 'auth_providers.dart';
import 'transaction_providers.dart';

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

/// Riverpod provider for fetching the current user's profile from public.profiles
final userProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final dbService = ref.watch(supabaseDbServiceProvider);
  return dbService.fetchProfile(user.id);
});

/// Riverpod provider for fetching the real-time Cashflow Rhythm & Safe-to-Spend metrics
final cashflowRhythmProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  ref.watch(transactionFeedProvider);
  final dbService = ref.watch(supabaseDbServiceProvider);
  return dbService.fetchCashflowRhythm(user.id);
});

/// Riverpod provider for fetching the user's active & confirmed recurring commitments
final recurringCommitmentsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final dbService = ref.watch(supabaseDbServiceProvider);
  return dbService.fetchRecurringCommitments(user.id);
});

/// Riverpod provider for fetching the user's computed habit profile and behavioral archetype
final habitProfileProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  ref.watch(transactionFeedProvider);
  final dbService = ref.watch(supabaseDbServiceProvider);
  return dbService.fetchHabitProfile(user.id);
});

/// Riverpod provider for fetching verified bank balance facts via get_current_balance
final balanceProvider = FutureProvider<Map<String, dynamic>?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  ref.watch(transactionFeedProvider);
  final dbService = ref.watch(supabaseDbServiceProvider);
  return dbService.fetchCurrentBalance();
});

