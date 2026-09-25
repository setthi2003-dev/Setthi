import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
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

  /// Sign in using Google (Native Google Sign-In with Web OAuth fallback)
  Future<bool> signInWithGoogle() async {
    const webClientId =
        '473884945637-in2cv7vk192k7se5vvad71s05qr75and.apps.googleusercontent.com';
    const redirectUrl = kIsWeb ? null : 'io.supabase.setthi://login-callback';

    // 1. Attempt Native Google Sign-In
    if (!kIsWeb) {
      try {
        final googleSignIn = GoogleSignIn(
          serverClientId: webClientId, // Required for Supabase aud verification
          scopes: ['email', 'profile', 'openid'],
        );

        final googleUser = await googleSignIn.signIn();
        if (googleUser == null) {
          // User voluntarily dismissed the sheet
          return false;
        }

        final googleAuth = await googleUser.authentication;
        final idToken = googleAuth.idToken;
        final accessToken = googleAuth.accessToken;

        if (idToken != null) {
          final response = await _effectiveClient.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
            accessToken: accessToken,
          );

          return response.session != null;
        }
      } catch (e) {
        debugPrint(
          '[AuthService] Native Google Sign-In error, falling back to Web OAuth: $e',
        );
      }
    }

    // 2. Web OAuth Fallback
    final success = await _effectiveClient.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: redirectUrl,
      authScreenLaunchMode: LaunchMode.externalApplication,
    );
    return success;
  }

  /// Sign in using native Apple ID Credential and Supabase signInWithIdToken
  Future<AuthResponse?> signInWithApple() async {
    // Check platform availability (iOS / macOS)
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      final isAvailable = await SignInWithApple.isAvailable();
      if (!isAvailable) {
        throw const AuthException(
          'Apple Sign In is not available on this device.',
        );
      }
    }

    // 1. Generate and hash the raw nonce for Supabase replay protection
    final rawNonce = _effectiveClient.auth.generateRawNonce();
    final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();

    // 2. Trigger native Apple ID sheet
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [
        AppleIDAuthorizationScopes.email,
        AppleIDAuthorizationScopes.fullName,
      ],
      nonce: hashedNonce,
    );

    final idToken = credential.identityToken;
    if (idToken == null) {
      throw const AuthException('Apple did not provide an identity token.');
    }

    String? tokenAudience;
    try {
      final parts = idToken.split('.');
      if (parts.length == 3) {
        final payloadJson = utf8.decode(
          base64Url.decode(base64Url.normalize(parts[1])),
        );
        final payload = jsonDecode(payloadJson) as Map<String, dynamic>;
        tokenAudience = payload['aud']?.toString();
        debugPrint('[AppleSignIn] Identity token audience (aud): $tokenAudience');
      }
    } catch (_) {}

    // 3. Authenticate with Supabase via ID token
    final AuthResponse response;
    try {
      response = await _effectiveClient.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
    } on AuthException catch (e) {
      if (e.message.toLowerCase().contains('bad id token')) {
        final expectedId = tokenAudience ?? 'your iOS Bundle ID';
        throw AuthException(
          'Bad ID token: Please ensure "$expectedId" is added to "Authorized Client IDs" in Supabase Dashboard -> Authentication -> Providers -> Apple.',
          statusCode: e.statusCode,
        );
      }
      rethrow;
    }

    // 4. Save initial name metadata if provided (Apple only returns this on first sign-in)
    if (response.user != null &&
        (credential.givenName != null || credential.familyName != null)) {
      final fullName = [credential.givenName, credential.familyName]
          .where((part) => part != null && part.isNotEmpty)
          .join(' ')
          .trim();

      if (fullName.isNotEmpty) {
        await _effectiveClient.auth.updateUser(
          UserAttributes(data: {'full_name': fullName}),
        );
      }
    }

    return response;
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

  /// Send password reset link to user's email with app deep link callback
  Future<void> resetPassword(
    String email, {
    String redirectTo = 'io.supabase.setthi://login-callback',
  }) async {
    await _effectiveClient.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: redirectTo,
    );
  }

  /// Updates the user's password once a recovery session is established
  Future<UserResponse> updatePassword(String newPassword) async {
    return await _effectiveClient.auth.updateUser(
      UserAttributes(password: newPassword),
    );
  }

  /// Verifies a 6-digit recovery OTP code sent to user's email
  Future<AuthResponse> verifyRecoveryOtp({
    required String email,
    required String token,
  }) async {
    return await _effectiveClient.auth.verifyOTP(
      type: OtpType.recovery,
      token: token.trim(),
      email: email.trim(),
    );
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

  /// Permanently deletes the current user account and purges all financial data
  Future<bool> deleteAccount() async {
    final uid = currentUser?.id;
    if (uid == null) return false;

    try {
      await _effectiveClient.rpc('delete_user_account');
      await _effectiveClient.auth.signOut();
      return true;
    } catch (e) {
      debugPrint('[AuthService] Error deleting user account: $e');
      rethrow;
    }
  }
}
