import 'dart:async';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../config/dpc_tokens.dart';
import '../config/setu_config.dart';
import '../services/setu_aa_service.dart';

/// Full-screen in-app WebView rendering Setu's Account Aggregator consent review flow
class SetuConsentWebView extends StatefulWidget {
  final String consentUrl;
  final String consentId;
  final SetuAaService aaService;

  const SetuConsentWebView({
    super.key,
    required this.consentUrl,
    required this.consentId,
    required this.aaService,
  });

  @override
  State<SetuConsentWebView> createState() => _SetuConsentWebViewState();
}

class _SetuConsentWebViewState extends State<SetuConsentWebView> {
  late final WebViewController _controller;
  Timer? _statusPollingTimer;
  bool _isLoading = true;
  int _loadingProgress = 0;
  bool _isDisposed = false;
  bool _isCompleted = false;

  @override
  void initState() {
    super.initState();
    _initWebViewController();
    _startPeriodicStatusCheck();
  }

  void _initWebViewController() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(DpcColors.bgOled)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!_isDisposed) {
              setState(() {
                _loadingProgress = progress;
                _isLoading = progress < 100;
              });
            }
          },
          onPageStarted: (url) {
            if (!_isDisposed) {
              setState(() => _isLoading = true);
            }
            _checkUrl(url);
          },
          onPageFinished: (url) {
            if (!_isDisposed) {
              setState(() => _isLoading = false);
            }
            _checkUrl(url);
          },
          onNavigationRequest: (request) {
            return _handleNavigation(request.url);
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.consentUrl));
  }

  bool _isCancellationUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('success=false') ||
        lower.contains('status=rejected') ||
        lower.contains('status=revoked') ||
        lower.contains('status=cancelled') ||
        lower.contains('status=canceled') ||
        lower.contains('status=failed') ||
        lower.contains('error=') ||
        lower.contains('error_code=') ||
        lower.contains('errorcode=') ||
        lower.contains('user_cancelled') ||
        lower.contains('user_canceled') ||
        lower.contains('user_rejected') ||
        lower.contains('denied');
  }

  bool _isRedirectOrSuccessCandidate(String url) {
    final lower = url.toLowerCase();
    final redirect = SetuConfig.redirectUrl.toLowerCase();
    final isRedirect = redirect.isNotEmpty && lower.contains(redirect);
    final hasSuccessIndicator = lower.contains('status=active') ||
        lower.contains('success=true') ||
        lower.contains('consent_approved=true') ||
        lower.contains('/consents/success');
    return isRedirect || hasSuccessIndicator;
  }

  NavigationDecision _handleNavigation(String url) {
    if (_isCancellationUrl(url)) {
      _completeConsentFlow(false);
      return NavigationDecision.prevent;
    }

    if (_isRedirectOrSuccessCandidate(url)) {
      _verifyAndCompleteConsent();
      return NavigationDecision.prevent;
    }

    return NavigationDecision.navigate;
  }

  void _checkUrl(String url) {
    if (_isCompleted) return;
    if (_isCancellationUrl(url)) {
      _completeConsentFlow(false);
      return;
    }
    if (_isRedirectOrSuccessCandidate(url)) {
      _verifyAndCompleteConsent();
    }
  }

  /// Verifies the consent status with Setu's backend before declaring success
  Future<void> _verifyAndCompleteConsent() async {
    if (_isCompleted) return;

    // Up to 3 attempts with brief delays to allow bank authorization to settle in Setu backend
    for (int i = 0; i < 3; i++) {
      if (_isCompleted || _isDisposed) return;
      try {
        final status =
            await widget.aaService.checkConsentStatus(widget.consentId);
        if (status == 'ACTIVE') {
          _completeConsentFlow(true);
          return;
        } else if (status == 'REJECTED' ||
            status == 'EXPIRED' ||
            status == 'REVOKED') {
          _completeConsentFlow(false);
          return;
        }
      } catch (_) {}
      if (i < 2) {
        await Future.delayed(const Duration(milliseconds: 600));
      }
    }

    // If status is still not ACTIVE (e.g. PENDING or uncompleted), mark as not successful
    _completeConsentFlow(false);
  }

  /// Periodically polls Setu's GET /v2/consents/:id every 1.2 seconds to detect approval
  void _startPeriodicStatusCheck() {
    _statusPollingTimer =
        Timer.periodic(const Duration(milliseconds: 1200), (timer) async {
      if (_isDisposed || _isCompleted) {
        timer.cancel();
        return;
      }

      try {
        final status =
            await widget.aaService.checkConsentStatus(widget.consentId);
        if (status == 'ACTIVE') {
          timer.cancel();
          _completeConsentFlow(true);
        } else if (status == 'REJECTED' ||
            status == 'EXPIRED' ||
            status == 'REVOKED') {
          timer.cancel();
          _completeConsentFlow(false);
        }
      } catch (_) {
        // Continue polling
      }
    });
  }

  Future<void> _handleClose() async {
    if (_isCompleted) return;
    
    // Check if the consent has actually succeeded on Setu's backend before giving up
    try {
      final status = await widget.aaService.checkConsentStatus(widget.consentId);
      if (status == 'ACTIVE') {
        _completeConsentFlow(true);
        return;
      }
    } catch (_) {}

    _completeConsentFlow(false);
  }

  void _completeConsentFlow(bool success) {
    if (_isDisposed || _isCompleted || !mounted) return;
    _isCompleted = true;
    _statusPollingTimer?.cancel();
    Navigator.of(context).pop(success);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _statusPollingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _handleClose();
        }
      },
      child: Scaffold(
        backgroundColor: DpcColors.bgOled,
        appBar: AppBar(
          backgroundColor: DpcColors.bgOled,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded, color: DpcColors.textPrimary),
            onPressed: _handleClose,
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: DpcColors.surfaceDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: DpcColors.surfaceBorder,
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_outline_rounded,
                      color: DpcColors.accentPositive,
                      size: 13,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Setu AA 256-bit Secure',
                      style: TextStyle(
                        color: DpcColors.accentPositive,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: DpcColors.textSecondary),
              onPressed: () => _controller.reload(),
            ),
            const SizedBox(width: 4),
          ],
          bottom: _isLoading
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    value: _loadingProgress / 100.0,
                    backgroundColor: DpcColors.surfaceTrack,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      DpcColors.accentPositive,
                    ),
                  ),
                )
              : null,
        ),
        body: SafeArea(
          child: WebViewWidget(controller: _controller),
        ),
      ),
    );
  }
}
