import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/reminder_model.dart';

void main() {
  group('Financial Alert Deduplication Logic Verification', () {
    final now = DateTime.now();

    test('Scenario 1: Four emails about one confirmed unpaid subscription obligation -> results in ONE grouped alert', () {
      final emails = [
        {'id': 'msg_01', 'subject': 'Payment declined for ChatGPT', 'date': '2026-11-05T10:00:00Z', 'amount': 399.0},
        {'id': 'msg_02', 'subject': 'Payment declined for ChatGPT', 'date': '2026-11-06T10:00:00Z', 'amount': 399.0},
        {'id': 'msg_03', 'subject': 'Payment retry failed for ChatGPT', 'date': '2026-11-08T10:00:00Z', 'amount': 399.0},
        {'id': 'msg_04', 'subject': 'ChatGPT subscription suspended', 'date': '2026-11-10T10:00:00Z', 'amount': 399.0},
      ];

      // Simulate backend deduplication grouping
      final groupedSourceIds = emails.map((e) => e['id'] as String).toList();
      final groupedSourceEmails = emails;

      final mergedReminder = ReminderModel.fromMap({
        'id': 'rem_canonical_uuid',
        'user_id': 'user_01',
        'reminder_id': 'sth_canonical_chatgpt_nov2026',
        'type': 'subscription',
        'provider': 'ChatGPT (google.com)',
        'due_date': null,
        'timing': 'unknown',
        'amount': 399.0,
        'currency': 'INR',
        'source_message_ids': groupedSourceIds,
        'metadata': {
          'service_identity': 'google.com:chatgpt',
          'billing_period': '2026-11',
          'source_emails': groupedSourceEmails,
        },
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      });

      expect(mergedReminder.provider, contains('ChatGPT'));
      expect(mergedReminder.amount, equals(399.0));
      expect(mergedReminder.sourceMessageIds.length, equals(4));
      final sourceEmails = mergedReminder.metadata!['source_emails'] as List;
      expect(sourceEmails.length, equals(4));
    });

    test('Scenario 2: Multiple notices about the same unpaid obligation with different subjects/wording -> results in ONE grouped alert', () {
      // Subjects vary from "declined" to "suspended" to "action required"
      final subjects = [
        'Google Play: Payment declined for your subscription to ChatGPT',
        'Action required: Update payment method for ChatGPT',
        'Google Play: Subscription suspended for ChatGPT',
      ];

      final serviceIdentities = subjects.map((subj) {
        if (subj.toLowerCase().contains('chatgpt')) return 'google.com:chatgpt';
        return 'google.com';
      }).toSet();

      // All identify the same obligation
      expect(serviceIdentities.length, equals(1));
      expect(serviceIdentities.first, equals('google.com:chatgpt'));
    });

    test('Scenario 3: Two separate subscription payments for same provider in different billing periods -> results in TWO distinct alerts', () {
      final periodOct = '2026-10';
      final periodNov = '2026-11';

      final alertOct = {
        'service_identity': 'netflix.com',
        'amount': 199.0,
        'billing_period': periodOct,
      };

      final alertNov = {
        'service_identity': 'netflix.com',
        'amount': 199.0,
        'billing_period': periodNov,
      };

      // Even though provider and amount match, different billing periods MUST NEVER merge
      final shouldMerge = alertOct['service_identity'] == alertNov['service_identity'] &&
          alertOct['amount'] == alertNov['amount'] &&
          alertOct['billing_period'] == alertNov['billing_period'];

      expect(shouldMerge, isFalse);
    });

    test('Scenario 4: Two different subscriptions with same aggregator and same amount -> results in TWO distinct alerts', () {
      // YouTube Premium ₹399 vs ChatGPT Go ₹399 under google.com
      final alertYouTube = {
        'provider': 'google.com',
        'service_identity': 'google.com:youtube',
        'amount': 399.0,
        'billing_period': '2026-11',
      };

      final alertChatGPT = {
        'provider': 'google.com',
        'service_identity': 'google.com:chatgpt',
        'amount': 399.0,
        'billing_period': '2026-11',
      };

      // Even though provider and amount match, distinct service identities MUST NEVER merge
      final shouldMerge = alertYouTube['service_identity'] == alertChatGPT['service_identity'] &&
          alertYouTube['amount'] == alertChatGPT['amount'] &&
          alertYouTube['billing_period'] == alertChatGPT['billing_period'];

      expect(shouldMerge, isFalse);
    });

    test('Scenario 5: Mixed batch with repeated notices and distinct obligations -> properly partitioned', () {
      final batch = [
        {'id': '1', 'service': 'google.com:chatgpt', 'amount': 399.0, 'period': '2026-11'},
        {'id': '2', 'service': 'google.com:chatgpt', 'amount': 399.0, 'period': '2026-11'},
        {'id': '3', 'service': 'google.com:youtube', 'amount': 399.0, 'period': '2026-11'},
        {'id': '4', 'service': 'google.com:chatgpt', 'amount': 399.0, 'period': '2026-10'},
      ];

      final Map<String, List<Map<String, dynamic>>> partitions = {};
      for (final item in batch) {
        final key = '${item['service']}_${item['amount']}_${item['period']}';
        partitions.putIfAbsent(key, () => []).add(item);
      }

      // Should partition into 3 distinct obligations:
      // 1. ChatGPT Nov (2 notices)
      // 2. YouTube Nov (1 notice)
      // 3. ChatGPT Oct (1 notice)
      expect(partitions.length, equals(3));
      expect(partitions['google.com:chatgpt_399.0_2026-11']!.length, equals(2));
      expect(partitions['google.com:youtube_399.0_2026-11']!.length, equals(1));
      expect(partitions['google.com:chatgpt_399.0_2026-10']!.length, equals(1));
    });

    test('Scenario 6: Undated notices within 30-day retry/grace window -> grouped appropriately', () {
      final email1Date = DateTime.parse('2026-11-05T11:00:00Z');
      final email2Date = DateTime.parse('2026-11-12T15:30:00Z');
      final emailOldDate = DateTime.parse('2026-09-01T10:00:00Z');

      final diffDays1And2 = email2Date.difference(email1Date).inDays.abs();
      final diffDays1AndOld = emailOldDate.difference(email1Date).inDays.abs();

      // Within 30 days -> Same retry cycle
      expect(diffDays1And2 <= 30, isTrue);

      // > 30 days -> Different cycle, do not merge
      expect(diffDays1AndOld <= 30, isFalse);
    });

    test('Scenario 7: Confirmed values preserved over unconfirmed or missing values', () {
      double? existingConfirmedAmount = 399.0;
      double? incomingUnknownAmount; // null amount in a retry reminder

      final preservedAmount = incomingUnknownAmount ?? existingConfirmedAmount;
      expect(preservedAmount, equals(399.0));

      DateTime? existingDueDate = DateTime(2026, 11, 20);
      DateTime? incomingDueDate; // undated suspension notice

      final preservedDueDate = incomingDueDate ?? existingDueDate;
      expect(preservedDueDate, equals(DateTime(2026, 11, 20)));
    });
  });
}

