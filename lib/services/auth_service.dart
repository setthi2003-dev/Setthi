import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';
import 'gmail_rate_limiter.dart';

/// Structured result from on-device Gmail OAuth authorization
class GmailAuthResult {
  final String? accessToken;
  final String? errorMessage;
  final String? email;

  const GmailAuthResult({this.accessToken, this.errorMessage, this.email});

  bool get isSuccess => accessToken != null && accessToken!.isNotEmpty;
}

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

  static const String googleWebClientId =
      '473884945637-in2cv7vk192k7se5vvad71s05qr75and.apps.googleusercontent.com';
  static const String googleIosClientId =
      '473884945637-150nfrlqch91jg9f833u6ni8v6ju00rv.apps.googleusercontent.com';
  static const String gmailReadonlyScope =
      'https://www.googleapis.com/auth/gmail.readonly';

  GoogleSignIn _buildGoogleSignIn({List<String>? scopes}) {
    return GoogleSignIn(
      clientId: (!kIsWeb && Platform.isIOS) ? googleIosClientId : null,
      serverClientId: googleWebClientId,
      scopes: scopes ?? ['email', 'profile', 'openid'],
    );
  }

  /// Sign in using Google (Native Google Sign-In with Web OAuth fallback)
  Future<bool> signInWithGoogle() async {
    const redirectUrl = kIsWeb ? null : 'io.supabase.setthi://login-callback';

    // 1. Attempt Native Google Sign-In
    if (!kIsWeb) {
      try {
        final googleSignIn = _buildGoogleSignIn();

        final googleUser = await googleSignIn.signIn();
        if (googleUser == null) {
          // User voluntarily dismissed the sheet
          return false;
        }

        final googleAuth = await googleUser.authentication;
        final idToken = googleAuth.idToken;
        final accessToken = googleAuth.accessToken;

        debugPrint('[AuthService] Google user signed in: ${googleUser.email}');
        debugPrint(
          '[AuthService] Google idToken received: ${idToken != null ? 'YES' : 'NO (null)'}',
        );

        if (idToken != null) {
          final response = await _effectiveClient.auth.signInWithIdToken(
            provider: OAuthProvider.google,
            idToken: idToken,
            accessToken: accessToken,
          );

          if (response.session != null) {
            // Once the Supabase auth session is established, sign out from
            // the native GoogleSignIn instance so that the app's sign-in
            // credentials do not automatically bleed into or map to Gmail sync.
            try {
              await googleSignIn.signOut();
            } catch (_) {}
            return true;
          }
          return false;
        } else {
          debugPrint(
            '[AuthService] Google Sign-In returned null idToken. '
            'This occurs when the Android SHA-1 fingerprint is not associated with webClientId ($googleWebClientId).',
          );
        }
      } catch (e, stack) {
        debugPrint(
          '[AuthService] Native Google Sign-In error, falling back to Web OAuth: $e\n$stack',
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

  /// Incrementally requests the `gmail.readonly` scope and returns an OAuth access token
  /// for direct on-device Gmail REST API calls. Does NOT modify initial app login scopes.
  /// If [promptIfUnauthenticated] is false, it attempts silent retrieval ONLY if [expectedEmail]
  /// is specified from an existing, user-confirmed connection.
  Future<GmailAuthResult> connectAndGetGmailAccessToken({
    bool promptIfUnauthenticated = true,
    String? expectedEmail,
  }) async {
    if (kIsWeb) {
      return const GmailAuthResult(
        errorMessage: 'Gmail API sync is supported natively on Android and iOS.',
      );
    }

    try {
      final googleSignIn = _buildGoogleSignIn(
        scopes: ['email', 'profile', 'openid', gmailReadonlyScope],
      );

      // 1. Silent Check: ONLY perform silent token check if the user previously
      // connected an explicit account. Never silently bind an unlinked user.
      if (!promptIfUnauthenticated && (expectedEmail == null || expectedEmail.isEmpty)) {
        return const GmailAuthResult(
          errorMessage: 'Gmail is not connected. Please connect your account.',
        );
      }

      GoogleSignInAccount? user = googleSignIn.currentUser;
      user ??= await googleSignIn.signInSilently();

      if (user != null) {
        final emailMatches = expectedEmail == null ||
            expectedEmail.isEmpty ||
            user.email.trim().toLowerCase() == expectedEmail.trim().toLowerCase();

        if (emailMatches) {
          try {
            final auth = await user.authentication;
            final accessToken = auth.accessToken;
            if (accessToken != null && accessToken.isNotEmpty) {
              final verifyRes = await verifyGmailTokenResponse(accessToken);
              if (verifyRes != null && verifyRes.statusCode == 200) {
                debugPrint(
                  '[AuthService] Reusing active verified Gmail access token for ${user.email} (Zero prompt)',
                );
                return GmailAuthResult(accessToken: accessToken, email: user.email);
              }
            }
          } catch (silentErr) {
            debugPrint('[AuthService] Silent token retrieval note: $silentErr');
          }
        } else {
          debugPrint(
            '[AuthService] Cached Google account (${user.email}) does not match expected Gmail account ($expectedEmail)',
          );
        }
      }

      // 2. If silent token failed and we are not supposed to prompt, return cleanly
      if (!promptIfUnauthenticated) {
        return const GmailAuthResult(
          errorMessage: 'Gmail is not connected. Please connect your account.',
        );
      }

      // 3. User needs interactive authorization for Gmail scopes (SINGLE PROMPT)
      debugPrint('[AuthService] Performing interactive sign-in with Gmail scopes...');

      // Reset any cached GoogleSignIn session to ensure Google presents the full
      // interactive consent sheet including Gmail scopes in a SINGLE prompt.
      // (Note: This does NOT affect the user's Supabase session).
      try {
        await googleSignIn.signOut();
      } catch (_) {}

      user = await googleSignIn.signIn();
      if (user == null) {
        debugPrint('[AuthService] User cancelled Google Sign-In for Gmail');
        return const GmailAuthResult(
          errorMessage: 'Google Sign-In was cancelled.',
        );
      }

      try {
        await user.clearAuthCache();
      } catch (_) {}

      final auth = await user.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null || accessToken.isEmpty) {
        debugPrint('[AuthService] Could not obtain accessToken for Gmail API');
        return const GmailAuthResult(
          errorMessage: 'Could not obtain access token from Google.',
        );
      }

      // Verify token access directly with Gmail API (exactly once, no re-prompt loops)
      final verifyRes = await verifyGmailTokenResponse(accessToken);
      debugPrint(
        '[AuthService] Gmail API validation response (${verifyRes?.statusCode}): ${verifyRes?.body}',
      );

      if (verifyRes != null && verifyRes.statusCode == 200) {
        debugPrint(
          '[AuthService] Successfully verified Gmail access token for ${user.email}',
        );
        return GmailAuthResult(accessToken: accessToken, email: user.email);
      } else if (verifyRes != null && verifyRes.statusCode == 403) {
        final bodyJson = jsonDecode(verifyRes.body) as Map<String, dynamic>?;
        final errorMsg =
            bodyJson?['error']?['message']?.toString() ?? verifyRes.body;

        if (errorMsg.contains('disabled') ||
            errorMsg.contains('has not been used')) {
          return const GmailAuthResult(
            errorMessage:
                'Gmail API is disabled in your Google Cloud Console project. Please enable Gmail API in Google Cloud Console.',
          );
        } else if (errorMsg.contains('insufficient') ||
            errorMsg.contains('scope')) {
          return const GmailAuthResult(
            errorMessage:
                'Gmail permission was not granted. Please make sure to tick the checkbox next to "View your email messages" on the Google consent prompt.',
          );
        }
        return GmailAuthResult(errorMessage: 'Google Cloud error: $errorMsg');
      }

      if (verifyRes == null) {
        return const GmailAuthResult(
          errorMessage:
              'Unable to reach Google servers. Please check your internet connection.',
        );
      }

      return GmailAuthResult(accessToken: accessToken, email: user.email);
    } catch (e, stack) {
      debugPrint('[AuthService] Error obtaining Gmail access token: $e\n$stack');
      return GmailAuthResult(errorMessage: 'Authentication error: $e');
    }
  }

  /// Sends a profile query to Gmail API to check validity and status of an access token.
  Future<http.Response?> verifyGmailTokenResponse(String accessToken, {String? accountEmail}) async {
    try {
      final verifyUri =
          Uri.parse('https://gmail.googleapis.com/gmail/v1/users/me/profile');
      return await GmailRateLimiter.instance.executeWithRetry<http.Response>(
        op: GmailApiOp.getProfile,
        accountEmail: accountEmail,
        requestAction: () => http.get(
          verifyUri,
          headers: {'Authorization': 'Bearer $accessToken'},
        ),
        getStatusCode: (res) => res.statusCode,
        getResponseBody: (res) => res.body,
      );
    } catch (e) {
      debugPrint('[AuthService] Token check network error: $e');
      return null;
    }
  }

  /// Verifies if an OAuth access token has active permission to read the Gmail API.
  Future<bool> verifyGmailAccessToken(String accessToken) async {
    final res = await verifyGmailTokenResponse(accessToken);
    return res != null && res.statusCode == 200;
  }

  /// Disconnects Gmail access and clears active session tokens
  Future<bool> disconnectGmail() async {
    try {
      final googleSignIn = _buildGoogleSignIn(
        scopes: ['email', 'profile', 'openid', gmailReadonlyScope],
      );
      try {
        await googleSignIn.disconnect();
      } catch (_) {}
      try {
        await googleSignIn.signOut();
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('[AuthService] Note disconnecting Google Sign-In: $e');
      return false;
    }
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
        debugPrint(
          '[AppleSignIn] Identity token audience (aud): $tokenAudience',
        );
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
    if (response.user != null) {
      final user = response.user!;
      String? fullName;
      if (credential.givenName != null || credential.familyName != null) {
        fullName = [
          credential.givenName,
          credential.familyName,
        ].where((part) => part != null && part.isNotEmpty).join(' ').trim();

        if (fullName.isNotEmpty) {
          try {
            await _effectiveClient.auth.updateUser(
              UserAttributes(data: {'full_name': fullName}),
            );
          } catch (_) {}
        }
      }

      // Ensure profile row exists in public.profiles
      try {
        final email = user.email ?? credential.email ?? '';
        final resolvedName = (fullName != null && fullName.isNotEmpty)
            ? fullName
            : user.userMetadata?['full_name']?.toString();
        await _effectiveClient.from('profiles').upsert({
          'id': user.id,
          'email': email,
          if (resolvedName != null && resolvedName.isNotEmpty)
            'full_name': resolvedName,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });
      } catch (e) {
        debugPrint('[AppleSignIn] Profile upsert note: $e');
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
      await _effectiveClient.auth.resend(type: type, email: email.trim());
    } catch (_) {
      await _effectiveClient.auth.resend(
        type: OtpType.email,
        email: email.trim(),
      );
    }
  }

  /// Sign out the current user session
  Future<void> signOut() async {
    try {
      await _effectiveClient.auth.signOut();
    } finally {
      try {
        await _buildGoogleSignIn().signOut();
      } catch (_) {}
    }
  }

  /// Permanently deletes the current user account and purges all financial data.
  /// If [signOutAfter] is true (default), signs out the user immediately.
  /// Set [signOutAfter] to false when the caller needs to dismiss dialogs/modals
  /// before the authentication state transitions to signed out.
  Future<bool> deleteAccount({bool signOutAfter = true}) async {
    final uid = currentUser?.id;
    if (uid == null) {
      throw const AuthException('No authenticated user session found.');
    }

    try {
      await _effectiveClient.rpc('delete_user_account');
    } on PostgrestException catch (e, stack) {
      debugPrint(
        '[AuthService] PostgrestException in delete_user_account: ${e.message} '
        '(Code: ${e.code}, Details: ${e.details})\n$stack',
      );
      throw Exception(
        e.message.isNotEmpty
            ? e.message
            : 'Database error occurred during account deletion.',
      );
    } on SocketException catch (e) {
      debugPrint('[AuthService] Network error during account deletion: $e');
      throw const SocketException(
        'Unable to reach server. Please check your internet connection.',
      );
    } catch (e, stack) {
      debugPrint(
        '[AuthService] Unexpected error executing delete_user_account RPC: $e\n$stack',
      );
      rethrow;
    }

    if (signOutAfter) {
      try {
        await _effectiveClient.auth.signOut();
      } catch (e) {
        debugPrint('[AuthService] Post-deletion sign-out warning: $e');
      }
      try {
        await _buildGoogleSignIn().signOut();
      } catch (_) {}
    }

    return true;
  }
}
