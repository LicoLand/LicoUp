import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_indicator.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

Future<void> showAssistantConfigurationDialog(
  BuildContext context, {
  required ConversationBinding conversation,
  required AgentsBinding agents,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ProjectionBuilder<AgentsProjection, AgentsProjection>(
      source: agents.projection,
      select: (projection) => projection,
      builder: (context, agentsProjection) =>
          ProjectionBuilder<
            CanonicalConversationProjection,
            CanonicalConversationProjection
          >(
            source: conversation.canonicalEvents,
            select: (projection) => projection,
            builder: (context, canonical) => _AssistantConfigurationDialog(
              agents: agents,
              agentsProjection: agentsProjection,
              groupSelected: canonical.conversation?.group == true,
            ),
          ),
    ),
  );
}

final class _AssistantConfigurationDialog extends StatefulWidget {
  const _AssistantConfigurationDialog({
    required this.agents,
    required this.agentsProjection,
    required this.groupSelected,
  });

  final AgentsBinding agents;
  final AgentsProjection agentsProjection;
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

  AdaptiveFlywheelProjection get _adaptive =>
      widget.agentsProjection.adaptiveFlywheel;

  List<TargetCandidate> get _targets =>
      agentOrchestrationCommanderTargets(widget.agentsProjection.targetDetails);

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _copy(String zh, String en) => _zh ? zh : en;

  @override
  void initState() {
    super.initState();
    _synchronizeFromProjection(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.agents.intents.send(const ReadAdaptiveFlywheelAssistantProfile());
    });
  }

  @override
  void didUpdateWidget(_AssistantConfigurationDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentsProjection.adaptiveFlywheel != _adaptive ||
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
      );
    }
    final targetId = _draft.agentId.trim();
    if (targetId.isNotEmpty && targetId != _refreshedCatalogKey) {
      _refreshedCatalogKey = targetId;
      widget.agents.intents.send(
        RefreshAdaptiveFlywheelModelCatalogs(agentIds: [targetId]),
      );
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
  }) {
    final target = _targetById(agentId);
    if (target == null) {
      return DailyConversationAgentAssignment(
        agentId: agentId,
        modelName: preferredModel,
        reasoningEffort: preferredReasoningEffort,
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
    );
  }

  bool _isRefreshingModelCatalog(String agentId) =>
      _adaptive.agent(agentId)?.refreshingModelCatalog ?? false;

  void _requestModelCatalog(String agentId) {
    widget.agents.intents.send(
      RefreshAdaptiveFlywheelModelCatalogs(agentIds: [agentId]),
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
      UpdateAdaptiveFlywheelAssistantProfile(
        agentId: _draft.agentId,
        modelId: _draft.modelName,
        reasoningEffort: _draft.reasoningEffort,
      ),
    );
  }

  void _handleEffect(AgentsEffect effect) {
    if (!mounted || !_savePending) return;
    switch (effect) {
      case AdaptiveFlywheelSaveCompleted():
        _savePending = false;
        Navigator.of(context).pop();
      case AdaptiveFlywheelActionRejected(:final reasonCode):
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                      Text(
                        _copy(
                          '选择 Assistant 使用的 Agent、模型和推理强度。此配置独立于 Adaptive Flywheel。',
                          'Choose the Agent, model, and reasoning effort used by Assistant. This profile is independent of Adaptive Flywheel.',
                        ),
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                      if (loading) ...[
                        const SizedBox(height: 12),
                        const LinearProgressIndicator(minHeight: 2),
                      ],
                      const SizedBox(height: 16),
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
