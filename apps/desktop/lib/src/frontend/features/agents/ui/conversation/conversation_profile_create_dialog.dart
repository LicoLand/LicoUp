import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_renderer_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_member_profile_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

/// "创建智能体" — creates a reusable Agent persona (Profile): mascot avatar,
/// display name, one backing local Agent, its model and reasoning effort,
/// with an advanced section collapsed by default (context window, default
/// prompt, permission mode, working directory).
///
/// On confirm the dialog sends [CreateConversationProfile]; the composition
/// registers the persona and materializes its direct canonical
/// Conversation, then [ConversationProfileCreated] closes the dialog.
Future<void> showConversationProfileCreateDialog({
  required BuildContext context,
  required IntentSink<ConversationIntent> intents,
  required EffectSource<ConversationEffect> effects,
  required IntentSink<AgentsIntent> agentsIntents,
  required List<TargetCandidate> targets,
  bool Function(String agentId)? isRefreshingAgentCatalog,
}) async {
  final candidates = agentOrchestrationCommanderTargets(targets);
  await showDialog<void>(
    context: context,
    builder: (context) => _ConversationProfileCreateDialog(
      intents: intents,
      effects: effects,
      agentsIntents: agentsIntents,
      candidates: candidates,
      isRefreshingAgentCatalog: isRefreshingAgentCatalog ?? (_) => false,
    ),
  );
}

class _ConversationProfileCreateDialog extends StatefulWidget {
  const _ConversationProfileCreateDialog({
    required this.intents,
    required this.effects,
    required this.agentsIntents,
    required this.candidates,
    required this.isRefreshingAgentCatalog,
  });

  final IntentSink<ConversationIntent> intents;
  final EffectSource<ConversationEffect> effects;
  final IntentSink<AgentsIntent> agentsIntents;
  final List<TargetCandidate> candidates;
  final bool Function(String agentId) isRefreshingAgentCatalog;

  @override
  State<_ConversationProfileCreateDialog> createState() =>
      _ConversationProfileCreateDialogState();
}

class _ConversationProfileCreateDialogState
    extends State<_ConversationProfileCreateDialog> {
  final _name = TextEditingController();
  final _contextWindow = TextEditingController();
  final _environment = TextEditingController();
  final _instructions = TextEditingController();
  late String _mascotId;
  DailyConversationAgentAssignment _draft =
      const DailyConversationAgentAssignment();
  var _advancedOpen = false;
  var _creating = false;
  var _failureCode = '';
  StreamSubscription<ConversationEffect>? _effectSubscription;

  @override
  void initState() {
    super.initState();
    _mascotId = MascotCatalog.avatars.keys.elementAt(
      Random().nextInt(MascotCatalog.avatars.length),
    );
    _effectSubscription = widget.effects.effects.listen(_handleEffect);
  }

  @override
  void dispose() {
    unawaited(_effectSubscription?.cancel());
    _name.dispose();
    _contextWindow.dispose();
    _environment.dispose();
    _instructions.dispose();
    super.dispose();
  }

  void _handleEffect(ConversationEffect effect) {
    if (!mounted || !_creating) return;
    switch (effect) {
      case ConversationProfileCreated():
        Navigator.of(context).pop();
      case ConversationActionRejected(:final stage, :final reasonCode)
          when stage == 'profile-create':
        setState(() {
          _creating = false;
          _failureCode = reasonCode;
        });
      default:
        break;
    }
  }

  TargetCandidate? _targetFor(String agentId) {
    for (final candidate in widget.candidates) {
      if (candidate.target == agentId.trim()) return candidate;
    }
    return null;
  }

  TargetCandidate? get _selectedTarget => _targetFor(_draft.agentId);

  int? get _contextWindowTokens {
    final text = _contextWindow.text.trim();
    if (text.isEmpty) return null;
    return int.tryParse(text);
  }

  bool get _contextWindowValid =>
      _contextWindow.text.trim().isEmpty ||
      (_contextWindowTokens != null && _contextWindowTokens! > 0);

  bool get _canCreate =>
      !_creating &&
      _name.text.trim().isNotEmpty &&
      _draft.agentId.trim().isNotEmpty &&
      _contextWindowValid;

  void _create() {
    setState(() {
      _creating = true;
      _failureCode = '';
    });
    widget.intents.send(
      CreateConversationProfile(
        ConversationProfile(
          id: 'p${DateTime.now().microsecondsSinceEpoch}',
          name: _name.text.trim(),
          mascotAvatarId: _mascotId,
          agentId: _draft.agentId.trim(),
          modelId: _draft.modelName.trim(),
          reasoningEffort: _draft.reasoningEffort.trim(),
          permissionMode: _draft.permissionMode.trim(),
          environment: _environment.text.trim(),
          contextWindowTokens: _contextWindowTokens,
          instructions: _instructions.text.trim(),
          createdAtUnixMs: DateTime.now().millisecondsSinceEpoch,
        ),
      ),
    );
  }

  void _requestModelCatalog(String agentId) {
    widget.agentsIntents.send(RefreshAcativaModelCatalogs(agentIds: [agentId]));
  }

  /// Mirrors the assistant configuration rule: the persisted mode is kept
  /// only while the adapter still supports it; an agent without a
  /// permission control renders no selector.
  Widget _permissionModeRow(LicoStrings strings, LicoThemeColors colors) {
    final modes =
        _selectedTarget?.conversationPermissionModes ?? const <String>[];
    if (modes.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = modes.contains(_draft.permissionMode)
        ? _draft.permissionMode
        : modes.first;
    return _advancedRow(
      label: strings.permissionMode,
      child: DropdownMenu<String>(
        key: const Key('agent-profile-permission-mode'),
        initialSelection: current,
        requestFocusOnTap: false,
        textStyle: TextStyle(color: colors.text, fontSize: 13),
        inputDecorationTheme: _fieldDecorationTheme(colors),
        dropdownMenuEntries: [
          for (final mode in modes)
            DropdownMenuEntry<String>(
              value: mode,
              label: strings.permissionModeOptionLabel(mode, mode),
            ),
        ],
        onSelected: (mode) {
          if (mode == null) return;
          setState(() => _draft = _draft.copyWith(permissionMode: mode));
        },
      ),
    );
  }

  InputDecorationTheme _fieldDecorationTheme(LicoThemeColors colors) =>
      InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: (colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surfaceLow),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          borderSide: BorderSide(color: colors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          borderSide: BorderSide(color: colors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          borderSide: BorderSide(color: colors.accent),
        ),
      );

  InputDecoration _fieldDecoration(LicoThemeColors colors, {String? hintText}) {
    final theme = _fieldDecorationTheme(colors);
    return InputDecoration(
      isDense: theme.isDense,
      filled: theme.filled,
      fillColor: theme.fillColor,
      contentPadding: theme.contentPadding,
      border: theme.border,
      enabledBorder: theme.enabledBorder,
      focusedBorder: theme.focusedBorder,
      hintText: hintText,
      hintStyle: TextStyle(color: colors.textDisabled, fontSize: 13),
    );
  }

  Widget _advancedRow({required String label, required Widget child}) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Padding(
              padding: const EdgeInsets.only(top: 9),
              child: Text(
                label,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    return AlertDialog(
      key: const Key('conversation-profile-create-dialog'),
      title: Text(strings.newAgentProfile),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.agentProfileAvatarLabel,
                style: TextStyle(
                  color: colors.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              MessagingMascotPicker(
                selected: _mascotId,
                onSelected: (id) => setState(() => _mascotId = id),
              ),
              const SizedBox(height: 18),
              TextField(
                key: const Key('agent-profile-name-field'),
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: strings.agentProfileNameLabel,
                  hintText: strings.agentProfileNameHint,
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 18),
              if (widget.candidates.isEmpty)
                Text(
                  strings.groupConversationNeedsAgent,
                  style: TextStyle(color: colors.error),
                )
              else
                AgentRuntimeAssignmentCascadeCards(
                  keyPrefix: 'agent-profile',
                  showFast: false,
                  borderRadius: BorderRadius.circular(
                    AppleControlMetrics.menuCornerRadius,
                  ),
                  maxHeight: 190,
                  agentCardWidth: 176,
                  modelCardWidth: 240,
                  settingsCardWidth: 160,
                  targets: widget.candidates,
                  draft: _draft,
                  selectedAgentIds: _draft.agentId.trim().isEmpty
                      ? const {}
                      : {_draft.agentId.trim()},
                  onDraftChanged: (draft) {
                    setState(() {
                      _failureCode = '';
                      final modes =
                          _targetFor(
                            draft.agentId,
                          )?.conversationPermissionModes ??
                          const <String>[];
                      // Mirror the assistant dialog: the draft always
                      // carries an executable selection — the first
                      // declared mode when nothing valid is persisted yet.
                      final mode = modes.contains(draft.permissionMode)
                          ? draft.permissionMode
                          : (modes.isEmpty ? '' : modes.first);
                      _draft = draft.copyWith(permissionMode: mode);
                    });
                  },
                  isRefreshingAgentCatalog: widget.isRefreshingAgentCatalog,
                  onAgentCatalogRequested: _requestModelCatalog,
                ),
              Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const Key('agent-profile-advanced-toggle'),
                  title: Text(
                    strings.agentProfileAdvancedTitle,
                    style: TextStyle(
                      color: colors.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  initiallyExpanded: _advancedOpen,
                  onExpansionChanged: (open) => _advancedOpen = open,
                  children: [
                    _advancedRow(
                      label: strings.agentProfileContextWindow,
                      child: TextField(
                        key: const Key('agent-profile-context-window-field'),
                        controller: _contextWindow,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _fieldDecoration(
                          colors,
                          hintText: strings.agentProfileContextWindowHint,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    _advancedRow(
                      label: strings.agentProfileEnvironment,
                      child: TextField(
                        key: const Key('agent-profile-environment-field'),
                        controller: _environment,
                        decoration: _fieldDecoration(colors),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    _permissionModeRow(strings, colors),
                    _advancedRow(
                      label: strings.agentProfileDefaultPrompt,
                      child: TextField(
                        key: const Key('agent-profile-instructions-field'),
                        controller: _instructions,
                        minLines: 2,
                        maxLines: 5,
                        decoration: _fieldDecoration(
                          colors,
                          hintText: strings.agentProfileDefaultPromptHint,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
              ),
              if (_failureCode.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  key: const Key('agent-profile-create-failure'),
                  strings.agentProfileCreateFailure(_failureCode),
                  style: TextStyle(color: colors.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          key: const Key('agent-profile-create-confirm'),
          onPressed: _canCreate ? _create : null,
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              if (states.contains(WidgetState.disabled)) {
                return (colors.isDark
                        ? LicoPaneGlass.contentInnerCardFill
                        : colors.surfaceLow)
                    .withValues(alpha: 0.5);
              }
              if (states.contains(WidgetState.pressed) ||
                  states.contains(WidgetState.hovered)) {
                return colors.primaryStrong;
              }
              return colors.primary;
            }),
            foregroundColor: WidgetStateProperty.resolveWith((states) {
              return states.contains(WidgetState.disabled)
                  ? colors.textDisabled
                  : colors.textOnPrimary;
            }),
          ),
          child: _creating
              ? const SizedBox.square(
                  dimension: 18,
                  child: LicoLoadingIndicator(strokeWidth: 2),
                )
              : Text(strings.agentProfileCreate),
        ),
      ],
    );
  }
}
