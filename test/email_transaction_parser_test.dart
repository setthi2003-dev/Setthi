import 'package:flutter_test/flutter_test.dart';
import 'package:setthi/models/transaction_model.dart';
import 'package:setthi/services/email_transaction_parser.dart';
import 'package:setthi/services/gmail_api_service.dart';

void main() {
  late EmailTransactionParser parser;

  setUp(() {
    parser = EmailTransactionParser();
  });

  group('EmailTransactionParser - Credit Card Transactions', () {
    test('extracts HDFC credit card transaction correctly', () {
      final hdfcEmail = GmailRawMessage(
        id: 'msg_hdfc_01',
        threadId: 'thread_01',
        from: 'alerts@hdfcbank.net',
        subject: 'Alert: Update on your HDFC Bank Credit Card',
        date: DateTime(2024, 10, 24, 20, 15, 30),
        bodyText:
            'Dear Cardmember, INR 1,499.00 was spent on your HDFC Bank Credit Card ending 4321 at SWIGGY on 24-OCT-2024 at 20:15:30. Available limit: INR 85,000.00.',
        internalDateEpochMs: 1729780000000,
      );

      final result = parser.parseMessage(hdfcEmail);
      expect(result.transaction, isNotNull);

      final tx = result.transaction!;
      expect(tx.amount, 1499.00);
      expect(tx.currency, 'INR');
      expect(tx.cardLast4, '4321');
      expect(tx.bankOrIssuer, 'HDFC Bank');
      expect(tx.merchantName, 'SWIGGY');
      expect(tx.type, TransactionType.debit);

      final bankTx = tx.toBankTransaction();
      expect(bankTx.txnId, 'gmail_msg_hdfc_01');
      expect(bankTx.mode, 'CREDIT_CARD');
      expect(bankTx.amount, 1499.00);
      expect(bankTx.type, TransactionType.debit);
    });

    test('extracts ICICI credit card transaction correctly', () {
      final iciciEmail = GmailRawMessage(
        id: 'msg_icici_02',
        threadId: 'thread_02',
        from: 'credit_cards@icicibank.com',
        subject: 'Transaction Alert: ICICI Bank Credit Card',
        date: DateTime(2024, 10, 20, 14, 30),
        bodyText:
            'Your ICICI Bank Credit Card ending XX1089 has been debited for Rs 3,250.00 on 20-OCT-2024 towards AMAZON INDIA.',
        internalDateEpochMs: 1729434000000,
      );

      final result = parser.parseMessage(iciciEmail);
      expect(result.transaction, isNotNull);

      final tx = result.transaction!;
      expect(tx.amount, 3250.00);
      expect(tx.cardLast4, '1089');
      expect(tx.bankOrIssuer, 'ICICI Bank');
      expect(tx.merchantName, 'AMAZON INDIA');
      expect(tx.type, TransactionType.debit);
    });

    test('extracts Axis credit card transaction correctly', () {
      final axisEmail = GmailRawMessage(
        id: 'msg_axis_03',
        threadId: 'thread_03',
        from: 'alerts@axisbank.com',
        subject: 'Transaction Alert for your Axis Bank Credit Card',
        date: DateTime(2024, 10, 22, 10, 0),
        bodyText:
            'Transaction alert: Your Axis Bank Credit Card ending in 9876 was used for a transaction of Rs. 849.00 at ZOMATO on 22-10-2024.',
        internalDateEpochMs: 1729600000000,
      );

      final result = parser.parseMessage(axisEmail);
      expect(result.transaction, isNotNull);

      final tx = result.transaction!;
      expect(tx.amount, 849.00);
      expect(tx.cardLast4, '9876');
      expect(tx.bankOrIssuer, 'Axis Bank');
      expect(tx.merchantName, 'ZOMATO');
    });
  });

  group('EmailTransactionParser - Subscriptions', () {
    test('extracts Netflix monthly renewal subscription', () {
      final netflixEmail = GmailRawMessage(
        id: 'msg_netflix_04',
        threadId: 'thread_04',
        from: 'info@mailer.netflix.com',
        subject: 'Your Netflix invoice',
        date: DateTime(2024, 10, 18),
        bodyText:
            'Your Netflix membership has renewed for Rs. 649.00. Payment method: Credit card ending in 4321 on October 18.',
        internalDateEpochMs: 1729250000000,
      );

      final result = parser.parseMessage(netflixEmail);
      expect(result.subscription, isNotNull);

      final sub = result.subscription!;
      expect(sub.serviceName, 'Netflix');
      expect(sub.expectedAmount, 649.00);
      expect(sub.frequency, 'MONTHLY');
      expect(sub.typicalDueDay, 18);
    });

    test('extracts Spotify subscription renewal', () {
      final spotifyEmail = GmailRawMessage(
        id: 'msg_spotify_05',
        threadId: 'thread_05',
        from: 'no-reply@spotify.com',
        subject: 'Your Spotify Premium receipt',
        date: DateTime(2024, 10, 15),
        bodyText:
            'Thanks for subscribing to Spotify Premium! Amount charged: ₹119.00 on 15 Oct 2024.',
        internalDateEpochMs: 1728990000000,
      );

      final result = parser.parseMessage(spotifyEmail);
      expect(result.subscription, isNotNull);

      final sub = result.subscription!;
      expect(sub.serviceName, 'Spotify');
      expect(sub.expectedAmount, 119.00);
      expect(sub.frequency, 'MONTHLY');
      expect(sub.typicalDueDay, 15);
    });
  });

  group('EmailTransactionParser - Noise Filtering', () {
    test('disqualifies OTP and verification codes', () {
      final otpEmail = GmailRawMessage(
        id: 'msg_otp_06',
        threadId: 'thread_06',
        from: 'alerts@hdfcbank.net',
        subject: 'One Time Password (OTP) for your transaction',
        date: DateTime(2024, 10, 24),
        bodyText:
            'Your OTP for transaction of INR 2,500.00 at Flipkart is 839201. OTP is valid for 10 minutes. Do not share with anyone.',
        internalDateEpochMs: 1729780000000,
      );

      final result = parser.parseMessage(otpEmail);
      expect(result.transaction, isNull);
      expect(result.subscription, isNull);
    });

    test('disqualifies failed or declined transactions', () {
      final failedEmail = GmailRawMessage(
        id: 'msg_failed_07',
        threadId: 'thread_07',
        from: 'alerts@hdfcbank.net',
        subject: 'Declined: Transaction on HDFC Bank Credit Card',
        date: DateTime(2024, 10, 24),
        bodyText:
            'Your transaction of Rs. 5000.00 at Shoppers Stop was declined due to insufficient limit.',
        internalDateEpochMs: 1729780000000,
      );

      final result = parser.parseMessage(failedEmail);
      expect(result.transaction, isNull);
      expect(result.subscription, isNull);
    });

    test('extracts credit card statement email as a first-class statement record', () {
      final statementEmail = GmailRawMessage(
        id: '1a172cb6e60bbd4d',
        threadId: 't_stmt',
        from: 'Pawan P R 0179 <prpawan04@gmail.com>',
        subject: 'Fwd: Your slice credit card statement for October 2026 is ready📄',
        date: DateTime(2026, 10, 25, 16, 51, 23),
        bodyText:
            '---------- Forwarded message --------- From: slice <noreply@slice.bank.in> Date: Wed, 21 Oct, 2026 Subject: Your slice credit card statement for October 2026 is ready Total Amount Due: ₹42,440.46 Minimum Amount Due: ₹2,122.00 Charges include LinkedIn Premium ₹1,499.00',
        internalDateEpochMs: DateTime(2026, 10, 25, 16, 51, 23).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(statementEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.isStatement, isTrue);
      expect(diag.transaction!.statementTotalDue, 42440.46);
      expect(diag.transaction!.statementMinDue, 2122.0);
    });

    test('extracts forwarded bank credit card alert with personal forwarder address', () {
      final fwdBankEmail = GmailRawMessage(
        id: 'fwd_hdfc_99',
        threadId: 't_fwd',
        from: 'Personal User <setthi2003@gmail.com>',
        subject: 'Fwd: Alert: Transaction on your HDFC Bank Credit Card',
        date: DateTime(2026, 10, 26, 10, 0),
        bodyText: '''
---------- Forwarded message ---------
From: alerts@hdfcbank.net
Date: Mon, 26 Oct 2026 09:30:00 +0530
Subject: Alert: Transaction on your HDFC Bank Credit Card
To: setthi2003@gmail.com

Dear Customer, INR 2,499.00 has been debited on your HDFC Bank Credit Card ending 1234 at AMAZON INDIA on 26-OCT-2026.
''',
        internalDateEpochMs: DateTime(2026, 10, 26, 10, 0).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(fwdBankEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.detectedIssuer, 'HDFC Bank');
      expect(diag.detectedMerchant, 'AMAZON INDIA');
      expect(diag.detectedAmount, 2499.00);
      expect(diag.detectedCardLast4, '1234');
      expect(diag.detectedPaymentMode, 'CREDIT_CARD');
    });

    test('extracts Airtel Mobile bill statement with PDF attachment as a bill statement', () {
      final airtelBillEmail = GmailRawMessage(
        id: 'airtel_bill_01',
        threadId: 't_airtel_bill',
        from: 'P Venkata Ramana Re. <pvramana@gmail.com>',
        subject: "Fwd: Bill for your Airtel Mobile 98451XXXXX - October'26",
        date: DateTime(2026, 10, 26, 12, 0),
        bodyText: '''
---------- Forwarded message ---------
From: Airtel <ebill@airtel.com>
Date: Mon, 26 Oct 2026 11:30:00 +0530
Subject: Bill for your Airtel Mobile 98451XXXXX - October'26

Dear Customer, Your mobile bill for 98451XXXXX is ready.
Total Amount Due: ₹749.00
Payment Due Date: 12 Nov 2026
Bill Period: 20 Sep 2026 to 19 Oct 2026
Please find attached your bill statement.
''',
        internalDateEpochMs: DateTime(2026, 10, 26, 12, 0).millisecondsSinceEpoch,
        attachments: const [
          GmailAttachmentInfo(
            attachmentId: 'att_airtel_pdf',
            filename: '1388227983_96.pdf',
            mimeType: 'application/pdf',
            size: 154000,
          ),
        ],
      );

      final diag = parser.parseMessageWithDiagnostics(airtelBillEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.isStatement, isTrue);
      expect(diag.transaction!.merchantName, 'Airtel');
      expect(diag.transaction!.category, 'Bills & Utilities');
      expect(diag.transaction!.statementTotalDue, 749.00);
    });

    test('extracts Airtel payment confirmation as a recurring utility commitment', () {
      final airtelPaymentEmail = GmailRawMessage(
        id: 'airtel_pay_02',
        threadId: 't_airtel_pay',
        from: 'Pawan PR <prpawan03@gmail.com>',
        subject: 'Fwd: Payment confirmation for your Airtel account',
        date: DateTime(2026, 10, 26, 14, 0),
        bodyText: '''
---------- Forwarded message ---------
From: Airtel <update@airtel.in>
Date: Wed, 7 Oct, 2026, 16:50
Subject: Payment confirmation for your Airtel account
To: <PRPAWAN03@gmail.com>

airtel business
Dear Pawan ,
Greetings from Airtel!
We acknowledge the receipt of your payment of Rs. 513.53 via Transaction ID 7513515566557560832 towards your Airtel account. The same will be posted in your account within 2 hrs.

Payment Method: QR_CODE
Amount Paid: Rs. 513.53
Transaction Date: 07/10/2026
''',
        internalDateEpochMs: DateTime(2026, 10, 26, 14, 0).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(airtelPaymentEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.subscription, isNotNull);
      expect(diag.subscription!.serviceName, 'Airtel');
      expect(diag.subscription!.expectedAmount, 513.53);
      expect(diag.subscription!.category, 'Bills & Utilities');
      expect(diag.subscription!.frequency, 'MONTHLY');
      expect(diag.detectedPaymentMode, 'UPI');
    });

    test('extracts GRT Jewellers JPS advance payment plan as a recurring savings scheme', () {
      final grtEmail = GmailRawMessage(
        id: 'grt_jps_03',
        threadId: 't_grt_jps',
        from: 'Kavitha Ks <kskavitha0133@gmail.com>',
        subject: 'Fwd: GRT JPS Advance payment',
        date: DateTime(2026, 10, 26, 15, 0),
        bodyText: '''
---------- Forwarded message ---------
From: Customer Care <mail@grtjewels.com>
Date: Mon, 17 Aug, 2026, 10:42
Subject: GRT JPS Advance payment
To: <KSKAVITHA0133@gmail.com>

Hi P Venkata Ramana Reddy,
Thanks for making advance payment for your jewellery purchase plan.
It will reflect in your ledger shortly.

Here's a quick preview of your Jewellery Purchase Plan:
Name : P Venkata Ramana Reddy,
Membership Number : 5450,
Group Code : EHD,
Branch : GBH,
Scheme Amount : 5000.
''',
        internalDateEpochMs: DateTime(2026, 10, 26, 15, 0).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(grtEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.subscription, isNotNull);
      expect(diag.subscription!.serviceName, 'GRT Jewellers (JPS)');
      expect(diag.subscription!.expectedAmount, 5000.00);
      expect(diag.subscription!.category, 'Savings & Schemes');
      expect(diag.subscription!.frequency, 'MONTHLY');
    });

    test('correctly identifies LinkedIn non-billed trial expiration alert as noise', () {
      final linkedinTrialEmail = GmailRawMessage(
        id: 'linkedin_trial_04',
        threadId: 't_linkedin',
        from: 'Pawan PR <prpawan03@gmail.com>',
        subject: 'Fwd: Your trial for LinkedIn: Community & Network will end on 4 Sept 2026',
        date: DateTime(2026, 10, 26, 16, 0),
        bodyText: '''
---------- Forwarded message ---------
From: LinkedIn <messages-noreply@linkedin.com>
Subject: Your trial for LinkedIn: Community & Network will end on 4 Sept 2026

Your free trial will end soon. If you decide to cancel, you will not be charged.
''',
        internalDateEpochMs: DateTime(2026, 10, 26, 16, 0).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(linkedinTrialEmail);
      expect(diag.isNoise, isTrue);
      expect(diag.transaction, isNull);
      expect(diag.subscription, isNull);
    });

    test('excludes savings bank account statement with interest earned from credit statements', () {
      final savingsStmtEmail = GmailRawMessage(
        id: '1a0fdeeebbd5944f',
        threadId: 't_savings',
        from: 'slice <noreply@slice.bank.in>',
        subject: 'Your savings bank account statement for September 2026 is here',
        date: DateTime(2026, 10, 3, 0, 14, 0),
        bodyText:
            'Hi SANTOSH, Your savings bank account statement for September 2026 is here. A simple snapshot of how your money moved, and how it grew. This month, you earned ₹57.02 in interest. A small step, but it adds up. Your file is password protected.',
        internalDateEpochMs: DateTime(2026, 10, 3, 0, 14, 0).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(savingsStmtEmail);
      // Must not be flagged as a credit card statement or transaction
      expect(diag.transaction, isNull);
    });

    test('extracts exact Slice credit card statement with due date 5 Nov 26 and minimum due', () {
      final sliceCardStmt = GmailRawMessage(
        id: '1a172cb6e60bbd4d',
        threadId: 't_slice_stmt',
        from: 'slice <noreply@slice.bank.in>',
        subject: 'Your slice credit card statement for October 2026 is ready!',
        date: DateTime(2026, 10, 25, 11, 21, 23),
        bodyText:
            "Hey P R, Your slice credit card statement for October 2026 is ready! You can find the full statement attached below. Statement snapshot: • Total amount due: ₹42,440.46 • Minimum due: ₹2,122.02 • Due date: 5 Nov '26 Make your payment anytime through the slice app",
        internalDateEpochMs: DateTime(2026, 10, 25, 11, 21, 23).millisecondsSinceEpoch,
        attachments: const [
          GmailAttachmentInfo(
            attachmentId: 'att_slice_pdf',
            filename: "slice P R's October 2026 statement.pdf",
            mimeType: 'application/pdf',
            size: 345000,
          ),
        ],
      );

      final diag = parser.parseMessageWithDiagnostics(sliceCardStmt);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.isStatement, isTrue);
      expect(diag.transaction!.statementTotalDue, 42440.46);
      expect(diag.transaction!.statementMinDue, 2122.02);
      expect(diag.transaction!.statementDueDate, DateTime(2026, 11, 5));
    });

    test('disqualifies promotional marketing bank card discount offers', () {
      final promoEmail = GmailRawMessage(
        id: '1a0368556a469fe1',
        threadId: 't_promo',
        from: 'Google Store <googlestore-noreply@google.com>',
        subject: 'Your exclusive Google Pixel 11 series offers end soon',
        date: DateTime(2026, 8, 25, 6, 55, 02),
        bodyText:
            "Don't miss out on your special offers. Instant discount of ₹10,000 on HDFC Bank cards when you pre-order now. Tell other users.",
        internalDateEpochMs: DateTime(2026, 8, 25, 6, 55, 02).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(promoEmail);
      expect(diag.isNoise, isTrue);
      expect(diag.transaction, isNull);
      expect(diag.subscription, isNull);
    });

    test('disqualifies bank charge / non-maintenance fee intimations as noise', () {
      final feeIntimation = GmailRawMessage(
        id: '1a153fa27000263e',
        threadId: 't_fee',
        from: 'bankalerts@kotak.bank.in',
        subject: 'Important information regarding your Kotak Account',
        date: DateTime(2026, 10, 19, 17, 13, 40),
        bodyText:
            'Dear Customer , We wish to inform you that the Non Maintenance Charge (NMC) for Sep 2026, of Rs.587.66 will be debited from your Account XXXXXX7533.',
        internalDateEpochMs: DateTime(2026, 10, 19, 17, 13, 40).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(feeIntimation);
      expect(diag.isNoise, isTrue);
      expect(diag.noiseReason, contains('Bank Fee / Charge Intimation'));
      expect(diag.transaction, isNull);
    });

    test('extracts true merchant name from Slice Bank UPI narration', () {
      final sliceEmail = GmailRawMessage(
        id: '1a13085bc03f139b',
        threadId: 't_slice_upi',
        from: 'slice <noreply@slice.bank.in>',
        subject: '₹20 debited from your slice account',
        date: DateTime(2026, 10, 12, 20, 00, 32),
        bodyText:
            'Hi SANTOSH, ₹20 debited from your slice bank account xx4720 via UPI. Transaction date 12-Oct-26 To NEW BIGG BASKET SHO RRN 628580608304 Best, Team slice',
        internalDateEpochMs: DateTime(2026, 10, 12, 20, 00, 32).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(sliceEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.amount, 20.0);
      expect(diag.transaction!.merchantName, 'NEW BIGG BASKET SHO');
      expect(diag.transaction!.cardLast4, '4720');
      expect(diag.detectedIssuer, 'Slice Bank');
    });

    test('extracts sender name from Kotak Bank credit alert and ignores footer disclaimer', () {
      final creditAlert = GmailRawMessage(
        id: '1a1387299a833843',
        threadId: 't_credit_alert',
        from: 'bankalerts@kotak.bank.in',
        subject: 'Credit Alert',
        date: DateTime(2026, 10, 14, 8, 56, 33),
        bodyText:
            'Dear Customer, Your account has been credited with 5000.00 Details: Your Account number: XXXXXX7533 Sender Name: JAYADEV PATIL Sender Account number: XXXXXXXX8318 Amount: Rs. 5000.00 Please do not reply at this message or mail address.',
        internalDateEpochMs: DateTime(2026, 10, 14, 8, 56, 33).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(creditAlert);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.amount, 5000.0);
      expect(diag.transaction!.type, TransactionType.credit);
      expect(diag.transaction!.merchantName, 'JAYADEV PATIL');
      expect(diag.detectedIssuer, 'Kotak Bank');
      expect(diag.transaction!.paymentMode, 'ACCOUNT_TRANSFER');
    });

    test('extracts PlayStation merchant even when bank card is mentioned on invoice', () {
      final psEmail = GmailRawMessage(
        id: '1a0e14fb4291adcf',
        threadId: 't_ps',
        from: 'PlayStation <sony@txn-email03.playstation.com>',
        subject: 'Thank You For Your Purchase',
        date: DateTime(2026, 9, 27, 10, 51, 31),
        bodyText:
            "Thank You For Your Purchase. Your PlayStation Store transaction was successful. Total: Rs. 2499.00. Payment method: RBL Bank Card ending 7811. Sony Interactive Entertainment Europe, 10 Great Marlborough Street.",
        internalDateEpochMs: DateTime(2026, 9, 27, 10, 51, 31).millisecondsSinceEpoch,
      );

      final diag = parser.parseMessageWithDiagnostics(psEmail);
      expect(diag.isNoise, isFalse);
      expect(diag.transaction, isNotNull);
      expect(diag.transaction!.merchantName, 'PlayStation');
      expect(diag.transaction!.amount, 2499.0);
      expect(diag.transaction!.cardLast4, '7811');
      expect(diag.detectedIssuer, 'RBL Bank');
      expect(diag.transaction!.paymentMode, 'CARD');
    });

    test('distinguishes DEBIT_CARD from CREDIT_CARD and UPI accurately', () {
      final kotakDebitEmail = GmailRawMessage(
        id: 'msg_kotak_debit',
        threadId: 't_kotak_debit',
        from: 'KOTAK BANK <bankalerts@kotak.bank.in>',
        subject: 'Transaction Success Alert  MOTO/SI on Card Transaction.',
        date: DateTime(2026, 10, 23, 22, 13, 34),
        bodyText:
            'Dear Customer, Your transaction of Rs.199.00 on 23/10/2026 22:13:28 using your Kotak Bank Debit Card XX7811 has been processed basis your standing instruction.',
        internalDateEpochMs: DateTime(2026, 10, 23, 22, 13, 34).millisecondsSinceEpoch,
      );

      final diagDebit = parser.parseMessageWithDiagnostics(kotakDebitEmail);
      expect(diagDebit.transaction, isNotNull);
      expect(diagDebit.transaction!.paymentMode, 'DEBIT_CARD');
      expect(diagDebit.transaction!.toBankTransaction().mode, 'DEBIT_CARD');

      final sliceUpiEmail = GmailRawMessage(
        id: 'msg_slice_upi',
        threadId: 't_slice_upi',
        from: 'slice <noreply@slice.bank.in>',
        subject: '₹20 debited from your slice account',
        date: DateTime(2026, 10, 12, 20, 00, 32),
        bodyText:
            'Hi SANTOSH, ₹20 debited from your slice bank account xx4720 via UPI. Transaction date 12-Oct-26 To NEW BIGG BASKET SHO RRN 628580608304',
        internalDateEpochMs: DateTime(2026, 10, 12, 20, 00, 32).millisecondsSinceEpoch,
      );

      final diagUpi = parser.parseMessageWithDiagnostics(sliceUpiEmail);
      expect(diagUpi.transaction, isNotNull);
      expect(diagUpi.transaction!.paymentMode, 'UPI');
      expect(diagUpi.transaction!.toBankTransaction().mode, 'UPI');

      final uberCashEmail = GmailRawMessage(
        id: 'msg_uber_cash',
        threadId: 't_uber_cash',
        from: 'Uber Receipts <noreply@uber.com>',
        subject: 'Your Friday evening trip with Uber',
        date: DateTime(2026, 9, 25, 19, 46, 24),
        bodyText:
            'Thanks for riding, Santosh. Total ₹87.21 Payments Cash ₹87.21',
        internalDateEpochMs: DateTime(2026, 9, 25, 19, 46, 24).millisecondsSinceEpoch,
      );

      final diagCash = parser.parseMessageWithDiagnostics(uberCashEmail);
      expect(diagCash.transaction, isNotNull);
      expect(diagCash.transaction!.paymentMode, 'CASH');
      expect(diagCash.transaction!.toBankTransaction().mode, 'CASH');
    });
  });
}
