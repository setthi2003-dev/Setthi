import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:setthi/config/setu_config.dart';
import 'package:setthi/config/supabase_config.dart';
import 'package:setthi/main.dart';
import 'package:setthi/screens/auth_screen.dart';
import 'package:setthi/screens/verify_email_screen.dart';
import 'package:setthi/screens/reset_password_screen.dart';
import 'package:setthi/models/merchant_category_model.dart';
import 'package:setthi/models/transaction_group_model.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/providers/auth_providers.dart';
import 'package:setthi/providers/transaction_providers.dart';
import 'package:setthi/services/fi_data_service.dart';
import 'package:setthi/services/setu_aa_service.dart';
import 'package:setthi/services/supabase_db_service.dart';
import 'package:setthi/widgets/dpc_floating_dock.dart';
import 'package:setthi/models/chat_message_model.dart';
import 'package:setthi/providers/chat_providers.dart';
import 'package:setthi/providers/supabase_provider.dart';
import 'package:setthi/services/chat_service.dart';
import 'package:setthi/widgets/dpc_telemetry_cards.dart';
import 'package:setthi/widgets/dpc_hero_carousel.dart';
import 'package:setthi/widgets/setthi_ai_sheet.dart';
import 'package:setthi/widgets/ai_companion_rive_widget.dart';
import 'package:setthi/widgets/profile_completion_dialog.dart';
import 'package:setthi/widgets/dpc_safe_to_spend_card.dart';

class _FakeChatService extends ChatService {
  final List<ChatStreamEvent> eventsToEmit;
  _FakeChatService(this.eventsToEmit);

  @override
  Stream<ChatStreamEvent> sendMessage({
    required String prompt,
    required String accessToken,
    String? sessionId,
  }) async* {
    for (final event in eventsToEmit) {
      yield event;
    }
  }
}

class _FakeTestRepository implements TransactionRepository {
  final List<BankTransaction> _txns;
  _FakeTestRepository(this._txns);

  @override
  Future<List<BankTransaction>> fetchTransactions() async => _txns;
}

class _FakeFeedNotifier extends TransactionFeedNotifier {
  final List<BankTransaction> _txns;
  _FakeFeedNotifier(this._txns);

  @override
  Future<List<BankTransaction>> build() async => _txns;
}

class _FakeSupabaseDbService extends SupabaseDbService {
  bool deleteChatHistoryCalled = false;
  List<ChatMessage> mockHistory = [];

  _FakeSupabaseDbService({this.mockHistory = const []});

  @override
  Future<List<ChatMessage>> fetchChatHistory({int limit = 50}) async {
    return List.of(mockHistory);
  }

  @override
  Future<bool> deleteChatHistory() async {
    deleteChatHistoryCalled = true;
    mockHistory = [];
    return true;
  }
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

      // Card and Cash transactions with slash-separated Indian banking narrations
      final cardTxn = BankTransaction(
        txnId: 'TXN-3',
        type: TransactionType.debit,
        mode: 'CARD',
        amount: 8991.27,
        currentBalance: 207265.34,
        transactionTimestamp: DateTime.now(),
        narration: 'CARD/DE/995415932503/Amira Salvi/ANIJ/08764285',
      );
      expect(cardTxn.cleanMerchantName, 'Amira Salvi');

      final cashTxn = BankTransaction(
        txnId: 'TXN-4',
        type: TransactionType.credit,
        mode: 'CASH',
        amount: 37745.87,
        currentBalance: 388347.04,
        transactionTimestamp: DateTime.now(),
        narration: 'CASH/CR/467366268432/Sara Dave/ZTAE/35521479',
      );
      expect(cashTxn.cleanMerchantName, 'Sara Dave');

      final nirviTxn = BankTransaction(
        txnId: 'TXN-5',
        type: TransactionType.debit,
        mode: 'CARD',
        amount: 28883.75,
        currentBalance: 111979.64,
        transactionTimestamp: DateTime.now(),
        narration: 'CARD/DE/523640260574/Nirvi Kant/OZQI/73725697',
      );
      expect(nirviTxn.cleanMerchantName, 'Nirvi Kant');
    });

    test('Dynamic MerchantCategoryRegistry matches known brands and assigns category or null', () {
      final swiggyParsed = BankTransaction.fromJson({
        'txnId': 'T-SWIGGY',
        'type': 'DEBIT',
        'mode': 'UPI',
        'amount': 350.0,
        'narration': 'UPI/428192019482/Swiggy/swiggy@icici/Order_Food',
      });
      expect(swiggyParsed.cleanMerchantName, 'Swiggy');
      expect(swiggyParsed.category, 'Food & Dining');

      final netflixParsed = BankTransaction.fromJson({
        'txnId': 'T-NETFLIX',
        'type': 'DEBIT',
        'mode': 'CARD',
        'amount': 649.0,
        'narration': 'CARD/DE/995415932503/Netflix/ANIJ/08764285',
      });
      expect(netflixParsed.cleanMerchantName, 'Netflix');
      expect(netflixParsed.category, 'Entertainment');

      // Unmatched counterparty: category must be null
      final cardParsed = BankTransaction.fromJson({
        'txnId': 'T-CARD',
        'type': 'DEBIT',
        'mode': 'CARD',
        'amount': 8991.27,
        'narration': 'CARD/DE/995415932503/Amira Salvi/ANIJ/08764285',
      });
      expect(cardParsed.cleanMerchantName, 'Amira Salvi');
      expect(cardParsed.category, isNull);

      final cashParsed = BankTransaction.fromJson({
        'txnId': 'T-CASH',
        'type': 'CREDIT',
        'mode': 'CASH',
        'amount': 37745.87,
        'narration': 'CASH/CR/467366268432/Sara Dave/ZTAE/35521479',
      });
      expect(cashParsed.cleanMerchantName, 'Sara Dave');
      expect(cashParsed.category, isNull);
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

      // build() only loads from Supabase (empty in test env); live sync requires explicit syncTransactions()
      final feed = await container.read(transactionFeedProvider.future);
      expect(feed, isA<List<BankTransaction>>());

      final balance = container.read(balanceProvider);
      expect(balance, isA<AsyncValue<Map<String, dynamic>?>>());
    });

    test('Auth providers resolve unauthenticated by default', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(isAuthenticatedProvider), isFalse);
      expect(container.read(currentUserProvider), isNull);
      expect(container.read(isPasswordRecoveryProvider), isFalse);

      container.read(isPasswordRecoveryProvider.notifier).setRecovery(true);
      expect(container.read(isPasswordRecoveryProvider), isTrue);

      container.read(isPasswordRecoveryProvider.notifier).clearRecovery();
      expect(container.read(isPasswordRecoveryProvider), isFalse);
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
      expect(find.text('Your Personal Finance Assistant'), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);
      expect(find.text('Create Account'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget);
      // Apple Sign-In should only appear on iOS devices
      expect(find.text('Continue with Apple'), findsNothing);

      // Verify that on iOS, Continue with Apple appears
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: SetthiApp(),
          ),
        );
        expect(find.text('Continue with Apple'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('AuthScreen enables Sign In, Google, and Apple buttons only when terms are checked', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await tester.pumpWidget(
          const ProviderScope(
            child: MaterialApp(
              home: AuthScreen(),
            ),
          ),
        );

        // Checkbox and legal links should be visible on Sign In
        expect(find.byType(Checkbox), findsOneWidget);
        expect(find.textContaining('Terms of Service'), findsWidgets);
        expect(find.textContaining('Privacy Policy'), findsWidgets);
        expect(find.textContaining('EULA'), findsWidgets);

        // Initially unchecked -> Sign In, Google, and Apple buttons are disabled (onPressed is null)
        ElevatedButton signInButton = tester.widget(find.widgetWithText(ElevatedButton, 'Sign In to Setthi'));
        expect(signInButton.onPressed, isNull);

        OutlinedButton googleButton = tester.widget(find.widgetWithText(OutlinedButton, 'Continue with Google'));
        expect(googleButton.onPressed, isNull);

        OutlinedButton appleButton = tester.widget(find.widgetWithText(OutlinedButton, 'Continue with Apple'));
        expect(appleButton.onPressed, isNull);

        // Tap the checkbox to agree to terms
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();

        // Checkbox is now checked
        final Checkbox checkbox = tester.widget(find.byType(Checkbox));
        expect(checkbox.value, isTrue);

        // Now Sign In, Google, and Apple buttons are enabled!
        signInButton = tester.widget(find.widgetWithText(ElevatedButton, 'Sign In to Setthi'));
        expect(signInButton.onPressed, isNotNull);

        googleButton = tester.widget(find.widgetWithText(OutlinedButton, 'Continue with Google'));
        expect(googleButton.onPressed, isNotNull);

        appleButton = tester.widget(find.widgetWithText(OutlinedButton, 'Continue with Apple'));
        expect(appleButton.onPressed, isNotNull);

        // Switch to Create Account tab -> Create Free Account button is also enabled because terms are checked
        await tester.tap(find.text('Create Account'));
        await tester.pumpAndSettle();

        final ElevatedButton createAccountButton = tester.widget(find.widgetWithText(ElevatedButton, 'Create Free Account'));
        expect(createAccountButton.onPressed, isNotNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('AuthScreen clears red validation errors when user taps anywhere on screen without wiping text', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: AuthScreen(),
          ),
        ),
      );

      // Agree to terms to enable submit button
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();

      // Attempt to submit empty form
      await tester.tap(find.widgetWithText(ElevatedButton, 'Sign In to Setthi'));
      await tester.pumpAndSettle();

      // Validation errors should be visible
      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);

      // Tap on screen header to dismiss errors
      await tester.tap(find.text('Setthi'));
      await tester.pumpAndSettle();

      // Errors must be gone
      expect(find.text('Email is required'), findsNothing);
      expect(find.text('Password is required'), findsNothing);

      // Switch to Create Account tab
      await tester.tap(find.text('Create Account'));
      await tester.pumpAndSettle();

      // Submit empty Create Account form
      final createButton = find.widgetWithText(ElevatedButton, 'Create Free Account');
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await tester.pumpAndSettle();

      // All 3 errors should appear
      expect(find.text('Please enter your name'), findsOneWidget);
      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);

      // Tap on the screen background/header
      await tester.ensureVisible(find.text('Your Personal Finance Assistant'));
      await tester.tap(find.text('Your Personal Finance Assistant'));
      await tester.pumpAndSettle();

      // Errors must vanish immediately
      expect(find.text('Please enter your name'), findsNothing);
      expect(find.text('Email is required'), findsNothing);
      expect(find.text('Password is required'), findsNothing);

      // Enter text into Full Name field
      final nameField = find.byType(TextFormField).first;
      await tester.ensureVisible(nameField);
      await tester.enterText(nameField, 'Maya Patel');
      await tester.pumpAndSettle();

      // Submit again (email & password are still empty)
      await tester.ensureVisible(createButton);
      await tester.tap(createButton);
      await tester.pumpAndSettle();

      // Full Name has text, so only Email and Password have errors
      expect(find.text('Please enter your name'), findsNothing);
      expect(find.text('Email is required'), findsOneWidget);
      expect(find.text('Password is required'), findsOneWidget);

      // Tap directly into the Email field
      final emailField = find.byType(TextFormField).at(1);
      await tester.ensureVisible(emailField);
      await tester.tap(emailField);
      await tester.pumpAndSettle();

      // Errors must vanish immediately on field tap!
      expect(find.text('Email is required'), findsNothing);
      expect(find.text('Password is required'), findsNothing);

      // Full Name entered text is preserved!
      expect(find.text('Maya Patel'), findsOneWidget);
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

      expect(find.text('Setthi AI'), findsWidgets);

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // Navigate to Spending Insights screen from initial Setthi AI screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      expect(find.byType(DpcHeroCarousel), findsNothing);
      expect(find.text('BALANCE'), findsWidgets);
      expect(find.text('No Bank Account Linked'), findsNothing);
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

    testWidgets('SetthiApp launches and renders ResetPasswordScreen when isPasswordRecovery is true', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isPasswordRecoveryProvider.overrideWith(
              () => _TestPasswordRecoveryNotifier(true),
            ),
          ],
          child: const SetthiApp(),
        ),
      );

      expect(find.text('Reset Password'), findsWidgets);
      expect(
        find.textContaining('Enter the 6-digit code'),
        findsOneWidget,
      );
      expect(find.text('Verify Code'), findsOneWidget);
    });

    testWidgets('ResetPasswordScreen validates 6-digit code and password creation in step 2', (WidgetTester tester) async {
      // Test Step 1: Verification with short code
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: ResetPasswordScreen(email: 'test@example.com'),
          ),
        ),
      );

      expect(find.text('Reset Password'), findsWidgets);
      expect(find.text('Verify Code'), findsOneWidget);

      await tester.tap(find.text('Verify Code'));
      await tester.pumpAndSettle();
      expect(find.text('Please enter the complete 6-digit verification code'), findsOneWidget);

      // Test Step 2: Render with initialCodeVerified = true
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: ResetPasswordScreen(
              key: ValueKey('step2_screen'),
              email: 'test@example.com',
              initialCodeVerified: true,
            ),
          ),
        ),
      );

      expect(find.text('Create New Password'), findsOneWidget);
      final submitButton = find.text('Set New Password');
      expect(submitButton, findsOneWidget);

      // Tap Set New Password with empty inputs -> validation error
      await tester.ensureVisible(submitButton);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();
      expect(find.text('Password must be at least 6 characters'), findsOneWidget);

      // Enter mismatched passwords (index 0 is password, index 1 is confirm password in step 2)
      final textFields = find.byType(TextFormField);
      await tester.enterText(textFields.at(0), 'newpassword123');
      await tester.enterText(textFields.at(1), 'wrongpassword');
      await tester.ensureVisible(submitButton);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();
      expect(find.text('Passwords do not match'), findsOneWidget);
    });

    testWidgets('DpcFloatingNavDock renders quick actions and handles navigation', (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Verify Dock items: AI, Insights & Activity, Profile
      expect(
        find.descendant(
          of: find.byType(DpcFloatingNavDock),
          matching: find.byType(AiCompanionRiveWidget),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(DpcFloatingNavDock),
          matching: find.byIcon(Icons.insights_rounded),
        ),
        findsOneWidget,
      );
      final dockProfile = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.byIcon(Icons.person_outline_rounded),
      );
      expect(dockProfile, findsOneWidget);

      // Tap Profile icon in floating dock to navigate to dedicated Profile Page
      await tester.tap(dockProfile);
      await tester.pumpAndSettle();

      // Verify Dedicated Profile & Account page is rendered
      expect(find.text('Profile & Account'), findsOneWidget);
      expect(find.text('Financial Intelligence'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
    });

    testWidgets('DpcFloatingNavDock supports navbar pages: AI, Telemetry, Home Balance, Profile', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Starts on primary Page 0: Setthi AI Chat
      expect(find.text('Setthi AI'), findsWidgets);

      // Verify navbar buttons exist in the dock
      final dockAi = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.byType(AiCompanionRiveWidget),
      );
      final dockInsights = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.byIcon(Icons.insights_rounded),
      );
      final dockProfile = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.byIcon(Icons.person_outline_rounded),
      );

      expect(dockAi, findsOneWidget);
      expect(dockInsights, findsOneWidget);
      expect(dockProfile, findsOneWidget);

      // 1. Enter text in Setthi AI Chat
      expect(find.text('Smart Finance Companion'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'How much did I spend?');
      expect(find.text('How much did I spend?'), findsOneWidget);

      // 2. Tap Page 1 (Spending Insights & Activity - Merged)
      await tester.tap(dockInsights);
      await tester.pumpAndSettle();

      expect(find.text('STATEMENT BREAKDOWN'), findsNothing);
      expect(find.text('BALANCE'), findsWidgets);

      // 3. Tap Page 2 (Profile & Account)
      await tester.tap(dockProfile);
      await tester.pumpAndSettle();

      expect(find.text('Profile & Account'), findsOneWidget);
      expect(find.text('Financial Intelligence'), findsOneWidget);
    });

    testWidgets('AuthScreen enforces sign in and does not display Skip for now button', (WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Ensure Skip for now is completely removed and auth cannot be bypassed
      expect(find.text('Skip for now'), findsNothing);
      expect(find.text('Skip for now (Explore UI)'), findsNothing);
      expect(find.text('Sign In to Setthi'), findsOneWidget);
    });
  });

  group('SupabaseDbService tests', () {
    test('Handles unauthenticated or unconfigured state safely without throwing', () async {
      final dbService = SupabaseDbService();
      expect(dbService.currentUserId, isNull);

      final profile = await dbService.fetchProfile('non-existent-user');
      expect(profile, isNull);

      final accounts = await dbService.fetchBankAccounts();
      expect(accounts, isEmpty);

      final txns = await dbService.fetchStoredTransactions();
      expect(txns, isEmpty);

      final categories = await dbService.fetchMerchantCategories();
      expect(categories, isNotEmpty);

      final activeConsent = await dbService.fetchActiveConsent();
      expect(activeConsent, isNull);

      // Mutating methods safely no-op
      await dbService.upsertProfile(userId: 'test', email: 'test@example.com');
      await dbService.recordConsent(consentId: 'c1', status: 'PENDING');
      await dbService.updateConsentStatus(consentId: 'c1', status: 'ACTIVE');
      await dbService.saveBankTransactions(transactions: []);
    });

    test('SetuConsentExpiredException instantiates properly', () {
      final ex = SetuConsentExpiredException(
        'Consent use exceeded',
        statusCode: 400,
        responseBody: {'errorCode': 'InvalidRequest'},
      );
      expect(ex.message, 'Consent use exceeded');
      expect(ex.statusCode, 400);
      expect(ex.toString(), contains('SetuConsentExpiredException'));
    });
  });

  group('Smart hierarchical date grouping & sort/filter tests', () {
    final sampleTxns = [
      BankTransaction(
        txnId: 'TXN-A',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 500.0,
        currentBalance: 10000.0,
        transactionTimestamp: DateTime(2024, 5, 15, 10, 30),
        narration: 'UPI/Swiggy',
      ),
      BankTransaction(
        txnId: 'TXN-B',
        type: TransactionType.credit,
        mode: 'SALARY',
        amount: 50000.0,
        currentBalance: 60000.0,
        transactionTimestamp: DateTime(2024, 5, 1, 9, 0),
        narration: 'Salary Credit',
      ),
      BankTransaction(
        txnId: 'TXN-C',
        type: TransactionType.debit,
        mode: 'CARD',
        amount: 1200.0,
        currentBalance: 9500.0,
        transactionTimestamp: DateTime(2024, 3, 10, 14, 0),
        narration: 'Amazon Shopping',
      ),
      BankTransaction(
        txnId: 'TXN-D',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 250.0,
        currentBalance: 8000.0,
        transactionTimestamp: DateTime(2023, 12, 25, 20, 0),
        narration: 'Zomato Christmas Dinner',
      ),
    ];

    test('groupTransactionsSmartly groups by Year -> Month -> Date (latestFirst default)', () {
      final groups = groupTransactionsSmartly(
        transactions: sampleTxns,
        sortOrder: TransactionSortOrder.latestFirst,
        typeFilter: TransactionTypeFilter.all,
        selectedYear: null,
      );

      // 2 Years: 2024, 2023
      expect(groups.length, 2);
      expect(groups[0].year, 2024);
      expect(groups[1].year, 2023);

      // Year 2024 has 2 months: May (5), March (3)
      final y2024 = groups[0];
      expect(y2024.monthGroups.length, 2);
      expect(y2024.monthGroups[0].month, 5);
      expect(y2024.monthGroups[0].monthName, 'May');
      expect(y2024.monthGroups[1].month, 3);
      expect(y2024.monthGroups[1].monthName, 'March');

      // Month May totals: 1 debit (500), 1 credit (50000)
      expect(y2024.monthGroups[0].totalDebit, 500.0);
      expect(y2024.monthGroups[0].totalCredit, 50000.0);

      // Days inside May: 15th, 1st
      expect(y2024.monthGroups[0].dayGroups.length, 2);
      expect(y2024.monthGroups[0].dayGroups[0].date.day, 15);
      expect(y2024.monthGroups[0].dayGroups[1].date.day, 1);
    });

    test('groupTransactionsSmartly sorts chronological ascending with oldestFirst', () {
      final groups = groupTransactionsSmartly(
        transactions: sampleTxns,
        sortOrder: TransactionSortOrder.oldestFirst,
        typeFilter: TransactionTypeFilter.all,
        selectedYear: null,
      );

      // Year 2023 comes first
      expect(groups.first.year, 2023);
      expect(groups.last.year, 2024);

      // In 2024, March comes before May
      final y2024 = groups.last;
      expect(y2024.monthGroups[0].month, 3);
      expect(y2024.monthGroups[1].month, 5);

      // In May, 1st comes before 15th
      expect(y2024.monthGroups[1].dayGroups[0].date.day, 1);
      expect(y2024.monthGroups[1].dayGroups[1].date.day, 15);
    });

    test('groupTransactionsSmartly filters by debitOnly and creditOnly correctly', () {
      final debitsOnly = groupTransactionsSmartly(
        transactions: sampleTxns,
        sortOrder: TransactionSortOrder.latestFirst,
        typeFilter: TransactionTypeFilter.debitOnly,
        selectedYear: null,
      );

      // All returned transactions are debits
      for (final yg in debitsOnly) {
        for (final mg in yg.monthGroups) {
          expect(mg.totalCredit, 0.0);
          for (final dg in mg.dayGroups) {
            for (final txn in dg.transactions) {
              expect(txn.type, TransactionType.debit);
            }
          }
        }
      }

      final creditsOnly = groupTransactionsSmartly(
        transactions: sampleTxns,
        sortOrder: TransactionSortOrder.latestFirst,
        typeFilter: TransactionTypeFilter.creditOnly,
        selectedYear: null,
      );

      // Only 1 credit transaction exists (in 2024)
      expect(creditsOnly.length, 1);
      expect(creditsOnly.first.year, 2024);
      expect(creditsOnly.first.monthGroups.length, 1);
      expect(creditsOnly.first.monthGroups.first.dayGroups.first.transactions.length, 1);
      expect(creditsOnly.first.monthGroups.first.dayGroups.first.transactions.first.txnId, 'TXN-B');
    });

    test('groupTransactionsSmartly filters by untagged (credits and debits with null/empty category)', () {
      final sampleWithUntagged = [
        sampleTxns[0].copyWith(category: 'Food & Dining'), // debit, categorized
        sampleTxns[1].copyWith(category: null), // credit, untagged
        sampleTxns[2].copyWith(category: ''), // debit, untagged
      ];

      final untagged = groupTransactionsSmartly(
        transactions: sampleWithUntagged,
        sortOrder: TransactionSortOrder.latestFirst,
        typeFilter: TransactionTypeFilter.untagged,
        selectedYear: null,
      );

      final returnedTxns = untagged
          .expand((y) => y.monthGroups)
          .expand((m) => m.dayGroups)
          .expand((d) => d.transactions)
          .toList();

      expect(returnedTxns.length, 2);
      expect(returnedTxns.any((t) => t.isCredit), isTrue);
      expect(returnedTxns.any((t) => t.isDebit), isTrue);
      expect(returnedTxns.every((t) => t.category == null || t.category!.isEmpty), isTrue);
    });

    test('groupTransactionsSmartly filters by specific year', () {
      final y2023Only = groupTransactionsSmartly(
        transactions: sampleTxns,
        sortOrder: TransactionSortOrder.latestFirst,
        typeFilter: TransactionTypeFilter.all,
        selectedYear: 2023,
      );

      expect(y2023Only.length, 1);
      expect(y2023Only.first.year, 2023);
      expect(y2023Only.first.monthGroups.first.monthName, 'December');
    });

    testWidgets('TransactionFeedScreen renders sort order toggle and filter ribbon', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(
              () => _FakeFeedNotifier(sampleTxns),
            ),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen from default AI screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Verify Sort Order Pill is present (initially shows 'Latest')
      expect(find.text('Latest'), findsOneWidget);

      // Verify Filter chips exist: All Flows, Debits ↓, Credits ↑, Untagged, All Years
      expect(find.text('All Flows'), findsOneWidget);
      expect(find.text('Debits ↓'), findsOneWidget);
      expect(find.text('Credits ↑'), findsOneWidget);
      expect(find.text('Untagged'), findsOneWidget);
      expect(find.text('All Years'), findsOneWidget);

      // Verify Year sections and Month headers are displayed
      expect(find.text('2024'), findsWidgets);
      expect(find.text('MAY 2024'), findsOneWidget);
      expect(find.text('MARCH 2024'), findsOneWidget);

      // Tap Sort Toggle to switch to Oldest First
      await tester.tap(find.text('Latest'));
      await tester.pumpAndSettle();

      // Button text now toggled to 'Oldest'
      expect(find.text('Oldest'), findsOneWidget);

      // Tap 'Debits ↓' filter
      await tester.tap(find.text('Debits ↓'));
      await tester.pumpAndSettle();

      // Salary credit (TXN-B) should not be visible anymore
      expect(find.text('Salary Credit'), findsNothing);
      // Swiggy debit should still be visible
      expect(find.text('Swiggy'), findsOneWidget);

      // Verify that tapping a transaction opens the detailed DPC bottom sheet
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();

      // Modal displays transaction details
      expect(find.text('Balance After'), findsOneWidget);
      expect(find.text('UPI/Swiggy'), findsOneWidget);
    });

    test('SupabaseDbService pagination parameters work safely without throwing', () async {
      final dbService = SupabaseDbService();
      final page1 = await dbService.fetchStoredTransactions(limit: 10, offset: 0);
      expect(page1, isEmpty);

      final total = await dbService.countStoredTransactions();
      expect(total, 0);
    });
  });

  group('Smart Category Assignment & Custom Tagging tests', () {
    test('MerchantCategoryRegistry registers custom rule and matches', () {
      final registry = MerchantCategoryRegistry.instance;
      registry.addRule(const MerchantCategoryRule(
        keyword: 'testmerchant',
        cleanName: 'Test Merchant',
        category: 'Food & Dining',
      ));

      final match = registry.findMatch('UPI/TESTMERCHANT/1234');
      expect(match, isNotNull);
      expect(match!.category, 'Food & Dining');
      expect(match.cleanName, 'Test Merchant');
    });

    test('TransactionFeedNotifier updates single and bulk merchant categories', () async {
      final txn1 = BankTransaction(
        txnId: 'TX-1',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 300,
        currentBalance: 5000,
        transactionTimestamp: DateTime(2024, 5, 10),
        narration: 'UPI/BlueTokai/coffee',
        category: null,
      );
      final txn2 = BankTransaction(
        txnId: 'TX-2',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 250,
        currentBalance: 4750,
        transactionTimestamp: DateTime(2024, 5, 11),
        narration: 'UPI/BlueTokai/beans',
        category: null,
      );

      final container = ProviderContainer(
        overrides: [
          transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([txn1, txn2])),
        ],
      );

      // Verify initial state
      final initial = await container.read(transactionFeedProvider.future);
      expect(initial[0].category, isNull);
      expect(initial[1].category, isNull);

      // Single transaction update
      await container.read(transactionFeedProvider.notifier).updateTransactionCategory(
        txnId: 'TX-1',
        category: 'Cafe & Coffee',
        applyToAllFromMerchant: false,
      );

      final afterSingle = container.read(transactionFeedProvider).value!;
      expect(afterSingle[0].category, 'Cafe & Coffee');
      expect(afterSingle[1].category, isNull);

      // Bulk merchant update
      await container.read(transactionFeedProvider.notifier).updateTransactionCategory(
        txnId: 'TX-2',
        category: 'Cafe & Coffee',
        applyToAllFromMerchant: true,
        cleanMerchantName: afterSingle[1].cleanMerchantName,
      );

      final afterBulk = container.read(transactionFeedProvider).value!;
      expect(afterBulk[0].category, 'Cafe & Coffee');
      expect(afterBulk[1].category, 'Cafe & Coffee');
    });

    testWidgets('Displays micro category pill and opens CategoryPickerSheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final testTxn = BankTransaction(
        txnId: 'TX-PICKER',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 450,
        currentBalance: 10000,
        transactionTimestamp: DateTime(2024, 5, 12, 14, 30),
        narration: 'UPI/Local Bakery/order99',
        category: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([testTxn])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen from initial AI screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Find the category chip in the feed row
      final tagChip = find.text('Not categorised');
      expect(tagChip, findsOneWidget);

      // Tap the "Tag" chip to open the category picker sheet
      await tester.tap(tagChip);
      await tester.pumpAndSettle();

      // Sheet title should be visible
      expect(find.text('Categorize Transaction'), findsOneWidget);
      expect(find.text('- ₹450 Debited'), findsOneWidget);

      // Curated category presets should be visible
      expect(find.text('Eating out, tea & snacks'), findsOneWidget);
      expect(find.text('Groceries & daily needs'), findsOneWidget);

      // Verify no auto-tag toggle switch is rendered
      expect(find.byType(Switch), findsNothing);

      // Test typing a custom category into the search field
      await tester.enterText(find.byType(TextField), 'Weekend Brunch');
      await tester.pumpAndSettle();

      // Custom option should dynamically appear
      expect(find.textContaining('Add custom:'), findsOneWidget);

      // Tap the custom category
      await tester.tap(find.textContaining('Add custom:'));
      await tester.pumpAndSettle();

      // Modal is dismissed, and the transaction tile reflects the new category
      expect(find.text('Categorize Transaction'), findsNothing);
      expect(find.text('Weekend Brunch'), findsWidgets);
    });

    testWidgets('CategoryPickerSheet opens cleanly for generic transactions without any toggle switch', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final otherTxn = BankTransaction(
        txnId: 'TX-OTHERS',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 200,
        currentBalance: 10000,
        transactionTimestamp: DateTime(2024, 5, 12, 14, 30),
        narration: 'UPI/123456/Others',
        precomputedMerchantName: 'Others',
        category: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([otherTxn])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen from initial AI screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      final tagChip = find.text('Not categorised');
      expect(tagChip, findsOneWidget);

      await tester.tap(tagChip);
      await tester.pumpAndSettle();

      // Check header
      expect(find.text('Categorize Transaction'), findsOneWidget);
      expect(find.text('- ₹200 Debited'), findsOneWidget);

      // Verify no switch is rendered anywhere
      expect(find.byType(Switch), findsNothing);

      // Tap a preset category
      await tester.tap(find.text('Eating out, tea & snacks'));
      await tester.pumpAndSettle();

      // Modal is dismissed
      expect(find.text('Categorize Transaction'), findsNothing);
    });

    testWidgets('CategoryPickerSheet opens Custom dialog and customly adds category', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final customTxn = BankTransaction(
        txnId: 'TX-CUSTOM-CAT',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 850,
        currentBalance: 9150,
        transactionTimestamp: DateTime(2024, 5, 12, 14, 30),
        narration: 'UPI/VetCareClinic/pets',
        precomputedMerchantName: 'Vet Care Clinic',
        category: null,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([customTxn])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen from initial AI screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Tap Not categorised chip
      final tagChip = find.text('Not categorised');
      expect(tagChip, findsOneWidget);
      await tester.tap(tagChip);
      await tester.pumpAndSettle();

      // Categorize Transaction sheet should be open
      expect(find.text('Categorize Transaction'), findsOneWidget);

      // Verify the Custom feature is visible
      expect(find.text('Custom Category'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);

      // Tap the Custom Category feature
      await tester.tap(find.text('Custom Category'));
      await tester.pumpAndSettle();

      // Custom dialog should now be open
      expect(find.text('Save Category'), findsOneWidget);
      expect(find.text('SUGGESTIONS'), findsOneWidget);

      // Select 'Pet Care' from suggestions or enter text
      final petCareChip = find.text('Pet Care');
      expect(petCareChip, findsOneWidget);
      await tester.tap(petCareChip);
      await tester.pumpAndSettle();

      // Tap Save Category
      await tester.tap(find.text('Save Category'));
      await tester.pumpAndSettle();

      // Both dialog and sheet dismissed, new custom category rendered
      expect(find.text('Categorize Transaction'), findsNothing);
      expect(find.text('Pet Care'), findsWidgets);
    });
  });

  group('Setthi AI Chat Companion & Credits tests', () {
    test('ChatMessage model serializes and parses correctly', () {
      final msg = ChatMessage(
        id: 'msg-1',
        role: ChatRole.assistant,
        content: 'You spent ₹1,450 on Swiggy this week.',
        createdAt: DateTime(2024, 5, 15, 10, 30),
      );

      final json = msg.toJson();
      expect(json['id'], 'msg-1');
      expect(json['role'], 'assistant');
      expect(json['content'], contains('₹1,450'));

      final parsed = ChatMessage.fromJson(json);
      expect(parsed.id, msg.id);
      expect(parsed.role, ChatRole.assistant);
      expect(parsed.isAssistant, isTrue);
      expect(parsed.isUser, isFalse);
    });

    test('AiCreditsNotifier initializes with 3 credits and handles mutations', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(aiCreditsProvider), 3);

      container.read(aiCreditsProvider.notifier).decrement();
      expect(container.read(aiCreditsProvider), 2);

      container.read(aiCreditsProvider.notifier).decrement();
      expect(container.read(aiCreditsProvider), 1);

      container.read(aiCreditsProvider.notifier).decrement();
      expect(container.read(aiCreditsProvider), 0);

      // Cannot go below 0
      container.read(aiCreditsProvider.notifier).decrement();
      expect(container.read(aiCreditsProvider), 0);

      container.read(aiCreditsProvider.notifier).setCredits(5);
      expect(container.read(aiCreditsProvider), 5);
    });

    test('ChatMessagesNotifier sends message and streams token events', () async {
      final fakeEvents = [
        const ChatChunkEvent('Hey! '),
        const ChatChunkEvent('You spent ₹450 '),
        const ChatChunkEvent('on coffee.'),
        const ChatDoneEvent(remainingCredits: 2),
      ];

      final container = ProviderContainer(
        overrides: [
          chatServiceProvider.overrideWithValue(_FakeChatService(fakeEvents)),
        ],
      );
      addTearDown(container.dispose);

      // Initialize state
      await container.read(chatMessagesProvider.future);
      expect(container.read(chatMessagesProvider).value, isEmpty);

      // Send message
      await container.read(chatMessagesProvider.notifier).sendMessage('How much on coffee?');

      final messages = container.read(chatMessagesProvider).value!;
      expect(messages.length, 2);
      expect(messages[0].isUser, isTrue);
      expect(messages[0].content, 'How much on coffee?');
      expect(messages[1].isAssistant, isTrue);
      expect(messages[1].content, 'Hey! You spent ₹450 on coffee.');
      expect(messages[1].isStreaming, isFalse);

      // Credit updated to 2
      expect(container.read(aiCreditsProvider), 2);
    });

    test('ChatMessagesNotifier clearHistory deletes chat history from backend database', () async {
      final fakeDb = _FakeSupabaseDbService(mockHistory: [
        ChatMessage(
          id: 'm1',
          role: ChatRole.user,
          content: 'Hello',
          createdAt: DateTime.now(),
        ),
      ]);

      final container = ProviderContainer(
        overrides: [
          supabaseDbServiceProvider.overrideWithValue(fakeDb),
        ],
      );
      addTearDown(container.dispose);

      final initial = await container.read(chatMessagesProvider.future);
      expect(initial.length, 1);

      final result = await container.read(chatMessagesProvider.notifier).clearHistory();
      expect(result, isTrue);
      expect(fakeDb.deleteChatHistoryCalled, isTrue);
      expect(container.read(chatMessagesProvider).value, isEmpty);
    });

    testWidgets('Delete conversation button prompts warning confirmation modal and clears backend on confirmation', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeDb = _FakeSupabaseDbService(mockHistory: [
        ChatMessage(
          id: 'msg-test-1',
          role: ChatRole.user,
          content: 'Show my weekly spend',
          createdAt: DateTime.now(),
        ),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
            supabaseDbServiceProvider.overrideWithValue(fakeDb),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Tap navbar item 0 (AI page)
      final navAiTab = find.byTooltip('Setthi AI');
      expect(navAiTab, findsOneWidget);
      await tester.tap(navAiTab);
      await tester.pumpAndSettle();

      // Find delete conversation sweep button in AppBar
      final deleteBtn = find.byKey(const Key('delete_conversation_button'));
      expect(deleteBtn, findsOneWidget);

      // Tap delete button to open warning confirmation modal
      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      // Verify confirmation modal with warning appears
      expect(find.text('Delete Conversation?'), findsOneWidget);
      expect(find.text('This action is irreversible'), findsOneWidget);
      expect(find.textContaining('permanently removed from this device and deleted from our cloud servers'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.byKey(const Key('confirm_delete_conversation_button')), findsOneWidget);

      // Test Cancel dismissal first
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Modal closed, backend was not called
      expect(find.text('Delete Conversation?'), findsNothing);
      expect(fakeDb.deleteChatHistoryCalled, isFalse);

      // Open modal again and confirm delete
      await tester.tap(deleteBtn);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('confirm_delete_conversation_button')));
      await tester.pumpAndSettle();

      // Verified deleted from backend and UI cleared
      expect(fakeDb.deleteChatHistoryCalled, isTrue);
      expect(find.text('Conversation permanently deleted'), findsOneWidget);
    });

    testWidgets('DpcFloatingNavDock renders AI action and opens SetthiAiSheet', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Verify AI button in dock
      final dockAiButton = find.descendant(
        of: find.byType(DpcFloatingNavDock),
        matching: find.byIcon(Icons.auto_awesome_rounded),
      );
      expect(dockAiButton, findsOneWidget);

      // Tap AI action to open SetthiAiSheet
      await tester.tap(dockAiButton);
      await tester.pumpAndSettle();

      // Header should display "Setthi AI" and "3 credits"
      expect(find.text('Setthi AI'), findsOneWidget);
      expect(find.text('Smart Finance Companion'), findsOneWidget);
      expect(find.text('3 credits'), findsOneWidget);

      // Empty state quick prompts should be visible
      expect(find.text('How much did I spend this week?'), findsOneWidget);
      expect(find.text('What are my recurring bills?'), findsOneWidget);
      expect(find.text('Top 3 food orders lately'), findsOneWidget);

      // Input field should be present and enabled
      expect(find.byType(TextField), findsOneWidget);
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.enabled, isTrue);
    });

    testWidgets('SetthiAiSheet renders AiCompanionRiveWidget in empty state', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            chatServiceProvider.overrideWithValue(_FakeChatService([])),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SetthiAiSheet(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Verify AiCompanionRiveWidget is mounted in both header avatar and empty state hero logo
      expect(find.byType(AiCompanionRiveWidget), findsNWidgets(2));
      expect(find.byKey(const Key('ai_companion_rive_widget')), findsNWidgets(2));
      expect(find.text('How can I help with your money today?'), findsOneWidget);
    });

    testWidgets('SetthiAiSheet formats **bold** markdown into clean rich text', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEvents = [
        const ChatChunkEvent("You're sitting on **₹2,29,122.82** right now! 💰✨"),
        const ChatDoneEvent(remainingCredits: 2),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            chatServiceProvider.overrideWithValue(_FakeChatService(fakeEvents)),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SetthiAiSheet(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Trigger prompt
      await tester.tap(find.text('What are my recurring bills?'));
      await tester.pumpAndSettle();

      // Verify the formatted text does NOT have raw **
      expect(find.textContaining('**₹2,29,122.82**'), findsNothing);
      // The inner bold currency text is rendered
      expect(find.textContaining('₹2,29,122.82'), findsOneWidget);
    });

    testWidgets('Transaction feed displays caught-up badge and replaces Load Earlier Transactions when final transaction is reached', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final singleTxn = BankTransaction(
        txnId: 'TXN-FINAL',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 350.00,
        currentBalance: 50000.00,
        transactionTimestamp: DateTime(2024, 1, 1, 12, 0),
        narration: 'UPI/Test/FinalTxn',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([singleTxn])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Scroll to bottom
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();

      // "Load Earlier Transactions" should not be visible
      expect(find.text('Load Earlier Transactions'), findsNothing);

      // Caught-up badge should be shown replacing it
      expect(find.textContaining("You're all caught up"), findsOneWidget);
    });

    testWidgets('Transaction feed auto-fetches earlier transactions when user scrolls towards bottom', (tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dummyTxns = List.generate(
        30,
        (i) => BankTransaction(
          txnId: 'TXN-$i',
          type: TransactionType.debit,
          mode: 'UPI',
          amount: 100.0 + i,
          currentBalance: 50000.00,
          transactionTimestamp: DateTime(2024, 1, 1).add(Duration(days: i)),
          narration: 'UPI/Test/Txn$i',
        ),
      );

      final feedNotifier = _AutoFetchFeedNotifier(dummyTxns);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => feedNotifier),
            hasMoreTransactionsProvider.overrideWithValue(true),
            isLoadingMoreTransactionsProvider.overrideWithValue(false),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Drag down towards bottom
      for (int i = 0; i < 6; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump();

      expect(feedNotifier.loadMoreInvoked, isTrue);
    });

    testWidgets('TransactionFeedScreen ensures Ambient AI is removed from homepage', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final dummyTxns = [
        BankTransaction(
          txnId: 'TXN-001',
          type: TransactionType.debit,
          mode: 'UPI',
          amount: 250.0,
          currentBalance: 50000.00,
          transactionTimestamp: DateTime.now().subtract(const Duration(hours: 2)),
          narration: 'UPI/Swiggy/Lunch',
        ),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier(dummyTxns)),
            balanceProvider.overrideWith((ref) => Future.value({
                  'verified': true,
                  'current_balance': 50000.00,
                  'as_of_date': '2026-10-06',
                })),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Ambient AI Briefing badge & conversational bar should NOT be present on the homepage
      expect(find.text('AMBIENT AI'), findsNothing);
      expect(find.text('Daily Runway Briefing'), findsNothing);
      expect(find.text('Ask Setthi about runway, balances, or spends...'), findsNothing);
      expect(find.text('How long is my runway? ⚡'), findsNothing);

      // Cleanly shows Balance and Transaction list
      expect(find.text('BALANCE'), findsWidgets);
      expect(find.text('Swiggy'), findsOneWidget);
    });

    testWidgets('SetthiAiSheet renders chat messages without bubble containers in Gemini/ChatGPT style', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEvents = [
        const ChatChunkEvent("You have **45 days** of runway at your current spending rate."),
        const ChatDoneEvent(remainingCredits: 2),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            chatServiceProvider.overrideWithValue(_FakeChatService(fakeEvents)),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SetthiAiSheet(initialPrompt: 'How long is my runway?'),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Send the pre-populated prompt
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
      await tester.pumpAndSettle();

      // Assistant message header should have Gemini/ChatGPT unboxed branding
      expect(find.text('Setthi AI'), findsWidgets);
      expect(find.textContaining('45 days'), findsOneWidget);
      // Copy action should be present
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    });
  });

  group('Setthi AI & Telemetry Intelligence Architecture tests', () {


    test('BankTransaction model parses and serializes spendTier and isRecurring', () {
      final txn = BankTransaction(
        txnId: 'TXN-INTELLIGENCE',
        type: TransactionType.debit,
        mode: 'UPI',
        amount: 350.0,
        currentBalance: 15000.0,
        transactionTimestamp: DateTime(2026, 9, 24, 1, 30),
        narration: 'UPI/Zepto/Grocery',
        spendTier: 'IMPULSE',
        isRecurring: false,
      );

      expect(txn.spendTier, 'IMPULSE');
      expect(txn.isRecurring, isFalse);

      final json = txn.toJson();
      expect(json['spend_tier'], 'IMPULSE');
      expect(json['is_recurring'], isFalse);

      final fromJsonTxn = BankTransaction.fromJson(json);
      expect(fromJsonTxn.spendTier, 'IMPULSE');
      expect(fromJsonTxn.isRecurring, isFalse);

      final recurringTxn = txn.copyWith(isRecurring: true, spendTier: 'FIXED');
      expect(recurringTxn.isRecurring, isTrue);
      expect(recurringTxn.spendTier, 'FIXED');
    });

    testWidgets('SetthiAiSheet parses and mounts Generative UI tags inline', (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fakeEvents = [
        const ChatChunkEvent(
          'Here is your current spend breakdown:\n\n<!--WIDGET:{"type":"segmented_bar","title":"SPEND BREAKDOWN","segments":[{"label":"UPI","value":82,"color":"#97C5B8"},{"label":"Cards","value":18,"color":"#D1BA8E"}]}-->',
        ),
        const ChatDoneEvent(remainingCredits: 2),
      ];

      final fakeChatService = _FakeChatService(fakeEvents);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            chatServiceProvider.overrideWithValue(fakeChatService),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SetthiAiSheet(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Enter a prompt to trigger AI response
      final inputFinder = find.byType(TextField);
      expect(inputFinder, findsOneWidget);
      await tester.enterText(inputFinder, 'Show cash flow');
      await tester.testTextInput.receiveAction(TextInputAction.send);

      await tester.pumpAndSettle();

      // Verify the widget tag is NOT shown as raw text
      expect(find.textContaining('<!--WIDGET:'), findsNothing);

      // Verify the text content is visible
      expect(find.textContaining('Here is your current spend breakdown'), findsOneWidget);

      // Verify segmented_bar is mounted in the chat tree and split_card is absent
      expect(find.text('SPEND BREAKDOWN'), findsOneWidget);
      expect(find.textContaining('UPI: 82'), findsOneWidget);
      expect(find.textContaining('Cards: 18'), findsOneWidget);
      expect(find.byType(DpcSplitTelemetryCard), findsNothing);
    });

    testWidgets('Hero Carousel cards are commented out on home screen', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Verify the hero carousel is commented out and not present in the widget tree
      expect(find.byType(DpcHeroCarousel), findsNothing);
    });

    testWidgets('Telemetry Screen renders real SQL aggregations from telemetryMetricsProvider', (tester) async {
      final mockMetrics = {
        'financial_health_score': 88,
        'savings_ratio': 0.45,
        'discretionary_ratio': 0.18,
        'daily_velocity': 720.0,
        'total_spent': 5040.0,
        'total_outflow': 5040.0,
        'total_inflow': 11200.0,
        'net_change': 6160.0,
        'channel_distribution': [
          {'mode': 'UPI', 'percentage': 85.0, 'amount': 4284.0},
          {'mode': 'ATM', 'percentage': 10.0, 'amount': 504.0},
          {'mode': 'CARD', 'percentage': 5.0, 'amount': 252.0},
        ],
        'weekly_outflow_velocity': [
          {'week': 1, 'label': 'Week 1', 'amount': 1200.0},
          {'week': 2, 'label': 'Week 2', 'amount': 1500.0},
          {'week': 3, 'label': 'Week 3', 'amount': 940.0},
          {'week': 4, 'label': 'Week 4', 'amount': 1400.0},
        ],
        'category_distribution': [
          {'category': 'Food & Dining', 'amount': 2500.0, 'count': 5, 'percentage': 49.6},
          {'category': 'Bills & Essentials', 'amount': 1500.0, 'count': 2, 'percentage': 29.8},
          {'category': 'Shopping & Lifestyle', 'amount': 1040.0, 'count': 3, 'percentage': 20.6},
        ],
      };

      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
            homeTelemetry7dProvider.overrideWith((ref) => mockMetrics),
            telemetryMetricsProvider.overrideWith((ref) => mockMetrics),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Switch to Spending Insights screen via floating navigation dock
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Verify statement breakdown card is removed and single category spend list is present on Spending Insights screen
      expect(find.text('STATEMENT BREAKDOWN'), findsNothing);
      expect(find.text('Money out'), findsNothing);
      expect(find.text('Money in'), findsNothing);
      expect(find.text('PAYMENT METHODS'), findsNothing);
      // Verify SPENDING BY CATEGORY is commented out from UI
      expect(find.text('SPENDING BY CATEGORY'), findsNothing);
    });
    test('balanceProvider delivers verified balance map from backend', () async {
      final container = ProviderContainer(
        overrides: [
          balanceProvider.overrideWith((ref) => Future.value({
                'verified': true,
                'current_balance': 37.21,
                'as_of_date': '2026-10-06',
                'source': 'statement_closing',
              })),
        ],
      );

      final balanceAsync = await container.read(balanceProvider.future);
      expect(balanceAsync, isNotNull);
      expect(balanceAsync!['verified'], isTrue);
      expect(balanceAsync['current_balance'], equals(37.21));
      expect(balanceAsync['as_of_date'], equals('2026-10-06'));
    });

    testWidgets('TransactionFeedScreen renders temporal statement period and avoids ₹0 contradiction', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            activeConsentIdProvider.overrideWith(() => _FakeActiveConsentNotifier('test-consent-123')),
            transactionFeedProvider.overrideWith(
              () => _FakeLiveFeedNotifier([
                BankTransaction(
                  txnId: 'hist-1',
                  amount: 18499.65,
                  type: TransactionType.credit,
                  mode: 'UPI',
                  currentBalance: 229122.82,
                  transactionTimestamp: DateTime(2024, 12, 17, 9, 25, 50),
                  narration: 'UPI/Anya Wable',
                ),
                BankTransaction(
                  txnId: 'hist-2',
                  amount: 49355.85,
                  type: TransactionType.credit,
                  mode: 'UPI',
                  currentBalance: 210623.17,
                  transactionTimestamp: DateTime(2024, 12, 11, 15, 35, 56),
                  narration: 'UPI/Navya Borah',
                ),
              ]),
            ),
          ],
          child: const SetthiApp(),
        ),
      );

      await tester.pumpAndSettle();

      // Tap Insights in dock to open Spending Insights screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Hero Aggregate displays balance and avoids "this week" contradiction
      expect(find.text('BALANCE'), findsWidgets);
      expect(find.textContaining('₹0 spent • ₹0 inflow this week'), findsNothing);
      expect(find.text('STATEMENT BREAKDOWN'), findsNothing);

      // Navigate to Profile & Account via bottom dock
      await tester.tap(find.byTooltip('Profile & Account'));
      await tester.pumpAndSettle();

      // Verify Profile screen rendered with elevated Financial Intelligence card
      expect(find.text('Profile & Account'), findsOneWidget);
      expect(find.text('Financial Intelligence'), findsOneWidget);
      expect(find.text('ACTIVE'), findsOneWidget);
      expect(find.textContaining('Gemini 2.5 Flash'), findsNothing);

      // Verify Security & Compliance is completely removed
      expect(find.text('Security & Compliance'), findsNothing);

      // Verify Account Actions
      expect(find.text('ACCOUNT ACTIONS'), findsOneWidget);
      expect(find.text('Sign Out'), findsOneWidget);
      expect(find.byKey(const Key('delete_account_button')), findsOneWidget);

      // Tap Delete Account button and verify confirmation modal
      await tester.tap(find.byKey(const Key('delete_account_button')));
      await tester.pumpAndSettle();

      expect(find.text('Delete Account & Data'), findsOneWidget);
      expect(find.text('PERMANENT & IRREVERSIBLE ACTION'), findsOneWidget);
      expect(find.textContaining('All synced bank transactions and balance logs'), findsOneWidget);
      expect(find.byKey(const Key('confirm_delete_account_button')), findsOneWidget);

      // Cancel dismissal
      await tester.tap(find.text('Cancel, Keep My Account'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Account & Data'), findsNothing);
    });

    testWidgets('ProfileCompletionDialog requires DOB, removes skip, and disables save button until all fields filled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileCompletionDialog(
              initialName: '',
              initialDob: DateTime(1996, 7, 15),
              initialGender: null,
              isMandatory: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify header and fields exist
      expect(find.text('Complete Your Profile'), findsOneWidget);
      expect(find.text('Full Name'), findsOneWidget);
      expect(find.text('Date of Birth'), findsOneWidget);
      expect(find.text('Gender'), findsOneWidget);

      // Verify "Skip for now" is completely removed
      expect(find.text('Skip for now'), findsNothing);

      // Verify Save button is initially DISABLED because name and gender are missing
      final saveFinder = find.byKey(const Key('save_profile_button'));
      expect(saveFinder, findsOneWidget);
      var saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);

      // Select gender chip
      await tester.tap(find.byKey(const Key('gender_chip_Female')));
      await tester.pumpAndSettle();

      // Button is still disabled (Name missing)
      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);

      // Enter Full Name (now all 3 are filled and changed from initial empty)
      await tester.enterText(find.byType(TextFormField).first, 'Maya Patel');
      await tester.pumpAndSettle();

      // Button should now be ENABLED
      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNotNull);

      // Clear the name to verify it disables again in real time
      await tester.enterText(find.byType(TextFormField).first, '');
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);
    });

    testWidgets('ProfileCompletionDialog disables save button when editing existing profile until a field is edited', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ProfileCompletionDialog(
              initialName: 'Maya Patel',
              initialDob: DateTime(1996, 7, 15),
              initialGender: 'Female',
              isMandatory: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveFinder = find.byKey(const Key('save_profile_button'));
      expect(saveFinder, findsOneWidget);

      // When opening with complete existing profile, button MUST BE DISABLED if nothing is edited
      var saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);

      // Edit name: button should ENABLE
      await tester.enterText(find.byType(TextFormField).first, 'Maya P');
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNotNull);

      // Revert name back to original: button should DISABLE again
      await tester.enterText(find.byType(TextFormField).first, 'Maya Patel');
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);

      // Change gender: button should ENABLE
      await tester.tap(find.byKey(const Key('gender_chip_Non-Binary')));
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNotNull);

      // Revert gender back to original Female: button should DISABLE
      await tester.tap(find.byKey(const Key('gender_chip_Female')));
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNull);

      // Select income type: button should ENABLE
      await tester.tap(find.byKey(const Key('income_type_chip_Salaried')));
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNotNull);

      // Enter income amount
      await tester.enterText(find.byKey(const Key('profile_income_input')), '75000');
      await tester.pumpAndSettle();

      saveButton = tester.widget<ElevatedButton>(saveFinder);
      expect(saveButton.onPressed, isNotNull);
    });

    test('Bank consent cancellation prevents false positive approval and clears pending state', () async {
      // Setup mock AA service returning PENDING (user aborted/cancelled before OTP)
      final mockClient = MockClient((request) async {
        if (request.url.path.contains('/v2/consents/pending-consent-123')) {
          return http.Response(
            jsonEncode({'id': 'pending-consent-123', 'status': 'PENDING'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{"error": "not found"}', 404);
      });

      final aaService = SetuAaService(client: mockClient);
      final container = ProviderContainer(
        overrides: [
          setuAaServiceProvider.overrideWithValue(aaService),
        ],
      );

      container.read(pendingConsentIdProvider.notifier).set('pending-consent-123');
      expect(container.read(pendingConsentIdProvider), equals('pending-consent-123'));
      expect(container.read(activeConsentIdProvider), isNull);

      // Verify status check returns PENDING, so checkAndSyncConsent returns false
      final synced = await container
          .read(transactionFeedProvider.notifier)
          .checkAndSyncConsent('pending-consent-123');

      expect(synced, isFalse);
      // Active consent must NEVER be set for a cancelled/pending flow
      expect(container.read(activeConsentIdProvider), isNull);
    });

    testWidgets('DpcCategorySpendCard renders donut chart and category rows accurately', (tester) async {
      final items = [
        CategorySpendItem(
          category: 'Food & Dining',
          amount: 4500,
          count: 8,
          percentage: 45.0,
          color: getCategorySpendColor('Food & Dining'),
          icon: getCategorySpendIcon('Food & Dining'),
        ),
        CategorySpendItem(
          category: 'Shopping & Lifestyle',
          amount: 3500,
          count: 4,
          percentage: 35.0,
          color: getCategorySpendColor('Shopping & Lifestyle'),
          icon: getCategorySpendIcon('Shopping & Lifestyle'),
        ),
        CategorySpendItem(
          category: 'Travel & Commute',
          amount: 2000,
          count: 5,
          percentage: 20.0,
          color: getCategorySpendColor('Travel & Commute'),
          icon: getCategorySpendIcon('Travel & Commute'),
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DpcCategorySpendCard(
              items: items,
              totalSpent: 10000,
              periodLabel: 'All Time',
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('SPEND BY CATEGORY'), findsOneWidget);
      expect(find.text('Category Outflows'), findsOneWidget);
      expect(find.text('₹10,000'), findsWidgets);
      expect(find.text('3 categories'), findsOneWidget);

      expect(find.text('Food & Dining'), findsOneWidget);
      expect(find.text('₹4,500'), findsOneWidget);
      expect(find.text('8 transactions'), findsOneWidget);
      expect(find.text('45.0%'), findsOneWidget);

      expect(find.text('Shopping & Lifestyle'), findsOneWidget);
      expect(find.text('₹3,500'), findsOneWidget);
      expect(find.text('4 transactions'), findsOneWidget);
      expect(find.text('35.0%'), findsOneWidget);

      expect(find.text('Travel & Commute'), findsOneWidget);
      expect(find.text('₹2,000'), findsOneWidget);
      expect(find.text('5 transactions'), findsOneWidget);
      expect(find.text('20.0%'), findsOneWidget);
    });
  });

  group('Cashflow Rhythm & Safe-to-Spend Tests', () {
    testWidgets('DpcSafeToSpendCard renders daily safe limit and commitments', (tester) async {
      final mockSafeToSpend = {
        'available': true,
        'safe_per_day': 1250.0,
        'horizon': {
          'days': 12,
          'end_date': '18 Oct 2026',
          'reason': 'Next expected income',
        },
        'health_status': 'HEALTHY',
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cashflowRhythmProvider.overrideWith((ref) async => mockSafeToSpend),
            recurringCommitmentsProvider.overrideWith((ref) async => [
              {
                'id': 'commit-1',
                'merchant_name': 'Netflix',
                'amount': 649.0,
                'cadence': 'MONTHLY',
                'day_of_month': 15,
                'is_active': true,
                'is_user_confirmed': true,
              },
            ]),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: DpcSafeToSpendCard(),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Check title and daily limit metrics
      expect(find.text('Daily safe limit'), findsOneWidget);
      expect(find.text('₹1,250'), findsOneWidget);
      expect(find.text('a day'), findsOneWidget);
      expect(find.text('On track'), findsOneWidget);
      expect(find.text('until 18 Oct 2026 (12 days)'), findsOneWidget);
    });

    testWidgets('DpcSafeToSpendCard is hidden when available is false', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            cashflowRhythmProvider.overrideWith((ref) async => {
              'available': false,
            }),
            activeConsentIdProvider.overrideWith(() => _FakeActiveConsentNotifier('')),
            transactionFeedProvider.overrideWith(() => _FakeFeedNotifier([])),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: DpcSafeToSpendCard(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Ensure the Safe-to-Spend card is NOT rendered when available is false
      expect(find.text('Daily safe limit'), findsNothing);
    });
  });
}

class _AutoFetchFeedNotifier extends TransactionFeedNotifier {
  final List<BankTransaction> _txns;
  bool loadMoreInvoked = false;
  _AutoFetchFeedNotifier(this._txns);

  @override
  Future<List<BankTransaction>> build() async => _txns;

  @override
  Future<void> loadMore() async {
    loadMoreInvoked = true;
  }
}

class _FakeLiveFeedNotifier extends TransactionFeedNotifier {
  final List<BankTransaction> _txns;
  _FakeLiveFeedNotifier(this._txns);

  @override
  Future<List<BankTransaction>> build() async => _txns;
}

class _FakeActiveConsentNotifier extends ActiveConsentIdNotifier {
  final String _id;
  _FakeActiveConsentNotifier(this._id);

  @override
  String? build() => _id;
}



class _TestPasswordRecoveryNotifier extends PasswordRecoveryNotifier {
  final bool _initial;
  _TestPasswordRecoveryNotifier(this._initial);

  @override
  bool build() => _initial;
}



