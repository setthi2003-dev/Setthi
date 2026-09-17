import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/setu_config.dart';
import '../models/transaction_model.dart';
import 'fi_data_service.dart';

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

/// Production & Sandbox implementation of Setu Account Aggregator Gateway
class SetuAaService implements TransactionRepository {
  static String? lastCreatedConsentId;
  final http.Client _client;
  String? activeConsentId;

  SetuAaService({
    http.Client? client,
    this.activeConsentId,
  }) : _client = client ?? http.Client();

  /// 1. Create Consent: POST /consents
  /// Initiates an Account Aggregator consent request with Setu ReBIT specification.
  Future<Map<String, String>> createConsent({required String mobileNumber}) async {
    final uri = Uri.parse('${SetuConfig.baseUrl}/v2/consents');

    final cleanPhone = mobileNumber.replaceAll(RegExp(r'\D'), '');
    final vua = cleanPhone.contains('@') ? cleanPhone : '$cleanPhone@onemoney';

    final now = DateTime.now().toUtc();
    final fromDate = '2020-01-01T00:00:00Z';
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
  Future<String> checkConsentStatus(String consentId) async {
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

  /// 3. Create Data Session: POST /sessions
  /// Creates an encrypted data session using an approved consent ID.
  Future<String> createDataSession(String consentId) async {
    final uri = Uri.parse('${SetuConfig.baseUrl}/v2/sessions');

    // Inspect the approved consent's allowed dataRange to ensure full compatibility
    Map<String, String> dataRange = {
      'from': '2020-01-01T00:00:00.000Z',
      'to': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final consentUri =
          Uri.parse('${SetuConfig.baseUrl}/v2/consents/$consentId');
      final cRes =
          await _client.get(consentUri, headers: SetuConfig.authHeaders);
      if (cRes.statusCode >= 200 && cRes.statusCode < 300) {
        final cJson = jsonDecode(cRes.body) as Map<String, dynamic>;
        final detail = cJson['detail'] as Map<String, dynamic>?;
        final cRange = detail?['dataRange'] as Map<String, dynamic>?;
        if (cRange != null && cRange['from'] != null && cRange['to'] != null) {
          dataRange = {
            'from': cRange['from'].toString(),
            'to': cRange['to'].toString(),
          };
        }
      }
    } catch (_) {}

    // Candidate date ranges to ensure compatibility with both historical (2021-2024) and recent consents
    final candidateRanges = [
      dataRange,
      {
        'from': '2021-01-01T00:00:00.000Z',
        'to': '2024-12-31T23:59:59.000Z',
      },
      {
        'from': '2020-01-01T00:00:00.000Z',
        'to': '2024-12-31T23:59:59.000Z',
      },
    ];

    String lastError = 'Failed to create data session';

    for (final range in candidateRanges) {
      final body = jsonEncode({
        'consentId': consentId,
        'dataRange': range,
        'format': 'json',
      });

      const maxSessionRetries = 4;
      for (int attempt = 1; attempt <= maxSessionRetries; attempt++) {
        debugPrint(
          '[Setu AA] Creating data session for $consentId (${range['from']} to ${range['to']}, attempt $attempt)...',
        );
        final response = await _client.post(
          uri,
          headers: SetuConfig.authHeaders,
          body: body,
        );

        debugPrint(
          '[Setu AA] Data session response ($attempt): ${response.statusCode} -> ${response.body}',
        );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final sessionId = data['id']?.toString() ?? '';
          if (sessionId.isNotEmpty) {
            return sessionId;
          }
        }

        lastError = response.body;

        // If range mismatch, break out immediately to try next range
        if (response.body.contains('not within the consent') ||
            response.body.contains('FIDataRange')) {
          debugPrint(
            '[Setu AA] Date range was outside consent FIDataRange. Trying fallback range...',
          );
          break;
        }

        // If "Consent artefact not ready" or "PENDING", wait and retry
        if (response.body.contains('not ready') ||
            response.body.contains('PENDING')) {
          if (attempt < maxSessionRetries) {
            debugPrint(
              '[Setu AA] Consent artefact not ready yet. Waiting 2s before retry...',
            );
            await Future.delayed(const Duration(milliseconds: 2000));
            continue;
          }
        }

        break;
      }
    }

    throw SetuApiException('Failed to create data session: $lastError');
  }

  /// 4. Fetch Decrypted FI Data: GET /sessions/:id
  /// Polls the data session until completed and parses ReBIT deposit transactions.
  Future<List<BankTransaction>> fetchSessionData(String sessionId) async {
    final uri = Uri.parse('${SetuConfig.baseUrl}/v2/sessions/$sessionId');

    const maxRetries = 10;
    const retryDelay = Duration(milliseconds: 2500);

    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      debugPrint(
        '[Setu AA] Polling data session $sessionId (attempt $attempt/$maxRetries)...',
      );
      final response = await _client.get(
        uri,
        headers: SetuConfig.authHeaders,
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw SetuApiException(
          'Failed to retrieve session data on attempt $attempt: ${response.body}',
          statusCode: response.statusCode,
          responseBody: response.body,
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final status = (json['status']?.toString() ?? '').toUpperCase();
      debugPrint('[Setu AA] Data session $sessionId status: $status');

      if (status == 'COMPLETED' || status == 'PARTIAL') {
        debugPrint('[Setu AA] Decrypted FI Data received!');
        return parseRebitPayload(json);
      } else if (status == 'FAILED') {
        throw SetuApiException(
          'Setu AA data fetch session failed with status FAILED',
          statusCode: response.statusCode,
          responseBody: json,
        );
      }

      // If PENDING, wait and poll again
      if (attempt < maxRetries) {
        await Future.delayed(retryDelay);
      }
    }

    throw SetuApiException(
      'Setu data session polling timed out after $maxRetries attempts.',
    );
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

  Future<List<BankTransaction>>? _inFlightFetch;

  /// Implementation of [TransactionRepository]
  @override
  Future<List<BankTransaction>> fetchTransactions() {
    final inFlight = _inFlightFetch;
    if (inFlight != null) {
      debugPrint('[Setu AA] Sharing in-flight fetchTransactions call.');
      return inFlight;
    }

    final future = _executeFetchTransactions();
    _inFlightFetch = future;
    return future.whenComplete(() {
      _inFlightFetch = null;
    });
  }

  Future<List<BankTransaction>> _executeFetchTransactions() async {
    final consentId = activeConsentId;
    if (consentId == null || consentId.isEmpty) {
      throw SetuNoConsentException(
        'No active Account Aggregator consent found. Please link your bank account first.',
      );
    }

    final sessionId = await createDataSession(consentId);
    return fetchSessionData(sessionId);
  }
}
