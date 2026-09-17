import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/dpc_tokens.dart';
import '../providers/auth_providers.dart';
import 'transaction_feed_screen.dart';
import 'verify_email_screen.dart';

/// Authentication Screen providing Email/Password Sign In & Sign Up
/// as well as Google OAuth integration with rich Gen Z aesthetics.
class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _fullNameController = TextEditingController();

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  String? _errorMessage;
  String? _successMessage;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        setState(() {
          _errorMessage = null;
          _successMessage = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _fullNameController.dispose();
    super.dispose();
  }

  bool get _isSignUp => _tabController.index == 1;

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final authService = ref.read(authServiceProvider);
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    try {
      if (_isSignUp) {
        final fullName = _fullNameController.text.trim();
        final response = await authService.signUpWithEmail(
          email: email,
          password: password,
          data: fullName.isNotEmpty ? {'full_name': fullName} : null,
        );

        if (!mounted) return;

        if (response.session == null && response.user != null) {
          setState(() {
            _successMessage =
                'Verification code sent to $email! Enter the 6-digit code to continue.';
          });
          if (mounted) {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => VerifyEmailScreen(email: email),
              ),
            );
          }
        } else {
          // Immediately logged in
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              backgroundColor: Color(0xFF171922),
              content: Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: Color(0xFF00FFA3)),
                  SizedBox(width: 8),
                  Text('Welcome to Setthi!', style: TextStyle(color: Colors.white)),
                ],
              ),
            ),
          );
        }
      } else {
        await authService.signInWithEmail(
          email: email,
          password: password,
        );

        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF171922),
            content: Row(
              children: [
                Icon(Icons.check_circle_rounded, color: Color(0xFF00FFA3)),
                SizedBox(width: 8),
                Text('Signed in successfully!', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
        );
      }
    } on AuthException catch (e) {
      setState(() {
        _errorMessage = _formatErrorMessage(e.message);
      });
    } catch (e) {
      setState(() {
        _errorMessage = _formatErrorMessage(e);
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatErrorMessage(dynamic error) {
    if (error == null) return 'An error occurred';
    final raw = error is AuthException ? error.message : error.toString();
    try {
      final trimmed = raw.trim();
      if (trimmed.startsWith('{') && trimmed.endsWith('}')) {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          if (decoded['message'] != null) {
            return decoded['message'].toString();
          }
          if (decoded['error_description'] != null) {
            return decoded['error_description'].toString();
          }
        }
      }
    } catch (_) {}
    return raw.replaceFirst(RegExp(r'^Exception:\s*'), '');
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() {
      _isGoogleLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    final authService = ref.read(authServiceProvider);

    try {
      await authService.signInWithGoogle();
    } on AuthException catch (e) {
      if (mounted) {
        setState(() => _errorMessage = _formatErrorMessage(e.message));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = _formatErrorMessage(e));
      }
    } finally {
      if (mounted) {
        setState(() => _isGoogleLoading = false);
      }
    }
  }

  void _handleSkip() {
    ref.read(authBypassProvider.notifier).bypass();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const TransactionFeedScreen()),
      );
    }
  }

  Future<void> _showForgotPasswordDialog() async {
    final resetEmailController = TextEditingController(text: _emailController.text);
    bool isSending = false;
    String? resetError;
    String? resetSuccess;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => Dialog(
          backgroundColor: DpcColors.surfaceDark,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: DpcColors.surfaceBorder),
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Reset Password',
                  style: TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Enter your email address and we will send you a link to reset your password.',
                  style: TextStyle(color: DpcColors.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: resetEmailController,
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: DpcColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Enter your email',
                    hintStyle: const TextStyle(color: DpcColors.textMuted),
                    prefixIcon: const Icon(Icons.mail_outline_rounded, color: DpcColors.textSecondary),
                    filled: true,
                    fillColor: DpcColors.bgOled,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: DpcColors.surfaceBorder),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: DpcColors.accentPositive),
                    ),
                  ),
                ),
                if (resetError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    resetError!,
                    style: const TextStyle(color: DpcColors.accentNegative, fontSize: 12),
                  ),
                ],
                if (resetSuccess != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    resetSuccess!,
                    style: const TextStyle(color: DpcColors.accentPositive, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel', style: TextStyle(color: DpcColors.textSecondary)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: isSending
                          ? null
                          : () async {
                              final email = resetEmailController.text.trim();
                              if (email.isEmpty || !email.contains('@')) {
                                setDialogState(() {
                                  resetError = 'Please enter a valid email address';
                                });
                                return;
                              }
                              setDialogState(() {
                                isSending = true;
                                resetError = null;
                              });
                              try {
                                await ref.read(authServiceProvider).resetPassword(email);
                                setDialogState(() {
                                  isSending = false;
                                  resetSuccess = 'Password reset email sent!';
                                });
                              } catch (e) {
                                setDialogState(() {
                                  isSending = false;
                                  resetError = e.toString();
                                });
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DpcColors.accentPositive,
                        foregroundColor: DpcColors.textContrast,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: isSending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: DpcColors.textContrast,
                              ),
                            )
                          : const Text('Send Link', style: TextStyle(fontWeight: FontWeight.w700)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const bgColor = DpcColors.bgOled;
    const cardColor = DpcColors.surfaceDark;
    const borderColor = DpcColors.surfaceBorder;
    const mintAccent = DpcColors.accentPositive;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          TextButton.icon(
            onPressed: _handleSkip,
            icon: const Icon(
              Icons.arrow_forward_rounded,
              size: 15,
              color: mintAccent,
            ),
            label: const Text(
              'Skip for now',
              style: TextStyle(
                color: mintAccent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Brand Header
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      gradient: DpcColors.heroPastel1,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF86E3CE).withValues(alpha: 0.25),
                          blurRadius: 20,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.bolt_rounded,
                      color: DpcColors.textContrast,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Setthi',
                    style: TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 32,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Next-Gen Financial Intelligence',
                    style: TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Tab switcher (Sign In vs Sign Up)
                  Container(
                    height: 48,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: borderColor),
                    ),
                    child: TabBar(
                      controller: _tabController,
                      indicatorSize: TabBarIndicatorSize.tab,
                      indicator: BoxDecoration(
                        color: DpcColors.surfaceTrack,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: DpcColors.surfaceBorder,
                          width: 1,
                        ),
                      ),
                      dividerColor: Colors.transparent,
                      labelColor: DpcColors.textPrimary,
                      unselectedLabelColor: DpcColors.textSecondary,
                      labelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      tabs: const [
                        Tab(text: 'Sign In'),
                        Tab(text: 'Create Account'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Error Banner
                  if (_errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5C5C).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFFFF5C5C).withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.error_outline_rounded,
                                color: Color(0xFFFF5C5C),
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: const TextStyle(
                                    color: Color(0xFFFF5C5C),
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_errorMessage!.toLowerCase().contains('confirm') ||
                              _errorMessage!.toLowerCase().contains('verify')) ...[
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              height: 36,
                              child: OutlinedButton(
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => VerifyEmailScreen(
                                        email: _emailController.text.trim(),
                                      ),
                                    ),
                                  );
                                },
                                style: OutlinedButton.styleFrom(
                                  side: const BorderSide(color: Color(0xFFFF5C5C)),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                                child: const Text(
                                  'Enter Verification Code',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Success Banner
                  if (_successMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: mintAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: mintAccent.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.mark_email_read_rounded,
                                color: mintAccent,
                                size: 18,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _successMessage!,
                                  style: const TextStyle(
                                    color: mintAccent,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: double.infinity,
                            height: 36,
                            child: ElevatedButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => VerifyEmailScreen(
                                      email: _emailController.text.trim(),
                                    ),
                                  ),
                                );
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: mintAccent,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              child: const Text(
                                'Enter 6-Digit Code Now',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Auth Form
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: borderColor),
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_isSignUp) ...[
                            _buildInputLabel('Full Name'),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _fullNameController,
                              style: const TextStyle(color: Colors.white, fontSize: 14),
                              decoration: _inputDecoration(
                                hint: 'e.g. Maya Patel',
                                icon: Icons.person_outline_rounded,
                              ),
                              validator: (val) {
                                if (_isSignUp && (val == null || val.trim().isEmpty)) {
                                  return 'Please enter your name';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                          ],

                          _buildInputLabel('Email Address'),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: _inputDecoration(
                              hint: 'you@domain.com',
                              icon: Icons.mail_outline_rounded,
                            ),
                            validator: (val) {
                              if (val == null || val.trim().isEmpty) {
                                return 'Email is required';
                              }
                              if (!val.contains('@') || !val.contains('.')) {
                                return 'Please enter a valid email address';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),

                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildInputLabel('Password'),
                              if (!_isSignUp)
                                GestureDetector(
                                  onTap: _showForgotPasswordDialog,
                                  child: const Text(
                                    'Forgot?',
                                    style: TextStyle(
                                      color: mintAccent,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _passwordController,
                            obscureText: !_isPasswordVisible,
                            style: const TextStyle(color: Colors.white, fontSize: 14),
                            decoration: _inputDecoration(
                              hint: '••••••••',
                              icon: Icons.lock_outline_rounded,
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _isPasswordVisible
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                  color: Colors.white60,
                                  size: 20,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _isPasswordVisible = !_isPasswordVisible;
                                  });
                                },
                              ),
                            ),
                            validator: (val) {
                              if (val == null || val.isEmpty) {
                                return 'Password is required';
                              }
                              if (_isSignUp && val.length < 6) {
                                return 'Password must be at least 6 characters';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 22),

                          // Submit Button
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleSubmit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: mintAccent,
                                foregroundColor: Colors.black,
                                elevation: 0,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.5,
                                        color: Colors.black,
                                      ),
                                    )
                                  : Text(
                                      _isSignUp ? 'Create Free Account' : 'Sign In to Setthi',
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Skip for now button
                          SizedBox(
                            width: double.infinity,
                            height: 44,
                            child: OutlinedButton.icon(
                              onPressed: _handleSkip,
                              icon: const Icon(
                                Icons.arrow_forward_rounded,
                                size: 16,
                                color: DpcColors.accentPrimary,
                              ),
                              label: const Text(
                                'Skip for now (Explore UI)',
                                style: TextStyle(
                                  color: DpcColors.accentPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: DpcColors.surfaceBorder),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Center(
                            child: TextButton.icon(
                              onPressed: () {
                                final email = _emailController.text.trim();
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => VerifyEmailScreen(email: email),
                                  ),
                                );
                              },
                              icon: const Icon(
                                Icons.pin_rounded,
                                size: 16,
                                color: mintAccent,
                              ),
                              label: const Text(
                                'Have a verification code? Enter Code',
                                style: TextStyle(
                                  color: mintAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Divider
                  Row(
                    children: [
                      const Expanded(child: Divider(color: borderColor)),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Text(
                          'OR CONTINUE WITH',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                      const Expanded(child: Divider(color: borderColor)),
                    ],
                  ),
                  const SizedBox(height: 20),

                  // Google Sign In Button
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: _isGoogleLoading ? null : _handleGoogleSignIn,
                      style: OutlinedButton.styleFrom(
                        backgroundColor: cardColor,
                        side: const BorderSide(color: borderColor),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: _isGoogleLoading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: mintAccent,
                              ),
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _buildGoogleIcon(),
                                const SizedBox(width: 12),
                                const Text(
                                  'Continue with Google',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Security Badge
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 14,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Secured with Supabase 256-bit AES encryption',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputLabel(String label) {
    return Text(
      label,
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: DpcColors.textMuted, fontSize: 13),
      prefixIcon: Icon(icon, color: DpcColors.textSecondary, size: 20),
      suffixIcon: suffixIcon,
      filled: true,
      fillColor: DpcColors.bgOled,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentPositive),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentNegative),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: DpcColors.accentNegative),
      ),
    );
  }

  /// Official Google 4-color "G" logo drawn cleanly with CustomPaint
  Widget _buildGoogleIcon() {
    return CustomPaint(
      size: const Size(20, 20),
      painter: _GoogleIconPainter(),
    );
  }
}

/// Custom painter rendering the Google 4-color 'G' vector
class _GoogleIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final paint = Paint()..style = PaintingStyle.fill;

    // Blue
    paint.color = const Color(0xFF4285F4);
    final bluePath = Path()
      ..moveTo(w * 0.95, h * 0.51)
      ..cubicTo(w * 0.95, h * 0.47, w * 0.94, h * 0.44, w * 0.93, h * 0.41)
      ..lineTo(w * 0.50, h * 0.41)
      ..lineTo(w * 0.50, h * 0.60)
      ..lineTo(w * 0.75, h * 0.60)
      ..cubicTo(w * 0.74, h * 0.67, w * 0.70, h * 0.73, w * 0.64, h * 0.77)
      ..lineTo(w * 0.79, h * 0.89)
      ..cubicTo(w * 0.88, h * 0.80, w * 0.95, h * 0.67, w * 0.95, h * 0.51)
      ..close();
    canvas.drawPath(bluePath, paint);

    // Green
    paint.color = const Color(0xFF34A853);
    final greenPath = Path()
      ..moveTo(w * 0.50, h * 0.96)
      ..cubicTo(w * 0.63, h * 0.96, w * 0.74, h * 0.92, w * 0.81, h * 0.85)
      ..lineTo(w * 0.66, h * 0.73)
      ..cubicTo(w * 0.62, h * 0.76, w * 0.56, h * 0.78, w * 0.50, h * 0.78)
      ..cubicTo(w * 0.37, h * 0.78, w * 0.27, h * 0.70, w * 0.23, h * 0.59)
      ..lineTo(w * 0.08, h * 0.70)
      ..cubicTo(w * 0.16, h * 0.86, w * 0.32, h * 0.96, w * 0.50, h * 0.96)
      ..close();
    canvas.drawPath(greenPath, paint);

    // Yellow
    paint.color = const Color(0xFFFBBC05);
    final yellowPath = Path()
      ..moveTo(w * 0.23, h * 0.59)
      ..cubicTo(w * 0.22, h * 0.56, w * 0.21, h * 0.53, w * 0.21, h * 0.50)
      ..cubicTo(w * 0.21, h * 0.47, w * 0.22, h * 0.44, w * 0.23, h * 0.41)
      ..lineTo(w * 0.08, h * 0.30)
      ..cubicTo(w * 0.04, h * 0.36, w * 0.02, h * 0.43, w * 0.02, h * 0.50)
      ..cubicTo(w * 0.02, h * 0.57, w * 0.04, h * 0.64, w * 0.08, h * 0.70)
      ..lineTo(w * 0.23, h * 0.59)
      ..close();
    canvas.drawPath(yellowPath, paint);

    // Red
    paint.color = const Color(0xFFEA4335);
    final redPath = Path()
      ..moveTo(w * 0.50, h * 0.22)
      ..cubicTo(w * 0.57, h * 0.22, w * 0.64, h * 0.25, w * 0.69, h * 0.29)
      ..lineTo(w * 0.81, h * 0.17)
      ..cubicTo(w * 0.73, h * 0.10, w * 0.62, h * 0.04, w * 0.50, h * 0.04)
      ..cubicTo(w * 0.32, h * 0.04, w * 0.16, h * 0.14, w * 0.08, h * 0.30)
      ..lineTo(w * 0.23, h * 0.41)
      ..cubicTo(w * 0.27, h * 0.30, w * 0.37, h * 0.22, w * 0.50, h * 0.22)
      ..close();
    canvas.drawPath(redPath, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
