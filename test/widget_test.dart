import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:setthi/config/setu_config.dart';
import 'package:setthi/config/supabase_config.dart';
import 'package:setthi/main.dart';
import 'package:setthi/screens/verify_email_screen.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/providers/auth_providers.dart';
import 'package:setthi/providers/transaction_providers.dart';
import 'package:setthi/services/fi_data_service.dart';
import 'package:setthi/services/setu_aa_service.dart';
import 'package:setthi/widgets/dpc_floating_dock.dart';

class _FakeTestRepository implements TransactionRepository {
  final List<BankTransaction> _txns;
  _FakeTestRepository(this._txns);

  @override
  Future<List<BankTransaction>> fetchTransactions() async => _txns;
}

void main() {
  group('SetuConfig & SupabaseConfig tests', () {
    test('Reads default sandbox configuration', () {
      expect(SetuConfig.baseUrl, isNotEmpty);
      expect(SetuConfig.authHeaders.containsKey('x-client-id'), isTrue);
      expect(SetuConfig.authHeaders.containsKey('x-client-secret'), isTrue);
      expect(SetuConfig.authHeaders.containsKey('x-product-instance-id'), isTrue);
      expect(SetuConfig.redirectUrl, isNotEmpty);
    });

    test('SupabaseConfig correctly parses environment variables from secrets.json', () {
      expect(SupabaseConfig.url, contains('supabase.co'));
      expect(SupabaseConfig.publishableKey, isNotEmpty);
      expect(SupabaseConfig.isConfigured, isTrue);
    });
  });

  group('BankTransaction model & ReBIT parsing tests', () {
    test('Cleans merchant names from Indian UPI narrations accurately', () {
      final swiggyTxn = BankTransaction(
        txnId: 'TXN-1',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 289.00,
        currentBalance: 12000.00,
        transactionTimestamp: DateTime.now(),
        narration: 'UPI/428192019482/Swiggy/swiggy@icici/Order_Food',
      );
      expect(swiggyTxn.cleanMerchantName, 'Swiggy');

      final blinkitTxn = BankTransaction(
        txnId: 'TXN-2',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 450.00,
        currentBalance: 11550.00,
        transactionTimestamp: DateTime.now(),
        narration: 'UPI/429591829301/Blinkit/blinkit.orders@kotak/LateNight_Snacks',
      );
      expect(blinkitTxn.cleanMerchantName, 'Blinkit');
    });

    test('Formats currency in Indian Rupee format properly', () {
      expect(BankTransaction.formatRupees(289), '₹289');
      expect(BankTransaction.formatRupees(1250), '₹1,250');
      expect(BankTransaction.formatRupees(65000), '₹65,000');
      expect(BankTransaction.formatRupees(18450.50), '₹18,450.50');
    });

    test('SetuAaService parses ReBIT deposit payload accurately', () {
      final mockPayload = {
        'payload': [
          {
            'data': [
              {
                'decrypted': {
                  'account': {
                    'transactions': {
                      'transaction': [
                        {
                          'txnId': 'REBIT-101',
                          'type': 'DEBIT',
                          'mode': 'UPI',
                          'amount': 350.0,
                          'currentBalance': 15000.0,
                          'transactionTimestamp': '2024-05-10T14:30:00Z',
                          'narration': 'UPI/492019284/Zepto/zepto@icici/Groceries',
                        },
                        {
                          'txnId': 'REBIT-102',
                          'type': 'CREDIT',
                          'mode': 'FT',
                          'amount': 50000.0,
                          'currentBalance': 15350.0,
                          'transactionTimestamp': '2024-05-11T10:00:00Z',
                          'narration': 'FT/SAL/Salary_Credit/Employer',
                        },
                      ]
                    }
                  }
                }
              }
            ]
          }
        ]
      };

      final transactions = SetuAaService.parseRebitPayload(mockPayload);
      expect(transactions.length, 2);
      expect(transactions.first.txnId, 'REBIT-102');
      expect(transactions.first.cleanMerchantName, 'Salary / Stipend');
      expect(transactions.last.cleanMerchantName, 'Zepto');
    });

    test('SetuAaService parses PascalCase and String amount ReBIT payloads with Summary fallback', () {
      final pascalPayload = {
        'fips': [
          {
            'fipId': 'SETU-FIP-2',
            'data': [
              {
                'decrypted': {
                  'Account': {
                    'Summary': {
                      'currentBalance': '25000.50',
                      'currency': 'INR',
                    },
                    'Transactions': {
                      'Transaction': [
                        {
                          'TxnId': 'REBIT-201',
                          'Type': 'DEBIT',
                          'Mode': 'UPI',
                          'Amount': '450.75',
                          'CurrentBalance': '24549.75',
                          'TransactionTimestamp': '2021-06-15T12:00:00Z',
                          'Narration': 'UPI/492019284/Swiggy/swiggy@icici/Food',
                        },
                        {
                          'TxnId': 'REBIT-202',
                          'Type': 'DEBIT',
                          'Mode': 'UPI',
                          'Amount': '120.00',
                          // Notice: No CurrentBalance, should fallback to Summary balance
                          'TransactionTimestamp': '2021-06-16T09:30:00Z',
                          'Narration': 'UPI/999182/Blinkit/blinkit@kotak/Snacks',
                        },
                      ]
                    }
                  }
                }
              }
            ]
          }
        ]
      };

      final txns = SetuAaService.parseRebitPayload(pascalPayload);
      expect(txns.length, 2);
      expect(txns.first.txnId, 'REBIT-202');
      expect(txns.first.cleanMerchantName, 'Blinkit');
      expect(txns.first.amount, 120.00);
      expect(txns.first.currentBalance, 25000.50); // Fallback used!

      expect(txns.last.txnId, 'REBIT-201');
      expect(txns.last.cleanMerchantName, 'Swiggy');
      expect(txns.last.amount, 450.75);
      expect(txns.last.currentBalance, 24549.75);
    });

    test('SetuAaService parses Setu AA V2 fips accounts payload structure', () {
      final setuV2Payload = {
        'fips': [
          {
            'fipID': 'setu-fip-2',
            'accounts': [
              {
                'FIstatus': 'READY',
                'maskedAccNumber': 'XXXXXXXX8167',
                'linkRefNumber': '927dfeb5-aae8-4b32-94e6-b145a6ebe3ea',
                'data': {
                  'account': {
                    'summary': {
                      'currentBalance': 251030.30,
                      'currency': 'INR',
                      'status': 'ACTIVE',
                    },
                    'transactions': {
                      'transaction': [
                        {
                          'amount': '30380.99',
                          'currentBalance': '275382.88',
                          'mode': 'ATM',
                          'narration': 'ATM/CR/318935631358/Saksham Suri/LGDN/Salary',
                          'transactionTimestamp': '2021-10-03T11:24:30+00:00',
                          'txnId': 'KANK35681326491510',
                          'type': 'CREDIT',
                        },
                        {
                          'amount': '150.00',
                          'currentBalance': '275232.88',
                          'mode': 'UPI',
                          'narration': 'UPI/492819/Swiggy/swiggy@icici/Food',
                          'transactionTimestamp': '2021-10-04T12:00:00+00:00',
                          'txnId': 'SWIGGY12345',
                          'type': 'DEBIT',
                        }
                      ]
                    }
                  }
                }
              }
            ]
          }
        ]
      };

      final txns = SetuAaService.parseRebitPayload(setuV2Payload);
      expect(txns.length, 2);
      expect(txns.first.txnId, 'SWIGGY12345');
      expect(txns.first.cleanMerchantName, 'Swiggy');
      expect(txns.first.amount, 150.00);

      expect(txns.last.txnId, 'KANK35681326491510');
      expect(txns.last.cleanMerchantName, 'Salary / Stipend');
      expect(txns.last.amount, 30380.99);
      expect(txns.last.currentBalance, 275382.88);
    });
  });

  group('SetuAaService consent creation with MockClient', () {
    test('Calls /v2/consents with correct headers and payload', () async {
      final mockClient = MockClient((request) async {
        expect(request.url.path, '/v2/consents');
        expect(request.headers['x-client-id'], isNotNull);
        expect(request.headers['x-product-instance-id'], isNotNull);

        final decoded = jsonDecode(request.body) as Map<String, dynamic>;
        expect(decoded['vua'], '9999999999@onemoney');
        expect(decoded['redirectUrl'], isNotNull);

        return http.Response(
          jsonEncode({
            'id': 'consent-mock-1234',
            'url': 'https://fiu-uat.setu.co/v2/consents/ui/consent-mock-1234',
            'status': 'PENDING',
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      });

      final service = SetuAaService(client: mockClient);
      final res = await service.createConsent(mobileNumber: '9999999999');
      expect(res['consentId'], 'consent-mock-1234');
      expect(res['url'], 'https://fiu-uat.setu.co/v2/consents/ui/consent-mock-1234');
    });
  });

  group('Riverpod Providers tests', () {
    setUp(() {
      ActiveConsentIdNotifier.enablePersistence = false;
      ActiveConsentIdNotifier.deletePersistedConsent();
    });

    tearDown(() {
      ActiveConsentIdNotifier.deletePersistedConsent();
      ActiveConsentIdNotifier.enablePersistence = true;
    });

    test('ProviderContainer resolves transaction feed, consent status and derived providers', () async {
      final sampleTxns = [
        BankTransaction(
          txnId: 'TXN-1',
          type: TransactionType.debit,
          mode: 'UPI',
          amount: 500.0,
          currentBalance: 24500.0,
          transactionTimestamp: DateTime.now(),
          narration: 'UPI/Swiggy/swiggy@icici',
        ),
      ];

      final container = ProviderContainer(
        overrides: [
          transactionRepositoryProvider.overrideWithValue(
            _FakeTestRepository(sampleTxns),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(container.read(hasActiveConsentProvider), isFalse);

      container.read(activeConsentIdProvider.notifier).setConsentId('consent_12345');
      expect(container.read(hasActiveConsentProvider), isTrue);

      final feed = await container.read(transactionFeedProvider.future);
      expect(feed.length, 1);

      final balance = container.read(latestBalanceProvider);
      expect(balance, 24500.0);
    });

    test('Auth providers resolve unauthenticated by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(isAuthenticatedProvider), isFalse);
      expect(container.read(currentUserProvider), isNull);
    });
  });

  group('Widget UI Smoke test with Riverpod', () {
    setUp(() {
      ActiveConsentIdNotifier.enablePersistence = false;
      ActiveConsentIdNotifier.deletePersistedConsent();
    });

    tearDown(() {
      ActiveConsentIdNotifier.deletePersistedConsent();
      ActiveConsentIdNotifier.enablePersistence = true;
    });

    testWidgets('SetthiApp launches and renders AuthScreen when unauthenticated', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: SetthiApp(),
        ),
      );

      expect(find.text('Setthi'), findsOneWidget);
      expect(find.text('Next-Gen Financial Intelligence'), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Create Account'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
    });

    testWidgets('SetthiApp launches and renders TransactionFeedScreen when authenticated', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
          ],
          child: const SetthiApp(),
        ),
      );

      expect(find.text('Setthi'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.text('Setu AA ReBIT Gateway'), findsOneWidget);
      expect(find.text('Link Bank'), findsWidgets);
      expect(find.text('TOTAL AVAILABLE BALANCE'), findsOneWidget);
      expect(find.text('No Bank Account Linked'), findsOneWidget);
    });

    testWidgets('VerifyEmailScreen renders 6-digit input boxes and action button', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: VerifyEmailScreen(email: 'testuser@example.com'),
          ),
        ),
      );

      expect(find.text('Verify Email'), findsOneWidget);
      expect(find.textContaining('testuser@example.com'), findsOneWidget);
      expect(find.text('Verify Code'), findsOneWidget);
      expect(find.textContaining("Didn't receive the code?"), findsOneWidget);
    });

    testWidgets('DpcFloatingNavDock renders quick actions and handles link bank tap', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Dock items: Feed, Sync, Link Bank
      expect(find.text('Feed'), findsOneWidget);
      expect(find.byIcon(Icons.sync_rounded), findsOneWidget);
      final dockLinkBank = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.text('Link Bank'),
      );
      expect(dockLinkBank, findsOneWidget);

      // Tap 'Link Bank' action on floating dock to open link bank bottom sheet
      await tester.tap(dockLinkBank);
      await tester.pumpAndSettle();

      // Verify Setu AA Consent Flow bottom sheet opened
      expect(find.text('Link Bank via Account Aggregator'), findsOneWidget);
      expect(find.text('Setu AA ReBIT Gateway (RBI Regulated)'), findsOneWidget);
    });

    testWidgets('Tapping Skip for now on AuthScreen bypasses auth to TransactionFeedScreen', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // On AuthScreen, find Skip for now button and tap it
      final skipBtn = find.text('Skip for now');
      expect(skipBtn, findsOneWidget);
      await tester.tap(skipBtn);
      await tester.pumpAndSettle();

      // Should now be on TransactionFeedScreen
      expect(find.text('TOTAL AVAILABLE BALANCE'), findsOneWidget);
      expect(find.text('Setu AA ReBIT Gateway'), findsOneWidget);
    });
  });
}
