import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class RuntimeMessageComposer extends StatefulWidget {
  const RuntimeMessageComposer({
    super.key,
    required this.targetLabel,
    required this.initialDraft,
    this.hasAttachments = false,
    required this.busy,
    required this.enabled,
    this.cancelEnabled = false,
    required this.modelOptions,
    required this.selectedModel,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onDraftChanged,
    required this.onSend,
    this.onSlashNewConversation,
    this.onCancel,
    this.defaultModel = '',
    this.defaultReasoningEffort = '',
    this.showRuntimeSettings = true,
    this.showWorkingDirectory = false,
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
    this.onChooseWorkingDirectory,
    this.floatingMatteCapsule = false,
    this.onAttach,
    this.onPasteImage,
    this.mentionTargets = const [],
    this.mentionLabels = const {},
    this.leading,
    this.fieldLeading,
  });

  final String targetLabel;
  final String initialDraft;
  final bool hasAttachments;
  final bool busy;
  final bool enabled;
  final bool cancelEnabled;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onDraftChanged;
  final Future<bool> Function(String) onSend;
  final Future<void> Function()? onCancel;

  /// Optional handler for the exact slash-new command submitted alone
  /// (trimmed). When set, submitting that command clears the field, runs this
  /// handler, and never reaches [onSend]. Hosts that pass nothing keep the
  /// ordinary posting behavior.
  final VoidCallback? onSlashNewConversation;

  /// The exact command text [onSlashNewConversation] intercepts when
  /// submitted alone (trimmed).
  static const String slashNewCommand = '/new';
  final String defaultModel;
  final String defaultReasoningEffort;

  /// Whether the composer embeds the runtime settings bar above the input
  /// row. Layout presentation strategies that relocate runtime settings keep
  /// the input row and hide the bar through this port.
  final bool showRuntimeSettings;
  final bool showWorkingDirectory;
  final String workingDirectory;
  final bool workingDirectorySelectable;
  final VoidCallback? onChooseWorkingDirectory;

  /// Messaging desktop: floating matte glass capsule over the transcript
  /// (blur + lower-transparency fill). Console keeps [AppleGlassSurface].
  final bool floatingMatteCapsule;

  /// Optional attach affordance shown as a separate overlay-glass capsule to
  /// the left of [floatingMatteCapsule] composer fields.
  final VoidCallback? onAttach;

  /// Tries to consume the active paste as an image attachment. Returning
  /// false delegates to Flutter's native text paste unchanged.
  final Future<bool> Function()? onPasteImage;

  /// Active group members available to the composer's @ mention picker.
  /// Ordinary one-to-one conversations leave this empty.
  final List<TargetCandidate> mentionTargets;

  /// Agent id to the exact membership display name recognized by the group
  /// dispatch parser. The visible compact product name remains local UI copy.
  final Map<String, String> mentionLabels;

  /// Optional capsule rendered immediately before the input field.
  final Widget? leading;

  /// Optional compact control rendered inside the field capsule, left of the
  /// text input (for example the assistant toggle).
  final Widget? fieldLeading;

  @override
  State<RuntimeMessageComposer> createState() => _RuntimeMessageComposerState();
}

class _RuntimeMessageComposerState extends State<RuntimeMessageComposer> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  LayoutFocusCoordinator? _layoutFocusCoordinator;
  bool _focused = false;
  late bool _hasText;
  int? _mentionStart;
  String _mentionQuery = '';
  int _mentionSelection = 0;
  final ScrollController _mentionScrollController = ScrollController();
  late final _ComposerPasteAction _pasteAction;

  /// Field height readback target for the capsule morph; the public field key
  /// stays a plain [ValueKey] for tests.
  final GlobalKey _fieldSizeKey = GlobalKey();
  bool _multilineEstimate = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _hasText = widget.initialDraft.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    _pasteAction = _ComposerPasteAction(
      () => widget.onPasteImage?.call() ?? Future<bool>.value(false),
    );
  }

  @override
  void didUpdateWidget(covariant RuntimeMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The draft is scoped per conversation: switching conversations (or a
    // successful send clearing the current draft) replaces the text without
    // recreating this widget. The store echoes every keystroke, so a rebuild
    // passes the same text back and this sync stays a no-op while typing.
    if (oldWidget.initialDraft != widget.initialDraft &&
        widget.initialDraft != _controller.text) {
      final restored = widget.initialDraft;
      _controller.value = TextEditingValue(
        text: restored,
        selection: TextSelection.collapsed(offset: restored.length),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = LayoutFocusScope.maybeOf(context);
    if (identical(next, _layoutFocusCoordinator)) {
      return;
    }
    _layoutFocusCoordinator?.unregister(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
    _layoutFocusCoordinator = next;
    _layoutFocusCoordinator?.register(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
  }

  @override
  void dispose() {
    _layoutFocusCoordinator?.unregister(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _mentionScrollController.dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onDraftChanged(_controller.text);
    final next = _controller.text.trim().isNotEmpty;
    final mentionChanged = _syncMentionQuery();
    if (!mounted || (next == _hasText && !mentionChanged)) return;
    setState(() => _hasText = next);
  }

  /// The field's laid-out height drives the capsule morph: one text line of
  /// interior is a stadium; anything taller (wrapped or hard-broken draft)
  /// becomes the rounded rectangle. Size notifications arrive mid-layout, so
  /// the readback runs post-frame.
  void _onFieldSizeNotification() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = _fieldSizeKey.currentContext?.size;
      if (size == null) return;
      final multiline = size.height > _singleLineFieldExtent(context) + 0.5;
      if (multiline == _multilineEstimate) return;
      setState(() => _multilineEstimate = multiline);
    });
  }

  /// The field's exact single-line height: outer insets plus the taller of
  /// the control row (send/leading extent) and one padded text line.
  double _singleLineFieldExtent(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge ?? const TextStyle();
    final painter = TextPainter(
      text: TextSpan(text: 'Ag', style: style),
      textDirection: Directionality.of(context),
    )..layout();
    return LicoRadius.composerInset * 2 +
        math.max(
          LicoIconButtonSize.medium.extent,
          painter.height + 10, // text row vertical padding (5 + 5)
        );
  }

  bool _syncMentionQuery() {
    final previousStart = _mentionStart;
    final previousQuery = _mentionQuery;
    final selection = _controller.selection;
    _mentionStart = null;
    _mentionQuery = '';
    if (widget.mentionTargets.isNotEmpty &&
        selection.isValid &&
        selection.isCollapsed) {
      final caret = selection.extentOffset;
      final beforeCaret = _controller.text.substring(0, caret);
      final match = RegExp(r'(^|\s)@([^\s@]*)$').firstMatch(beforeCaret);
      if (match != null) {
        _mentionStart = match.start + (match.group(1)?.length ?? 0);
        _mentionQuery = match.group(2) ?? '';
      }
    }
    if (_mentionStart != previousStart || _mentionQuery != previousQuery) {
      _mentionSelection = 0;
      _resetMentionScroll();
      return true;
    }
    return false;
  }

  List<TargetCandidate> get _mentionSuggestions {
    if (_mentionStart == null) return const [];
    final query = _mentionQuery.toLowerCase();
    return widget.mentionTargets
        .where((target) {
          if (query.isEmpty) return true;
          final membershipLabel = widget.mentionLabels[target.target] ?? '';
          return membershipLabel.toLowerCase().contains(query) ||
              agentConversationTargetDisplayName(
                target,
              ).toLowerCase().contains(query) ||
              agentConversationTargetCompactDisplayName(
                target,
              ).toLowerCase().contains(query) ||
              target.target.toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  KeyEventResult _handleMentionKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final suggestions = _mentionSuggestions;
    if (suggestions.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _mentionSelection = (_mentionSelection + 1) % suggestions.length;
      });
      _revealMentionSelection(suggestions);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _mentionSelection =
            (_mentionSelection - 1 + suggestions.length) % suggestions.length;
      });
      _revealMentionSelection(suggestions);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _insertMention(suggestions[_mentionSelection]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _mentionStart = null;
        _mentionQuery = '';
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _resetMentionScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_mentionScrollController.hasClients) {
        _mentionScrollController.jumpTo(0);
      }
    });
  }

  void _revealMentionSelection(List<TargetCandidate> suggestions) {
    final selectedIndex = _mentionSelection;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          selectedIndex >= suggestions.length ||
          !_mentionScrollController.hasClients) {
        return;
      }
      const rowExtent = _ComposerMentionSuggestions.rowExtent;
      final position = _mentionScrollController.position;
      final itemStart = selectedIndex * rowExtent;
      final itemEnd = itemStart + rowExtent;
      final viewportStart = position.pixels;
      final viewportEnd = viewportStart + position.viewportDimension;
      final targetOffset = switch ((itemStart, itemEnd)) {
        _ when itemStart < viewportStart => itemStart,
        _ when itemEnd > viewportEnd => itemEnd - position.viewportDimension,
        _ => viewportStart,
      };
      final bounded = targetOffset
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((bounded - viewportStart).abs() < 0.5) return;
      _mentionScrollController.animateTo(
        bounded,
        duration: context.motion(LicoMotion.short),
        curve: LicoMotion.standard,
      );
    });
  }

  void _insertMention(TargetCandidate target) {
    final start = _mentionStart;
    final selection = _controller.selection;
    if (start == null || !selection.isValid || !selection.isCollapsed) return;
    final label = (widget.mentionLabels[target.target] ?? '').trim().isEmpty
        ? agentConversationTargetDisplayName(target)
        : widget.mentionLabels[target.target]!.trim();
    final replacement = '@$label ';
    final caret = selection.extentOffset;
    final text = _controller.text;
    final next = text.replaceRange(start, caret, replacement);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + replacement.length),
    );
    _mentionStart = null;
    _mentionQuery = '';
    _focusNode.requestFocus();
  }

  void _onFocusChanged() {
    final next = _focusNode.hasFocus;
    if (next == _focused || !mounted) {
      return;
    }
    setState(() => _focused = next);
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if ((text.isEmpty && !widget.hasAttachments) || !widget.enabled) {
      return;
    }
    final onSlashNewConversation = widget.onSlashNewConversation;
    if (onSlashNewConversation != null &&
        text == RuntimeMessageComposer.slashNewCommand) {
      _controller.clear();
      onSlashNewConversation();
      return;
    }
    _controller.clear();
    final consumed = await widget.onSend(text);
    if (!consumed && mounted && _controller.text.trim().isEmpty) {
      _controller
        ..text = text
        ..selection = TextSelection.collapsed(offset: text.length);
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final mobileClient = isMobileClientPlatform(context);
    final interactive = widget.enabled;
    final canSend = interactive && (_hasText || widget.hasAttachments);
    final canCancel = widget.cancelEnabled && widget.onCancel != null;
    final fieldBody = Padding(
      padding: const EdgeInsets.all(LicoRadius.composerInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // The in-field control pins to the first text line: while the
                // capsule grows upward into a rounded rectangle, it stays at
                // the interior top-left instead of sinking with the baseline.
                if (widget.fieldLeading != null)
                  SizedBox(
                    height: double.infinity,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: widget.fieldLeading!,
                    ),
                  ),
                Expanded(
                  child: SizedBox(
                    height: double.infinity,
                    child: Align(
                      // The text column centers between the frame's insets at
                      // one line and fills the grown field on wrap — it never
                      // sinks toward the send button's baseline.
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
                        child: Actions(
                          actions: widget.onPasteImage == null
                              ? const <Type, Action<Intent>>{}
                              : <Type, Action<Intent>>{
                                  PasteTextIntent: _pasteAction,
                                },
                          child: Focus(
                            onKeyEvent: _handleMentionKey,
                            child: TextField(
                              key: const Key('agent-conversation-composer-input'),
                              controller: _controller,
                              focusNode: _focusNode,
                              minLines: 1,
                              maxLines: 4,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _submit(),
                              enabled: interactive,
                              style: theme.textTheme.bodyLarge,
                              decoration: InputDecoration(
                                hintText: interactive
                                    ? strings.messageTarget(widget.targetLabel)
                                    : null,
                                hintStyle: theme.textTheme.bodyLarge?.copyWith(
                                  color: colors.textDisabled,
                                ),
                                isDense: true,
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: LicoContentSpacing.compact),
                _ComposerSendButton(
                  canSend: canSend,
                  canCancel: canCancel,
                  busy: widget.busy,
                  onTap: canCancel
                      ? () => widget.onCancel?.call()
                      : canSend
                      ? _submit
                      : null,
                  tooltip: canCancel ? strings.cancel : strings.send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
    // Telegram-style growth: the floating capsule is a stadium on one line
    // and morphs into a rounded rectangle as the draft grows the field
    // upward; the laid-out field height decides (see _onFieldSizeNotification).
    final field = NotificationListener<SizeChangedLayoutNotification>(
      key: const Key('agent-conversation-composer-field'),
      onNotification: (_) {
        _onFieldSizeNotification();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: TweenAnimationBuilder<BorderRadius>(
          key: _fieldSizeKey,
          tween: Tween(
            end: BorderRadius.circular(
              widget.floatingMatteCapsule && !_multilineEstimate
                  ? MessagingDesktopMetrics
                        .conversationComposerCapsuleCornerRadius
                  : LicoRadius.composerField,
            ),
          ),
          duration: LicoMotion.micro,
          curve: Curves.easeOut,
          builder: (context, radius, child) {
            return widget.floatingMatteCapsule
                ? Material(
                    color: Colors.transparent,
                    child: MessagingConversationOverlayGlass(
                      borderRadius: radius,
                      focused: _focused && interactive,
                      child: child!,
                    ),
                  )
                : AppleGlassSurface(
                    borderRadius: radius,
                    focused: _focused && interactive,
                    child: child!,
                  );
          },
          child: fieldBody,
        ),
      ),
    );
    final mentionSuggestions = _mentionSuggestions;
    return Padding(
      padding: mobileClient
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : widget.floatingMatteCapsule
          ? const EdgeInsets.fromLTRB(
              MessagingDesktopMetrics.conversationComposerCapsuleInsetH,
              8,
              MessagingDesktopMetrics.conversationComposerCapsuleInsetH,
              MessagingDesktopMetrics.conversationComposerCapsuleInsetV,
            )
          : const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showRuntimeSettings &&
              (widget.modelOptions.isNotEmpty ||
                  widget.reasoningEffortOptions.isNotEmpty ||
                  widget.showWorkingDirectory)) ...[
            ConversationRuntimeSettingsBar(
              enabled: interactive,
              modelOptions: widget.modelOptions,
              selectedModel: widget.selectedModel,
              reasoningEffortOptions: widget.reasoningEffortOptions,
              selectedReasoningEffort: widget.selectedReasoningEffort,
              onModelChanged: widget.onModelChanged,
              onReasoningEffortChanged: widget.onReasoningEffortChanged,
              defaultModel: widget.defaultModel,
              defaultReasoningEffort: widget.defaultReasoningEffort,
              showWorkingDirectory: widget.showWorkingDirectory,
              workingDirectory: widget.workingDirectory,
              workingDirectorySelectable: widget.workingDirectorySelectable,
              onChooseWorkingDirectory: widget.onChooseWorkingDirectory,
            ),
            const SizedBox(height: 8),
          ],
          if (mentionSuggestions.isNotEmpty) ...[
            _ComposerMentionSuggestions(
              targets: mentionSuggestions,
              labels: widget.mentionLabels,
              selectedIndex: _mentionSelection,
              scrollController: _mentionScrollController,
              onSelected: _insertMention,
            ),
            const SizedBox(height: 8),
          ],
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(
                    width: MessagingDesktopMetrics
                        .conversationHeaderCapsuleButtonGap,
                  ),
                ],
                if (widget.floatingMatteCapsule && widget.onAttach != null) ...[
                  Align(
                    child: _ComposerAttachCapsuleButton(
                      enabled: interactive,
                      tooltip: strings.attachments,
                      onPressed: widget.onAttach,
                    ),
                  ),
                  const SizedBox(
                    width: MessagingDesktopMetrics
                        .conversationHeaderCapsuleButtonGap,
                  ),
                ],
                Expanded(child: field),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

final class _ComposerPasteAction extends Action<PasteTextIntent> {
  _ComposerPasteAction(this.onPasteImage);

  final Future<bool> Function() onPasteImage;
  bool _pending = false;

  @override
  Object? invoke(PasteTextIntent intent) {
    if (_pending) return null;
    final nativePaste = callingAction;
    _pending = true;
    onPasteImage()
        .then((consumed) {
          if (!consumed) nativePaste?.invoke(intent);
        })
        .onError((_, _) {
          nativePaste?.invoke(intent);
        })
        .whenComplete(() => _pending = false);
    return null;
  }

  @override
  bool isEnabled(PasteTextIntent intent) =>
      !_pending && (callingAction?.isEnabled(intent) ?? false);

  @override
  bool consumesKey(PasteTextIntent intent) =>
      callingAction?.consumesKey(intent) ?? true;
}

class _ComposerMentionSuggestions extends StatelessWidget {
  const _ComposerMentionSuggestions({
    required this.targets,
    required this.labels,
    required this.selectedIndex,
    required this.scrollController,
    required this.onSelected,
  });

  static const double rowExtent = 54;

  final List<TargetCandidate> targets;
  final Map<String, String> labels;
  final int selectedIndex;
  final ScrollController scrollController;
  final ValueChanged<TargetCandidate> onSelected;

  @override
  Widget build(BuildContext context) {
    final height = math.min(targets.length * rowExtent + 8, 224.0);
    return MessagingGlassOptionCard(
      key: const Key('agent-conversation-mention-suggestions'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      constraints: BoxConstraints(maxHeight: height),
      child: SizedBox(
        height: height,
        child: ListView.builder(
          key: const Key('agent-conversation-mention-list'),
          controller: scrollController,
          padding: EdgeInsets.zero,
          itemExtent: rowExtent,
          itemCount: targets.length,
          itemBuilder: (context, index) {
            final target = targets[index];
            return _ComposerMentionSuggestionRow(
              key: Key('agent-conversation-mention-${target.target}'),
              target: target,
              label: (labels[target.target] ?? '').trim().isEmpty
                  ? agentConversationTargetDisplayName(target)
                  : labels[target.target]!.trim(),
              selected: index == selectedIndex,
              onTap: () => onSelected(target),
            );
          },
        ),
      ),
    );
  }
}

class _ComposerMentionSuggestionRow extends StatelessWidget {
  const _ComposerMentionSuggestionRow({
    super.key,
    required this.target,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final TargetCandidate target;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      key: Key('agent-conversation-mention-surface-${target.target}'),
      color: selected
          ? (colors.isDark
                ? Colors.white.withAlpha(24)
                : Colors.black.withAlpha(18))
          : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 54,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                MessagingAgentAvatar(target: target, size: 36, iconSize: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        '@${target.target}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.textMuted,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// External attach control for messaging desktop floating composer rows.
/// Matches header capsule icon buttons — square overlay glass, shared radius.
class _ComposerAttachCapsuleButton extends StatelessWidget {
  const _ComposerAttachCapsuleButton({
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final radius = BorderRadius.circular(
      MessagingDesktopMetrics.conversationComposerCapsuleCornerRadius,
    );
    return Tooltip(
      message: tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: SizedBox.square(
          dimension:
              MessagingDesktopMetrics.conversationHeaderCapsuleButtonExtent,
          child: MessagingConversationOverlayGlass(
            borderRadius: radius,
            child: InkWell(
              key: const Key('agent-conversation-composer-attach'),
              onTap: enabled ? onPressed : null,
              customBorder: RoundedRectangleBorder(borderRadius: radius),
              hoverColor: colors.isDark
                  ? Colors.white.withAlpha(10)
                  : Colors.black.withAlpha(12),
              child: Icon(
                Icons.attach_file_rounded,
                size: 19,
                color: enabled
                    ? colors.textMuted
                    : colors.textMuted.withAlpha(120),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The composer's embedded send affordance.
///
/// Quiet while there is nothing to send, brand-filled the moment a real
/// message can go out. Because lemon appears only in the sendable state, the
/// brand color stays scarce in a surface the user stares at all day.
///
/// The control is a perfect circle — a deliberate accent inside the rounded
/// field capsule, not a concentric nested square.
class _ComposerSendButton extends StatelessWidget {
  const _ComposerSendButton({
    required this.canSend,
    required this.canCancel,
    required this.busy,
    required this.onTap,
    required this.tooltip,
  });

  final bool canSend;
  final bool canCancel;
  final bool busy;
  final VoidCallback? onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LicoIconButton(
      key: const Key('agent-conversation-composer-send'),
      tooltip: tooltip,
      onPressed: onTap,
      size: LicoIconButtonSize.medium,
      shape: LicoIconButtonShape.circle,
      tone: canSend || canCancel
          ? LicoIconButtonTone.brand
          : LicoIconButtonTone.ghost,
      icon: canCancel
          ? const Icon(Icons.stop_rounded)
          : busy
          ? LicoSpinningRefreshIcon(
              size: 15,
              strokeWidth: 1.8,
              color: canSend || canCancel
                  ? colors.textOnPrimary
                  : colors.textMuted,
            )
          : const Icon(Icons.arrow_upward_rounded),
    );
  }
}

class InactiveRuntimeMessageComposer extends StatelessWidget {
  const InactiveRuntimeMessageComposer({super.key, required this.targetLabel});

  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AppleGlassSurface(
              borderRadius: BorderRadius.circular(LicoRadius.composerField),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  strings.messageTarget(targetLabel),
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colors.textDisabled,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
