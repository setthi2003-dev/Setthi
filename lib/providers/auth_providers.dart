import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';

/// Provider for the [AuthService] instance
final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService();
});

/// Stream provider listening to Supabase auth state changes
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  final service = ref.watch(authServiceProvider);
  return service.authStateChanges;
});

/// Derived provider exposing the current authenticated [User]
final currentUserProvider = Provider<User?>((ref) {
  final authStateAsync = ref.watch(authStateChangesProvider);
  final sessionUser = authStateAsync.value?.session?.user;
  final user = sessionUser ?? ref.watch(authServiceProvider).currentUser;
  if (user != null) {
    debugPrint('[SESSION UID]: ${user.id} (${user.email ?? 'No email'})');
  }
  return user;
});

/// State notifier allowing developers/users to bypass auth for UI development
class AuthBypassNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void bypass() => state = true;
  void reset() => state = false;
}

final authBypassProvider =
    NotifierProvider<AuthBypassNotifier, bool>(AuthBypassNotifier.new);

/// State notifier tracking whether the user entered the app via a password recovery link
class PasswordRecoveryNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Listen to auth state stream events for passwordRecovery
    ref.listen<AsyncValue<AuthState>>(authStateChangesProvider, (prev, next) {
      if (next.value?.event == AuthChangeEvent.passwordRecovery) {
        state = true;
      }
    });

    final currentEvent = ref.read(authStateChangesProvider).value?.event;
    return currentEvent == AuthChangeEvent.passwordRecovery;
  }

  void setRecovery(bool isRecovery) {
    state = isRecovery;
  }

  void clearRecovery() {
    state = false;
  }
}

final isPasswordRecoveryProvider =
    NotifierProvider<PasswordRecoveryNotifier, bool>(
      PasswordRecoveryNotifier.new,
    );

/// Boolean provider indicating whether the user is currently authenticated
final isAuthenticatedProvider = Provider<bool>((ref) {
  final isBypassed = ref.watch(authBypassProvider);
  if (isBypassed) return true;

  final user = ref.watch(currentUserProvider);
  return user != null;
});

