import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:setthi/models/reminder_model.dart';
import 'package:setthi/providers/gmail_sync_provider.dart';
import 'package:setthi/providers/supabase_provider.dart';
import 'package:setthi/services/gmail_api_service.dart';
import 'package:setthi/services/supabase_db_service.dart';

class FakeGmailApiService extends GmailApiService {
  @override
  Future<List<String>> searchFinancialMessageIds({
    required String accessToken,
    DateTime? afterDate,
    int maxMessages = 150,
    bool unfiltered = true,
    String? customQuery,
    String? accountEmail,
  }) async {
    return ['e2e_msg_trial_01', 'e2e_msg_sub_02'];
  }

  @override
  Future<List<GmailRawMessage>> fetchMessagesInBatches({
    required String accessToken,
    required List<String> messageIds,
    String? accountEmail,
    int batchSize = 10,
    void Function(int fetched, int total)? onProgress,
  }) async {
    return [
      GmailRawMessage(
        id: 'e2e_msg_trial_01',
        threadId: 'th_01',
        from: 'billing@service.example',
        subject: 'Your free trial expires on 17 November 2026',
        date: DateTime(2026, 11, 5, 10, 0),
        bodyText: 'Your free trial expires on 17 November 2026. After trial you will be charged ₹999.',
        internalDateEpochMs: DateTime(2026, 11, 5).millisecondsSinceEpoch,
      ),
      GmailRawMessage(
        id: 'e2e_msg_sub_02',
        threadId: 'th_02',
        from: 'alerts@bank.example',
        subject: 'Credit card statement ready',
        date: DateTime(2026, 11, 5, 11, 0),
        bodyText: 'Your statement is ready. Total due ₹6,780.00. Due date: 20 Nov 2026.',
        internalDateEpochMs: DateTime(2026, 11, 5).millisecondsSinceEpoch,
      ),
    ];
  }
}

class MockSupabaseDbService extends SupabaseDbService {
  final List<ReminderModel> inMemoryDb = [];

  MockSupabaseDbService() : super(client: null);

  @override
  Future<Map<String, dynamic>> classifyEmailsViaBackend({
    required List<Map<String, dynamic>> messages,
    String? timezone,
    bool includeDecisions = false,
  }) async {
    // Simulates the Modal ML pipeline return
    final alerts = messages.map((m) {
      final isTrial = m['subject'].toString().contains('trial');
      return {
        'message_id': m['id'],
        'reminder_id': isTrial ? 'sth_e2e_trial_123' : 'sth_e2e_stmt_456',
        'type': isTrial ? 'trial_ending' : 'credit_card_statement',
        'provider': isTrial ? 'service.example' : 'bank.example',
        'date': isTrial ? '2026-11-17' : '2026-11-20',
        'timing': 'upcoming',
        'amount': isTrial ? 999.0 : 6780.0,
        'currency': 'INR',
        'amount_source': 'gliner2.5',
        'review': false,
        'reminder_eligible': true,
        'source_message_ids': [m['id']],
      };
    }).toList();

    for (final a in alerts) {
      inMemoryDb.add(ReminderModel.fromMap({
        'id': 'uuid_${a['reminder_id']}',
        'user_id': 'test_user_uuid',
        ...a,
        'due_date': a['date'],
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      }));
    }

    return {
      'success': true,
      'saved_count': alerts.length,
      'alerts': alerts,
      'summary': {'processed': messages.length, 'alerts': alerts.length},
    };
  }

  @override
  Future<List<ReminderModel>> fetchReminders({
    String? userId,
    bool includeDismissed = false,
  }) async {
    if (includeDismissed) return inMemoryDb;
    return inMemoryDb.where((r) => !r.isDismissed).toList();
  }

  @override
  Future<bool> dismissReminder(String reminderId, {bool isDismissed = true}) async {
    final idx = inMemoryDb.indexWhere((r) => r.reminderId == reminderId);
    if (idx != -1) {
      inMemoryDb[idx] = inMemoryDb[idx].copyWith(isDismissed: isDismissed);
      return true;
    }
    return false;
  }

  @override
  Future<bool> toggleReminderActioned(String reminderId, {required bool isActioned}) async {
    final idx = inMemoryDb.indexWhere((r) => r.reminderId == reminderId);
    if (idx != -1) {
      inMemoryDb[idx] = inMemoryDb[idx].copyWith(isActioned: isActioned);
      return true;
    }
    return false;
  }
}

void main() {
  group('Phase 5: End-to-End Reminders Sync and Resilience Test', () {
    test('Simulates background email batch dispatch and server-side persistence', () async {
      final mockDb = MockSupabaseDbService();
      final mockGmail = FakeGmailApiService();

      final container = ProviderContainer(
        overrides: [
          supabaseDbServiceProvider.overrideWithValue(mockDb),
          gmailApiServiceProvider.overrideWithValue(mockGmail),
        ],
      );

      // 1. Verify initial empty state
      final initialReminders = await mockDb.fetchReminders(userId: 'test_user_uuid');
      expect(initialReminders, isEmpty);

      // 2. Simulate message fetching and dispatching to backend
      final messages = await mockGmail.fetchMessagesInBatches(
        accessToken: 'mock_token',
        messageIds: ['e2e_msg_trial_01', 'e2e_msg_sub_02'],
      );

      final payload = messages.map((m) => {
        'id': m.id,
        'subject': m.subject,
        'from': m.from,
        'date': m.date.toIso8601String(),
        'body': m.bodyText,
      }).toList();

      final result = await mockDb.classifyEmailsViaBackend(messages: payload);
      expect(result['success'], isTrue);
      expect(result['saved_count'], equals(2));

      // 3. Verify server-side persistence: reminders are now in Postgres
      final persistedReminders = await mockDb.fetchReminders(userId: 'test_user_uuid');
      expect(persistedReminders.length, equals(2));

      final trial = persistedReminders.firstWhere((r) => r.type == ReminderType.trialEnding);
      expect(trial.provider, equals('service.example'));
      expect(trial.amount, equals(999.0));
      expect(trial.formattedAmount, equals('₹999.00'));
      expect(trial.dueDate?.month, equals(11));
      expect(trial.dueDate?.day, equals(17));

      final stmt = persistedReminders.firstWhere((r) => r.type == ReminderType.creditCardStatement);
      expect(stmt.provider, equals('bank.example'));
      expect(stmt.amount, equals(6780.0));
      expect(stmt.formattedAmount, equals('₹6780.00'));

      // 4. Test Background Persistence Resilience (Simulating App Restart / New Instance)
      // Even if app was closed, a fresh provider or fresh screen reads the saved reminders directly from Supabase
      final freshContainer = ProviderContainer(
        overrides: [
          supabaseDbServiceProvider.overrideWithValue(mockDb),
        ],
      );
      final refreshedReminders = await mockDb.fetchReminders(userId: 'test_user_uuid');
      expect(refreshedReminders.length, equals(2));

      // 5. Test user action: Dismissing a reminder
      final dismissSuccess = await mockDb.dismissReminder(trial.reminderId);
      expect(dismissSuccess, isTrue);

      final activeReminders = await mockDb.fetchReminders(userId: 'test_user_uuid', includeDismissed: false);
      expect(activeReminders.length, equals(1));
      expect(activeReminders.first.type, equals(ReminderType.creditCardStatement));

      // 6. Test user action: Marking as Done
      final actionSuccess = await mockDb.toggleReminderActioned(stmt.reminderId, isActioned: true);
      expect(actionSuccess, isTrue);

      final updatedStmt = (await mockDb.fetchReminders(userId: 'test_user_uuid', includeDismissed: true))
          .firstWhere((r) => r.reminderId == stmt.reminderId);
      expect(updatedStmt.isActioned, isTrue);

      container.dispose();
      freshContainer.dispose();
    });
  });
}

