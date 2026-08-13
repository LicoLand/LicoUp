import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_editor_models.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_multi_capsule_section.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_workflow_diagram.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

Future<void> showAdaptiveFlywheelDialog(
  BuildContext context,
  ClientController clientController,
) {
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _AdaptiveFlywheelDialog(clientController: clientController),
  );
}

final class _AdaptiveFlywheelDialog extends StatefulWidget {
  const _AdaptiveFlywheelDialog({required this.clientController});

  final ClientController clientController;

  @override
  State<_AdaptiveFlywheelDialog> createState() =>
      _AdaptiveFlywheelDialogState();
}

final class _AdaptiveFlywheelDialogState
    extends State<_AdaptiveFlywheelDialog> {
  late final AdaptiveFlywheelController _controller;
  final Map<String, List<DailyConversationAgentAssignment>> _assignments = {};
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
    _controller = AdaptiveFlywheelController(
      gateway: widget.clientController.adaptiveFlywheelGateway,
    )..addListener(_changed);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
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
    final binding = _controller.inspection!.bindings[slot.id];
    final boundTarget = binding == null
        ? null
        : _targetById(targets, binding.valueId);
    final target = boundTarget ?? (targets.isEmpty ? null : targets.first);
    if (target == null) return const [];
    final models = agentOrchestrationCommanderModels(target);
    final model = binding?.model.trim().isNotEmpty == true
        ? binding!.model.trim()
        : (models.isEmpty ? '' : models.first);
    final effort = binding?.reasoningEffort.trim().isNotEmpty == true
        ? binding!.reasoningEffort.trim()
        : agentOrchestrationDefaultReasoningEffortForModel(target, model);
    return [
      DailyConversationAgentAssignment(
        id: 'strategy-${slot.id}-${target.target}',
        agentId: target.target,
        modelName: model,
        reasoningEffort: effort,
      ),
    ];
  }

  TargetCandidate? _targetById(Iterable<TargetCandidate> targets, String id) {
    for (final target in targets) {
      if (target.target == id) return target;
    }
    return null;
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
      _assignments[slotId] = values.isEmpty ? const [] : [values.last];
    });
  }

  Future<void> _save() async {
    final inspection = _controller.inspection;
    if (inspection == null) return;
    final missing = inspection.slots
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
    await _controller.saveActorBindings({
      for (final slot in inspection.slots.where((slot) => slot.kind == 'actor'))
        if (_assignments[slot.id]?.isNotEmpty == true)
          slot.id: AdaptiveFlywheelBinding(
            slotId: slot.id,
            valueId: _assignments[slot.id]!.single.agentId,
            model: _assignments[slot.id]!.single.modelName,
            reasoningEffort: _assignments[slot.id]!.single.reasoningEffort,
          ),
    });
    if (!mounted || _controller.error.isNotEmpty) return;
    if (_controller.inspection?.diagnosticCode == 'binding_incomplete') {
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

  String _slotTitle(AdaptiveFlywheelSlot slot, LicoStrings strings) {
    return switch (slot.id) {
      'designer' => strings.codeEngineeringDesigner,
      'worker' => strings.codeEngineeringWorker,
      'reviewer' => strings.codeEngineeringReviewer,
      _ => slot.label,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final inspection = _controller.inspection;
    final actorSlots = inspection?.slots
        .where((slot) => slot.kind == 'actor')
        .toList(growable: false);
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('adaptive-flywheel-import-package'),
                        onPressed: _controller.busy ? null : _importPackage,
                        icon: const Icon(Icons.inventory_2_outlined),
                        label: Text(_copy('导入策略', 'Import strategy')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          key: const Key('adaptive-flywheel-definition'),
                          initialValue: _controller.selectedRevision.isEmpty
                              ? null
                              : _controller.selectedRevision,
                          decoration: InputDecoration(
                            labelText: _copy('策略', 'Strategy'),
                          ),
                          items: _controller.definitions
                              .map(
                                (definition) => DropdownMenuItem(
                                  value: definition.revisionDigest,
                                  child: Text(
                                    '${definition.name} · ${definition.version}',
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: _controller.busy
                              ? null
                              : (revision) {
                                  if (revision != null) {
                                    _selectDefinition(revision);
                                  }
                                },
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        key: const Key('adaptive-flywheel-workflow'),
                        tooltip: _copy('工作流程', 'Workflow'),
                        onPressed: inspection == null
                            ? null
                            : () => showAdaptiveFlywheelWorkflowDiagram(
                                context,
                                inspection,
                              ),
                        icon: const Icon(Icons.account_tree_outlined),
                      ),
                    ],
                  ),
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
                  if (actorSlots == null || actorSlots.isEmpty)
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
                        title: _slotTitle(actorSlots[index], strings),
                        keyPrefix: 'adaptive-flywheel-${actorSlots[index].id}',
                        idPrefix: 'strategy-${actorSlots[index].id}',
                        assignments:
                            _assignments[actorSlots[index].id] ?? const [],
                        targets: _targets,
                        onChanged: (values) =>
                            _setAssignments(actorSlots[index].id, values),
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
                        _controller.busy || _controller.inspection == null
                        ? null
                        : _save,
                    child: Text(strings.save),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
