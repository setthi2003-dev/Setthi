import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

/// Supported Gmail API operations and their semantics
enum GmailApiOp {
  messagesList,
  messagesGetMetadata,
  messagesGetFull,
  attachmentsGet,
  getProfile,
}

/// Centralized, configurable Gmail API quota units and rate limits
class GmailQuotaCosts {
  final int messagesList;
  final int messagesGetMetadata;
  final int messagesGetFull;
  final int attachmentsGet;
  final int getProfile;

  /// Maximum quota units allowed per rolling window (Default: 4,500)
  final int maxQuotaPerMinute;

  /// Maximum full email fetches allowed per rolling window (Default: 50)
  final int maxFullFetchesPerMinute;

  /// Window duration (Default: 60 seconds)
  final Duration windowDuration;

  const GmailQuotaCosts({
    this.messagesList = 5,
    this.messagesGetMetadata = 20,
    this.messagesGetFull = 60,
    this.attachmentsGet = 20,
    this.getProfile = 1,
    this.maxQuotaPerMinute = 4500,
    this.maxFullFetchesPerMinute = 50,
    this.windowDuration = const Duration(seconds: 60),
  });

  int getCost(GmailApiOp op) {
    switch (op) {
      case GmailApiOp.messagesList:
        return messagesList;
      case GmailApiOp.messagesGetMetadata:
        return messagesGetMetadata;
      case GmailApiOp.messagesGetFull:
        return messagesGetFull;
      case GmailApiOp.attachmentsGet:
        return attachmentsGet;
      case GmailApiOp.getProfile:
        return getProfile;
    }
  }

  bool isFullFetch(GmailApiOp op) => op == GmailApiOp.messagesGetFull;
}

/// Record of an allowed Gmail API request inside the rolling window
class _QuotaEntry {
  final DateTime timestamp;
  final int units;
  final bool isFullFetch;
  final GmailApiOp op;

  const _QuotaEntry({
    required this.timestamp,
    required this.units,
    required this.isFullFetch,
    required this.op,
  });
}

/// Per-account rolling window rate tracker with strict FIFO queueing
class _AccountRateTracker {
  final String accountEmail;
  final GmailQuotaCosts costs;
  final DateTime Function() nowFn;
  final Future<void> Function(Duration) sleepFn;

  final List<_QuotaEntry> _entries = [];
  Completer<void>? _activeLock;

  _AccountRateTracker({
    required this.accountEmail,
    required this.costs,
    required this.nowFn,
    required this.sleepFn,
  });

  /// Synchronizes access so concurrent requests evaluate quota in strict FIFO order
  Future<T> synchronized<T>(Future<T> Function() action) async {
    while (_activeLock != null) {
      await _activeLock!.future;
    }
    final lock = Completer<void>();
    _activeLock = lock;
    try {
      return await action();
    } finally {
      _activeLock = null;
      lock.complete();
    }
  }

  /// Purges entries that fall outside the rolling window
  void _pruneOldEntries(DateTime now) {
    final cutoff = now.subtract(costs.windowDuration);
    _entries.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }

  int get currentQuotaUnits {
    _pruneOldEntries(nowFn());
    return _entries.fold<int>(0, (sum, e) => sum + e.units);
  }

  int get currentFullFetches {
    _pruneOldEntries(nowFn());
    return _entries.where((e) => e.isFullFetch).length;
  }

  /// Acquires permission to run [op]. If limits would be exceeded, automatically waits
  /// until capacity becomes available.
  Future<void> acquire(GmailApiOp op) async {
    final cost = costs.getCost(op);
    final isFull = costs.isFullFetch(op);

    while (true) {
      final now = nowFn();
      _pruneOldEntries(now);

      final currentUnits = _entries.fold<int>(0, (sum, e) => sum + e.units);
      final currentFetches = _entries.where((e) => e.isFullFetch).length;

      final wouldExceedQuota = (currentUnits + cost) > costs.maxQuotaPerMinute;
      final wouldExceedFetches = isFull && (currentFetches + 1 > costs.maxFullFetchesPerMinute);

      if (!wouldExceedQuota && !wouldExceedFetches) {
        // Capacity available: record entry and proceed
        _entries.add(_QuotaEntry(
          timestamp: now,
          units: cost,
          isFullFetch: isFull,
          op: op,
        ));

        final newFetches = currentFetches + (isFull ? 1 : 0);
        final newUnits = currentUnits + cost;

        debugPrint('[GmailQuota] Email fetch usage: $newFetches/${costs.maxFullFetchesPerMinute}');
        debugPrint('[GmailQuota] Quota consumption: $newUnits/${costs.maxQuotaPerMinute}');
        debugPrint('[GmailQuota] Request allowed');
        return;
      }

      // Limits reached: calculate duration until earliest entry rolls out of window
      debugPrint('[GmailQuota] Waiting for quota availability...');
      Duration waitDuration = const Duration(milliseconds: 500);

      if (_entries.isNotEmpty) {
        final oldest = _entries.first.timestamp;
        final expiry = oldest.add(costs.windowDuration);
        final remaining = expiry.difference(now);
        if (remaining > Duration.zero) {
          // Add a tiny buffer (10ms) to ensure the oldest entry is past the cutoff
          waitDuration = remaining + const Duration(milliseconds: 10);
        }
      }

      await sleepFn(waitDuration);
    }
  }

  /// Records an externally granted operation (e.g. from Supabase cross-device coordinator)
  void recordGranted(GmailApiOp op) {
    final now = nowFn();
    _pruneOldEntries(now);
    _entries.add(_QuotaEntry(
      timestamp: now,
      units: costs.getCost(op),
      isFullFetch: costs.isFullFetch(op),
      op: op,
    ));
  }

  void reset() {
    _entries.clear();
  }
}

/// Centralized Gmail API Rate Limiter
/// Enforces:
/// 1. 50 full email fetches per rolling 60-second window
/// 2. 4,500 quota units per rolling 60-second window
/// 3. Exponential backoff with jitter on 429 and rate-limiting 403s
/// 4. Per-account rate tracking & cross-device coordination via Supabase RPC
class GmailRateLimiter {
  static final GmailRateLimiter instance = GmailRateLimiter();

  final GmailQuotaCosts costs;
  final DateTime Function() _nowFn;
  final Future<void> Function(Duration) _sleepFn;
  final double Function()? _jitterGenerator;
  final SupabaseClient? _supabaseClient;

  final Map<String, _AccountRateTracker> _trackers = {};

  GmailRateLimiter({
    this.costs = const GmailQuotaCosts(),
    DateTime Function()? nowFn,
    Future<void> Function(Duration)? sleepFn,
    this._jitterGenerator,
    this._supabaseClient,
  })  : _nowFn = nowFn ?? DateTime.now,
        _sleepFn = sleepFn ?? Future.delayed;

  SupabaseClient? get _effectiveSupabaseClient {
    if (_supabaseClient != null) return _supabaseClient;
    try {
      if (SupabaseConfig.isConfigured) {
        return Supabase.instance.client;
      }
    } catch (_) {}
    return null;
  }

  String _normalizeAccount(String? email) {
    final clean = (email ?? 'default').trim().toLowerCase();
    return clean.isEmpty ? 'default' : clean;
  }

  _AccountRateTracker _getTracker(String? email) {
    final key = _normalizeAccount(email);
    return _trackers.putIfAbsent(
      key,
      () => _AccountRateTracker(
        accountEmail: key,
        costs: costs,
        nowFn: _nowFn,
        sleepFn: _sleepFn,
      ),
    );
  }

  /// Current quota units consumed in the rolling 60s window for [accountEmail]
  int getCurrentQuotaUnits([String? accountEmail]) =>
      _getTracker(accountEmail).currentQuotaUnits;

  /// Current full email fetches performed in the rolling 60s window for [accountEmail]
  int getCurrentFullFetches([String? accountEmail]) =>
      _getTracker(accountEmail).currentFullFetches;

  /// Resets tracker state (useful for tests)
  void reset([String? accountEmail]) {
    if (accountEmail != null) {
      _trackers[_normalizeAccount(accountEmail)]?.reset();
    } else {
      for (final t in _trackers.values) {
        t.reset();
      }
      _trackers.clear();
    }
  }

  /// Determines whether an HTTP response represents a rate limit error that should be retried.
  /// Matches HTTP 429 or HTTP 403 containing 'rateLimitExceeded' or 'userRateLimitExceeded'.
  /// Does NOT match regular permission, authentication, or missing scope errors.
  static bool isRateLimitError(int statusCode, String responseBody) {
    if (statusCode == 429) return true;
    if (statusCode == 403) {
      final lower = responseBody.toLowerCase();
      if (lower.contains('ratelimitexceeded') ||
          lower.contains('userratelimitexceeded') ||
          lower.contains('rate limit exceeded')) {
        return true;
      }
    }
    return false;
  }

  /// Coordinates quota acquisition with Supabase RPC for multi-device sync
  Future<bool> _tryAcquireCrossDevice(String accountEmail, GmailApiOp op) async {
    final client = _effectiveSupabaseClient;
    if (client == null) return false;

    try {
      final res = await client.rpc(
        'check_and_record_gmail_quota',
        params: {
          'p_account_email': accountEmail,
          'p_operation': op.name,
          'p_quota_units': costs.getCost(op),
          'p_is_full_fetch': costs.isFullFetch(op),
          'p_max_quota': costs.maxQuotaPerMinute,
          'p_max_full_fetches': costs.maxFullFetchesPerMinute,
          'p_window_seconds': costs.windowDuration.inSeconds,
        },
      );

      if (res is Map) {
        final allowed = res['allowed'] == true;
        if (!allowed) {
          final waitSec = (res['wait_seconds'] as num?)?.toDouble() ?? 1.0;
          debugPrint('[GmailQuota] Cross-device coordination: Waiting ${waitSec.toStringAsFixed(1)}s for quota availability...');
          await _sleepFn(Duration(milliseconds: (waitSec * 1000).toInt()));
          return false; // Loop caller will retry
        }
        return true;
      }
    } catch (e) {
      debugPrint('[GmailQuota] Note: Cross-device coordination skipped ($e). Using client rate limiter.');
    }
    return false;
  }

  /// Acquires quota before an API request
  Future<void> acquire({
    required GmailApiOp op,
    String? accountEmail,
  }) async {
    final tracker = _getTracker(accountEmail);
    await tracker.synchronized(() async {
      final key = _normalizeAccount(accountEmail);

      // 1. If Supabase is connected, attempt centralized cross-device atomic coordination
      if (_effectiveSupabaseClient != null) {
        while (true) {
          final granted = await _tryAcquireCrossDevice(key, op);
          if (granted) {
            tracker.recordGranted(op);
            debugPrint('[GmailQuota] Request allowed');
            return;
          }
          final client = _effectiveSupabaseClient;
          if (client == null) break;
        }
      }

      // 2. Strict local in-memory rolling window acquisition (guarantees local safety)
      await tracker.acquire(op);
    });
  }

  /// Executes an API request with pre-request quota checking and exponential backoff retry
  /// if Google returns 429 or rateLimitExceeded 403.
  Future<T> executeWithRetry<T>({
    required GmailApiOp op,
    String? accountEmail,
    required Future<T> Function() requestAction,
    required int Function(T result) getStatusCode,
    required String Function(T result) getResponseBody,
    int maxRetries = 6,
  }) async {
    final backoffSchedule = [1, 2, 4, 8, 16, 32];
    int attempt = 0;

    while (true) {
      // 1. Wait for quota availability before dispatching
      await acquire(op: op, accountEmail: accountEmail);

      // 2. Execute network request
      final result = await requestAction();
      final statusCode = getStatusCode(result);
      final body = getResponseBody(result);

      // 3. Inspect for Google rate limit errors
      if (isRateLimitError(statusCode, body) && attempt < maxRetries) {
        final baseSeconds = attempt < backoffSchedule.length
            ? backoffSchedule[attempt]
            : backoffSchedule.last;

        // Exponential backoff with jitter (0.0 to 0.5s)
        final jitter = (_jitterGenerator != null)
            ? _jitterGenerator() * 0.5
            : (Random().nextDouble() * 0.5);

        final totalDelaySeconds = (baseSeconds + jitter);
        final delayMs = (totalDelaySeconds * 1000).toInt();

        debugPrint('[GmailQuota] Rate limit detected. Retrying in $baseSeconds seconds.');
        attempt++;
        await _sleepFn(Duration(milliseconds: delayMs));
        continue;
      }

      if (statusCode >= 200 && statusCode < 300) {
        debugPrint('[GmailQuota] Request completed successfully.');
      }

      return result;
    }
  }
}
