import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:licoup/src/frontend/features/agents/ui/composer_agent_mention.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class RuntimeMessageComposer extends StatefulWidget {
  const RuntimeMessageComposer({
    super.key,
    required this.targetLabel,
    required this.initialDraft,
    required this.busy,
    required this.enabled,
    required this.modelOptions,
    required this.selectedModel,
    required this.reasoningEffortOptions,
    required this.selectedReasoningEffort,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
    required this.onDraftChanged,
    required this.onSend,
    this.defaultModel = '',
    this.defaultReasoningEffort = '',
    this.showRuntimeSettings = true,
    this.showWorkingDirectory = false,
    this.workingDirectory = '',
    this.workingDirectorySelectable = false,
    this.onChooseWorkingDirectory,
    this.floatingMatteCapsule = false,
    this.onAttach,
    this.mentionBridge,
  });

  final String targetLabel;
  final String initialDraft;
  final bool busy;
  final bool enabled;
  final List<String> modelOptions;
  final String selectedModel;
  final List<String> reasoningEffortOptions;
  final String selectedReasoningEffort;
  final ValueChanged<String> onModelChanged;
  final ValueChanged<String> onReasoningEffortChanged;
  final ValueChanged<String> onDraftChanged;
  final Future<bool> Function(String) onSend;
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

  /// Optional bridge for inserting Adaptive Flywheel `@agent` mention chips.
  final ComposerMentionBridge? mentionBridge;

  @override
  State<RuntimeMessageComposer> createState() => _RuntimeMessageComposerState();
}

class _ComposerMentionChip {
  const _ComposerMentionChip({
    required this.agentId,
    required this.displayLabel,
    this.target,
  });

  final String agentId;
  final String displayLabel;
  final TargetCandidate? target;
}

class _RuntimeMessageComposerState extends State<RuntimeMessageComposer> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  LayoutFocusCoordinator? _layoutFocusCoordinator;
  bool _focused = false;
  late bool _hasText;
  final List<_ComposerMentionChip> _mentionChips = [];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _hasText = widget.initialDraft.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
    widget.mentionBridge?.bind(_insertAgentMention);
  }

  @override
  void didUpdateWidget(covariant RuntimeMessageComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mentionBridge != widget.mentionBridge) {
      oldWidget.mentionBridge?.unbind(_insertAgentMention);
      widget.mentionBridge?.bind(_insertAgentMention);
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
    widget.mentionBridge?.unbind(_insertAgentMention);
    _layoutFocusCoordinator?.unregister(
      LayoutFocusTargets.composerField,
      _focusNode,
    );
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _insertAgentMention({
    required String agentId,
    required String displayLabel,
    TargetCandidate? target,
  }) {
    final id = agentId.trim();
    final label = displayLabel.trim().isNotEmpty ? displayLabel.trim() : id;
    if (id.isEmpty || label.isEmpty || !widget.enabled) {
      return;
    }
    final token = composerAgentMentionToken(label);
    if (token.isEmpty) {
      return;
    }
    final selection = _controller.selection;
    final text = _controller.text;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : start;
    final before = start > 0 ? text.substring(0, start) : '';
    final after = end < text.length ? text.substring(end) : '';
    final needsLeadingSpace =
        before.isNotEmpty && !RegExp(r'\s$').hasMatch(before);
    final needsTrailingSpace =
        after.isEmpty || !RegExp(r'^\s').hasMatch(after);
    final insertion =
        '${needsLeadingSpace ? ' ' : ''}$token${needsTrailingSpace ? ' ' : ''}';
    final next = text.replaceRange(start, end, insertion);
    final caret = start + insertion.length;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: caret),
    );
    if (!_mentionChips.any((chip) => chip.agentId == id)) {
      setState(() {
        _mentionChips.add(
          _ComposerMentionChip(
            agentId: id,
            displayLabel: label,
            target: target,
          ),
        );
      });
    }
    _focusNode.requestFocus();
  }

  void _removeMentionChip(_ComposerMentionChip chip) {
    final token = composerAgentMentionToken(chip.displayLabel);
    var next = _controller.text;
    if (token.isNotEmpty) {
      next = next.replaceFirst('$token ', token);
      next = next.replaceFirst(token, '');
      next = next.replaceAll(RegExp(r'  +'), ' ');
    }
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: next.length.clamp(0, next.length),
      ),
    );
    setState(() => _mentionChips.removeWhere((item) => item.agentId == chip.agentId));
  }

  void _onTextChanged() {
    widget.onDraftChanged(_controller.text);
    final next = _controller.text.trim().isNotEmpty || _mentionChips.isNotEmpty;
    if (next == _hasText || !mounted) {
      return;
    }
    setState(() => _hasText = next);
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
    if ((text.isEmpty && _mentionChips.isEmpty) || !widget.enabled) {
      return;
    }
    final chips = List<_ComposerMentionChip>.from(_mentionChips);
    _controller.clear();
    if (_mentionChips.isNotEmpty) {
      setState(() => _mentionChips.clear());
    }
    final consumed = await widget.onSend(text);
    if (!consumed && mounted && _controller.text.trim().isEmpty) {
      _controller
        ..text = text
        ..selection = TextSelection.collapsed(offset: text.length);
      setState(() {
        _mentionChips
          ..clear()
          ..addAll(chips);
      });
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
    final canSend = interactive && _hasText;
    final fieldRadius = BorderRadius.circular(
      widget.floatingMatteCapsule
          ? MessagingDesktopMetrics.conversationComposerCapsuleCornerRadius
          : LicoRadius.composerField,
    );
    final fieldBody = Padding(
      padding: const EdgeInsets.all(LicoRadius.composerInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_mentionChips.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final chip in _mentionChips)
                    _ComposerAgentMentionChip(
                      key: Key('composer-agent-mention-${chip.agentId}'),
                      label: chip.displayLabel,
                      target: chip.target,
                      enabled: interactive,
                      onDeleted: interactive
                          ? () => _removeMentionChip(chip)
                          : null,
                    ),
                ],
              ),
            ),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
                  child: TextField(
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
              const SizedBox(width: LicoContentSpacing.compact),
              _ComposerSendButton(
                canSend: canSend,
                busy: widget.busy,
                onTap: canSend ? _submit : null,
                tooltip: strings.send,
              ),
            ],
          ),
        ],
      ),
    );
    final field = widget.floatingMatteCapsule
        ? Material(
            key: const Key('agent-conversation-composer-field'),
            color: Colors.transparent,
            child: MessagingConversationOverlayGlass(
              borderRadius: fieldRadius,
              focused: _focused && interactive,
              child: fieldBody,
            ),
          )
        : AppleGlassSurface(
            key: const Key('agent-conversation-composer-field'),
            borderRadius: fieldRadius,
            focused: _focused && interactive,
            child: fieldBody,
          );
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.floatingMatteCapsule && widget.onAttach != null) ...[
                _ComposerAttachCapsuleButton(
                  enabled: interactive,
                  tooltip: strings.attachments,
                  onPressed: widget.onAttach,
                ),
                const SizedBox(
                  width: MessagingDesktopMetrics
                      .conversationHeaderCapsuleButtonGap,
                ),
              ],
              Expanded(child: field),
            ],
          ),
        ],
      ),
    );
  }
}

/// Encapsulated `@agent` chip shown inside the composer field glass.
class _ComposerAgentMentionChip extends StatelessWidget {
  const _ComposerAgentMentionChip({
    super.key,
    required this.label,
    required this.enabled,
    this.target,
    this.onDeleted,
  });

  final String label;
  final bool enabled;
  final TargetCandidate? target;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Material(
      color: colors.isDark
          ? colors.accent.withAlpha(36)
          : colors.accent.withAlpha(28),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onDeleted,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (target case final target?)
                AgentBrandIcon(target: target, size: 14, iconSize: 14)
              else
                Icon(
                  Icons.alternate_email_rounded,
                  size: 13,
                  color: colors.accent,
                ),
              const SizedBox(width: 5),
              Text(
                '@$label',
                style: TextStyle(
                  color: colors.text.withAlpha(235),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
              if (enabled && onDeleted != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.close_rounded,
                  size: 13,
                  color: colors.textMuted.withAlpha(180),
                ),
              ],
            ],
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
      waitDuration: const Duration(milliseconds: 400),
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
    required this.busy,
    required this.onTap,
    required this.tooltip,
  });

  final bool canSend;
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
      tone: canSend ? LicoIconButtonTone.brand : LicoIconButtonTone.ghost,
      icon: busy
          ? LicoSpinningRefreshIcon(
              size: 15,
              strokeWidth: 1.8,
              color: canSend ? colors.textOnPrimary : colors.textMuted,
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
