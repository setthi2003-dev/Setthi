import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/setu_config.dart';
import '../config/supabase_config.dart';
import '../models/transaction_model.dart';
import 'supabase_db_service.dart';

/// Custom exception for Setu Account Aggregator API errors
class SetuApiException implements Exception {
  final String message;
  final int? statusCode;
  final dynamic responseBody;

  SetuApiException(this.message, {this.statusCode, this.responseBody});

  @override
  String toString() => 'SetuApiException: $message (HTTP ${statusCode ?? 'N/A'})';
}

/// Thrown when attempting to fetch transactions without an approved consent
class SetuNoConsentException implements Exception {
  final String message;
  SetuNoConsentException([this.message = 'No active Account Aggregator consent found.']);

  @override
  String toString() => 'SetuNoConsentException: $message';
}

/// Thrown when an Account Aggregator consent has expired or reached maximum allowed usages
class SetuConsentExpiredException extends SetuApiException {
  SetuConsentExpiredException(
    super.message, {
    super.statusCode,
    super.responseBody,
  });

  @override
  String toString() => 'SetuConsentExpiredException: $message';
}

/// Client-side handler for Setu Account Aggregator Gateway consent flows
class SetuAaService {
  static String? lastCreatedConsentId;

  /// Stores the exact data range used when creating the consent, so we can
  /// reuse it for the data session without relying on JSON-path guesswork.
  static Map<String, String>? lastCreatedConsentDataRange;

  final http.Client _client;
  final SupabaseDbService? dbService;
  String? activeConsentId;

  SetuAaService({
    http.Client? client,
    this.dbService,
    this.activeConsentId,
  }) : _client = client ?? http.Client();

  /// 1. Create Consent: POST /consents
  /// Initiates an Account Aggregator consent request with Setu ReBIT specification.
  /// If Supabase is configured, retrieves API credentials securely from Supabase Vault via Edge Function.
  Future<Map<String, String>> createConsent({required String mobileNumber}) async {
    final db = dbService;
    if (db != null && SupabaseConfig.isConfigured) {
      final result = await db.createConsentViaBackend(mobileNumber: mobileNumber);
      lastCreatedConsentId = result['consentId'];
      return result;
    }

    final uri = Uri.parse('${SetuConfig.baseUrl}/v2/consents');

    var cleanPhone = mobileNumber.replaceAll(RegExp(r'\D'), '');
    if (cleanPhone.length == 12 && cleanPhone.startsWith('91')) {
      cleanPhone = cleanPhone.substring(2);
    }
    final vua = cleanPhone.contains('@') ? cleanPhone : '$cleanPhone@onemoney';

    final now = DateTime.now().toUtc();
    // Use 2020-01-01 start to cover historical records & Setu UAT/sandbox mock transactions (2021-2024)
    const fromDate = '2020-01-01T00:00:00Z';
    final toDate = now.toIso8601String();

    final body = jsonEncode({
      'consentDuration': {'unit': 'MONTH', 'value': '3'},
      'vua': vua,
      'dataRange': {
        'from': fromDate,
        'to': toDate,
      },
      'consentMode': 'STORE',
      'consentTypes': ['TRANSACTIONS', 'SUMMARY', 'PROFILE'],
      'fetchType': 'ONETIME',
      'redirectUrl': SetuConfig.redirectUrl,
    });

    final response = await _client.post(
      uri,
      headers: SetuConfig.authHeaders,
      body: body,
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final consentId = data['id']?.toString() ?? '';
      final url = data['url']?.toString() ?? '';

      if (consentId.isEmpty || url.isEmpty) {
        throw SetuApiException(
          'Malformed consent response from Setu: missing id or url',
          statusCode: response.statusCode,
          responseBody: data,
        );
      }

      lastCreatedConsentId = consentId;
      lastCreatedConsentDataRange = {'from': fromDate, 'to': toDate};

      return {
        'consentId': consentId,
        'url': url,
      };
    } else {
      throw SetuApiException(
        'Failed to create consent with Setu AA Gateway: ${response.body}',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }
  }

  /// 2. Check Consent Status: GET /consents/:id
  /// Returns status: "PENDING", "ACTIVE", "REJECTED", "EXPIRED", etc.
  /// If Supabase is configured, queries Setu via Supabase Vault Edge Function.
  Future<String> checkConsentStatus(String consentId) async {
    final db = dbService;
    if (db != null && SupabaseConfig.isConfigured) {
      return db.checkConsentStatusViaBackend(consentId: consentId);
    }

    final uri = Uri.parse('${SetuConfig.baseUrl}/v2/consents/$consentId');

    final response = await _client.get(
      uri,
      headers: SetuConfig.authHeaders,
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      return (data['status']?.toString() ?? 'PENDING').toUpperCase();
    } else {
      throw SetuApiException(
        'Failed to fetch consent status: ${response.body}',
        statusCode: response.statusCode,
        responseBody: response.body,
      );
    }
  }

  /// Extracts and parses ReBIT deposit transactions from Setu's decrypted JSON
  static List<BankTransaction> parseRebitPayload(Map<String, dynamic> json) {
    final List<BankTransaction> results = [];

    // Collect all candidate top-level data lists: 'fips', 'payload', 'fipData', 'data'
    final List<dynamic> topLevelItems = [];
    if (json['fips'] is List) {
      topLevelItems.addAll(json['fips'] as List);
    }
    if (json['payload'] is List) {
      topLevelItems.addAll(json['payload'] as List);
    }
    if (json['fipData'] is List) {
      topLevelItems.addAll(json['fipData'] as List);
    }
    if (json['data'] is List) {
      topLevelItems.addAll(json['data'] as List);
    }
    if (topLevelItems.isEmpty) {
      topLevelItems.add(json);
    }

    for (final p in topLevelItems) {
      if (p is! Map<String, dynamic>) continue;

      // In Setu AA V2, fips contains 'accounts', or p may have 'data'
      final List<dynamic> accountNodes = [];
      if (p['accounts'] is List) {
        accountNodes.addAll(p['accounts'] as List);
      } else if (p['data'] is List) {
        accountNodes.addAll(p['data'] as List);
      } else {
        accountNodes.add(p);
      }

      for (final d in accountNodes) {
        if (d is! Map<String, dynamic>) continue;

        // In Setu AA V2, the account payload is nested under d['data'] or d['decrypted'] or d directly
        final dynamic rawData = d['data'] ?? d['decrypted'] ?? d;
        final Map<String, dynamic> dataMap =
            (rawData is Map<String, dynamic>) ? rawData : d;

        final account = (dataMap['account'] is Map<String, dynamic>)
            ? (dataMap['account'] as Map<String, dynamic>)
            : (dataMap['Account'] is Map<String, dynamic>)
                ? (dataMap['Account'] as Map<String, dynamic>)
                : (d['account'] is Map<String, dynamic>)
                    ? (d['account'] as Map<String, dynamic>)
                    : (d['Account'] is Map<String, dynamic>)
                        ? (d['Account'] as Map<String, dynamic>)
                        : dataMap;

        // Extract account summary balance if present
        double? summaryBalance;
        final summaryObj = account['summary'] ?? account['Summary'];
        if (summaryObj is Map<String, dynamic>) {
          final balVal = summaryObj['currentBalance'] ??
              summaryObj['CurrentBalance'] ??
              summaryObj['balance'] ??
              summaryObj['Balance'];
          if (balVal != null) {
            final cleaned =
                balVal.toString().replaceAll(RegExp(r'[^\d.-]'), '');
            summaryBalance = double.tryParse(cleaned);
          }
        }

        // Extract transactions list
        final txnsObj = account['transactions'] ??
            account['Transactions'] ??
            account['txns'] ??
            account['Txns'];

        List<dynamic>? rawTxns;
        if (txnsObj is Map<String, dynamic>) {
          rawTxns = (txnsObj['transaction'] ??
                  txnsObj['Transaction'] ??
                  txnsObj['txns'] ??
                  txnsObj['Txns'] ??
                  txnsObj['item'] ??
                  txnsObj['items']) as List<dynamic>?;
        } else if (txnsObj is List<dynamic>) {
          rawTxns = txnsObj;
        }

        if (rawTxns != null) {
          for (final raw in rawTxns) {
            if (raw is Map<String, dynamic>) {
              try {
                results.add(
                  BankTransaction.fromJson(
                    raw,
                    fallbackBalance: summaryBalance,
                  ),
                );
              } catch (_) {
                // Ignore single malformed transaction if any
              }
            }
          }
        }
      }
    }

    // Sort newest first
    results.sort(
      (a, b) => b.transactionTimestamp.compareTo(a.transactionTimestamp),
    );

    debugPrint('[Setu AA] Successfully parsed ${results.length} bank transactions!');
    return results;
  }
}
