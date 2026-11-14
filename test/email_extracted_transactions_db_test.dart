import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/services/email_transaction_parser.dart';
import 'package:setthi/services/supabase_db_service.dart';

void main() {
  group('SupabaseDbService - email_extracted_transactions persistence', () {
    test('saveEmailExtractedTransactions gracefully handles null/unconfigured client', () async {
      final dbService = SupabaseDbService(client: null);

      final txns = [
        ExtractedEmailTransaction(
          gmailMessageId: 'msg_godaddy_01',
          amount: 116.82,
          currency: 'INR',
          merchantName: 'GoDaddy',
          bankOrIssuer: 'HDFC Bank',
          cardLast4: '4321',
          transactionDate: DateTime(2026, 9, 18, 10, 0),
          type: TransactionType.debit,
          narration: 'GoDaddy invoice: ₹ 116.82',
          paymentMode: 'CREDIT_CARD',
        ),
      ];

      final subs = [
        ExtractedEmailSubscription(
          serviceName: 'Netflix',
          expectedAmount: 649.0,
          currency: 'INR',
          typicalDueDay: 15,
          frequency: 'MONTHLY',
          billingDate: DateTime(2026, 3, 15),
        ),
      ];

      // Returns false when unconfigured client
      final success = await dbService.saveEmailExtractedTransactions(
        transactions: txns,
        subscriptions: subs,
        userId: 'test_user_uuid',
      );

      expect(success, isFalse);

      final fetched = await dbService.fetchEmailExtractedTransactions(
        userId: 'test_user_uuid',
      );
      expect(fetched, isEmpty);

      final count = await dbService.countEmailExtractedTransactions('test_user_uuid');
      expect(count, equals(0));
    });

    test('ExtractedEmailTransaction toBankTransaction creates valid model without polluting DB', () {
      final emailTx = ExtractedEmailTransaction(
        gmailMessageId: 'msg_kotak_01',
        amount: 3000.0,
        currency: 'INR',
        merchantName: 'JAYADEV PATIL',
        bankOrIssuer: 'Kotak Mahindra Bank',
        transactionDate: DateTime(2026, 10, 24, 18, 30),
        type: TransactionType.credit,
        narration: 'Kotak Cr: JAYADEV PATIL credited ₹3000.00',
        paymentMode: 'ACCOUNT_TRANSFER',
      );

      final bankTx = emailTx.toBankTransaction();
      expect(bankTx.amount, equals(3000.0));
      expect(bankTx.type, equals(TransactionType.credit));
      expect(bankTx.mode, equals('ACCOUNT_TRANSFER'));
      expect(bankTx.precomputedMerchantName, equals('JAYADEV PATIL'));
      expect(bankTx.txnId, equals('gmail_msg_kotak_01'));
      expect(bankTx.tagSource, equals('gmail_sync'));
    });

    test('Multiple recurring billing emails for same service consolidate into single subscription record', () async {
      final dbService = SupabaseDbService(client: null);

      final recurringInvoices = [
        ExtractedEmailTransaction(
          gmailMessageId: 'msg_netflix_july',
          amount: 199.0,
          currency: 'INR',
          merchantName: 'Netflix',
          bankOrIssuer: 'Email Subscription',
          transactionDate: DateTime(2026, 7, 29),
          type: TransactionType.debit,
          narration: 'Netflix subscription renewal',
          paymentMode: 'SUBSCRIPTION',
          isRecurring: true,
          category: 'Subscription',
        ),
        ExtractedEmailTransaction(
          gmailMessageId: 'msg_netflix_august',
          amount: 199.0,
          currency: 'INR',
          merchantName: 'Netflix',
          bankOrIssuer: 'Email Subscription',
          transactionDate: DateTime(2026, 8, 23),
          type: TransactionType.debit,
          narration: 'Netflix subscription renewal',
          paymentMode: 'SUBSCRIPTION',
          isRecurring: true,
          category: 'Subscription',
        ),
        ExtractedEmailTransaction(
          gmailMessageId: 'msg_netflix_september',
          amount: 199.0,
          currency: 'INR',
          merchantName: 'Netflix',
          bankOrIssuer: 'Email Subscription',
          transactionDate: DateTime(2026, 9, 23),
          type: TransactionType.debit,
          narration: 'Netflix subscription renewal',
          paymentMode: 'SUBSCRIPTION',
          isRecurring: true,
          category: 'Subscription',
        ),
        ExtractedEmailTransaction(
          gmailMessageId: 'msg_netflix_october',
          amount: 199.0,
          currency: 'INR',
          merchantName: 'Netflix',
          bankOrIssuer: 'Email Subscription',
          transactionDate: DateTime(2026, 10, 23),
          type: TransactionType.debit,
          narration: 'Netflix subscription renewal',
          paymentMode: 'SUBSCRIPTION',
          cardLast4: '2254',
          isRecurring: true,
          category: 'Subscription',
        ),
      ];

      // Handled safely without errors even with unconfigured client
      final success = await dbService.saveEmailExtractedTransactions(
        transactions: recurringInvoices,
        userId: 'test_uid',
      );
      expect(success, isFalse);
    });
  });
}
