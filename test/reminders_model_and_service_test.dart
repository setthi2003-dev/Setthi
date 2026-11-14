import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/reminder_model.dart';
import 'package:setthi/services/supabase_db_service.dart';

void main() {
  group('ReminderModel unit tests', () {
    test('Correctly deserializes from Supabase row map', () {
      final now = DateTime.now();
      final targetDue = now.add(const Duration(days: 9));

      final map = {
        'id': 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
        'user_id': 'user_test_uuid_123',
        'reminder_id': 'sth_87ffb03e6005089102ddd08e',
        'type': 'credit_card_statement',
        'provider': 'HDFC Bank',
        'due_date': targetDue.toIso8601String().split('T').first,
        'timing': 'upcoming',
        'amount': 6780.0,
        'currency': 'INR',
        'amount_source': 'gliner2.5',
        'amount_evidence': {
          'text': 'Total amount due ₹6,780.00',
          'confidence': 0.94,
          'model_label': 'total_amount',
        },
        'review': false,
        'reminder_eligible': true,
        'source_message_ids': ['msg_gmail_01', 'msg_gmail_02'],
        'is_dismissed': false,
        'is_actioned': false,
        'created_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      final reminder = ReminderModel.fromMap(map);

      expect(reminder.id, equals('a1b2c3d4-e5f6-7890-abcd-ef1234567890'));
      expect(reminder.reminderId, equals('sth_87ffb03e6005089102ddd08e'));
      expect(reminder.type, equals(ReminderType.creditCardStatement));
      expect(reminder.provider, equals('HDFC Bank'));
      expect(reminder.amount, equals(6780.0));
      expect(reminder.formattedAmount, equals('₹6780.00'));
      expect(reminder.timing, equals(ReminderTiming.upcoming));
      expect(reminder.review, isFalse);
      expect(reminder.reminderEligible, isTrue);
      expect(reminder.sourceMessageIds.length, equals(2));
      expect(reminder.daysRemaining, inInclusiveRange(8, 10));
      expect(reminder.countdownText, contains('days'));
    });

    test('Correctly formats trial ending and subscription types', () {
      final trialReminder = ReminderModel(
        id: 'trial_1',
        userId: 'u1',
        reminderId: 'sth_trial_123',
        type: ReminderType.trialEnding,
        provider: 'Claude Pro',
        amount: 1999.0,
        currency: 'INR',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(trialReminder.type.label, equals('Trial Ending'));
      expect(trialReminder.formattedAmount, equals('₹1999.00'));

      final subReminder = ReminderModel(
        id: 'sub_1',
        userId: 'u1',
        reminderId: 'sth_sub_123',
        type: ReminderType.subscription,
        provider: 'Spotify Premium',
        amount: 119.0,
        currency: 'INR',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      expect(subReminder.type.label, equals('Subscription'));
      expect(subReminder.formattedAmount, equals('₹119.00'));
    });

    test('Gracefully handles null client in SupabaseDbService reminder methods', () async {
      final dbService = SupabaseDbService(client: null);

      final reminders = await dbService.fetchReminders(userId: 'test_user');
      expect(reminders, isEmpty);

      final dismissRes = await dbService.dismissReminder('sth_123');
      expect(dismissRes, isFalse);

      final actionRes = await dbService.toggleReminderActioned('sth_123', isActioned: true);
      expect(actionRes, isFalse);
    });
  });
}

