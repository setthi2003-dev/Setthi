import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/chat_message_model.dart';
import '../providers/chat_providers.dart';
import 'dpc_gauges.dart';
import 'dpc_telemetry_cards.dart';

/// Full DPC Styled Bottom Sheet Modal for Setthi AI
class SetthiAiSheet extends ConsumerStatefulWidget {
  final String? initialPrompt;

  const SetthiAiSheet({super.key, this.initialPrompt});

  /// Static helper to display the sheet from anywhere
  static Future<void> show(BuildContext context, {String? initialPrompt}) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SetthiAiSheet(initialPrompt: initialPrompt),
    );
  }

  @override
  ConsumerState<SetthiAiSheet> createState() => _SetthiAiSheetState();
}

class _SetthiAiSheetState extends ConsumerState<SetthiAiSheet> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  static const List<String> _quickPrompts = [
    'How much did I spend this week? 💸',
    'What is my current balance? 🏦',
    'Top 3 food orders lately 🍔',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.initialPrompt != null && widget.initialPrompt!.trim().isNotEmpty) {
      _inputController.text = widget.initialPrompt!.trim();
    }
  }

  @override
  void dispose() {
    _inputController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutQuad,
        );
      }
    });
  }

  void _handleSend([String? textToSend]) {
    final text = (textToSend ?? _inputController.text).trim();
    if (text.isEmpty) return;

    final credits = ref.read(aiCreditsProvider);
    if (credits <= 0) return;

    HapticFeedback.lightImpact();
    _inputController.clear();
    ref.read(chatMessagesProvider.notifier).sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final messagesAsync = ref.watch(chatMessagesProvider);
    final credits = ref.watch(aiCreditsProvider);
    final isZeroCredits = credits <= 0;

    // Listen to message updates to auto-scroll as tokens arrive
    ref.listen(chatMessagesProvider, (prev, next) {
      _scrollToBottom();
    });

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.88,
      ),
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          left: BorderSide(color: DpcColors.surfaceBorder, width: 1),
          right: BorderSide(color: DpcColors.surfaceBorder, width: 1),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset),
          child: Column(
            children: [
              // Top Drag Handle
              Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 10),
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceTrack,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header
              _buildHeader(context, credits),

              const Divider(color: DpcColors.surfaceBorder, height: 1),

              // Conversation Area
              Expanded(
                child: messagesAsync.when(
                  loading:
                      () => const Center(
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFE0C3FC),
                        ),
                      ),
                  error:
                      (err, _) => Center(
                        child: Text(
                          'Failed to load chat history: $err',
                          style: const TextStyle(
                            color: DpcColors.accentNegative,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  data: (messages) {
                    if (messages.isEmpty) {
                      return _buildEmptyState();
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        return _buildMessageBubble(msg);
                      },
                    );
                  },
                ),
              ),

              // Out-of-credits warning banner
              if (isZeroCredits) _buildOutOfCreditsBanner(),

              // Input Bar
              _buildInputBar(isZeroCredits),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int credits) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 16, 12),
      child: Row(
        children: [
          // Glowing Lilac AI Sparkle Avatar
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: DpcColors.heroPastel2,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE0C3FC).withValues(alpha: 0.3),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              size: 20,
              color: DpcColors.textContrast,
            ),
          ),
          const SizedBox(width: 12),

          // Title & Online pulse
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'Setthi AI',
                      style: TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: DpcColors.accentPositive,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 1),
                const Text(
                  'Smart Finance Companion',
                  style: TextStyle(color: DpcColors.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),

          // Credit Pill Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color:
                  credits > 0
                      ? const Color(0xFFE0C3FC).withValues(alpha: 0.12)
                      : DpcColors.accentNegative.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color:
                    credits > 0
                        ? const Color(0xFFE0C3FC).withValues(alpha: 0.35)
                        : DpcColors.accentNegative.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 14,
                  color:
                      credits > 0
                          ? const Color(0xFFE0C3FC)
                          : DpcColors.accentNegative,
                ),
                const SizedBox(width: 3),
                Text(
                  '$credits credits',
                  style: TextStyle(
                    color:
                        credits > 0
                            ? const Color(0xFFE0C3FC)
                            : DpcColors.accentNegative,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),

          // Close button
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            color: DpcColors.textMuted,
            onPressed: () => Navigator.of(context).pop(),
            splashRadius: 18,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFE0C3FC).withValues(alpha: 0.08),
              shape: BoxShape.circle,
              border: Border.all(
                color: const Color(0xFFE0C3FC).withValues(alpha: 0.2),
                width: 1,
              ),
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 28,
              color: Color(0xFFE0C3FC),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            'Ask me anything about your money',
            style: TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            'Powered by Gemini 2.5 Flash + live verified bank ledger tools. Zero guessing.',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Suggestion Chips
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'TRY ASKING',
              style: TextStyle(
                color: DpcColors.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 10),
          ..._quickPrompts.map((prompt) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => _handleSend(prompt),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: DpcColors.surfaceBorder,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          prompt,
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 15,
                        color: Color(0xFFE0C3FC),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg) {
    final isUser = msg.isUser;

    Map<String, dynamic>? widgetData;
    String displayContent = msg.content;

    if (!isUser) {
      final widgetMatch =
          RegExp(r'<!--WIDGET:(.*?)-->', dotAll: true).firstMatch(msg.content);
      if (widgetMatch != null) {
        final rawJson = widgetMatch.group(1)?.trim();
        displayContent = msg.content
            .replaceRange(widgetMatch.start, widgetMatch.end, '')
            .trim();
        if (rawJson != null && rawJson.isNotEmpty) {
          try {
            widgetData = jsonDecode(rawJson) as Map<String, dynamic>;
          } catch (e) {
            debugPrint('[Setthi AI] Widget JSON parse error: $e');
          }
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              margin: const EdgeInsets.only(right: 8, top: 2),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                gradient: DpcColors.heroPastel2,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.auto_awesome_rounded,
                size: 13,
                color: DpcColors.textContrast,
              ),
            ),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    isUser
                        ? DpcColors.surfaceTrack
                        : DpcColors.surfaceElevated,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
                border: Border.all(
                  color:
                      isUser
                          ? DpcColors.surfaceBorder
                          : const Color(0xFFE0C3FC).withValues(alpha: 0.22),
                  width: 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.isStreaming && displayContent.isEmpty && widgetData == null)
                    _buildThinkingIndicator()
                  else if (displayContent.isNotEmpty)
                    _buildFormattedContent(displayContent, isUser)
                  else if (!msg.isStreaming && !isUser && widgetData == null)
                    _buildFormattedContent(
                      'I checked your account, but couldn\'t find any matching records for that request. Try asking about your overall balance or recent transfers!',
                      isUser,
                    ),
                  if (widgetData != null)
                    _buildGenerativeWidget(widgetData),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenerativeWidget(Map<String, dynamic> data) {
    final type = data['type']?.toString().toLowerCase();

    if (type == 'split_card') {
      final title = data['title']?.toString() ?? 'CASH FLOW';
      final progress =
          ((data['gaugeProgress'] ?? 0.5) as num).toDouble().clamp(0.0, 1.0);
      final label = data['gaugeLabel']?.toString() ?? 'Ratio';
      final rawKv = data['keyValues'] as List<dynamic>? ?? [];
      final keyValues = rawKv.map((kv) {
        final m = kv as Map<String, dynamic>;
        Color? c;
        final rawColor = m['color']?.toString();
        if (rawColor != null && rawColor.startsWith('#')) {
          final hex = rawColor.replaceAll('#', '');
          if (hex.length == 6) c = Color(int.parse('0xFF$hex'));
        }
        return (
          label: m['label']?.toString() ?? '',
          value: m['value']?.toString() ?? '',
          color: c,
        );
      }).toList();

      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: DpcSplitTelemetryCard(
          title: title,
          gaugeProgress: progress,
          gaugeLabel: label,
          keyValues: keyValues,
        ),
      );
    } else if (type == 'segmented_bar') {
      final title = data['title']?.toString() ?? 'SPEND BREAKDOWN';
      final rawSegments = data['segments'] as List<dynamic>? ?? [];
      double totalVal = 0;
      for (final s in rawSegments) {
        if (s is Map) totalVal += ((s['value'] ?? 0) as num).toDouble();
      }

      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: DpcDecorations.cardBase(radius: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title.toUpperCase(), style: DpcTypography.badgeTag),
                const Icon(Icons.bar_chart_rounded,
                    size: 16, color: DpcColors.accentPrimary),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(
                  children: rawSegments.map((s) {
                    final m = s as Map<String, dynamic>;
                    final val = ((m['value'] ?? 0) as num).toDouble();
                    final flex =
                        totalVal > 0 ? (val / totalVal * 100).round() : 1;
                    Color segColor = DpcColors.accentPositive;
                    final hex = m['color']?.toString().replaceAll('#', '');
                    if (hex != null && hex.length == 6) {
                      segColor = Color(int.parse('0xFF$hex'));
                    }
                    return Expanded(
                      flex: flex > 0 ? flex : 1,
                      child: Container(color: segColor),
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: rawSegments.map((s) {
                final m = s as Map<String, dynamic>;
                final label = m['label']?.toString() ?? '';
                final val = m['value']?.toString() ?? '';
                Color segColor = DpcColors.accentPositive;
                final hex = m['color']?.toString().replaceAll('#', '');
                if (hex != null && hex.length == 6) {
                  segColor = Color(int.parse('0xFF$hex'));
                }
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: segColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$label: $val',
                      style: const TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      );
    } else if (type == 'radial_gauge') {
      final title = data['title']?.toString() ?? 'FINANCIAL HEALTH';
      final val = ((data['value'] ?? 50) as num).toDouble();
      final maxVal = ((data['max'] ?? 100) as num).toDouble();
      final progress = maxVal > 0 ? (val / maxVal).clamp(0.0, 1.0) : 0.5;
      final subtitle = data['subtitle']?.toString() ?? '';

      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: DpcDecorations.cardBase(radius: 16),
        child: Row(
          children: [
            DpcRadialGauge(
              progress: progress,
              size: 64,
              strokeWidth: 6,
              activeColor: DpcColors.accentPositive,
              centerChild: Text(
                '${val.round()}',
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.toUpperCase(), style: DpcTypography.badgeTag),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildFormattedContent(String content, bool isUser) {
    final baseStyle = TextStyle(
      color: isUser ? DpcColors.textPrimary : const Color(0xFFF1F1F5),
      fontSize: 13.5,
      height: 1.45,
      letterSpacing: -0.1,
    );

    final spans = _parseMarkdownSpans(content, isUser, baseStyle);

    return SelectableText.rich(
      TextSpan(
        style: baseStyle,
        children: spans,
      ),
    );
  }

  List<InlineSpan> _parseMarkdownSpans(
    String rawText,
    bool isUser,
    TextStyle baseStyle,
  ) {
    if (rawText.isEmpty) return const [];

    // Format list bullets nicely: lines starting with "* " or "- " become "• "
    final text = rawText.replaceAllMapped(
      RegExp(r'(^|\n)[*-]\s+', multiLine: true),
      (m) => '${m.group(1)}• ',
    );

    final spans = <InlineSpan>[];
    // Matches:
    // group 1 & 2: **bold**
    // group 3 & 4: *italic*
    // group 5 & 6: `code`
    final regex = RegExp(r'(\*\*(.+?)\*\*)|(\*(.+?)\*)|(`(.+?)`)');
    int lastIndex = 0;

    for (final match in regex.allMatches(text)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: text.substring(lastIndex, match.start),
          style: baseStyle,
        ));
      }

      if (match.group(1) != null) {
        // Bold: **<TEXT>**
        final boldText = match.group(2) ?? '';
        final isCurrency = boldText.contains('₹');
        spans.add(TextSpan(
          text: boldText,
          style: baseStyle.copyWith(
            fontWeight: FontWeight.w700,
            color: isCurrency && !isUser
                ? const Color(0xFF38BDF8) // Currency accent in DPC Cyan
                : DpcColors.textPrimary,
          ),
        ));
      } else if (match.group(3) != null) {
        // Italic: *<TEXT>*
        final italicText = match.group(4) ?? '';
        spans.add(TextSpan(
          text: italicText,
          style: baseStyle.copyWith(
            fontStyle: FontStyle.italic,
          ),
        ));
      } else if (match.group(5) != null) {
        // Inline code: `<TEXT>`
        final codeText = match.group(6) ?? '';
        spans.add(TextSpan(
          text: codeText,
          style: baseStyle.copyWith(
            fontFamily: 'monospace',
            backgroundColor: const Color(0xFF26262B),
            fontSize: 12.5,
          ),
        ));
      }

      lastIndex = match.end;
    }

    // Trailing text (handles incomplete streaming markdown tokens smoothly)
    if (lastIndex < text.length) {
      final tail = text.substring(lastIndex);
      final unclosedIdx = tail.lastIndexOf('**');
      if (unclosedIdx != -1) {
        if (unclosedIdx > 0) {
          spans.add(TextSpan(
            text: tail.substring(0, unclosedIdx),
            style: baseStyle,
          ));
        }
        final partialBold = tail.substring(unclosedIdx + 2);
        if (partialBold.isNotEmpty) {
          spans.add(TextSpan(
            text: partialBold,
            style: baseStyle.copyWith(
              fontWeight: FontWeight.w700,
              color: DpcColors.textPrimary,
            ),
          ));
        }
      } else {
        spans.add(TextSpan(
          text: tail,
          style: baseStyle,
        ));
      }
    }

    return spans;
  }

  Widget _buildThinkingIndicator() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 12,
          height: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: Color(0xFFE0C3FC),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Checking ledger & crunching numbers...',
          style: TextStyle(
            color: const Color(0xFFE0C3FC).withValues(alpha: 0.85),
            fontSize: 12,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }

  Widget _buildOutOfCreditsBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: DpcColors.accentNegative.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: DpcColors.accentNegative.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.lock_clock_rounded,
            size: 16,
            color: DpcColors.accentNegative,
          ),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'You have used all 3 free trial credits. Credit top-ups are arriving shortly!',
              style: TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(bool isZeroCredits) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      decoration: const BoxDecoration(
        color: DpcColors.surfaceDark,
        border: Border(
          top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(23),
                border: Border.all(
                  color: DpcColors.surfaceBorder,
                  width: 1,
                ),
              ),
              child: TextField(
                controller: _inputController,
                focusNode: _focusNode,
                enabled: !isZeroCredits,
                onSubmitted: (_) => _handleSend(),
                style: const TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 13,
                ),
                cursorColor: const Color(0xFFB8F5D8),
                decoration: InputDecoration(
                  hintText:
                      isZeroCredits
                          ? 'Out of credits'
                          : 'Ask about balances, spends, or merchants...',
                  hintStyle: const TextStyle(
                    color: DpcColors.textMuted,
                    fontSize: 12.5,
                  ),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Send Button
          GestureDetector(
            onTap: isZeroCredits ? null : () => _handleSend(),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: isZeroCredits ? null : DpcColors.heroPastel1,
                color: isZeroCredits ? DpcColors.surfaceTrack : null,
                shape: BoxShape.circle,
                boxShadow:
                    isZeroCredits
                        ? null
                        : [
                          BoxShadow(
                            color: const Color(
                              0xFF86E3CE,
                            ).withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 20,
                color:
                    isZeroCredits
                        ? DpcColors.textMuted
                        : DpcColors.textContrast,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
