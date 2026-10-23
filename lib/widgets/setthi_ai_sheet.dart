import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../config/dpc_tokens.dart';
import '../models/chat_message_model.dart';
import '../providers/chat_providers.dart';
import 'ai_companion_rive_widget.dart';

/// Full DPC Styled Bottom Sheet Modal or Dedicated Full Page for Setthi AI
class SetthiAiSheet extends ConsumerStatefulWidget {
  final String? initialPrompt;
  final bool isFullScreenPage;

  const SetthiAiSheet({
    super.key,
    this.initialPrompt,
    this.isFullScreenPage = false,
  });

  /// Static helper to display the sheet from anywhere as a modal
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
    'How much did I spend this week?',
    'What are my recurring bills?',
    'Top 3 food orders lately',
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

  bool _hasInitialScrolled = false;
  double _previousBottomInset = 0.0;

  void _scrollToBottom({bool immediate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _performScroll(immediate: immediate, attempt: 0);
    });
  }

  void _performScroll({required bool immediate, required int attempt}) {
    if (!mounted || !_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;

    if (maxScroll <= 0) {
      if (attempt < 4) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _performScroll(immediate: immediate, attempt: attempt + 1);
        });
      }
      return;
    }

    if (immediate) {
      _scrollController.jumpTo(maxScroll);
    } else {
      _scrollController.animateTo(
        maxScroll,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutQuad,
      );
    }

    // Because ListView.builder computes layout lazily, maxScrollExtent expands
    // as subsequent items are built. Continue adjusting until settled at the true bottom.
    if (attempt < 4) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        if ((_scrollController.position.maxScrollExtent - _scrollController.position.pixels).abs() > 2.0) {
          _performScroll(immediate: immediate, attempt: attempt + 1);
        }
      });
    }
  }

  void _handleSend([String? textToSend]) {
    final text = (textToSend ?? _inputController.text).trim();
    if (text.isEmpty) return;

    final credits = ref.read(aiCreditsProvider);
    if (credits <= 0) return;

    HapticFeedback.lightImpact();
    _inputController.clear();
    ref.read(dynamicSuggestionsProvider.notifier).clear();
    ref.read(chatMessagesProvider.notifier).sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final messagesAsync = ref.watch(chatMessagesProvider);
    final credits = ref.watch(aiCreditsProvider);
    final isZeroCredits = credits <= 0;

    // Reset initial scroll flag if chat is cleared
    if (messagesAsync.hasValue && (messagesAsync.value?.isEmpty ?? true)) {
      _hasInitialScrolled = false;
    }

    // Automatically scroll to bottom when page is opened with existing messages
    if (!_hasInitialScrolled && messagesAsync.hasValue && (messagesAsync.value?.isNotEmpty ?? false)) {
      _hasInitialScrolled = true;
      _scrollToBottom(immediate: true);
    }

    // Automatically keep latest message in view when keyboard opens
    if (bottomInset > _previousBottomInset && _hasInitialScrolled) {
      _scrollToBottom(immediate: false);
    }
    _previousBottomInset = bottomInset;

    // Listen to message updates to auto-scroll as tokens arrive or state changes
    ref.listen(chatMessagesProvider, (prev, next) {
      if (!_hasInitialScrolled && next.hasValue && (next.value?.isNotEmpty ?? false)) {
        _hasInitialScrolled = true;
        _scrollToBottom(immediate: true);
      } else {
        _scrollToBottom(immediate: false);
      }
    });

    final mainBody = Column(
      children: [
        if (!widget.isFullScreenPage) ...[
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
        ],

        // Conversation Area
        Expanded(
          child: messagesAsync.when(
            loading:
                () => const Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: DpcColors.textPrimary,
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

              final icebreaker = ref.watch(setthiIcebreakerProvider);
              final dynamicSuggestions = ref.watch(dynamicSuggestionsProvider);
              final showIcebreakerChips = icebreaker != null &&
                  messages.length == 1 &&
                  messages.first.role == ChatRole.assistant;
              final showDynamicSuggestions = !showIcebreakerChips &&
                  dynamicSuggestions.isNotEmpty &&
                  messages.isNotEmpty &&
                  messages.last.role == ChatRole.assistant &&
                  !messages.last.isStreaming;

              return ListView.builder(
                controller: _scrollController,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
                itemCount: messages.length +
                    (showIcebreakerChips ? 1 : 0) +
                    (showDynamicSuggestions ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index < messages.length) {
                    final msg = messages[index];
                    return _buildMessageBubble(msg);
                  }
                  if (showIcebreakerChips) {
                    return _buildIcebreakerChips(icebreaker.promptChips);
                  }
                  return _buildDynamicSuggestions(dynamicSuggestions);
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
    );

    if (widget.isFullScreenPage) {
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Container(
          color: DpcColors.bgOled,
          child: SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: mainBody,
            ),
          ),
        ),
      );
    }

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
          child: mainBody,
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int credits) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 16, 12),
      child: Row(
        children: [
          // Architectural AI Companion Avatar
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: DpcColors.surfaceBorder,
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: const AiCompanionRiveWidget(
                size: 40,
              ),
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
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: credits > 0
                    ? DpcColors.surfaceBorder
                    : DpcColors.accentNegative.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: Text(
              '$credits credits',
              style: TextStyle(
                color: credits > 0
                    ? DpcColors.textPrimary
                    : DpcColors.accentNegative,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Delete conversation button (with warning confirmation)
          IconButton(
            key: const Key('sheet_delete_conversation_button'),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            color: DpcColors.textMuted,
            tooltip: 'Delete Conversation',
            onPressed: () => showDeleteConversationConfirmation(context, ref),
            splashRadius: 18,
          ),
          const SizedBox(width: 4),

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
    final icebreaker = ref.watch(setthiIcebreakerProvider);
    if (icebreaker != null) {
      return _buildIcebreakerEmptyState(icebreaker);
    }

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Setthi AI Companion Animated Hero Logo
          Container(
            width: 108,
            height: 108,
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(
                color: DpcColors.surfaceBorder,
                width: 1.5,
              ),
            ),
            child: ClipOval(
              child: const AiCompanionRiveWidget(
                size: 105,
                fit: Fit.cover,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'How can I help with your money today?',
            style: TextStyle(
              color: DpcColors.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          const Text(
            'Clear answers from your transactions • Safe & private • No guesswork',
            style: TextStyle(
              color: DpcColors.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Suggestion Chips (Gemini style)
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
                    vertical: 12,
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
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: DpcColors.surfaceElevated,
                          shape: BoxShape.circle,
                          border: Border.all(color: DpcColors.surfaceBorder),
                        ),
                        child: const Icon(
                          Icons.auto_awesome_rounded,
                          size: 13,
                          color: DpcColors.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 10),
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
                        color: DpcColors.textSecondary,
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

  Widget _buildIcebreakerChips(List<String> chips) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 18, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'QUICK REPLIES',
                style: TextStyle(
                  color: DpcColors.textMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips.map((chip) {
              return ActionChip(
                onPressed: () => _handleSend(chip),
                avatar: const Icon(Icons.arrow_outward_rounded, size: 13, color: DpcColors.accentPositive),
                label: Text(
                  chip,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                backgroundColor: DpcColors.surfaceElevated,
                side: const BorderSide(color: DpcColors.surfaceBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicSuggestions(List<String> chips) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 18, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SUGGESTED NEXT',
            style: TextStyle(
              color: DpcColors.textMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips.map((chip) {
              return ActionChip(
                onPressed: () {
                  ref.read(dynamicSuggestionsProvider.notifier).clear();
                  _handleSend(chip);
                },
                avatar: const Icon(
                  Icons.arrow_outward_rounded,
                  size: 13,
                  color: DpcColors.accentPositive,
                ),
                label: Text(
                  chip,
                  style: const TextStyle(
                    color: DpcColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                backgroundColor: DpcColors.surfaceElevated,
                side: const BorderSide(color: DpcColors.surfaceBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildIcebreakerEmptyState(SetthiIcebreakerData icebreaker) {
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Animated Companion Avatar
          Container(
            width: 108,
            height: 108,
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              shape: BoxShape.circle,
              border: Border.all(
                color: DpcColors.surfaceBorder,
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: DpcColors.accentPositive.withValues(alpha: 0.15),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const ClipOval(
              child: AiCompanionRiveWidget(
                size: 105,
                fit: Fit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Cleo Badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: DpcColors.surfaceBorder),
            ),
            child: const Text(
              'SETTHI RADAR READY',
              style: TextStyle(
                color: DpcColors.accentPositive,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Speech Bubble with Cleo's witty greeting
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: DpcColors.accentPositive.withValues(alpha: 0.4)),
            ),
            child: Text(
              icebreaker.greeting,
              style: const TextStyle(
                color: DpcColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),

          // Prompt Action Chips
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'SUGGESTED QUESTIONS',
              style: TextStyle(
                color: DpcColors.textMuted,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const SizedBox(height: 10),
          ...icebreaker.promptChips.map((chip) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: () => _handleSend(chip),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
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
                          chip,
                          style: const TextStyle(
                            color: DpcColors.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 15,
                        color: DpcColors.textSecondary,
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
            final parsed = jsonDecode(rawJson) as Map<String, dynamic>;
            final widgetType = parsed['type']?.toString().toLowerCase();
            if (widgetType == 'segmented_bar' || widgetType == 'radial_gauge') {
              widgetData = parsed;
            }
          } catch (e) {
            debugPrint('[Setthi AI] Widget JSON parse error: $e');
          }
        }
      }

      // Guarantee 100% emoji-free responses across all historical and incoming assistant messages
      displayContent = displayContent
          .replaceAll(
            RegExp(
              r'[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE00}-\u{FE0F}\u{1F900}-\u{1F9FF}\u{1F600}-\u{1F64F}\u{1F680}-\u{1F6FF}\u{200D}\u{2300}-\u{23FF}\u{2B50}]',
              unicode: true,
            ),
            '',
          )
          .replaceAll(RegExp(r' {2,}'), ' ')
          .trim();
    }

    // 1. User Message: Sleek, right-aligned modern pill (Gemini/ChatGPT style)
    if (isUser) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 6, left: 40),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: DpcColors.surfaceElevated,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: DpcColors.surfaceBorder.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
            child: _buildFormattedContent(displayContent, true),
          ),
        ),
      );
    }

    // 2. Assistant Message: NO CHAT BUBBLE. Expansive typography directly on canvas
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Model branding header with glowing sparkle
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: DpcColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: DpcColors.surfaceBorder),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(7),
                  child: const AiCompanionRiveWidget(
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 9),
              const Text(
                'Setthi AI',
                style: TextStyle(
                  color: DpcColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              if (msg.isStreaming) ...[
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Color(0xFF38BDF8),
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),

          // Message content flows naturally without an enclosing bubble box
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (msg.isStreaming && displayContent.isEmpty && widgetData == null)
                  _buildThinkingIndicator()
                else if (displayContent.isNotEmpty)
                  _buildFormattedContent(displayContent, false)
                else if (!msg.isStreaming && widgetData == null)
                  _buildFormattedContent(
                    'I checked your account, but couldn\'t find any matching records for that request. Try asking about your overall balance or recent transfers!',
                    false,
                  ),
                if (widgetData != null)
                  _buildGenerativeWidget(widgetData),
              ],
            ),
          ),

          // Minimalist Action Row (Copy, feedback)
          if (!msg.isStreaming && displayContent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8, left: 4),
              child: Row(
                children: [
                  InkWell(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: displayContent));
                      HapticFeedback.lightImpact();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Response copied to clipboard'),
                          duration: Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(
                            Icons.copy_rounded,
                            size: 13,
                            color: DpcColors.textMuted,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'Copy',
                            style: TextStyle(
                              color: DpcColors.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGenerativeWidget(Map<String, dynamic> data) {
    final type = data['type']?.toString().toLowerCase();

    if (type == 'segmented_bar') {
      final title = data['title']?.toString() ?? 'SPEND BREAKDOWN';
      final rawSegments = data['segments'] as List<dynamic>? ?? [];

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
              ],
            ),
            const SizedBox(height: 8),
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
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: segColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '$label: $val',
                      style: const TextStyle(
                        color: DpcColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
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
      final subtitle = data['subtitle']?.toString() ?? '';

      return Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(14),
        decoration: DpcDecorations.cardBase(radius: 16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: DpcColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DpcColors.surfaceBorder, width: 1),
              ),
              child: Text(
                '${val.round()}',
                style: const TextStyle(
                  color: DpcColors.accentPositive,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title.toUpperCase(), style: DpcTypography.badgeTag),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: DpcColors.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
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
      fontSize: isUser ? 13.5 : 14.5,
      height: isUser ? 1.45 : 1.55,
      letterSpacing: isUser ? -0.1 : -0.15,
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
            color: DpcColors.textPrimary,
          ),
        ),
        const SizedBox(width: 8),
        const Text(
          'Checking your transactions & crunching numbers...',
          style: TextStyle(
            color: DpcColors.textSecondary,
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
          bottom: BorderSide(color: DpcColors.surfaceBorder, width: 1),
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
                textInputAction: TextInputAction.send,
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
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color:
                    isZeroCredits
                        ? DpcColors.surfaceElevated
                        : DpcColors.textPrimary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.arrow_upward_rounded,
                size: 20,
                color:
                    isZeroCredits
                        ? DpcColors.textMuted
                        : DpcColors.bgOled,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Confirmation modal taking user confirmation with an explicit warning before deleting conversation
Future<bool?> showDeleteConversationConfirmation(
  BuildContext context,
  WidgetRef ref,
) {
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (modalContext) {
      bool isDeleting = false;

      return StatefulBuilder(
        builder: (context, setModalState) {
          return Container(
            decoration: const BoxDecoration(
              color: DpcColors.surfaceDark,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(color: DpcColors.surfaceBorder, width: 1),
                left: BorderSide(color: DpcColors.surfaceBorder, width: 1),
                right: BorderSide(color: DpcColors.surfaceBorder, width: 1),
              ),
            ),
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 14,
              bottom: MediaQuery.of(context).padding.bottom + 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: DpcColors.surfaceTrack,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Warning Icon + Title
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: DpcColors.accentNegative.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: DpcColors.accentNegative.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.warning_amber_rounded,
                        color: DpcColors.accentNegative,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Delete Conversation?',
                            style: TextStyle(
                              color: DpcColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'This action is irreversible',
                            style: TextStyle(
                              color: DpcColors.accentNegative,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Warning description card
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: DpcColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: DpcColors.surfaceBorder,
                      width: 1,
                    ),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: DpcColors.textSecondary,
                        size: 18,
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'All messages in this conversation will be permanently removed from this device and deleted from our cloud servers. Your AI credits will remain unchanged.',
                          style: TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 12.5,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),

                // Action buttons
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: isDeleting
                            ? null
                            : () => Navigator.of(modalContext).pop(false),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(
                            color: DpcColors.textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        key: const Key('confirm_delete_conversation_button'),
                        onPressed: isDeleting
                            ? null
                            : () async {
                                setModalState(() => isDeleting = true);
                                final success = await ref
                                    .read(chatMessagesProvider.notifier)
                                    .clearHistory();
                                if (modalContext.mounted) {
                                  Navigator.of(modalContext).pop(true);
                                }
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      backgroundColor: DpcColors.surfaceDark,
                                      behavior: SnackBarBehavior.floating,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      content: Row(
                                        children: [
                                          Icon(
                                            success
                                                ? Icons.check_circle_rounded
                                                : Icons.error_outline_rounded,
                                            color: success
                                                ? DpcColors.accentPositive
                                                : DpcColors.accentNegative,
                                            size: 18,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              success
                                                  ? 'Conversation permanently deleted'
                                                  : 'Failed to delete from server',
                                              style: const TextStyle(
                                                color: DpcColors.textPrimary,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }
                              },
                        icon: isDeleting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.delete_forever_rounded, size: 18),
                        label: Text(
                          isDeleting ? 'Deleting...' : 'Delete Conversation',
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: DpcColors.accentNegative,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
