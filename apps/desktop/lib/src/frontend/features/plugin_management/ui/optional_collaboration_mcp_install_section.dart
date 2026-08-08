import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_agent_destination_editor.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_card.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_choice_subtitle.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_workflow_plan_review.dart';

final class OptionalCollaborationMcpInstallSection extends StatefulWidget {
  const OptionalCollaborationMcpInstallSection({
    super.key,
    required this.choices,
    required this.controller,
    required this.requiresPerFileApproval,
    required this.isChinese,
  });

  final List<OptionalCollaborationWorkflowChoice> choices;
  final OptionalCollaborationWorkflowController controller;
  final bool requiresPerFileApproval;
  final bool isChinese;

  @override
  State<OptionalCollaborationMcpInstallSection> createState() =>
      _OptionalCollaborationMcpInstallSectionState();
}

final class _OptionalCollaborationMcpInstallSectionState
    extends State<OptionalCollaborationMcpInstallSection> {
  final Set<String> _selected = <String>{};
  final List<OptionalCollaborationAgentDestinationEditors> _destinations = [
    OptionalCollaborationAgentDestinationEditors(),
  ];
  bool _confirmed = false;

  @override
  void dispose() {
    for (final destination in _destinations) {
      destination.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.controller.mcpInstallPlan;
    final busy = widget.controller.busy;
    final inputEnabled =
        !busy && plan == null && widget.requiresPerFileApproval;
    return OptionalCollaborationWorkflowCard(
      key: const Key('collaboration-mcp-install-workflow-section'),
      icon: Icons.extension_outlined,
      title: widget.isChinese ? 'MCP 插件本机安装' : 'Local MCP installation',
      policy: widget.requiresPerFileApproval
          ? (widget.isChinese
                ? '精确选择 MCP 插件、支持 ACP stdio 的智能体和本机安装目标。一次直接确认会原子写入插件与 LicoUp 私有注册；不会修改厂商配置，也不会授权外发。认证审批代理尚未实现，ACP 注入和外发桥接保持关闭。'
                : 'Select exact MCP plugins, ACP-stdio-capable agents, and local install targets. One direct confirmation atomically writes the plugins and private LicoUp registrations. Vendor configuration is untouched and outbound access is not authorized. ACP injection and outbound bridging remain disabled until an authenticated review broker exists.')
          : (widget.isChinese
                ? '目录未声明逐文件审批策略，已阻止继续。'
                : 'The catalog does not declare per-file approval, so this workflow is blocked.'),
      isChinese: widget.isChinese,
      children: [
        for (final choice in widget.choices)
          CheckboxListTile(
            key: Key('collaboration-mcp-choice-${choice.id}'),
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
        const Divider(height: 24),
        for (var index = 0; index < _destinations.length; index += 1) ...[
          OptionalCollaborationAgentDestinationFields(
            key: ValueKey(_destinations[index]),
            index: index,
            editors: _destinations[index],
            enabled: inputEnabled,
            isChinese: widget.isChinese,
            removable: _destinations.length > 1,
            onRemove: () => _removeDestination(index),
          ),
          if (index != _destinations.length - 1) const Divider(height: 24),
        ],
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              key: const Key('collaboration-mcp-add-agent'),
              onPressed: inputEnabled && _destinations.length < 32
                  ? () => setState(
                      () => _destinations.add(
                        OptionalCollaborationAgentDestinationEditors(),
                      ),
                    )
                  : null,
              icon: const Icon(Icons.add, size: 16),
              label: Text(widget.isChinese ? '添加智能体' : 'Add agent'),
            ),
            FilledButton.icon(
              key: const Key('collaboration-mcp-plan'),
              onPressed: inputEnabled
                  ? () {
                      unawaited(_plan());
                    }
                  : null,
              icon: const Icon(Icons.fact_check_outlined, size: 16),
              label: Text(widget.isChinese ? '生成精确计划' : 'Create exact plan'),
            ),
          ],
        ),
        if (plan != null) ...[
          const SizedBox(height: 12),
          OptionalCollaborationWorkflowPlanReview(
            plan: plan,
            confirmed: _confirmed,
            busy: busy,
            isChinese: widget.isChinese,
            keyPrefix: 'collaboration-mcp',
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

  void _removeDestination(int index) {
    final removed = _destinations.removeAt(index);
    removed.dispose();
    setState(() {});
  }

  Future<void> _plan() async {
    final planned = await widget.controller.planMcpInstall(
      selectedPluginIds: _selected.toList(growable: false),
      agentDestinations: _destinations
          .map((editors) => editors.value)
          .toList(growable: false),
    );
    if (mounted && planned) setState(() => _confirmed = false);
  }

  Future<void> _apply() async {
    final applied = await widget.controller.applyMcpInstall(confirmed: true);
    if (mounted && applied) setState(() => _confirmed = false);
  }

  Future<void> _cancel() async {
    final cancelled = await widget.controller.cancel(
      OptionalCollaborationWorkflowKind.mcpInstall,
      confirmed: true,
    );
    if (mounted && cancelled) setState(() => _confirmed = false);
  }
}
