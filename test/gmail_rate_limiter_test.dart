import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:setthi/services/gmail_api_service.dart';
import 'package:setthi/services/gmail_rate_limiter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GmailRateLimiter Unit & Concurrency Tests', () {
    late DateTime simulatedTime;
    late List<Duration> simulatedSleeps;

    DateTime testNow() => simulatedTime;
    Future<void> testSleep(Duration d) async {
      simulatedSleeps.add(d);
      simulatedTime = simulatedTime.add(d);
    }

    setUp(() {
      simulatedTime = DateTime(2026, 11, 11, 12, 0, 0);
      simulatedSleeps = [];
    });

    test('1. 50 full email fetches can proceed within a rolling minute if quota permits', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // 50 full email fetches = 50 * 60 = 3000 units (well within 4500 limit)
      for (int i = 0; i < 50; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'test@example.com');
      }

      expect(limiter.getCurrentFullFetches('test@example.com'), equals(50));
      expect(limiter.getCurrentQuotaUnits('test@example.com'), equals(3000));
      expect(simulatedSleeps, isEmpty, reason: 'All 50 full fetches should proceed without waiting');
    });

    test('2. The 51st email fetch waits until capacity is available', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      for (int i = 0; i < 50; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'test@example.com');
      }

      expect(limiter.getCurrentFullFetches('test@example.com'), equals(50));

      // The 51st fetch must wait
      await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'test@example.com');

      expect(simulatedSleeps, isNotEmpty, reason: '51st fetch should have triggered wait');
      expect(simulatedSleeps.first.inSeconds, greaterThanOrEqualTo(60));
      expect(limiter.getCurrentFullFetches('test@example.com'), equals(1),
          reason: 'After rolling 60s has passed, old 50 fetches expired and only 1 remains');
    });

    test('3. The 4,500-unit quota budget is never exceeded', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // Using messages.get with metadata (20 units each, not a full email fetch).
      // 225 calls * 20 units = 4,500 units.
      for (int i = 0; i < 225; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetMetadata, accountEmail: 'budget@example.com');
      }

      expect(limiter.getCurrentQuotaUnits('budget@example.com'), equals(4500));
      expect(simulatedSleeps, isEmpty);

      // Next call (20 units) would exceed 4,500, so it must wait
      await limiter.acquire(op: GmailApiOp.messagesGetMetadata, accountEmail: 'budget@example.com');

      expect(simulatedSleeps, isNotEmpty);
      expect(limiter.getCurrentQuotaUnits('budget@example.com'), lessThanOrEqualTo(4500));
    });

    test('4. Attachment downloads consume 20 units each and do NOT increment full email fetch count', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      await limiter.acquire(op: GmailApiOp.attachmentsGet, accountEmail: 'attach@example.com');

      expect(limiter.getCurrentQuotaUnits('attach@example.com'), equals(20));
      expect(limiter.getCurrentFullFetches('attach@example.com'), equals(0));
    });

    test('5. Multiple attachments are counted independently', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // Download 3 attachments
      for (int i = 0; i < 3; i++) {
        await limiter.acquire(op: GmailApiOp.attachmentsGet, accountEmail: 'multi@example.com');
      }

      expect(limiter.getCurrentQuotaUnits('multi@example.com'), equals(60));
      expect(limiter.getCurrentFullFetches('multi@example.com'), equals(0));
    });

    test('6. Concurrent requests cannot exceed either limit', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // Fire 60 concurrent full fetch requests simultaneously
      final futures = List.generate(
        60,
        (_) => limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'concurrent@example.com'),
      );

      await Future.wait(futures);

      // After all 60 complete, 50 executed in window 1, and 10 in window 2
      expect(simulatedSleeps, isNotEmpty, reason: 'At least 10 requests had to wait');
      expect(limiter.getCurrentFullFetches('concurrent@example.com'), equals(10));
      expect(limiter.getCurrentQuotaUnits('concurrent@example.com'), equals(600));
    });

    test('7. HTTP 403 rate-limit and HTTP 429 errors trigger exponential backoff', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
        jitterGenerator: () => 0.0, // Zero jitter for deterministic check
      );

      int attempts = 0;
      final result = await limiter.executeWithRetry<http.Response>(
        op: GmailApiOp.messagesGetMetadata,
        accountEmail: 'retry@example.com',
        requestAction: () async {
          attempts++;
          if (attempts == 1) {
            return http.Response('{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}', 403);
          } else if (attempts == 2) {
            return http.Response('Too Many Requests', 429);
          } else if (attempts == 3) {
            return http.Response('{"error": {"errors": [{"reason": "userRateLimitExceeded"}]}}', 403);
          }
          return http.Response('{"id": "msg_success"}', 200);
        },
        getStatusCode: (r) => r.statusCode,
        getResponseBody: (r) => r.body,
      );

      expect(result.statusCode, equals(200));
      expect(attempts, equals(4));
      // Schedule: 1s, 2s, 4s
      expect(simulatedSleeps.length, equals(3));
      expect(simulatedSleeps[0].inSeconds, equals(1));
      expect(simulatedSleeps[1].inSeconds, equals(2));
      expect(simulatedSleeps[2].inSeconds, equals(4));
    });

    test('8. Non-rate-limit 403 (e.g. insufficientPermissions) does NOT trigger rate-limit backoff', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      int attempts = 0;
      final result = await limiter.executeWithRetry<http.Response>(
        op: GmailApiOp.messagesGetMetadata,
        accountEmail: 'perm@example.com',
        requestAction: () async {
          attempts++;
          return http.Response('{"error": {"errors": [{"reason": "insufficientPermissions"}]}}', 403);
        },
        getStatusCode: (r) => r.statusCode,
        getResponseBody: (r) => r.body,
      );

      expect(result.statusCode, equals(403));
      expect(attempts, equals(1), reason: 'Permanent permission error should not retry');
      expect(simulatedSleeps, isEmpty);
    });

    test('9. Requests resume automatically after quota becomes available', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // Exhaust 50 full fetches
      for (int i = 0; i < 50; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'resume@example.com');
      }

      expect(limiter.getCurrentFullFetches('resume@example.com'), equals(50));

      // 51st request waits and then automatically completes
      await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'resume@example.com');

      expect(simulatedSleeps.length, equals(1));
      expect(limiter.getCurrentFullFetches('resume@example.com'), equals(1));
    });

    test('10. Different connected Gmail accounts track quotas independently', () async {
      final limiter = GmailRateLimiter(
        nowFn: testNow,
        sleepFn: testSleep,
      );

      // Account A exhausts its 50 full email fetches
      for (int i = 0; i < 50; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'account_a@gmail.com');
      }

      expect(limiter.getCurrentFullFetches('account_a@gmail.com'), equals(50));
      expect(limiter.getCurrentFullFetches('account_b@gmail.com'), equals(0));

      // Account B can immediately make 50 full fetches without waiting
      for (int i = 0; i < 50; i++) {
        await limiter.acquire(op: GmailApiOp.messagesGetFull, accountEmail: 'account_b@gmail.com');
      }

      expect(limiter.getCurrentFullFetches('account_b@gmail.com'), equals(50));
      expect(simulatedSleeps, isEmpty, reason: 'Account B has independent quota');
    });
  });

  group('GmailApiService with RateLimiter Mock HTTP Integration', () {
    test('GmailApiService executes search, fetch, and download through rate limiter', () async {
      DateTime mockTime = DateTime(2026, 11, 11, 15, 0, 0);
      final sleeps = <Duration>[];

      final testLimiter = GmailRateLimiter(
        nowFn: () => mockTime,
        sleepFn: (d) async {
          sleeps.add(d);
          mockTime = mockTime.add(d);
        },
      );

      final mockClient = MockClient((request) async {
        final path = request.url.path;

        if (path.endsWith('/messages')) {
          return http.Response(jsonEncode({
            'messages': [
              {'id': 'msg_001'},
              {'id': 'msg_002'},
            ]
          }), 200);
        }

        if (path.contains('/attachments/')) {
          return http.Response(jsonEncode({
            'data': base64Url.encode(utf8.encode('PDF_BYTES')),
          }), 200);
        }

        if (path.contains('/messages/msg_001')) {
          return http.Response(jsonEncode({
            'id': 'msg_001',
            'threadId': 't1',
            'internalDate': '1794313800000',
            'payload': {
              'headers': [
                {'name': 'From', 'value': 'billing@netflix.com'},
                {'name': 'Subject', 'value': 'Your Netflix renewal'},
              ],
              'body': {'data': base64Url.encode(utf8.encode('Renewal ₹649'))},
            }
          }), 200);
        }

        return http.Response('Not Found', 404);
      });

      final apiService = GmailApiService(
        client: mockClient,
        rateLimiter: testLimiter,
      );

      // 1. messages.list (5 units)
      final ids = await apiService.searchFinancialMessageIds(
        accessToken: 'mock_token',
        accountEmail: 'user@test.com',
      );
      expect(ids, equals(['msg_001', 'msg_002']));
      expect(testLimiter.getCurrentQuotaUnits('user@test.com'), equals(5));

      // 2. messages.get with full format (60 units, 1 full fetch)
      final msg = await apiService.fetchMessageDetail(
        accessToken: 'mock_token',
        messageId: 'msg_001',
        accountEmail: 'user@test.com',
      );
      expect(msg, isNotNull);
      expect(msg!.id, equals('msg_001'));
      expect(testLimiter.getCurrentQuotaUnits('user@test.com'), equals(65));
      expect(testLimiter.getCurrentFullFetches('user@test.com'), equals(1));

      // 3. messages.attachments.get (20 units)
      final bytes = await apiService.downloadAttachmentBytes(
        accessToken: 'mock_token',
        messageId: 'msg_001',
        attachmentId: 'att_001',
        accountEmail: 'user@test.com',
      );
      expect(bytes, isNotNull);
      expect(testLimiter.getCurrentQuotaUnits('user@test.com'), equals(85));
      expect(testLimiter.getCurrentFullFetches('user@test.com'), equals(1));
    });
  });
}
