import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

/// Service managing user authentication with Supabase, supporting
/// email/password sign-up & sign-in, and Google OAuth.
class AuthService {
  final SupabaseClient? client;

  AuthService({this.client});

  SupabaseClient get _effectiveClient {
    if (client != null) return client!;
    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Supabase is not configured. Please supply credentials in secrets.json.',
      );
    }
    return SupabaseConfig.client;
  }

  /// Stream of authentication state events (signed in, signed out, token refreshed)
  Stream<AuthState> get authStateChanges {
    try {
      return _effectiveClient.auth.onAuthStateChange;
    } catch (_) {
      return const Stream.empty();
    }
  }

  /// Current authenticated [User], or null if unauthenticated
  User? get currentUser {
    try {
      return _effectiveClient.auth.currentUser;
    } catch (_) {
      return null;
    }
  }

  /// Current active [Session], or null if unauthenticated
  Session? get currentSession {
    try {
      return _effectiveClient.auth.currentSession;
    } catch (_) {
      return null;
    }
  }

  /// Sign up a new user with email and password
  Future<AuthResponse> signUpWithEmail({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async {
    final response = await _effectiveClient.auth.signUp(
      email: email.trim(),
      password: password,
      data: data,
    );
    return response;
  }

  /// Sign in an existing user with email and password
  Future<AuthResponse> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final response = await _effectiveClient.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    return response;
  }

  /// Sign in using Google OAuth via Supabase
  Future<bool> signInWithGoogle() async {
    const redirectUrl = kIsWeb ? null : 'io.supabase.setthi://login-callback';
    final success = await _effectiveClient.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectUrl,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
    return success;
  }

  /// Send a 6-digit one-time password (OTP) to user's email for passwordless sign-in
  Future<void> signInWithOtp({
    required String email,
    bool shouldCreateUser = true,
  }) async {
    await _effectiveClient.auth.signInWithOtp(
      email: email.trim(),
      shouldCreateUser: shouldCreateUser,
    );
  }

  /// Send password reset link to user's email
  Future<void> resetPassword(String email) async {
    await _effectiveClient.auth.resetPasswordForEmail(email.trim());
  }

  /// Verify 6-digit email confirmation OTP
  Future<AuthResponse> verifyEmailOtp({
    required String email,
    required String token,
  }) async {
    AuthResponse response;
    try {
      response = await _effectiveClient.auth.verifyOTP(
        type: OtpType.signup,
        token: token.trim(),
        email: email.trim(),
      );
    } catch (_) {
      // Fallback to email OTP type if signup was already completed or configured differently
      response = await _effectiveClient.auth.verifyOTP(
        type: OtpType.email,
        token: token.trim(),
        email: email.trim(),
      );
    }

    // Ensure profile row exists in public.profiles as an explicit fallback to the DB trigger
    if (response.user != null) {
      final user = response.user!;
      final fullName = user.userMetadata?['full_name']?.toString();
      try {
        await _effectiveClient.from('profiles').upsert({
          'id': user.id,
          'email': user.email ?? email.trim(),
          if (fullName != null && fullName.isNotEmpty) 'full_name': fullName,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (_) {}
    }

    return response;
  }

  /// Resend confirmation OTP to email
  Future<void> resendOtp({
    required String email,
    OtpType type = OtpType.signup,
  }) async {
    try {
      await _effectiveClient.auth.resend(
        type: type,
        email: email.trim(),
      );
    } catch (_) {
      await _effectiveClient.auth.resend(
        type: OtpType.email,
        email: email.trim(),
      );
    }
  }

  /// Sign out the current user session
  Future<void> signOut() async {
    await _effectiveClient.auth.signOut();
  }
}
