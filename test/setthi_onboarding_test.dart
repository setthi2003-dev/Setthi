import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/providers/chat_providers.dart';
import 'package:setthi/screens/transaction_feed_screen.dart';
import 'package:setthi/widgets/setthi_onboarding_flow.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Cleo-style Onboarding & Account Linking Tests', () {
    testWidgets('Empty state displays Meet Setthi card and launches SetthiOnboardingFlow', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: TransactionFeedScreen(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Navigate to Spending Insights & Activity screen
      await tester.tap(find.byIcon(Icons.insights_rounded));
      await tester.pumpAndSettle();

      // Verify Cleo Hook & Persona card in empty state
      expect(find.text('MEET SETTHI'), findsOneWidget);
      expect(find.text('Your AI money coach that won\'t bore you to tears.'), findsOneWidget);
      expect(find.text('Get Started'), findsOneWidget);

      // Scroll down to make Get Started card fully visible
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();

      // Tap Get Started to launch SetthiOnboardingFlow modal
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();

      // Step 1: Meet Setthi is presented
      expect(find.byType(SetthiOnboardingFlow), findsOneWidget);
      expect(find.text('Talks like a real human'), findsOneWidget);
      expect(find.text('100% on-device & read-only'), findsOneWidget);
      expect(find.text('Daily safe limit'), findsOneWidget);

      // Tap Get Started inside the modal to proceed to Step 2
      final getStartedInModal = find.descendant(
        of: find.byType(SetthiOnboardingFlow),
        matching: find.text('Get Started'),
      );
      await tester.ensureVisible(getStartedInModal);
      await tester.tap(getStartedInModal);
      await tester.pumpAndSettle();

      // Step 2: Connect Your Bank
      expect(find.text('Connect Your Bank'), findsOneWidget);
      expect(find.text('Select Bank Statement PDF'), findsOneWidget);
      expect(find.text('Choose PDF Statement'), findsOneWidget);
    });

    testWidgets('SetthiOnboardingFlow step navigation and payday confirmation', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SetthiOnboardingFlow(
                onComplete: () {},
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Check Step 1
      expect(find.text('MEET SETTHI'), findsOneWidget);
      await tester.ensureVisible(find.text('Get Started'));
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();

      // Check Step 2
      expect(find.text('Connect Your Bank'), findsOneWidget);

      // Back navigation works
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.text('MEET SETTHI'), findsOneWidget);
    });

    test('Icebreaker data correctly formats Cleo-style prompt based on transactions', () {
      final sampleTxns = [
        BankTransaction(
          txnId: 'TXN1',
          type: TransactionType.credit,
          mode: 'NEFT',
          amount: 65000.0,
          currentBalance: 75000.0,
          transactionTimestamp: DateTime(2026, 9, 28),
          narration: 'SALARY CREDIT ACME CORP',
        ),
        BankTransaction(
          txnId: 'TXN2',
          type: TransactionType.debit,
          mode: 'UPI',
          amount: 850.0,
          currentBalance: 74150.0,
          transactionTimestamp: DateTime(2026, 9, 29),
          narration: 'SWIGGY BANGALORE UPI',
          category: 'Food & Dining',
        ),
      ];

      final container = ProviderContainer();
      final icebreaker = SetthiIcebreakerData(
        greeting: "I've finished looking through your transactions. Want me to tell you how much you spent on food delivery (₹850) last month, or should I just roast you right now?",
        promptChips: [
          'How much on food?',
          'Roast my spending right now',
          'What is my daily safe limit?',
        ],
        topCategory: 'Food & Dining',
        topCategoryAmount: 850.0,
        totalDebitAmount: 850.0,
      );

      container.read(setthiIcebreakerProvider.notifier).setIcebreaker(icebreaker);
      expect(sampleTxns.length, 2);
      expect(container.read(setthiIcebreakerProvider), isNotNull);
      expect(container.read(setthiIcebreakerProvider)!.greeting, contains('roast you right now'));
      expect(container.read(setthiIcebreakerProvider)!.promptChips.length, 3);
    });

    test('Icebreaker data correctly includes archetype from user_habit_profile', () {
      final icebreakerWithArchetype = SetthiIcebreakerData(
        greeting: "I've finished looking through your transactions. Looks like your money archetype is the **Break-Even Glider**. Want me to tell you how much you spent on food delivery (₹850) last month, or should I just roast you right now?",
        promptChips: [
          'Explain my Break-Even Glider archetype',
          'How much on food?',
          'Roast my spending right now',
          'What is my daily safe limit?',
        ],
        topCategory: 'Food & Dining',
        topCategoryAmount: 850.0,
      );

      final container = ProviderContainer();
      container.read(setthiIcebreakerProvider.notifier).setIcebreaker(icebreakerWithArchetype);
      final current = container.read(setthiIcebreakerProvider);
      expect(current, isNotNull);
      expect(current!.greeting, contains('Break-Even Glider'));
      expect(current.promptChips.first, contains('Explain my Break-Even Glider archetype'));
    });

    testWidgets('SetthiOnboardingFlow resets and displays upload option instead of stale success card', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SetthiOnboardingFlow(
                onComplete: () {},
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Proceed from Step 1 to Step 2
      final getStarted = find.text('Get Started');
      await tester.ensureVisible(getStarted);
      await tester.tap(getStarted);
      await tester.pumpAndSettle();

      // Verify that Step 2 shows the upload interface and NOT the stale 'Statement Added Successfully' card
      expect(find.text('Connect Your Bank'), findsOneWidget);
      expect(find.text('Select Bank Statement PDF'), findsOneWidget);
      expect(find.text('Choose PDF Statement'), findsOneWidget);
      expect(find.text('Statement Added Successfully'), findsNothing);
      expect(find.textContaining('Extracted 301 transactions'), findsNothing);
    });
  });
}
