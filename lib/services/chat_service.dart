import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/supabase_config.dart';

/// Events emitted during Setthi AI SSE streaming
sealed class ChatStreamEvent {
  const ChatStreamEvent();
}

class ChatChunkEvent extends ChatStreamEvent {
  final String text;
  const ChatChunkEvent(this.text);
}

class ChatDoneEvent extends ChatStreamEvent {
  final int? remainingCredits;
  const ChatDoneEvent({this.remainingCredits});
}

class ChatOutOfCreditsEvent extends ChatStreamEvent {
  final String message;
  const ChatOutOfCreditsEvent({required this.message});
}

class ChatErrorEvent extends ChatStreamEvent {
  final String error;
  const ChatErrorEvent(this.error);
}

/// Service handling streaming communication with the `chat-assistant` Edge Function
class ChatService {
  final http.Client _client;

  ChatService({http.Client? client}) : _client = client ?? http.Client();

  /// Streams responses from the `chat-assistant` Edge Function via Server-Sent Events (SSE)
  Stream<ChatStreamEvent> sendMessage({
    required String prompt,
    required String accessToken,
  }) async* {
    if (!SupabaseConfig.isConfigured) {
      yield const ChatErrorEvent('Supabase configuration is missing');
      return;
    }

    final uri = Uri.parse('${SupabaseConfig.url}/functions/v1/chat-assistant');

    final request = http.Request('POST', uri);
    request.headers.addAll({
      'Authorization': 'Bearer $accessToken',
      'apikey': SupabaseConfig.publishableKey,
      'Content-Type': 'application/json',
      'Accept': 'text/event-stream',
    });
    request.body = jsonEncode({'prompt': prompt});

    http.StreamedResponse streamedResponse;
    try {
      streamedResponse = await _client.send(request);
    } catch (e) {
      yield ChatErrorEvent('Network request failed: $e');
      return;
    }

    if (streamedResponse.statusCode == 401) {
      yield const ChatErrorEvent('Unauthorized. Please sign in again.');
      return;
    }

    if (streamedResponse.statusCode == 402) {
      final errorBody = await streamedResponse.stream.bytesToString();
      String message = 'You have 0 AI credits remaining.';
      try {
        final parsed = jsonDecode(errorBody);
        if (parsed is Map && parsed['message'] != null) {
          message = parsed['message'].toString();
        }
      } catch (_) {}
      yield ChatOutOfCreditsEvent(message: message);
      return;
    }

    if (streamedResponse.statusCode >= 400) {
      final errorBody = await streamedResponse.stream.bytesToString();
      yield ChatErrorEvent(
        'Server error (${streamedResponse.statusCode}): $errorBody',
      );
      return;
    }

    // Process Server-Sent Events line by line
    final lineStream = streamedResponse.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lineStream) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('data:')) continue;

      final dataStr = trimmed.substring(5).trim();
      if (dataStr.isEmpty || dataStr == '[DONE]') continue;

      try {
        final parsed = jsonDecode(dataStr);
        if (parsed is! Map) continue;

        if (parsed.containsKey('error')) {
          yield ChatErrorEvent(parsed['error'].toString());
          continue;
        }

        if (parsed['done'] == true) {
          int? credits;
          if (parsed['remaining_credits'] != null) {
            credits = int.tryParse(parsed['remaining_credits'].toString());
          }
          yield ChatDoneEvent(remainingCredits: credits);
          continue;
        }

        final text = parsed['text']?.toString();
        if (text != null && text.isNotEmpty) {
          yield ChatChunkEvent(text);
        }
      } catch (e) {
        debugPrint('[ChatService] Error parsing SSE data: $e (raw: $trimmed)');
      }
    }
  }

  void dispose() {
    _client.close();
  }
}
