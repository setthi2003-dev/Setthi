import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'gmail_rate_limiter.dart';

/// Metadata for an email attachment (e.g. Credit Card e-Statement PDF)
class GmailAttachmentInfo {
  final String attachmentId;
  final String? directData;
  final String filename;
  final String mimeType;
  final int size;

  const GmailAttachmentInfo({
    required this.attachmentId,
    this.directData,
    required this.filename,
    required this.mimeType,
    required this.size,
  });

  bool get isPdf =>
      mimeType.toLowerCase().contains('pdf') ||
      mimeType.toLowerCase() == 'application/octet-stream' ||
      filename.toLowerCase().endsWith('.pdf') ||
      filename.toLowerCase().contains('statement');

  Map<String, dynamic> toMap() => {
        'filename': filename,
        'mime_type': mimeType,
        'size': size,
        'attachment_id': attachmentId,
        'is_pdf': isPdf,
      };
}

/// Represents a raw decoded Gmail message processed on-device,
/// optionally retaining the exact unmodified raw JSON payload returned by Gmail API.
class GmailRawMessage {
  final String id;
  final String threadId;
  final String from;
  final String subject;
  final DateTime date;
  final String bodyText;
  final int internalDateEpochMs;
  final List<GmailAttachmentInfo> attachments;
  final Map<String, dynamic>? rawApiData;

  const GmailRawMessage({
    required this.id,
    required this.threadId,
    required this.from,
    required this.subject,
    required this.date,
    required this.bodyText,
    required this.internalDateEpochMs,
    this.attachments = const [],
    this.rawApiData,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'thread_id': threadId,
        'from': from,
        'subject': subject,
        'date': date.toIso8601String(),
        'internal_date_epoch_ms': internalDateEpochMs,
        'body_text': bodyText,
        'attachments': attachments.map((a) => a.toMap()).toList(),
        if (rawApiData != null) 'raw_api_data': rawApiData,
      };
}

/// Lightweight on-device Gmail REST API client.
/// Conforms to Google Cloud API limits by integrating a centralized rate limiter.
class GmailApiService {
  static const String _baseUrl = 'https://gmail.googleapis.com/gmail/v1/users/me';
  static const int _concurrentBatchSize = 10;

  final http.Client _client;
  final GmailRateLimiter _rateLimiter;

  GmailApiService({
    http.Client? client,
    GmailRateLimiter? rateLimiter,
  })  : _client = client ?? http.Client(),
        _rateLimiter = rateLimiter ?? GmailRateLimiter.instance;

  /// Fetches candidate message IDs from Gmail.
  /// When [unfiltered] is true (default: true), queries Gmail directly with NO keyword search filter,
  /// fetching all emails from the mailbox.
  Future<List<String>> searchFinancialMessageIds({
    required String accessToken,
    DateTime? afterDate,
    int maxMessages = 150,
    bool unfiltered = true,
    String? customQuery,
    String? accountEmail,
  }) async {
    final effectiveMax = maxMessages.clamp(1, 150);
    final messageIds = <String>[];
    String? pageToken;

    String? query;
    if (!unfiltered) {
      if (customQuery != null && customQuery.isNotEmpty) {
        query = customQuery;
      } else {
        query =
            r'-category:{social forums} '
            r'("credit card statement" OR "statement is ready" OR "e-statement" OR "estatement" OR '
            r'"billing statement" OR "credit statement" OR "statement for card" OR '
            r'"Bill for your" OR "e-bill" OR "ebill" OR "invoice for your account" OR "payment confirmation for your" OR '
            r'"Airtel" OR "Jio" OR "Vodafone" OR "Vi " OR "broadband bill" OR "electricity bill" OR '
            r'"jewellery purchase" OR "purchase plan" OR "scheme amount" OR "gold scheme" OR "advance payment for your" OR '
            r'"GRT" OR "Tanishq" OR "Malabar" OR "Joyalukkas" OR "Kalyan Jewellers" OR '
            r'"subscription renewal" OR "subscription renewed" OR "membership renewal" OR '
            r'"recurring payment" OR "auto-debit" OR "mandate debited" OR '
            r'"insurance premium" OR "policy renewal" OR '
            r'"Netflix" OR "Spotify" OR "Apple Services" OR "Google One" OR "YouTube Premium" OR '
            r'"ChatGPT" OR "Claude" OR "Disney+ Hotstar" OR "Amazon Prime")';

        if (afterDate != null) {
          final epochSeconds = afterDate.millisecondsSinceEpoch ~/ 1000;
          query += ' after:$epochSeconds';
        } else {
          query += ' newer_than:90d';
        }
      }
    }

    if (query != null && query.isNotEmpty) {
      debugPrint('[GmailApiService] Executing Gmail search query: "$query"');
    } else {
      debugPrint('[GmailApiService] Fetching ALL inbox messages directly with NO query filter (max: $effectiveMax)...');
    }

    try {
      while (messageIds.length < effectiveMax) {
        final batchSize = (effectiveMax - messageIds.length).clamp(1, 100);
        final queryParams = <String, String>{
          'maxResults': batchSize.toString(),
          if (query != null && query.isNotEmpty) 'q': query,
          if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
        };

        final uri = Uri.parse('$_baseUrl/messages').replace(queryParameters: queryParams);
        final response = await _rateLimiter.executeWithRetry<http.Response>(
          op: GmailApiOp.messagesList,
          accountEmail: accountEmail,
          requestAction: () => _client.get(
            uri,
            headers: {
              'Authorization': 'Bearer $accessToken',
              'Accept': 'application/json',
            },
          ),
          getStatusCode: (res) => res.statusCode,
          getResponseBody: (res) => res.body,
        );

        if (response.statusCode != 200) {
          debugPrint(
            '[GmailApiService] List/search request failed (HTTP ${response.statusCode}): ${response.body}',
          );
          break;
        }

        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final messages = data['messages'] as List<dynamic>?;

        if (messages == null || messages.isEmpty) {
          break;
        }

        for (final m in messages) {
          if (m is Map && m['id'] != null) {
            messageIds.add(m['id'].toString());
            if (messageIds.length >= effectiveMax) break;
          }
        }

        pageToken = data['nextPageToken']?.toString();
        if (pageToken == null || pageToken.isEmpty) {
          break;
        }
      }
    } catch (e, stack) {
      debugPrint('[GmailApiService] Error searching messages: $e\n$stack');
    }

    final finalIds = messageIds.take(effectiveMax).toList();
    debugPrint('[GmailApiService] Found ${finalIds.length} candidate message IDs matching search query (capped at $effectiveMax).');
    return finalIds;
  }

  /// Fetches full message contents in throttled parallel batches.
  Future<List<GmailRawMessage>> fetchMessagesInBatches({
    required String accessToken,
    required List<String> messageIds,
    String? accountEmail,
    void Function(int fetchedCount, int totalCount)? onProgress,
  }) async {
    final results = <GmailRawMessage>[];
    final targetIds = messageIds.length > 150 ? messageIds.take(150).toList() : messageIds;

    for (int i = 0; i < targetIds.length; i += _concurrentBatchSize) {
      final end = (i + _concurrentBatchSize < targetIds.length)
          ? i + _concurrentBatchSize
          : targetIds.length;
      final batchIds = targetIds.sublist(i, end);

      final futures = batchIds.map((id) => fetchMessageDetail(
            accessToken: accessToken,
            messageId: id,
            accountEmail: accountEmail,
          ));

      final batchMessages = await Future.wait(futures);
      for (final msg in batchMessages) {
        if (msg != null) {
          results.add(msg);
        }
      }

      onProgress?.call(results.length, targetIds.length);

      // Throttling delay between batches to respect Google's per-second rate limits
      if (end < targetIds.length) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }

    return results;
  }

  /// Fetches a single message with format=full and decodes its headers and body on-device.
  Future<GmailRawMessage?> fetchMessageDetail({
    required String accessToken,
    required String messageId,
    String? accountEmail,
    int retryCount = 0,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/messages/$messageId?format=full');
      final response = await _rateLimiter.executeWithRetry<http.Response>(
        op: GmailApiOp.messagesGetFull,
        accountEmail: accountEmail,
        requestAction: () => _client.get(
          uri,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Accept': 'application/json',
          },
        ),
        getStatusCode: (res) => res.statusCode,
        getResponseBody: (res) => res.body,
      );

      if (response.statusCode != 200) {
        debugPrint(
          '[GmailApiService] Failed to fetch message $messageId (HTTP ${response.statusCode}): ${response.body}',
        );
        return null;
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final id = data['id']?.toString() ?? messageId;
      final threadId = data['threadId']?.toString() ?? '';
      final internalDateStr = data['internalDate']?.toString() ?? '0';
      final internalDateMs = int.tryParse(internalDateStr) ?? 0;

      final payload = data['payload'] as Map<String, dynamic>? ?? {};
      final headers = (payload['headers'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>();

      String from = '';
      String subject = '';
      String dateHeader = '';

      for (final h in headers) {
        final name = (h['name']?.toString() ?? '').toLowerCase();
        final value = h['value']?.toString() ?? '';
        if (name == 'from') from = value;
        if (name == 'subject') subject = value;
        if (name == 'date') dateHeader = value;
      }

      DateTime date = DateTime.fromMillisecondsSinceEpoch(
        internalDateMs > 0 ? internalDateMs : DateTime.now().millisecondsSinceEpoch,
      );

      // Attempt parsing RFC-2822 date header if internalDate is missing
      if (internalDateMs == 0 && dateHeader.isNotEmpty) {
        try {
          date = DateTime.parse(dateHeader);
        } catch (_) {}
      }

      // Recursive MIME Body Extraction
      final bodyText = _extractMimeBody(payload);

      // Extract Attachment Metadata (e.g. PDF credit statements)
      final attachments = _extractAttachments(payload);

      return GmailRawMessage(
        id: id,
        threadId: threadId,
        from: from,
        subject: subject,
        date: date,
        bodyText: bodyText,
        internalDateEpochMs: internalDateMs,
        attachments: attachments,
        rawApiData: data,
      );
    } catch (e, stack) {
      debugPrint('[GmailApiService] Error fetching message $messageId: $e\n$stack');
      return null;
    }
  }

  /// Downloads raw attachment bytes for a message attachment from Gmail API (or decodes directData)
  Future<Uint8List?> downloadAttachmentBytes({
    required String accessToken,
    required String messageId,
    required String attachmentId,
    String? directData,
    String? accountEmail,
  }) async {
    if (directData != null && directData.isNotEmpty) {
      try {
        final normalized = base64Url.normalize(directData);
        return base64Url.decode(normalized);
      } catch (e) {
        debugPrint('[GmailApiService] Error decoding direct attachment data: $e');
      }
    }

    if (attachmentId.isEmpty) return null;

    try {
      final uri = Uri.parse('$_baseUrl/messages/$messageId/attachments/$attachmentId');
      final response = await _rateLimiter.executeWithRetry<http.Response>(
        op: GmailApiOp.attachmentsGet,
        accountEmail: accountEmail,
        requestAction: () => _client.get(
          uri,
          headers: {
            'Authorization': 'Bearer $accessToken',
            'Accept': 'application/json',
          },
        ),
        getStatusCode: (res) => res.statusCode,
        getResponseBody: (res) => res.body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final rawData = data['data']?.toString();
        if (rawData == null || rawData.isEmpty) return null;

        final normalized = base64Url.normalize(rawData);
        return base64Url.decode(normalized);
      }

      debugPrint(
        '[GmailApiService] Failed to download attachment $attachmentId (HTTP ${response.statusCode}): ${response.body}',
      );
      return null;
    } catch (e, stack) {
      debugPrint('[GmailApiService] Error downloading attachment $attachmentId: $e\n$stack');
      return null;
    }
  }

  /// Recursively walks MIME payload parts to discover attached files (such as statement PDFs)
  List<GmailAttachmentInfo> _extractAttachments(Map<String, dynamic> payload) {
    final attachments = <GmailAttachmentInfo>[];

    void traverseParts(Map<String, dynamic> node) {
      String resolvedFilename = node['filename']?.toString() ?? '';
      final mimeType = node['mimeType']?.toString() ?? '';
      final body = node['body'] as Map<String, dynamic>?;
      final attachmentId = body?['attachmentId']?.toString();
      final directData = body?['data']?.toString();
      final size = (body?['size'] as num?)?.toInt() ?? 0;

      if (resolvedFilename.isEmpty) {
        final nodeHeaders = node['headers'] as List<dynamic>?;
        if (nodeHeaders != null) {
          for (final h in nodeHeaders) {
            if (h is Map) {
              final name = h['name']?.toString().toLowerCase();
              final val = h['value']?.toString() ?? '';
              if (name == 'content-disposition' && val.toLowerCase().contains('filename=')) {
                final match = RegExp(r'filename=["\x27]?([^"\x27;\r\n]+)', caseSensitive: false).firstMatch(val);
                if (match != null) {
                  resolvedFilename = match.group(1)?.trim() ?? '';
                }
              }
            }
          }
        }
      }

      final hasAttachmentId = attachmentId != null && attachmentId.isNotEmpty;
      final isFile = hasAttachmentId ||
          (resolvedFilename.isNotEmpty && !mimeType.startsWith('text/') && !mimeType.startsWith('multipart/'));

      if (isFile) {
        attachments.add(
          GmailAttachmentInfo(
            attachmentId: attachmentId ?? '',
            directData: directData,
            filename: resolvedFilename.isNotEmpty ? resolvedFilename : 'statement.pdf',
            mimeType: mimeType.isNotEmpty ? mimeType : 'application/pdf',
            size: size,
          ),
        );
      }

      final parts = node['parts'] as List<dynamic>?;
      if (parts != null) {
        for (final child in parts) {
          if (child is Map<String, dynamic>) {
            traverseParts(child);
          }
        }
      }
    }

    traverseParts(payload);
    return attachments;
  }

  /// Recursively walks MIME payload parts to extract plain text or strip HTML into plain text.
  String _extractMimeBody(Map<String, dynamic> payload) {
    final plainParts = <String>[];
    final htmlParts = <String>[];

    void traverseParts(Map<String, dynamic> node) {
      final mimeType = (node['mimeType']?.toString() ?? '').toLowerCase();
      final body = node['body'] as Map<String, dynamic>?;
      final rawData = body?['data']?.toString();

      if (rawData != null && rawData.isNotEmpty) {
        final decoded = _decodeBase64Url(rawData);
        if (decoded.trim().isNotEmpty) {
          if (mimeType.contains('text/plain')) {
            plainParts.add(decoded);
          } else if (mimeType.contains('text/html')) {
            htmlParts.add(decoded);
          }
        }
      }

      final parts = node['parts'] as List<dynamic>?;
      if (parts != null) {
        for (final child in parts) {
          if (child is Map<String, dynamic>) {
            traverseParts(child);
          }
        }
      }
    }

    traverseParts(payload);

    // Prefer plain text; fall back to stripped HTML
    if (plainParts.isNotEmpty) {
      return plainParts.join('\n').trim();
    }

    if (htmlParts.isNotEmpty) {
      return _cleanHtmlToPlainText(htmlParts.join('\n'));
    }

    return '';
  }

  /// Safely decodes base64url encoded strings
  String _decodeBase64Url(String raw) {
    try {
      final normalized = base64Url.normalize(raw);
      final bytes = base64Url.decode(normalized);
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      try {
        final alt = raw.replaceAll('-', '+').replaceAll('_', '/');
        final bytes = base64.decode(base64.normalize(alt));
        return utf8.decode(bytes, allowMalformed: true);
      } catch (_) {
        return '';
      }
    }
  }

  /// Converts raw HTML body into clean, normalized readable text
  String _cleanHtmlToPlainText(String html) {
    var text = html;

    // Remove style and script tags and their content
    text = text.replaceAll(RegExp(r'<style[^>]*>[\s\S]*?<\/style>', caseSensitive: false), ' ');
    text = text.replaceAll(RegExp(r'<script[^>]*>[\s\S]*?<\/script>', caseSensitive: false), ' ');
    text = text.replaceAll(RegExp(r'<head[^>]*>[\s\S]*?<\/head>', caseSensitive: false), ' ');

    // Convert block level elements and line breaks to newlines
    text = text.replaceAll(RegExp(r'<\/(p|div|tr|h\d|li)>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<br\s*\/?>', caseSensitive: false), '\n');

    // Remove remaining HTML tags
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');

    // Unescape common HTML entities
    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&#8377;', '₹')
        .replaceAll('&bull;', '•');

    // Replace multiple newlines and spaces with clean whitespace
    text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
    text = text.replaceAll(RegExp(r'\n\s*\n+'), '\n\n');

    return text.trim();
  }
}
