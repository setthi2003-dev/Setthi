import 'dart:async';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/supabase_config.dart';
import '../models/chat_message_model.dart';
import '../services/chat_service.dart';
import 'supabase_provider.dart';

/// Provider exposing the HTTP ChatService for SSE communications
final chatServiceProvider = Provider<ChatService>((ref) {
  final service = ChatService();
  ref.onDispose(service.dispose);
  return service;
});

/// Tracks the user's available AI credits (defaults to 3 free credits)
class AiCreditsNotifier extends Notifier<int> {
  @override
  int build() {
    // Initial fetch from backend in background
    Future.microtask(() => refreshCredits());
    return 3;
  }

  Future<void> refreshCredits() async {
    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      final credits = await dbService.fetchAiCredits();
      state = credits;
    } catch (_) {}
  }

  void setCredits(int value) {
    state = value.clamp(0, 999999);
  }

  void decrement() {
    if (state > 0) {
      state = state - 1;
    }
  }
}

final aiCreditsProvider = NotifierProvider<AiCreditsNotifier, int>(
  AiCreditsNotifier.new,
);

/// Dynamic follow-up suggestion chips sent from Setthi AI
class DynamicSuggestionsNotifier extends Notifier<List<String>> {
  @override
  List<String> build() => const [];

  void setSuggestions(List<String> suggestions) {
    state = suggestions;
  }

  void clear() {
    state = const [];
  }
}

final dynamicSuggestionsProvider =
    NotifierProvider<DynamicSuggestionsNotifier, List<String>>(
  DynamicSuggestionsNotifier.new,
);

/// Active conversational session ID to thread follow-up queries
class ChatSessionIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setSessionId(String? id) {
    state = id;
  }

  void clear() {
    state = null;
  }
}

final chatSessionIdProvider =
    NotifierProvider<ChatSessionIdNotifier, String?>(
  ChatSessionIdNotifier.new,
);

/// State management for the Setthi AI conversation stream and history
class ChatMessagesNotifier extends AsyncNotifier<List<ChatMessage>> {
  bool _isSending = false;
  bool get isSending => _isSending;

  @override
  Future<List<ChatMessage>> build() async {
    final dbService = ref.read(supabaseDbServiceProvider);
    final history = await dbService.fetchChatHistory();
    return history;
  }

  String _generateId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rand = Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return 'msg-$now-$rand';
  }

  /// Sends a user message to Setthi AI and streams the incoming tokens
  Future<void> sendMessage(String prompt) async {
    final trimmedPrompt = prompt.trim();
    if (trimmedPrompt.isEmpty || _isSending) return;

    final currentCredits = ref.read(aiCreditsProvider);
    if (currentCredits <= 0) return;

    // Reset suggestions while processing new query
    ref.read(dynamicSuggestionsProvider.notifier).clear();

    _isSending = true;

    final currentMessages = state.value ?? [];
    final userMessage = ChatMessage(
      id: _generateId(),
      role: ChatRole.user,
      content: trimmedPrompt,
      createdAt: DateTime.now(),
    );

    final assistantPlaceholderId = _generateId();
    final assistantPlaceholder = ChatMessage(
      id: assistantPlaceholderId,
      role: ChatRole.assistant,
      content: '',
      createdAt: DateTime.now(),
      isStreaming: true,
    );

    // Optimistically show user bubble & streaming placeholder
    state = AsyncData([...currentMessages, userMessage, assistantPlaceholder]);

    // Retrieve authentication token
    String accessToken = '';
    try {
      if (SupabaseConfig.isConfigured) {
        accessToken =
            SupabaseConfig.client.auth.currentSession?.accessToken ?? '';
      }
    } catch (_) {}

    final chatService = ref.read(chatServiceProvider);
    final activeSessionId = ref.read(chatSessionIdProvider);
    String accumulatedText = '';

    try {
      final stream = chatService.sendMessage(
        prompt: trimmedPrompt,
        accessToken: accessToken,
        sessionId: activeSessionId,
      );

      await for (final event in stream) {
        switch (event) {
          case ChatChunkEvent(:final text):
            accumulatedText += text;
            _updateAssistantBubble(
              id: assistantPlaceholderId,
              content: accumulatedText,
              isStreaming: true,
            );

          case ChatDoneEvent(
            :final remainingCredits,
            :final sessionId,
            :final suggestions,
          ):
            _updateAssistantBubble(
              id: assistantPlaceholderId,
              content: accumulatedText,
              isStreaming: false,
            );
            if (sessionId != null && sessionId.isNotEmpty) {
              ref.read(chatSessionIdProvider.notifier).setSessionId(sessionId);
            }
            if (suggestions != null && suggestions.isNotEmpty) {
              ref.read(dynamicSuggestionsProvider.notifier).setSuggestions(suggestions);
            }
            if (remainingCredits != null) {
              ref.read(aiCreditsProvider.notifier).setCredits(remainingCredits);
            } else {
              ref.read(aiCreditsProvider.notifier).decrement();
            }

          case ChatOutOfCreditsEvent(:final message):
            _updateAssistantBubble(
              id: assistantPlaceholderId,
              content: message,
              isStreaming: false,
            );
            ref.read(aiCreditsProvider.notifier).setCredits(0);

          case ChatErrorEvent(:final error):
            _updateAssistantBubble(
              id: assistantPlaceholderId,
              content:
                  accumulatedText.isNotEmpty
                      ? '$accumulatedText\n\n*(Error: $error)*'
                      : 'Sorry, I ran into an issue answering that. Please try again!',
              isStreaming: false,
            );
        }
      }
    } catch (e) {
      _updateAssistantBubble(
        id: assistantPlaceholderId,
        content:
            accumulatedText.isNotEmpty
                ? '$accumulatedText\n\n*(Stream disconnected)*'
                : 'Connection failed. Please check your connection and try again.',
        isStreaming: false,
      );
    } finally {
      _isSending = false;
    }
  }

  void _updateAssistantBubble({
    required String id,
    required String content,
    required bool isStreaming,
  }) {
    final currentList = state.value ?? [];
    final updatedList = currentList.map((msg) {
      if (msg.id == id) {
        return msg.copyWith(content: content, isStreaming: isStreaming);
      }
      return msg;
    }).toList();

    state = AsyncData(updatedList);
  }

  /// Clears the chat conversation locally and removes all chat message records from the backend
  Future<bool> clearHistory() async {
    state = const AsyncData([]);
    ref.read(chatSessionIdProvider.notifier).clear();
    ref.read(dynamicSuggestionsProvider.notifier).clear();

    try {
      final dbService = ref.read(supabaseDbServiceProvider);
      return await dbService.deleteChatHistory();
    } catch (_) {
      return false;
    }
  }

  /// Seeds an introductory assistant icebreaker message from onboarding
  void seedIcebreakerMessage(String content) {
    final currentList = state.value ?? [];
    if (currentList.isNotEmpty) return; // Don't overwrite if history exists
    final assistantMsg = ChatMessage(
      id: _generateId(),
      role: ChatRole.assistant,
      content: content,
      createdAt: DateTime.now(),
      isStreaming: false,
    );
    state = AsyncData([assistantMsg]);
  }
}

final chatMessagesProvider =
    AsyncNotifierProvider<ChatMessagesNotifier, List<ChatMessage>>(
      ChatMessagesNotifier.new,
    );

/// Cleo-style customized icebreaker data generated during onboarding
class SetthiIcebreakerData {
  final String greeting;
  final List<String> promptChips;
  final String? topCategory;
  final double? topCategoryAmount;
  final double? totalDebitAmount;

  const SetthiIcebreakerData({
    required this.greeting,
    required this.promptChips,
    this.topCategory,
    this.topCategoryAmount,
    this.totalDebitAmount,
  });
}

class SetthiIcebreakerNotifier extends Notifier<SetthiIcebreakerData?> {
  @override
  SetthiIcebreakerData? build() => null;

  void setIcebreaker(SetthiIcebreakerData data) {
    state = data;
  }

  void clear() {
    state = null;
  }
}

final setthiIcebreakerProvider =
    NotifierProvider<SetthiIcebreakerNotifier, SetthiIcebreakerData?>(
  SetthiIcebreakerNotifier.new,
);
