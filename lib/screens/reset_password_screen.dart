import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/dpc_tokens.dart';
import '../providers/auth_providers.dart';

/// Screen implementing a 2-step password recovery flow:
/// Step 1: Verify 6-digit OTP code sent to user email.
/// Step 2: Show and enable new password fields to create/save new password.
class ResetPasswordScreen extends ConsumerStatefulWidget {
  final String? email;
  final bool initialCodeVerified;

  const ResetPasswordScreen({
    super.key,
    this.email,
    this.initialCodeVerified = false,
  });

  @override
  ConsumerState<ResetPasswordScreen> createState() =>
      _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _emailController;
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final FocusNode _codeFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  late bool _isCodeVerified;
  bool _isPasswordVisible = false;
  bool _isConfirmVisible = false;
  bool _isLoading = false;
  bool _isResending = false;
  String? _errorMessage;
  String? _successMessage;

  int _resendCooldown = 30;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    _isCodeVerified = widget.initialCodeVerified;
    _emailController = TextEditingController(text: widget.email ?? '');
    _startCooldownTimer();

    // Auto-focus appropriate field
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (!_isCodeVerified) {
          _codeFocusNode.requestFocus();
        } else {
          _passwordFocusNode.requestFocus();
        }
      }
    });
  }

  @override
  void didUpdateWidget(ResetPasswordScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialCodeVerified != oldWidget.initialCodeVerified) {
      setState(() {
        _isCodeVerified = widget.initialCodeVerified;
      });
    }
  }

  void _startCooldownTimer() {
    setState(() => _resendCooldown = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldown > 0) {
        setState(() => _resendCooldown--);
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _emailController.dispose();
    _codeController.dispose();
    _codeFocusNode.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _handleResendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = 'Please enter a valid email address';
      });
      return;
    }

    setState(() {
      _isResending = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final authService = ref.read(authServiceProvider);
      await authService.resetPassword(email);

      if (!mounted) return;
      setState(() {
        _isResending = false;
        _successMessage = 'A new 6-digit code has been sent to $email';
      });
      _startCooldownTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isResending = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _handleVerifyCode() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      setState(() {
        _errorMessage = 'Please enter a valid email address';
      });
      return;
    }

    if (code.length < 6) {
      setState(() {
        _errorMessage = 'Please enter the complete 6-digit verification code';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final authService = ref.read(authServiceProvider);

      // Verify 6-digit recovery OTP code with Supabase
      await authService.verifyRecoveryOtp(
        email: email,
        token: code,
      );

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _isCodeVerified = true;
        _errorMessage = null;
        _successMessage = 'Code verified! Now create your new password.';
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _passwordFocusNode.requestFocus();
        }
      });
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _handleUpdatePassword() async {
    if (!_formKey.currentState!.validate()) return;

    final newPassword = _passwordController.text;
    final confirmPassword = _confirmPasswordController.text;

    if (newPassword.length < 6) {
      setState(() {
        _errorMessage = 'Password must be at least 6 characters';
      });
      return;
    }

    if (newPassword != confirmPassword) {
      setState(() {
        _errorMessage = 'Passwords do not match';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final authService = ref.read(authServiceProvider);

      // Set the new password via Supabase
      await authService.updatePassword(newPassword);

      if (!mounted) return;

      // Clear recovery state to allow seamless transition to home
      ref.read(isPasswordRecoveryProvider.notifier).clearRecovery();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF1E1E24),
          behavior: SnackBarBehavior.floating,
          content: Row(
            children: [
              Icon(Icons.check_circle_rounded, color: DpcColors.accentPositive),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Password reset successfully! You are now signed in.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );

      // Pop back to root to render TransactionFeedScreen
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _handleCancel() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      ref.read(isPasswordRecoveryProvider.notifier).clearRecovery();
    }
  }

  @override
  Widget build(BuildContext context) {
    const cardColor = Color(0xFF111116);
    const borderColor = Color(0xFF26262E);
    const mintAccent = DpcColors.accentPositive;

    return Scaffold(
      backgroundColor: DpcColors.bgOled,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: DpcColors.textPrimary),
          onPressed: _handleCancel,
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // App Brand Icon
                  Image.asset(
                    'assets/app icon/Setthi.png',
                    width: 56,
                    height: 56,
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => const Icon(
                      Icons.lock_reset_rounded,
                      color: DpcColors.textPrimary,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _isCodeVerified ? 'Create New Password' : 'Reset Password',
                    style: const TextStyle(
                      color: DpcColors.textPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _isCodeVerified
                        ? 'Choose a strong password with at least 6 characters.'
                        : (widget.email != null && widget.email!.isNotEmpty
                            ? 'Enter the 6-digit code sent to ${widget.email}'
                            : 'Enter the 6-digit code sent to your email address.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: DpcColors.textSecondary,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 2-Step Flow Indicator
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildStepBadge(
                        step: 1,
                        title: 'Enter Code',
                        isActive: !_isCodeVerified,
                        isDone: _isCodeVerified,
                        mintAccent: mintAccent,
                        borderColor: borderColor,
                      ),
                      Container(
                        width: 24,
                        height: 1.5,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: _isCodeVerified ? mintAccent : borderColor,
                      ),
                      _buildStepBadge(
                        step: 2,
                        title: 'New Password',
                        isActive: _isCodeVerified,
                        isDone: false,
                        mintAccent: mintAccent,
                        borderColor: borderColor,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

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
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle_outline_rounded,
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
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Error Banner
                  if (_errorMessage != null) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: DpcColors.accentNegative.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: DpcColors.accentNegative.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline_rounded,
                            color: DpcColors.accentNegative,
                            size: 18,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: const TextStyle(
                                color: DpcColors.accentNegative,
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],

                  // Form Container
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: borderColor),
                    ),
                    child: Form(
                      key: _formKey,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: !_isCodeVerified
                            ? _buildVerificationStep(
                                context: context,
                                borderColor: borderColor,
                                mintAccent: mintAccent,
                                cardColor: cardColor,
                              )
                            : _buildPasswordStep(
                                context: context,
                                borderColor: borderColor,
                                mintAccent: mintAccent,
                                cardColor: cardColor,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepBadge({
    required int step,
    required String title,
    required bool isActive,
    required bool isDone,
    required Color mintAccent,
    required Color borderColor,
  }) {
    final color = isDone || isActive ? mintAccent : DpcColors.textMuted;
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDone ? mintAccent : Colors.transparent,
            border: Border.all(color: color, width: 1.5),
          ),
          alignment: Alignment.center,
          child: isDone
              ? const Icon(Icons.check, size: 13, color: DpcColors.bgOled)
              : Text(
                  '$step',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
        const SizedBox(width: 7),
        Text(
          title,
          style: TextStyle(
            color: isDone || isActive
                ? DpcColors.textPrimary
                : DpcColors.textMuted,
            fontSize: 12,
            fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ],
    );
  }

  /// Step 1 UI: Verify 6-digit code
  Widget _buildVerificationStep({
    required BuildContext context,
    required Color borderColor,
    required Color mintAccent,
    required Color cardColor,
  }) {
    return Column(
      key: const ValueKey('step_verification'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Email Address
        const Text(
          'Email Address',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'you@domain.com',
            hintStyle: const TextStyle(color: DpcColors.textMuted),
            prefixIcon: const Icon(
              Icons.mail_outline_rounded,
              color: DpcColors.textSecondary,
              size: 20,
            ),
            filled: true,
            fillColor: DpcColors.bgOled,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: mintAccent),
            ),
          ),
          validator: (val) {
            if (val == null || !val.contains('@')) {
              return 'Please enter a valid email';
            }
            return null;
          },
        ),
        const SizedBox(height: 18),

        // 6-Digit Code Header
        const Text(
          '6-Digit Verification Code',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),

        // Visual 6-Digit Code Boxes
        Stack(
          alignment: Alignment.center,
          children: [
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _codeController,
              builder: (context, val, _) {
                final text = val.text;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (index) {
                    final char = index < text.length ? text[index] : '';
                    final isFocused = index == text.length && _codeFocusNode.hasFocus;

                    return Container(
                      width: 44,
                      height: 50,
                      decoration: BoxDecoration(
                        color: DpcColors.bgOled,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isFocused
                              ? mintAccent
                              : char.isNotEmpty
                                  ? mintAccent.withValues(alpha: 0.5)
                                  : borderColor,
                          width: isFocused ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        char,
                        style: const TextStyle(
                          color: DpcColors.textPrimary,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            // Hidden actual input field for keypad and paste
            Opacity(
              opacity: 0.0,
              child: TextField(
                controller: _codeController,
                focusNode: _codeFocusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                autofillHints: const [
                  AutofillHints.oneTimeCode,
                ],
                enableInteractiveSelection: true,
                onSubmitted: (_) => _handleVerifyCode(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),

        // Verify Code Button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: mintAccent,
              foregroundColor: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            onPressed: _isLoading ? null : _handleVerifyCode,
            child: _isLoading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(cardColor),
                    ),
                  )
                : const Text(
                    'Verify Code',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),

        // Resend Code Section
        Center(
          child: _resendCooldown > 0
              ? Text(
                  'Resend code in ${_resendCooldown}s',
                  style: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                )
              : TextButton.icon(
                  onPressed: _isResending ? null : _handleResendCode,
                  icon: _isResending
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.8,
                            color: mintAccent,
                          ),
                        )
                      : Icon(
                          Icons.refresh_rounded,
                          size: 16,
                          color: mintAccent,
                        ),
                  label: Text(
                    'Resend 6-digit Code',
                    style: TextStyle(
                      color: mintAccent,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// Step 2 UI: Create & confirm new password
  Widget _buildPasswordStep({
    required BuildContext context,
    required Color borderColor,
    required Color mintAccent,
    required Color cardColor,
  }) {
    return Column(
      key: const ValueKey('step_password'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Verified Account Chip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: DpcColors.bgOled,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(Icons.verified_rounded, color: mintAccent, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'VERIFIED ACCOUNT',
                      style: TextStyle(
                        color: DpcColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _emailController.text.trim().isNotEmpty
                          ? _emailController.text.trim()
                          : (widget.email ?? ''),
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => setState(() {
                  _isCodeVerified = false;
                  _errorMessage = null;
                  _successMessage = null;
                }),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Change',
                  style: TextStyle(
                    color: mintAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // New Password
        const Text(
          'New Password',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          obscureText: !_isPasswordVisible,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: 'At least 6 characters',
            hintStyle: const TextStyle(
              color: DpcColors.textMuted,
            ),
            prefixIcon: const Icon(
              Icons.lock_outline_rounded,
              color: DpcColors.textSecondary,
              size: 20,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _isPasswordVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: DpcColors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() {
                  _isPasswordVisible = !_isPasswordVisible;
                });
              },
            ),
            filled: true,
            fillColor: DpcColors.bgOled,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: mintAccent),
            ),
          ),
          validator: (val) {
            if (val == null || val.length < 6) {
              return 'Password must be at least 6 characters';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),

        // Confirm Password
        const Text(
          'Confirm New Password',
          style: TextStyle(
            color: DpcColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: _confirmPasswordController,
          obscureText: !_isConfirmVisible,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
          ),
          decoration: InputDecoration(
            hintText: 'Re-enter your password',
            hintStyle: const TextStyle(
              color: DpcColors.textMuted,
            ),
            prefixIcon: const Icon(
              Icons.lock_outline_rounded,
              color: DpcColors.textSecondary,
              size: 20,
            ),
            suffixIcon: IconButton(
              icon: Icon(
                _isConfirmVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                color: DpcColors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                setState(() {
                  _isConfirmVisible = !_isConfirmVisible;
                });
              },
            ),
            filled: true,
            fillColor: DpcColors.bgOled,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: mintAccent),
            ),
          ),
          validator: (val) {
            if (val != _passwordController.text) {
              return 'Passwords do not match';
            }
            return null;
          },
        ),
        const SizedBox(height: 22),

        // Submit Action Button
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: mintAccent,
              foregroundColor: cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            onPressed: _isLoading ? null : _handleUpdatePassword,
            child: _isLoading
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(cardColor),
                    ),
                  )
                : const Text(
                    'Set New Password',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
