import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/presentation/plugin_management/optional_collaboration_presentation_actions.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/frontend/features/plugin_management/ui/optional_collaboration_install_plan_review.dart';

final class OptionalCollaborationInstallSection extends StatefulWidget {
  const OptionalCollaborationInstallSection({
    super.key,
    required this.controller,
    required this.plan,
    required this.busy,
    required this.isChinese,
  });

  final OptionalCollaborationPresentationActions controller;
  final OptionalCollaborationInstallPlan? plan;
  final bool busy;
  final bool isChinese;

  @override
  State<OptionalCollaborationInstallSection> createState() =>
      _OptionalCollaborationInstallSectionState();
}

final class _OptionalCollaborationInstallSectionState
    extends State<OptionalCollaborationInstallSection> {
  final _githubUrlController = TextEditingController();
  final _gitRefController = TextEditingController();
  final _pluginPathController = TextEditingController();
  bool _planConfirmed = false;
  bool _confirmed = false;

  @override
  void dispose() {
    _githubUrlController.dispose();
    _gitRefController.dispose();
    _pluginPathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          key: const Key('collaboration-install-source'),
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isChinese
                      ? 'GitHub 精确 commit 下载来源'
                      : 'GitHub exact-commit download source',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('collaboration-github-url'),
                  controller: _githubUrlController,
                  enabled: !widget.busy,
                  decoration: InputDecoration(
                    labelText: widget.isChinese
                        ? 'GitHub 仓库 HTTPS 地址'
                        : 'GitHub repository HTTPS URL',
                    hintText: 'https://github.com/owner/repository',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('collaboration-git-ref'),
                  controller: _gitRefController,
                  enabled: !widget.busy,
                  maxLength: 40,
                  decoration: InputDecoration(
                    labelText: widget.isChinese
                        ? 'Git commit SHA（必填，40 位小写十六进制）'
                        : 'Git commit SHA (required, 40 lower-case hex)',
                    hintText: '0123456789abcdef0123456789abcdef01234567',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('collaboration-plugin-path'),
                  controller: _pluginPathController,
                  enabled: !widget.busy,
                  decoration: InputDecoration(
                    labelText: widget.isChinese
                        ? '仓库内插件路径（可选）'
                        : 'Plugin path inside repository (optional)',
                  ),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  key: const Key('collaboration-confirm-install-plan-download'),
                  contentPadding: EdgeInsets.zero,
                  value: _planConfirmed,
                  onChanged: widget.busy
                      ? null
                      : (value) =>
                            setState(() => _planConfirmed = value ?? false),
                  title: Text(
                    widget.isChinese
                        ? '我确认访问上方 GitHub 仓库的精确 commit，下载并生成一次安装计划。'
                        : 'I confirm accessing the exact commit in the GitHub repository above to download and create one install plan.',
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    key: const Key('collaboration-plan-install'),
                    onPressed: widget.busy || !_planConfirmed
                        ? null
                        : () => unawaited(_plan()),
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: Text(
                      widget.isChinese
                          ? '下载并生成安装计划'
                          : 'Download and create install plan',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.plan case final plan?) ...[
          const SizedBox(height: 12),
          OptionalCollaborationInstallPlanReview(
            plan: plan,
            confirmed: _confirmed,
            busy: widget.busy,
            isChinese: widget.isChinese,
            onConfirmed: (value) => setState(() => _confirmed = value ?? false),
            onApply: _confirmed ? _apply : null,
            onCancel: _confirmed ? _cancel : null,
          ),
        ],
      ],
    );
  }

  Future<void> _plan() async {
    final planned = await widget.controller.planInstall(
      githubUrl: _githubUrlController.text,
      gitRef: _gitRefController.text,
      pluginPath: _pluginPathController.text,
      confirmed: true,
    );
    if (mounted && planned) setState(() => _planConfirmed = false);
  }

  Future<void> _apply() async {
    final applied = await widget.controller.applyInstall(confirmed: true);
    if (mounted && applied) setState(() => _confirmed = false);
  }

  Future<void> _cancel() async {
    final cancelled = await widget.controller.cancelInstall(confirmed: true);
    if (mounted && cancelled) setState(() => _confirmed = false);
  }
}
