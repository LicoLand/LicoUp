import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_editor_models.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_diagram.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_hover_popover.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/assistant_sparkles_icon.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Shared height for the strategy selector and the import button.
const double kAdaptiveFlywheelToolbarControlHeight = 36;

/// Shared corner radius for the toolbar controls and the workflow card.
const double kAdaptiveFlywheelToolbarControlRadius =
    AppleControlMetrics.controlCornerRadius;

/// Fixed viewport for the expanded workflow diagram inside the card.
const double kAdaptiveFlywheelWorkflowExpandedHeight = 360;

Future<void> showAdaptiveFlywheelDialog(
  BuildContext context,
  ClientController clientController, {
  String initialRevision = '',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _AdaptiveFlywheelDialog(
      clientController: clientController,
      initialRevision: initialRevision,
    ),
  );
}

final class _AdaptiveFlywheelDialog extends StatefulWidget {
  const _AdaptiveFlywheelDialog({
    required this.clientController,
    required this.initialRevision,
  });

  final ClientController clientController;
  final String initialRevision;

  @override
  State<_AdaptiveFlywheelDialog> createState() =>
      _AdaptiveFlywheelDialogState();
}

final class _AdaptiveFlywheelDialogState
    extends State<_AdaptiveFlywheelDialog> {
  late final AdaptiveFlywheelController _controller;
  final Map<String, List<DailyConversationAgentAssignment>> _assignments = {};
  DailyConversationAgentAssignment _assistantDraft =
      const DailyConversationAgentAssignment();
  String _assistantConversationId = '';
  bool _assistantLoading = false;
  bool _assistantSaving = false;
  String _loadedRevision = '';
  String _validationError = '';
  bool _draftDirty = false;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _copy(String zh, String en) => _zh ? zh : en;

  List<TargetCandidate> get _targets => agentOrchestrationCommanderTargets(
    widget.clientController.scannedTargets,
  );

  @override
  void initState() {
    super.initState();
    widget.clientController.addListener(_onClientChanged);
    _controller = AdaptiveFlywheelController(
      gateway: widget.clientController.adaptiveFlywheelGateway,
    )..addListener(_changed);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    await Future.wait([_controller.initialize(), _loadAssistantProfile()]);
    if (!mounted) return;
    if (widget.initialRevision.isNotEmpty) {
      final revisionExists = _controller.definitions.any(
        (definition) => definition.revisionDigest == widget.initialRevision,
      );
      if (revisionExists &&
          _controller.selectedRevision != widget.initialRevision) {
        await _controller.selectDefinition(widget.initialRevision);
      }
    }
    _syncDraft(force: true);
    unawaited(_refreshSelectedModelCatalogs());
  }

  Future<void> _refreshSelectedModelCatalogs() async {
    final targetIds = <String>{};
    final inspection = _controller.inspection;
    if (inspection != null) {
      for (final bindings in inspection.bindings.values) {
        for (final binding in bindings) {
          final id = binding.valueId.trim();
          if (id.isNotEmpty) targetIds.add(id);
        }
      }
    }
    final assistantId = _assistantDraft.agentId.trim();
    if (assistantId.isNotEmpty) targetIds.add(assistantId);
    await widget.clientController.refreshAgentModelCatalogs(targetIds);
    if (!mounted) return;
    _syncDraft(force: true);
    setState(() {});
  }

  @override
  void dispose() {
    widget.clientController.removeListener(_onClientChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  void _onClientChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _changed() {
    if (!mounted) return;
    _syncDraft();
    setState(() {});
  }

  void _syncDraft({bool force = false}) {
    final inspection = _controller.inspection;
    final revision = _controller.selectedRevision;
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

  List<DailyConversationAgentAssignment> _assignmentFor(
    AdaptiveFlywheelSlot slot,
    List<TargetCandidate> targets,
  ) {
    final bindings = _controller.inspection!.bindings[slot.id] ?? const [];
    final assignments = <DailyConversationAgentAssignment>[];
    for (var index = 0; index < bindings.length; index += 1) {
      final binding = bindings[index];
      final target = _targetById(targets, binding.valueId);
      if (target == null) continue;
      final models = agentOrchestrationCommanderModels(target);
      final model = binding.model.trim().isNotEmpty
          ? binding.model.trim()
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

  ClientConversation? get _assistantConversation {
    final conversation = widget
        .clientController
        .clientConversationController
        .selectedConversation;
    return conversation?.group == true ? conversation : null;
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

  ClientConversationMembership? _membershipForAgent(
    ClientConversation conversation,
    String agentId,
  ) {
    for (final membership in conversation.activeAgentMemberships) {
      if (membership.principal.agentId == agentId) return membership;
    }
    return null;
  }

  Future<void> _loadAssistantProfile() async {
    final conversation = _assistantConversation;
    if (conversation == null) return;
    final conversationId = conversation.id;
    final membership =
        conversation.assistantMembership ??
        (conversation.activeAgentMemberships.isEmpty
            ? null
            : conversation.activeAgentMemberships.first);
    final targets = _targets;
    final agentId =
        membership?.principal.agentId.trim() ??
        (targets.isEmpty ? '' : targets.first.target);
    if (mounted) {
      setState(() {
        _assistantConversationId = conversationId;
        _assistantLoading = membership != null;
        _assistantDraft = _assistantAssignmentDefaults(agentId);
      });
    }
    if (membership == null) return;
    try {
      final profile = await widget.clientController.clientConversationController
          .membershipProfile(membership.id);
      if (!mounted ||
          _assistantConversation?.id != conversationId ||
          _assistantConversationId != conversationId) {
        return;
      }
      setState(() {
        _assistantDraft = _assistantAssignmentDefaults(
          agentId,
          preferredModel: (profile?['preferredModel'] ?? '').toString(),
          preferredReasoningEffort: (profile?['preferredReasoningEffort'] ?? '')
              .toString(),
        );
        _assistantLoading = false;
      });
    } on Object {
      if (!mounted || _assistantConversationId != conversationId) return;
      setState(() => _assistantLoading = false);
    }
  }

  List<String> _profileStringList(Object? value) => value is List
      ? value
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false)
      : const [];

  Future<bool> _saveAssistantProfile() async {
    final controller = widget.clientController.clientConversationController;
    final conversation = controller.selectedConversation;
    final conversationId = conversation?.id ?? '';
    final agentId = _assistantDraft.agentId.trim();
    if (conversation == null ||
        !conversation.group ||
        conversationId != _assistantConversationId ||
        agentId.isEmpty) {
      return false;
    }
    var membership = _membershipForAgent(conversation, agentId);
    if (membership == null) {
      final target = _targetById(_targets, agentId);
      final joined = await controller.ensureSelectedAgentMembership(
        agentId: agentId,
        displayName: target == null
            ? agentId
            : agentConversationTargetDisplayName(target),
      );
      if (!joined) return false;
      final refreshed = controller.selectedConversation;
      if (refreshed == null || refreshed.id != conversationId) return false;
      membership = _membershipForAgent(refreshed, agentId);
    }
    if (membership == null) return false;
    if (!await controller.setSelectedAssistantMembership(membership.id)) {
      return false;
    }
    final profile = await controller.membershipProfile(membership.id);
    if (profile == null) return false;
    final model = _assistantDraft.modelName.trim();
    final effort = _assistantDraft.reasoningEffort.trim();
    await controller.updateMembershipProfileIntent(
      membershipId: membership.id,
      expectedRevision: (profile['revision'] as num?)?.toInt() ?? 0,
      intent: {
        'requiredCapabilities': _profileStringList(
          profile['requiredCapabilities'],
        ),
        'preferredCapabilities': _profileStringList(
          profile['preferredCapabilities'],
        ),
        'skillReferences': _profileStringList(profile['skillReferences']),
        'preferredModel': model.isEmpty ? null : model,
        'preferredReasoningEffort': effort.isEmpty ? null : effort,
        'preferredEnvironment': profile['preferredEnvironment'],
      },
    );
    return mounted && controller.selectedConversationId == conversationId;
  }

  Future<void> _importPackage() async {
    const zip = XTypeGroup(label: 'ZIP', extensions: ['zip']);
    final file = await openFile(acceptedTypeGroups: const [zip]);
    if (file == null) return;
    _loadedRevision = '';
    _draftDirty = false;
    await _controller.importPackage(file.path);
    _syncDraft(force: true);
  }

  void _selectDefinition(String revision) {
    _loadedRevision = '';
    _draftDirty = false;
    unawaited(_controller.selectDefinition(revision));
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

  Future<void> _save() async {
    final inspection = _controller.inspection;
    final hasAssistant = _assistantConversation != null;
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
        ? const <AdaptiveFlywheelSlot>[]
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
      _assistantSaving = true;
      _validationError = '';
    });
    try {
      if (hasAssistant && !await _saveAssistantProfile()) {
        if (!mounted) return;
        setState(() {
          _validationError = _copy(
            'Assistant 配置保存失败，请重试。',
            'Assistant profile could not be saved. Try again.',
          );
        });
        return;
      }
      if (inspection != null) {
        await _controller.saveActorBindings({
          for (final slot in inspection.slots.where(
            (slot) => slot.kind == 'actor',
          ))
            slot.id: [
              for (
                var index = 0;
                index < (_assignments[slot.id]?.length ?? 0);
                index += 1
              )
                AdaptiveFlywheelBinding(
                  slotId: slot.id,
                  ordinal: index,
                  valueId: _assignments[slot.id]![index].agentId,
                  model: _assignments[slot.id]![index].modelName,
                  reasoningEffort:
                      _assignments[slot.id]![index].reasoningEffort,
                ),
            ],
        });
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _validationError = _copy(
          '配置保存失败，请重试。',
          'The configuration could not be saved. Try again.',
        );
      });
      return;
    } finally {
      if (mounted) setState(() => _assistantSaving = false);
    }
    if (!mounted || _controller.error.isNotEmpty) return;
    if (inspection != null &&
        _controller.inspection?.diagnosticCode == 'binding_incomplete') {
      setState(() {
        _validationError = _copy(
          '后台未检测到策略所需的本机运行时，请安装后重试。',
          'A required local runtime was not detected in the background. Install it and retry.',
        );
      });
      return;
    }
    Navigator.of(context).pop();
  }

  String _slotTitle(AdaptiveFlywheelSlot slot) {
    final label = slot.label.trim();
    if (label.isNotEmpty) return label;
    return slot.id;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final inspection = _controller.inspection;
    final actorSlots = inspection?.slots
        .where((slot) => slot.kind == 'actor')
        .toList(growable: false);
    final showAssistantCard = _assistantConversation != null;
    return Dialog(
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
                      loading: _assistantLoading || _assistantSaving,
                      onDraftChanged: (draft) {
                        setState(() {
                          _validationError = '';
                          _assistantDraft = _assistantAssignmentDefaults(
                            draft.agentId,
                            preferredModel: draft.modelName,
                            preferredReasoningEffort: draft.reasoningEffort,
                          );
                        });
                      },
                      isRefreshingAgentCatalog: widget
                          .clientController
                          .isRefreshingNativeModelCatalog,
                      onAgentCatalogRequested: widget
                          .clientController
                          .ensureSelectedAgentModelCatalog,
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
                          onPressed: _controller.busy ? null : _importPackage,
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
                  if (_controller.busy) ...[
                    const SizedBox(height: 10),
                    const LinearProgressIndicator(),
                  ],
                  if (_controller.error.isNotEmpty ||
                      _validationError.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      _validationError.isNotEmpty
                          ? _validationError
                          : _controller.error,
                      key: const Key('adaptive-flywheel-error'),
                      style: TextStyle(color: colors.error),
                    ),
                  ],
                  const SizedBox(height: 22),
                  if (_controller.definitions.isEmpty)
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
                    for (var index = 0; index < actorSlots.length; index++) ...[
                      AdaptiveFlywheelMultiCapsuleSection(
                        title: _slotTitle(actorSlots[index]),
                        keyPrefix: 'adaptive-flywheel-${actorSlots[index].id}',
                        idPrefix: 'strategy-${actorSlots[index].id}',
                        assignments:
                            _assignments[actorSlots[index].id] ?? const [],
                        targets: _targets,
                        onChanged: (values) =>
                            _setAssignments(actorSlots[index].id, values),
                        isRefreshingAgentCatalog: widget
                            .clientController
                            .isRefreshingNativeModelCatalog,
                        onAgentCatalogRequested: widget
                            .clientController
                            .ensureSelectedAgentModelCatalog,
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
                        _controller.busy ||
                            _assistantLoading ||
                            _assistantSaving ||
                            (!showAssistantCard &&
                                _controller.inspection == null)
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
    );
  }

  Widget _strategySelector(LicoThemeColors colors) {
    final empty = _controller.definitions.isEmpty;
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
                  for (final definition in _controller.definitions)
                    MessagingGlassMenuItem(
                      key: Key(
                        'adaptive-flywheel-option-${definition.revisionDigest}',
                      ),
                      label: '${definition.name} · ${definition.version}',
                      selected:
                          definition.revisionDigest ==
                          _controller.selectedRevision,
                      onTap: _controller.busy
                          ? null
                          : () {
                              close();
                              _selectDefinition(definition.revisionDigest);
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

  AdaptiveFlywheelDefinition? _selectedDefinition() {
    for (final definition in _controller.definitions) {
      if (definition.revisionDigest == _controller.selectedRevision) {
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

  final AdaptiveFlywheelInspection? inspection;

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
