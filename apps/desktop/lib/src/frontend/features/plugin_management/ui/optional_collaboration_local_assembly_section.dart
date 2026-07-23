import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_card.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_choice_subtitle.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_plan_review.dart';

final class OptionalCollaborationDeploymentSection extends StatefulWidget {
  const OptionalCollaborationDeploymentSection({
    super.key,
    required this.choices,
    required this.controller,
    required this.isChinese,
  });

  final List<OptionalCollaborationWorkflowChoice> choices;
  final OptionalCollaborationWorkflowController controller;
  final bool isChinese;

  @override
  State<OptionalCollaborationDeploymentSection> createState() =>
      _OptionalCollaborationDeploymentSectionState();
}

final class _OptionalCollaborationDeploymentSectionState
    extends State<OptionalCollaborationDeploymentSection> {
  final TextEditingController _destinationController = TextEditingController();
  final Set<String> _selected = <String>{};
  bool _confirmed = false;

  @override
  void dispose() {
    _destinationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.controller.localDeploymentPlan;
    final busy = widget.controller.busy;
    final inputEnabled = !busy && plan == null;
    return OptionalCollaborationWorkflowCard(
      key: const Key('collaboration-deployment-workflow-section'),
      icon: Icons.dns_outlined,
      title: widget.isChinese ? 'LicoMesh 本机组装' : 'Local LicoMesh assembly',
      policy: widget.isChinese
          ? '从 commit、包清单与信任指纹绑定的包中选择组件，由 LicoArc 自有适配器组装服务端与受签名固定 runner。完成后状态为待部署；runner 只会在下一次单独确认后执行。不执行插件命令或脚本，也不授权外发。'
          : 'Select components from a commit-, inventory-, and trust-bound bundle. A LicoArc-owned adapter assembles the server and signed fixed runner. The result awaits deployment; the runner executes only after a separate direct confirmation. Plugin commands and scripts are not run, and egress is not authorized.',
      isChinese: widget.isChinese,
      children: [
        for (final choice in widget.choices)
          CheckboxListTile(
            key: Key('collaboration-local-choice-${choice.id}'),
            contentPadding: EdgeInsets.zero,
            value: _selected.contains(choice.id),
            onChanged: inputEnabled
                ? (selected) {
                    setState(() {
                      if (selected == true) {
                        _selected.add(choice.id);
                      } else {
                        _selected.remove(choice.id);
                      }
                    });
                  }
                : null,
            title: Text(choice.label),
            subtitle: OptionalCollaborationWorkflowChoiceSubtitle(
              choice: choice,
            ),
          ),
        const SizedBox(height: 6),
        TextField(
          key: const Key('collaboration-local-destination'),
          controller: _destinationController,
          enabled: inputEnabled,
          decoration: InputDecoration(
            labelText: widget.isChinese
                ? '新的本机组装绝对路径'
                : 'New absolute local assembly path',
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('collaboration-local-plan'),
            onPressed: inputEnabled
                ? () {
                    unawaited(_plan());
                  }
                : null,
            icon: const Icon(Icons.fact_check_outlined, size: 16),
            label: Text(widget.isChinese ? '生成组装计划' : 'Create assembly plan'),
          ),
        ),
        if (plan != null) ...[
          const SizedBox(height: 12),
          OptionalCollaborationWorkflowPlanReview(
            plan: plan,
            confirmed: _confirmed,
            busy: busy,
            isChinese: widget.isChinese,
            keyPrefix: 'collaboration-local',
            onConfirmed: (value) {
              setState(() => _confirmed = value ?? false);
            },
            onApply: _confirmed ? _apply : null,
            onCancel: _confirmed ? _cancel : null,
          ),
        ],
      ],
    );
  }

  Future<void> _plan() async {
    final planned = await widget.controller.planLocalDeployment(
      selectedFeatureIds: _selected.toList(growable: false),
      destination: _destinationController.text,
    );
    if (mounted && planned) setState(() => _confirmed = false);
  }

  Future<void> _apply() async {
    final applied = await widget.controller.applyLocalDeployment(
      confirmed: true,
    );
    if (mounted && applied) setState(() => _confirmed = false);
  }

  Future<void> _cancel() async {
    final cancelled = await widget.controller.cancel(
      OptionalCollaborationWorkflowKind.localDeployment,
      confirmed: true,
    );
    if (mounted && cancelled) setState(() => _confirmed = false);
  }
}
