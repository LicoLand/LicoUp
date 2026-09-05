import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_diagram.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

/// Shared height for the strategy selector and the import button.
const double kAdaptiveFlywheelToolbarControlHeight = 36;

/// Shared corner radius for the toolbar controls and the workflow card.
const double kAdaptiveFlywheelToolbarControlRadius =
    AppleControlMetrics.controlCornerRadius;

/// Fixed viewport for the expanded workflow diagram inside the card.
const double kAdaptiveFlywheelWorkflowExpandedHeight = 360;

Future<void> showAdaptiveFlywheelDialog(
  BuildContext context, {
  required ConversationBinding conversation,
  required AgentsBinding agents,
  String initialRevision = '',
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
            builder: (context, canonical) => _AdaptiveFlywheelDialog(
              agents: agents,
              agentsProjection: agentsProjection,
              canonical: canonical,
              initialRevision: initialRevision,
            ),
          ),
    ),
  );
}

final class _AdaptiveFlywheelDialog extends StatefulWidget {
  const _AdaptiveFlywheelDialog({
    required this.agents,
    required this.agentsProjection,
    required this.canonical,
    required this.initialRevision,
  });

  final AgentsBinding agents;
  final AgentsProjection agentsProjection;
  final CanonicalConversationProjection canonical;
  final String initialRevision;

  @override
  State<_AdaptiveFlywheelDialog> createState() =>
      _AdaptiveFlywheelDialogState();
}

final class _AdaptiveFlywheelDialogState
    extends State<_AdaptiveFlywheelDialog> {
  final Map<String, List<DailyConversationAgentAssignment>> _assignments = {};
  DailyConversationAgentAssignment _assistantDraft =
      const DailyConversationAgentAssignment();
  String _loadedRevision = '';
  String _validationError = '';
  String _refreshedCatalogKey = '';
  bool _draftDirty = false;
  bool _assistantDirty = false;
  bool _assistantSaving = false;
  bool _savePending = false;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _copy(String zh, String en) => _zh ? zh : en;
  AdaptiveFlywheelProjection get _adaptive =>
      widget.agentsProjection.adaptiveFlywheel;

  List<TargetCandidate> get _targets =>
      agentOrchestrationCommanderTargets(widget.agentsProjection.targetDetails);

  @override
  void initState() {
    super.initState();
    _synchronizeFromProjection(force: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.agents.intents.send(
        InitializeAdaptiveFlywheel(initialRevision: widget.initialRevision),
      );
    });
  }

  @override
  void didUpdateWidget(_AdaptiveFlywheelDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agentsProjection.adaptiveFlywheel != _adaptive ||
        oldWidget.canonical != widget.canonical) {
      _synchronizeFromProjection();
    }
  }

  void _synchronizeFromProjection({bool force = false}) {
    _syncDraft(force: force);
    _syncAssistant(force: force);
    _refreshSelectedModelCatalogs();
    if (_assistantSaving && !_adaptive.assistant.saving) {
      _assistantSaving = false;
    }
  }

  void _syncDraft({bool force = false}) {
    final inspection = _adaptive.inspection;
    final revision = _adaptive.selectedRevision;
    if (inspection == null || revision.isEmpty) return;
    if (!force && (_draftDirty || _loadedRevision == revision)) return;
    final targets = _targets;
    _assignments
      ..clear()
      ..addEntries(
        inspection.slots
            .where((slot) => slot.kind == 'actor')
            .map((slot) => MapEntry(slot.id, _assignmentFor(slot, targets))),
      );
    _loadedRevision = revision;
    _draftDirty = false;
    _validationError = '';
  }

  void _syncAssistant({bool force = false}) {
    final assistant = _adaptive.assistant;
    if (!assistant.available) {
      if (force || !_assistantDirty) {
        _assistantDraft = const DailyConversationAgentAssignment();
      }
      return;
    }
    if (!force && _assistantDirty) return;
    _assistantDraft = _assistantAssignmentDefaults(
      assistant.agentId,
      preferredModel: assistant.modelId,
      preferredReasoningEffort: assistant.reasoningEffort,
    );
  }

  List<DailyConversationAgentAssignment> _assignmentFor(
    AdaptiveFlywheelSlotProjection slot,
    List<TargetCandidate> targets,
  ) {
    final bindings = _adaptive.inspection!.assignmentsFor(slot.id);
    final assignments = <DailyConversationAgentAssignment>[];
    for (var index = 0; index < bindings.length; index += 1) {
      final binding = bindings[index];
      final target = _targetById(targets, binding.agentId);
      if (target == null) continue;
      final models = agentOrchestrationCommanderModels(target);
      final model = binding.modelId.trim().isNotEmpty
          ? binding.modelId.trim()
          : (models.isEmpty ? '' : models.first);
      final effort = binding.reasoningEffort.trim().isNotEmpty
          ? binding.reasoningEffort.trim()
          : agentOrchestrationDefaultReasoningEffortForModel(target, model);
      assignments.add(
        DailyConversationAgentAssignment(
          id: 'strategy-${slot.id}-$index-${target.target}',
          agentId: target.target,
          modelName: model,
          reasoningEffort: effort,
        ),
      );
    }
    return assignments;
  }

  TargetCandidate? _targetById(Iterable<TargetCandidate> targets, String id) {
    for (final target in targets) {
      if (target.target == id) return target;
    }
    return null;
  }

  DailyConversationAgentAssignment _assistantAssignmentDefaults(
    String agentId, {
    String preferredModel = '',
    String preferredReasoningEffort = '',
  }) {
    final target = _targetById(_targets, agentId);
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

  void _refreshSelectedModelCatalogs() {
    final targetIds = <String>{};
    final inspection = _adaptive.inspection;
    if (inspection != null) {
      for (final binding in inspection.assignments) {
        final id = binding.agentId.trim();
        if (id.isNotEmpty) targetIds.add(id);
      }
    }
    final assistantId = _assistantDraft.agentId.trim();
    if (assistantId.isNotEmpty) targetIds.add(assistantId);
    final ids = targetIds.toList()..sort();
    final catalogKey = ids.join('\u0000');
    if (catalogKey == _refreshedCatalogKey) return;
    _refreshedCatalogKey = catalogKey;
    if (ids.isNotEmpty) {
      widget.agents.intents.send(
        RefreshAdaptiveFlywheelModelCatalogs(agentIds: ids),
      );
    }
  }

  bool _isRefreshingModelCatalog(String agentId) =>
      _adaptive.agent(agentId)?.refreshingModelCatalog ?? false;

  void _requestModelCatalog(String agentId) {
    widget.agents.intents.send(
      RefreshAdaptiveFlywheelModelCatalogs(agentIds: [agentId]),
    );
  }

  Future<void> _importPackage() async {
    const zip = XTypeGroup(label: 'ZIP', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [zip]);
    if (file == null) return;
    _loadedRevision = '';
    _draftDirty = false;
    widget.agents.intents.send(ImportAdaptiveFlywheelPackage(file.path));
  }

  void _selectDefinition(String revision) {
    _loadedRevision = '';
    _draftDirty = false;
    widget.agents.intents.send(SelectAdaptiveFlywheelDefinition(revision));
  }

  void _setAssignments(
    String slotId,
    List<DailyConversationAgentAssignment> values,
  ) {
    setState(() {
      _draftDirty = true;
      _validationError = '';
      _assignments[slotId] = List<DailyConversationAgentAssignment>.from(
        values,
      );
    });
  }

  void _save() {
    final inspection = _adaptive.inspection;
    final hasAssistant =
        widget.canonical.conversation?.group == true &&
        _adaptive.assistant.available;
    if (!hasAssistant && inspection == null) return;
    if (hasAssistant && _assistantDraft.agentId.trim().isEmpty) {
      setState(() {
        _validationError = _copy(
          '请为 Assistant 选择一个可调用 Agent。',
          'Choose one callable Agent for the Assistant.',
        );
      });
      return;
    }
    final missing = inspection == null
        ? const <AdaptiveFlywheelSlotProjection>[]
        : inspection.slots
              .where((slot) => slot.kind == 'actor' && slot.required)
              .where((slot) => _assignments[slot.id]?.isNotEmpty != true)
              .toList(growable: false);
    if (missing.isNotEmpty) {
      setState(() {
        _validationError = _copy(
          '请为每个必需角色选择一个可调用 Agent。',
          'Choose one callable Agent for every required role.',
        );
      });
      return;
    }
    setState(() {
      _assistantSaving = hasAssistant;
      _savePending = true;
      _validationError = '';
    });
    widget.agents.intents.send(
      SaveAdaptiveFlywheelConfiguration(
        assignments: [
          for (final slot
              in inspection?.slots.where((slot) => slot.kind == 'actor') ??
                  const <AdaptiveFlywheelSlotProjection>[])
            for (
              var index = 0;
              index < (_assignments[slot.id]?.length ?? 0);
              index += 1
            )
              AdaptiveFlywheelAssignmentIntent(
                slotId: slot.id,
                ordinal: index,
                agentId: _assignments[slot.id]![index].agentId,
                modelId: _assignments[slot.id]![index].modelName,
                reasoningEffort: _assignments[slot.id]![index].reasoningEffort,
              ),
        ],
        updateAssistant: hasAssistant,
        assistantAgentId: _assistantDraft.agentId,
        assistantModelId: _assistantDraft.modelName,
        assistantReasoningEffort: _assistantDraft.reasoningEffort,
      ),
    );
  }

  void _handleEffect(AgentsEffect effect) {
    if (!mounted || !_savePending) return;
    switch (effect) {
      case AdaptiveFlywheelSaveCompleted() ||
          AdaptiveFlywheelConfigurationSaved():
        _savePending = false;
        Navigator.of(context).pop();
      case AdaptiveFlywheelActionRejected(:final reasonCode):
        setState(() {
          _savePending = false;
          _assistantSaving = false;
          _validationError = reasonCode;
        });
      case AgentSelectionRejected() || AgentWorkingDirectorySelectionRejected():
        break;
    }
  }

  String _slotTitle(AdaptiveFlywheelSlotProjection slot) {
    final label = slot.label.trim();
    if (label.isNotEmpty) return label;
    return slot.id;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final inspection = _adaptive.inspection;
    final actorSlots = inspection?.slots
        .where((slot) => slot.kind == 'actor')
        .toList(growable: false);
    final showAssistantCard =
        widget.canonical.conversation?.group == true &&
        _adaptive.assistant.available;
    return EffectListener<AgentsEffect>(
      source: widget.agents.effects,
      onEffect: _handleEffect,
      child: Dialog(
        key: const Key('adaptive-flywheel-dialog'),
        backgroundColor: colors.surface,
        insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780, maxHeight: 680),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, color: colors.textSecondary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Adaptive Flywheel',
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
              Expanded(
                child: ListView(
                  key: const Key('main-agent-settings'),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (showAssistantCard) ...[
                      _AdaptiveFlywheelAssistantCard(
                        targets: _targets,
                        draft: _assistantDraft,
                        loading:
                            _adaptive.assistant.loading || _assistantSaving,
                        onDraftChanged: (draft) {
                          setState(() {
                            _validationError = '';
                            _assistantDirty = true;
                            _assistantDraft = _assistantAssignmentDefaults(
                              draft.agentId,
                              preferredModel: draft.modelName,
                              preferredReasoningEffort: draft.reasoningEffort,
                            );
                          });
                        },
                        isRefreshingAgentCatalog: _isRefreshingModelCatalog,
                        onAgentCatalogRequested: _requestModelCatalog,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(child: _strategySelector(colors)),
                        const SizedBox(width: 12),
                        SizedBox(
                          height: kAdaptiveFlywheelToolbarControlHeight,
                          child: OutlinedButton.icon(
                            key: const Key('adaptive-flywheel-import-package'),
                            onPressed: _adaptive.busy ? null : _importPackage,
                            style: _toolbarButtonStyle(colors),
                            icon: const Icon(
                              Icons.inventory_2_outlined,
                              size: 18,
                            ),
                            label: Text(_copy('导入策略', 'Import strategy')),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _AdaptiveFlywheelWorkflowCard(inspection: inspection),
                    if (_adaptive.busy) ...[
                      const SizedBox(height: 10),
                      const LinearProgressIndicator(),
                    ],
                    if (_adaptive.error.isNotEmpty ||
                        _validationError.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        _validationError.isNotEmpty
                            ? _validationError
                            : _adaptive.error,
                        key: const Key('adaptive-flywheel-error'),
                        style: TextStyle(color: colors.error),
                      ),
                    ],
                    const SizedBox(height: 22),
                    if (_adaptive.definitions.isEmpty)
                      Text(
                        _copy(
                          '尚未导入策略。请先导入 ZIP 配置包。',
                          'No strategies yet. Import a ZIP package first.',
                        ),
                        style: TextStyle(color: colors.textMuted),
                      )
                    else if (actorSlots == null || actorSlots.isEmpty)
                      Text(
                        _copy(
                          '当前策略没有需要配置的 Agent 角色。',
                          'This strategy has no Agent roles to configure.',
                        ),
                        style: TextStyle(color: colors.textMuted),
                      )
                    else
                      for (
                        var index = 0;
                        index < actorSlots.length;
                        index++
                      ) ...[
                        AdaptiveFlywheelMultiCapsuleSection(
                          title: _slotTitle(actorSlots[index]),
                          keyPrefix:
                              'adaptive-flywheel-${actorSlots[index].id}',
                          idPrefix: 'strategy-${actorSlots[index].id}',
                          assignments:
                              _assignments[actorSlots[index].id] ?? const [],
                          targets: _targets,
                          onChanged: (values) =>
                              _setAssignments(actorSlots[index].id, values),
                          isRefreshingAgentCatalog: _isRefreshingModelCatalog,
                          onAgentCatalogRequested: _requestModelCatalog,
                        ),
                        if (index != actorSlots.length - 1)
                          const SizedBox(height: 16),
                      ],
                  ],
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
                      key: const Key('main-agent-save'),
                      onPressed:
                          _adaptive.busy ||
                              _adaptive.assistant.loading ||
                              _assistantSaving ||
                              (!showAssistantCard &&
                                  _adaptive.inspection == null)
                          ? null
                          : _save,
                      child: _assistantSaving
                          ? const SizedBox.square(
                              dimension: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
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

  Widget _strategySelector(LicoThemeColors colors) {
    final empty = _adaptive.definitions.isEmpty;
    final selected = _selectedDefinition();
    final emptyLabel = _copy(
      '尚未导入策略。请先导入 ZIP 配置包。',
      'No strategies yet. Import a ZIP package first.',
    );
    final label = empty
        ? emptyLabel
        : (selected == null
              ? _copy('策略', 'Strategy')
              : '${selected.name} · ${selected.version}');
    final radius = BorderRadius.circular(kAdaptiveFlywheelToolbarControlRadius);
    final menuRadius = BorderRadius.circular(
      AppleControlMetrics.menuCornerRadius,
    );
    return SizedBox(
      key: empty ? null : const Key('adaptive-flywheel-definition'),
      height: kAdaptiveFlywheelToolbarControlHeight,
      child: MessagingHoverPopover(
        wrapInGlass: false,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 4),
        maxHeight: MessagingDesktopMetrics.composerOptionPopoverMaxHeight,
        borderRadius: menuRadius,
        cardBuilder: (context, close) {
          return MessagingGlassOptionCard(
            borderRadius: menuRadius,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (empty)
                  MessagingGlassMenuItem(label: emptyLabel, enabled: false)
                else
                  for (final definition in _adaptive.definitions)
                    MessagingGlassMenuItem(
                      key: Key(
                        'adaptive-flywheel-option-${definition.revision}',
                      ),
                      label: '${definition.name} · ${definition.version}',
                      selected:
                          definition.revision == _adaptive.selectedRevision,
                      onTap: _adaptive.busy
                          ? null
                          : () {
                              close();
                              _selectDefinition(definition.revision);
                            },
                    ),
              ],
            ),
          );
        },
        triggerBuilder:
            (context, {required open, required toggle, required close}) {
              return SizedBox.expand(
                child: AppleGlassSurface(
                  borderRadius: radius,
                  focused: open,
                  child: InkWell(
                    onTap: toggle,
                    borderRadius: radius,
                    mouseCursor: SystemMouseCursors.click,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                label,
                                key: empty
                                    ? const Key(
                                        'adaptive-flywheel-empty-catalog',
                                      )
                                    : null,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: empty || selected == null
                                      ? colors.textMuted
                                      : colors.text,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 18,
                            color: colors.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
      ),
    );
  }

  AdaptiveFlywheelDefinitionProjection? _selectedDefinition() {
    for (final definition in _adaptive.definitions) {
      if (definition.revision == _adaptive.selectedRevision) {
        return definition;
      }
    }
    return null;
  }
}

final class _AdaptiveFlywheelAssistantCard extends StatelessWidget {
  const _AdaptiveFlywheelAssistantCard({
    required this.targets,
    required this.draft,
    required this.loading,
    required this.onDraftChanged,
    required this.isRefreshingAgentCatalog,
    required this.onAgentCatalogRequested,
  });

  final List<TargetCandidate> targets;
  final DailyConversationAgentAssignment draft;
  final bool loading;
  final ValueChanged<DailyConversationAgentAssignment> onDraftChanged;
  final bool Function(String agentId) isRefreshingAgentCatalog;
  final ValueChanged<String> onAgentCatalogRequested;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final radius = BorderRadius.circular(kAdaptiveFlywheelToolbarControlRadius);
    return AppleGlassSurface(
      key: const Key('adaptive-flywheel-assistant-card'),
      borderRadius: radius,
      fillAlpha: colors.isDark ? 18 : 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.accentSurface,
                    border: Border.all(color: colors.accentBorder),
                  ),
                  child: AssistantSparklesIcon(color: colors.accent, size: 16),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.assistantProfileTitle,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        strings.isChinese
                            ? '独立于工作流的长期调度者配置'
                            : 'Long-term coordinator, independent of workflows',
                        style: TextStyle(color: colors.textMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (loading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(minHeight: 2),
            ],
            const SizedBox(height: 12),
            AgentRuntimeAssignmentCascadeCards(
              keyPrefix: 'adaptive-flywheel-assistant',
              showFast: false,
              borderRadius: BorderRadius.circular(
                AppleControlMetrics.menuCornerRadius,
              ),
              maxHeight: 190,
              agentCardWidth: 188,
              modelCardWidth: 288,
              settingsCardWidth: 184,
              revealSelectionOnOpen: true,
              targets: targets,
              draft: draft,
              selectedAgentIds: draft.agentId.trim().isEmpty
                  ? const {}
                  : {draft.agentId.trim()},
              onDraftChanged: onDraftChanged,
              isRefreshingAgentCatalog: isRefreshingAgentCatalog,
              onAgentCatalogRequested: onAgentCatalogRequested,
            ),
          ],
        ),
      ),
    );
  }
}

ButtonStyle _toolbarButtonStyle(LicoThemeColors colors) {
  return OutlinedButton.styleFrom(
    foregroundColor: colors.text,
    minimumSize: const Size(0, kAdaptiveFlywheelToolbarControlHeight),
    maximumSize: const Size(
      double.infinity,
      kAdaptiveFlywheelToolbarControlHeight,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    side: BorderSide(color: colors.line),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(
        kAdaptiveFlywheelToolbarControlRadius,
      ),
    ),
  );
}

final class _AdaptiveFlywheelWorkflowCard extends StatefulWidget {
  const _AdaptiveFlywheelWorkflowCard({required this.inspection});

  final AdaptiveFlywheelInspectionProjection? inspection;

  @override
  State<_AdaptiveFlywheelWorkflowCard> createState() =>
      _AdaptiveFlywheelWorkflowCardState();
}

final class _AdaptiveFlywheelWorkflowCardState
    extends State<_AdaptiveFlywheelWorkflowCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final enabled = widget.inspection != null;
    final radius = BorderRadius.circular(kAdaptiveFlywheelToolbarControlRadius);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: radius,
        border: Border.all(color: colors.line),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              key: const Key('adaptive-flywheel-workflow'),
              onTap: enabled
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.account_tree_outlined,
                      size: 16,
                      color: enabled ? colors.text : colors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        zh ? '工作流程' : 'Workflow',
                        style: TextStyle(
                          color: enabled ? colors.text : colors.textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: LicoMotion.medium,
              curve: LicoMotion.decelerate,
              alignment: Alignment.topCenter,
              child: _expanded && widget.inspection != null
                  ? SizedBox(
                      height: kAdaptiveFlywheelWorkflowExpandedHeight,
                      child: AdaptiveFlywheelWorkflowDiagram(
                        inspection: widget.inspection!,
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ],
        ),
      ),
    );
  }
}
