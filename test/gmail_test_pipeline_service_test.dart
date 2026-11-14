import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/services/email_transaction_parser.dart';
import 'package:setthi/services/gmail_api_service.dart';
import 'package:setthi/services/gmail_test_pipeline_service.dart';

class MockGmailApiService extends GmailApiService {
  @override
  Future<List<String>> searchFinancialMessageIds({
    required String accessToken,
    DateTime? afterDate,
    int maxMessages = 150,
    bool unfiltered = true,
    String? customQuery,
    String? accountEmail,
  }) async {
    return ['msg_hdfc_01', 'msg_netflix_02', 'msg_otp_03'];
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
        id: 'msg_hdfc_01',
        threadId: 't1',
        from: 'alerts@hdfcbank.net',
        subject: 'Alert: Transaction on your HDFC Bank Credit Card',
        date: DateTime(2026, 3, 10, 14, 30),
        bodyText: 'Dear Customer, INR 1,499.00 has been debited on card ending 4321 at ZOMATO.',
        internalDateEpochMs: DateTime(2026, 3, 10, 14, 30).millisecondsSinceEpoch,
      ),
      GmailRawMessage(
        id: 'msg_netflix_02',
        threadId: 't2',
        from: 'info@mailer.netflix.com',
        subject: 'Your Netflix membership will renew soon',
        date: DateTime(2026, 3, 11, 10, 0),
        bodyText: 'Your monthly Netflix subscription of ₹649 will renew on March 15, 2026. Payment successful.',
        internalDateEpochMs: DateTime(2026, 3, 11, 10, 0).millisecondsSinceEpoch,
      ),
      GmailRawMessage(
        id: 'msg_otp_03',
        threadId: 't3',
        from: 'security@bank.com',
        subject: 'Your One Time Password (OTP) is 849201',
        date: DateTime(2026, 3, 11, 12, 0),
        bodyText: 'Do not share your OTP 849201 with anyone.',
        internalDateEpochMs: DateTime(2026, 3, 11, 12, 0).millisecondsSinceEpoch,
      ),
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DetailedEmailParseResult diagnostics', () {
    final parser = EmailTransactionParser();

    test('classifies credit card transaction with detailed metadata', () {
      final msg = GmailRawMessage(
        id: '1',
        threadId: '1',
        from: 'alerts@hdfcbank.net',
        subject: 'Transaction alert',
        date: DateTime(2026, 3, 10),
        bodyText: 'INR 2,500.00 spent on HDFC Bank Credit Card ending 9876 at AMAZON INDIA',
        internalDateEpochMs: DateTime(2026, 3, 10).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(msg);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.amount, 2500.0);
      expect(diag.detectedIssuer, 'HDFC Bank');
      expect(diag.detectedCardLast4, '9876');
      expect(diag.detectedMerchant, 'AMAZON INDIA');
      expect(diag.transaction!.type, TransactionType.debit);
    });

    test('classifies subscription renewal with detailed metadata', () {
      final msg = GmailRawMessage(
        id: '2',
        threadId: '2',
        from: 'billing@spotify.com',
        subject: 'Spotify Premium Invoice',
        date: DateTime(2026, 3, 11),
        bodyText: 'Payment successful. Your monthly recurring subscription of ₹119 has been renewed.',
        internalDateEpochMs: DateTime(2026, 3, 11).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(msg);
      expect(diag.isNoise, isFalse);
      expect(diag.isSubscriptionSignal, isTrue);
      expect(diag.subscription, isNotNull);
      expect(diag.subscription!.serviceName, 'Spotify');
      expect(diag.subscription!.expectedAmount, 119.0);
      expect(diag.subscription!.frequency, 'MONTHLY');
    });

    test('classifies noise email with explicit noiseReason', () {
      final msg = GmailRawMessage(
        id: '3',
        threadId: '3',
        from: 'alerts@bank.com',
        subject: 'Your OTP is 492019',
        date: DateTime(2026, 3, 11),
        bodyText: 'Use OTP 492019 to complete your login. Do not share.',
        internalDateEpochMs: DateTime(2026, 3, 11).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(msg);
      expect(diag.isNoise, isTrue);
      expect(diag.noiseReason, contains('OTP'));
      expect(diag.transaction, isNull);
      expect(diag.subscription, isNull);
    });

    test('discards Sitepeel trial email as noise without flagging transaction', () {
      final msg = GmailRawMessage(
        id: '1a12e8370b0201ad',
        threadId: 't_sitepeel',
        from: 'Sitepeel <hello@notify.sitepeel.dev>',
        subject: 'Your 24-hour Sitepeel trial has started',
        date: DateTime(2026, 10, 12, 10, 38, 46),
        bodyText: 'Take a closer look. Your trial is ready. Use all 12 Sitepeel tools until 2026-10-13 05:08 UTC. No card was needed, and you won’t be charged automatically. Lifetime access is ₹499 if you decide to keep...',
        internalDateEpochMs: DateTime(2026, 10, 12, 10, 38, 46).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(msg);
      expect(diag.isNoise, isTrue);
      expect(diag.noiseReason, contains('Free Trial'));
      expect(diag.transaction, isNull);
      expect(diag.subscription, isNull);
    });

    test('accurately classifies GoDaddy order confirmation as DEBIT with merchant GoDaddy and NO subscription', () {
      final msg = GmailRawMessage(
        id: '1a0b365d0ab28e6b',
        threadId: 't_godaddy',
        from: 'GoDaddy <donotreply@godaddy.com>',
        subject: 'Setthi, your order confirmation is inside.',
        date: DateTime(2026, 9, 18, 12, 53, 04),
        bodyText: '''
Thanks for buying a domain with GoDaddy.
Order Number: 4186759752
.IN Domain Registration ₹ 99.00
setthi.in
1 Year
Auto-renews on 18-09-2027 for ₹ 899.00*
VALUE ADDED TAX ID: EU826010755
Subtotal: ₹ 99.00
IGST: ₹ 17.82
Total: ₹ 116.82
''',
        internalDateEpochMs: DateTime(2026, 9, 18, 12, 53, 04).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(msg);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.merchantName, 'GoDaddy');
      expect(diag.transaction!.amount, 116.82);
      expect(diag.transaction!.type, TransactionType.debit);
      // Ensure it is NOT a monthly subscription
      expect(diag.subscription, isNull);
    });
  });

  group('GmailTestPipelineService executeTestRun', () {
    test('runs dry-run pipeline, outputs detailed log, and returns report', () async {
      final mockApi = MockGmailApiService();
      final parser = EmailTransactionParser();
      final service = GmailTestPipelineService(apiService: mockApi, parser: parser);

      final report = await service.executeTestRun(
        accessToken: 'fake_token',
        maxEmails: 10,
      );

      expect(report.totalFound, 3);
      expect(report.totalFetched, 3);
      expect(report.transactionCount, 2);
      expect(report.subscriptionCount, 1);
      expect(report.noiseCount, 1);

      // Verify transactions
      expect(report.transactions.first.merchantName, 'ZOMATO');
      expect(report.transactions.first.amount, 1499.0);
      expect(report.transactions.first.cardLast4, '4321');

      // Verify subscriptions
      expect(report.subscriptions.first.serviceName, 'Netflix');
      expect(report.subscriptions.first.expectedAmount, 649.0);

      // Verify formatted log contains key headers
      expect(report.formattedLog, contains('SETTHI ON-DEVICE GMAIL SYNC - TEST RUN AUDIT REPORT'));
      expect(report.formattedLog, contains('FLAGGED TRANSACTIONS (2)'));
      expect(report.formattedLog, contains('Mode      : CREDIT_CARD'));
      expect(report.formattedLog, contains('FLAGGED SUBSCRIPTIONS & RECURRING BILLS (1)'));
      expect(report.formattedLog, contains('GRANULAR AUDIT PER EMAIL (3 emails examined)'));
      expect(report.formattedLog, contains('No database records written'));
    });

    test('saveRealSyncJsonData serializes unmodified API data and categorization diagnostics', () async {
      final parser = EmailTransactionParser();
      final messages = [
        GmailRawMessage(
          id: 'msg_test_01',
          threadId: 'th_01',
          from: 'ebill@airtel.com',
          subject: 'Bill for your Airtel Mobile 98451XXXXX - October 26',
          date: DateTime(2026, 10, 24, 18, 30),
          bodyText: 'Your Airtel mobile bill of Rs 513.53 is generated. Due date: 10-Nov-2026',
          internalDateEpochMs: 1729794600000,
          attachments: [
            const GmailAttachmentInfo(
              attachmentId: 'att_01',
              filename: '1388227983_96.pdf',
              mimeType: 'application/pdf',
              size: 45000,
            ),
          ],
          rawApiData: {
            'id': 'msg_test_01',
            'threadId': 'th_01',
            'snippet': 'Your Airtel mobile bill of Rs 513.53 is generated...',
            'payload': {
              'mimeType': 'multipart/mixed',
              'headers': [
                {'name': 'From', 'value': 'ebill@airtel.com'},
                {'name': 'Subject', 'value': 'Bill for your Airtel Mobile 98451XXXXX - October 26'},
              ],
            },
          },
        ),
      ];

      final savedPath = await GmailTestPipelineService.saveRealSyncJsonData(
        messages: messages,
        parser: parser,
        userEmail: 'setthi2003@gmail.com',
        writeToWorkspaceLogs: false,
      );

      expect(savedPath, isNotNull);
    });
  });
}
