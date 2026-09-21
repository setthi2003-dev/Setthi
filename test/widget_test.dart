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
import 'package:setthi/models/transaction_group_model.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/providers/auth_providers.dart';
import 'package:setthi/providers/transaction_providers.dart';
import 'package:setthi/services/fi_data_service.dart';
import 'package:setthi/services/setu_aa_service.dart';
import 'package:setthi/services/supabase_db_service.dart';
import 'package:setthi/widgets/dpc_floating_dock.dart';

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

      final balance = container.read(latestBalanceProvider);
      expect(balance, isA<double>());
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

      // Verify Sort Order Pill is present (initially shows 'Latest')
      expect(find.text('Latest'), findsOneWidget);

      // Verify Filter chips exist: All Flows, Debits ↓, Credits ↑, All Years
      expect(find.text('All Flows'), findsOneWidget);
      expect(find.text('Debits ↓'), findsOneWidget);
      expect(find.text('Credits ↑'), findsOneWidget);
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
}
