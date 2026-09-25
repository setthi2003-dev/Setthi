import 'package:flutter/foundation.dart';

/// Role of a participant in the Setthi AI conversation
enum ChatRole {
  user,
  assistant,
  system;

  static ChatRole fromString(String role) {
    switch (role.toLowerCase().trim()) {
      case 'user':
        return ChatRole.user;
      case 'assistant':
      case 'model':
        return ChatRole.assistant;
      default:
        return ChatRole.system;
    }
  }

  String toDbValue() {
    switch (this) {
      case ChatRole.user:
        return 'user';
      case ChatRole.assistant:
        return 'assistant';
      case ChatRole.system:
        return 'system';
    }
  }
}

/// Represents a single conversation bubble in Setthi AI
@immutable
class ChatMessage {
  final String id;
  final ChatRole role;
  final String content;
  final DateTime createdAt;
  final bool isStreaming;
  final Map<String, dynamic>? metadata;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.isStreaming = false,
    this.metadata,
  });

  bool get isUser => role == ChatRole.user;
  bool get isAssistant => role == ChatRole.assistant;

  ChatMessage copyWith({
    String? id,
    ChatRole? role,
    String? content,
    DateTime? createdAt,
    bool? isStreaming,
    Map<String, dynamic>? metadata,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
      isStreaming: isStreaming ?? this.isStreaming,
      metadata: metadata ?? this.metadata,
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: (json['id'] ?? '').toString(),
      role: ChatRole.fromString(json['role']?.toString() ?? 'assistant'),
      content: (json['content'] ?? '').toString(),
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'].toString())?.toLocal() ??
              DateTime.now()
          : DateTime.now(),
      isStreaming: false,
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata'] as Map<String, dynamic>
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.toDbValue(),
        'content': content,
        'created_at': createdAt.toUtc().toIso8601String(),
        if (metadata != null) 'metadata': metadata,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          role == other.role &&
          content == other.content &&
          isStreaming == other.isStreaming;

  @override
  int get hashCode =>
      id.hashCode ^ role.hashCode ^ content.hashCode ^ isStreaming.hashCode;
}
