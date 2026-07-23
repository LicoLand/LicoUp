import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_conversation_runtime_settings.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/shared/platform/client_platform.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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

  @override
  State<RuntimeMessageComposer> createState() => _RuntimeMessageComposerState();
}

class _RuntimeMessageComposerState extends State<RuntimeMessageComposer> {
  late final TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  LayoutFocusCoordinator? _layoutFocusCoordinator;
  bool _focused = false;
  late bool _hasText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialDraft);
    _hasText = widget.initialDraft.trim().isNotEmpty;
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(_onFocusChanged);
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
    _focusNode
      ..removeListener(_onFocusChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    widget.onDraftChanged(_controller.text);
    final next = _controller.text.trim().isNotEmpty;
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
    if (text.isEmpty || !widget.enabled) {
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
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final mobileClient = isMobileClientPlatform(context);
    final interactive = widget.enabled;
    final canSend = interactive && _hasText;
    final fieldRadius = BorderRadius.circular(
      AppleControlMetrics.controlCornerRadius,
    );
    return Padding(
      padding: mobileClient
          ? const EdgeInsets.fromLTRB(12, 10, 12, 12)
          : const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.modelOptions.isNotEmpty ||
              widget.reasoningEffortOptions.isNotEmpty) ...[
            ConversationRuntimeSettingsBar(
              enabled: interactive,
              modelOptions: widget.modelOptions,
              selectedModel: widget.selectedModel,
              reasoningEffortOptions: widget.reasoningEffortOptions,
              selectedReasoningEffort: widget.selectedReasoningEffort,
              onModelChanged: widget.onModelChanged,
              onReasoningEffortChanged: widget.onReasoningEffortChanged,
              defaultModel: widget.defaultModel,
            ),
            const SizedBox(height: 8),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: LicoPerimeterPulse(
                  key: const Key('agent-conversation-composer-running-border'),
                  enabled: widget.busy,
                  borderRadius: fieldRadius,
                  color: colors.primaryStrong,
                  child: AppleGlassSurface(
                    key: const Key('agent-conversation-composer-field'),
                    borderRadius: fieldRadius,
                    focused: _focused && interactive,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: TextField(
                                controller: _controller,
                                focusNode: _focusNode,
                                minLines: 1,
                                maxLines: 4,
                                textInputAction: TextInputAction.send,
                                onSubmitted: (_) => _submit(),
                                enabled: interactive,
                                cursorColor: colors.info,
                                cursorWidth: 1.2,
                                style: TextStyle(
                                  color: colors.text.withAlpha(235),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: -0.08,
                                  height: 1.35,
                                ),
                                decoration: InputDecoration(
                                  hintText: interactive
                                      ? strings.messageTarget(
                                          widget.targetLabel,
                                        )
                                      : null,
                                  hintStyle: TextStyle(
                                    color: colors.textMuted.withAlpha(150),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    letterSpacing: -0.08,
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
                          const SizedBox(width: 6),
                          _ComposerSendButton(
                            canSend: canSend,
                            busy: widget.busy,
                            onTap: canSend ? _submit : null,
                            tooltip: strings.send,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The composer's embedded send affordance: a quiet ghost while idle and a
/// solid brand circle the moment a real message can go out — the one
/// control that must always read as immediately usable.
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
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          key: const Key('agent-conversation-composer-send'),
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: canSend ? colors.primary : colors.surfaceLow,
            ),
            child: Center(
              child: busy
                  ? LicoSpinningRefreshIcon(
                      size: 14,
                      strokeWidth: 1.8,
                      color: canSend ? colors.textOnPrimary : colors.textMuted,
                    )
                  : Icon(
                      Icons.arrow_upward_rounded,
                      size: 16,
                      color: canSend
                          ? colors.textOnPrimary
                          : colors.textMuted.withAlpha(140),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class InactiveRuntimeMessageComposer extends StatelessWidget {
  const InactiveRuntimeMessageComposer({super.key, required this.targetLabel});

  final String targetLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: AppleGlassSurface(
              borderRadius: BorderRadius.circular(
                AppleControlMetrics.controlCornerRadius,
              ),
              fillAlpha: 14,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  strings.messageTarget(targetLabel),
                  style: TextStyle(
                    color: colors.textMuted.withAlpha(140),
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    letterSpacing: -0.08,
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
