import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/acativa_renderer_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/acativa_projection.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';

Future<void> showAssistantConfigurationDialog(
  BuildContext context, {
  required ConversationBinding conversation,
  required AgentsBinding agents,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        ProjectionBuilder<AgentsProjection, AgentsDialogSlice>(
          source: agents.projection,
          select: (projection) => (
            acativa: projection.acativa,
            targetDetails: projection.targetDetails,
          ),
          builder: (context, slice) =>
              ProjectionBuilder<CanonicalConversationProjection, bool>(
                source: conversation.canonicalEvents,
                select: (projection) => projection.conversation?.group == true,
                builder: (context, groupSelected) =>
                    _AssistantConfigurationDialog(
                      agents: agents,
                      acativa: slice.acativa,
                      targetDetails: slice.targetDetails,
                      groupSelected: groupSelected,
                    ),
              ),
        ),
  );
}

/// The dialog reads only the assistant profile and the target details; every
/// other field on the projection is free to churn without rebuilding it.
typedef AgentsDialogSlice = ({
  AcativaProjection acativa,
  List<TargetCandidate> targetDetails,
});

final class _AssistantConfigurationDialog extends StatefulWidget {
  const _AssistantConfigurationDialog({
    required this.agents,
    required this.acativa,
    required this.targetDetails,
    required this.groupSelected,
  });

  final AgentsBinding agents;
  final AcativaProjection acativa;
  final List<TargetCandidate> targetDetails;
  final bool groupSelected;

  @override
  State<_AssistantConfigurationDialog> createState() =>
      _AssistantConfigurationDialogState();
}

final class _AssistantConfigurationDialogState
    extends State<_AssistantConfigurationDialog> {
  DailyConversationAgentAssignment _draft =
      const DailyConversationAgentAssignment();
  bool _dirty = false;
  bool _savePending = false;
  String _validationError = '';
  String _refreshedCatalogKey = '';

  AcativaProjection get _adaptive => widget.acativa;

  List<TargetCandidate> get _targets =>
      agentOrchestrationCommanderTargets(widget.targetDetails);

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _copy(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _synchronizeFromProjection(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.agents.intents.send(const ReadAcativaAssistantProfile());
    });
  }

  @override
  void didUpdateWidget(_AssistantConfigurationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.acativa != _adaptive ||
        oldWidget.groupSelected != widget.groupSelected) {
      _synchronizeFromProjection();
    }
  }

  void _synchronizeFromProjection({bool force = false}) {
    final assistant = _adaptive.assistant;
    if ((force || !_dirty) && assistant.available) {
      _draft = _assignmentDefaults(
        assistant.agentId,
        preferredModel: assistant.modelId,
        preferredReasoningEffort: assistant.reasoningEffort,
        preferredPermissionMode: assistant.permissionMode,
      );
    }
    final targetId = _draft.agentId.trim();
    if (targetId.isNotEmpty && targetId != _refreshedCatalogKey) {
      _refreshedCatalogKey = targetId;
      // Probe the native model catalog only while it is still undiscovered;
      // a catalog that already carries native sources is authoritative here
      // and re-probing it on every open is what made the dialog stall.
      final target = _targetById(targetId);
      if (target != null && !target.hasSelectedAgentModelCatalog) {
        widget.agents.intents.send(
          RefreshAcativaModelCatalogs(agentIds: [targetId]),
        );
      }
    }
  }

  TargetCandidate? _targetById(String id) {
    for (final target in _targets) {
      if (target.target == id) return target;
    }
    return null;
  }

  DailyConversationAgentAssignment _assignmentDefaults(
    String agentId, {
    String preferredModel = '',
    String preferredReasoningEffort = '',
    String preferredPermissionMode = '',
  }) {
    final target = _targetById(agentId);
    if (target == null) {
      return DailyConversationAgentAssignment(
        agentId: agentId,
        modelName: preferredModel,
        reasoningEffort: preferredReasoningEffort,
        permissionMode: preferredPermissionMode,
      );
    }
    final models = agentOrchestrationCommanderModels(target);
    final persistedModel = preferredModel.trim();
    final model = persistedModel.isNotEmpty
        ? persistedModel
        : (models.isEmpty ? '' : models.first);
    final persistedEffort = preferredReasoningEffort.trim();
    final effort = persistedEffort.isNotEmpty
        ? persistedEffort
        : agentOrchestrationDefaultReasoningEffortForModel(target, model);
    return DailyConversationAgentAssignment(
      agentId: agentId,
      modelName: model,
      reasoningEffort: effort,
      permissionMode: _resolvePermissionMode(target, preferredPermissionMode),
    );
  }

  /// The draft always shows an executable selection: the persisted mode when
  /// the adapter still supports it, otherwise the first declared mode. Agents
  /// without a permission control get an empty value and no selector.
  String _resolvePermissionMode(TargetCandidate target, String persisted) {
    final modes = target.conversationPermissionModes;
    if (modes.isEmpty) {
      return '';
    }
    final trimmed = persisted.trim();
    return modes.contains(trimmed) ? trimmed : modes.first;
  }

  bool _isRefreshingModelCatalog(String agentId) =>
      _adaptive.agent(agentId)?.refreshingModelCatalog ?? false;

  void _requestModelCatalog(String agentId) {
    widget.agents.intents.send(
      RefreshAcativaModelCatalogs(agentIds: [agentId]),
    );
  }

  void _save() {
    if (!widget.groupSelected || _draft.agentId.trim().isEmpty) {
      setState(() {
        _validationError = _copy(
          '请为 Assistant 选择一个可调用 Agent。',
          'Choose one callable Agent for the Assistant.',
        );
      });
      return;
    }
    setState(() {
      _savePending = true;
      _validationError = '';
    });
    widget.agents.intents.send(
      UpdateAcativaAssistantProfile(
        agentId: _draft.agentId,
        modelId: _draft.modelName,
        reasoningEffort: _draft.reasoningEffort,
        permissionMode: _draft.permissionMode.trim().isEmpty
            ? null
            : _draft.permissionMode.trim(),
      ),
    );
  }

  /// Capability-gated permission selector: rendered only when the selected
  /// agent's adapter declares executable permission modes. The draft always
  /// carries a valid selection so saving never emits an unsupported value.
  Widget _permissionModeRow(LicoStrings strings, LicoThemeColors colors) {
    final agentId = _draft.agentId.trim();
    if (agentId.isEmpty) {
      return const SizedBox.shrink();
    }
    final target = _targetById(agentId);
    final modes = target?.conversationPermissionModes ?? const <String>[];
    if (modes.isEmpty) {
      return const SizedBox.shrink();
    }
    final current = modes.contains(_draft.permissionMode)
        ? _draft.permissionMode
        : modes.first;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 15, color: colors.textMuted),
          const SizedBox(width: 8),
          Text(
            strings.permissionMode,
            style: TextStyle(
              color: colors.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: DropdownMenu<String>(
                key: const Key('assistant-configuration-permission-mode'),
                initialSelection: current,
                requestFocusOnTap: false,
                textStyle: TextStyle(color: colors.text, fontSize: 13),
                inputDecorationTheme: InputDecorationTheme(
                  isDense: true,
                  filled: true,
                  fillColor: (colors.isDark
                      ? LicoPaneGlass.contentInnerCardFill
                      : colors.surfaceLow),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
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
                ),
                dropdownMenuEntries: [
                  for (final mode in modes)
                    DropdownMenuEntry<String>(
                      value: mode,
                      label: strings.permissionModeOptionLabel(mode, mode),
                    ),
                ],
                onSelected: (mode) {
                  if (mode == null) return;
                  setState(() {
                    _dirty = true;
                    _draft = _draft.copyWith(permissionMode: mode);
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleEffect(AgentsEffect effect) {
    if (!mounted || !_savePending) return;
    switch (effect) {
      case AcativaSaveCompleted():
        _savePending = false;
        Navigator.of(context).pop();
      case AcativaActionRejected(:final reasonCode):
        setState(() {
          _savePending = false;
          _validationError = reasonCode;
        });
      case AgentSelectionRejected() || AgentWorkingDirectorySelectionRejected():
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final assistant = _adaptive.assistant;
    final loading = assistant.loading || _savePending;
    return EffectListener<AgentsEffect>(
      source: widget.agents.effects,
      onEffect: _handleEffect,
      child: Dialog(
        key: const Key('assistant-configuration-dialog'),
        backgroundColor: colors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LicoRadius.floating),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 430),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 13),
                child: Row(
                  children: [
                    AssistantSparklesIcon(color: colors.accent, size: 19),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        strings.assistantProfileTitle,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: strings.close,
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.line),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (loading) ...[
                        const LinearProgressIndicator(minHeight: 2),
                        const SizedBox(height: 12),
                      ],
                      AgentRuntimeAssignmentCascadeCards(
                        keyPrefix: 'assistant-configuration',
                        showFast: false,
                        borderRadius: BorderRadius.circular(
                          AppleControlMetrics.menuCornerRadius,
                        ),
                        maxHeight: 190,
                        agentCardWidth: 188,
                        modelCardWidth: 288,
                        settingsCardWidth: 184,
                        revealSelectionOnOpen: true,
                        targets: _targets,
                        draft: _draft,
                        selectedAgentIds: _draft.agentId.trim().isEmpty
                            ? const {}
                            : {_draft.agentId.trim()},
                        onDraftChanged: (draft) {
                          setState(() {
                            _validationError = '';
                            _dirty = true;
                            _draft = _assignmentDefaults(
                              draft.agentId,
                              preferredModel: draft.modelName,
                              preferredReasoningEffort: draft.reasoningEffort,
                            );
                          });
                        },
                        isRefreshingAgentCatalog: _isRefreshingModelCatalog,
                        onAgentCatalogRequested: _requestModelCatalog,
                      ),
                      _permissionModeRow(strings, colors),
                      if (_validationError.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          _validationError,
                          key: const Key('assistant-configuration-error'),
                          style: TextStyle(color: colors.error),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Divider(height: 1, color: colors.line),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(strings.cancel),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('assistant-configuration-save'),
                      onPressed: loading || !widget.groupSelected
                          ? null
                          : _save,
                      child: _savePending
                          ? const SizedBox.square(
                              dimension: 14,
                              child: LicoLoadingIndicator(strokeWidth: 2),
                            )
                          : Text(strings.save),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
