import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

class SkillUpdateSection extends StatefulWidget {
  const SkillUpdateSection({
    super.key,
    required this.controller,
    required this.agentController,
    required this.installRootController,
  });

  final SkillUpdateViewModel controller;
  final TextEditingController agentController;
  final TextEditingController installRootController;

  @override
  State<SkillUpdateSection> createState() => _SkillUpdateSectionState();
}

class _SkillUpdateSectionState extends State<SkillUpdateSection> {
  final _skillController = TextEditingController();
  final _githubController = TextEditingController();
  final _mirrorController = TextEditingController();
  bool _enabled = false;

  @override
  void dispose() {
    _skillController.dispose();
    _githubController.dispose();
    _mirrorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final busy = widget.controller.isSkillUpdateBusy;
    final confirmation =
        (widget.controller.skillUpdatePlan?['confirmation'] ?? '').toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.isChinese ? '手动更新与自动更新' : 'Manual and automatic updates',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _Field(
              key: const ValueKey('skill-update-skill-id'),
              controller: _skillController,
              label: strings.isChinese ? '技能 ID' : 'Skill ID',
            ),
            _Field(
              key: const ValueKey('skill-update-github'),
              controller: _githubController,
              label: strings.isChinese ? 'GitHub 仓库' : 'GitHub repository',
              width: 300,
            ),
            _Field(
              key: const ValueKey('skill-update-mirror'),
              controller: _mirrorController,
              label: strings.isChinese ? '本机镜像目录' : 'Local mirror directory',
              width: 300,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: busy ? null : _preview,
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              label: Text(strings.isChinese ? '检查更新' : 'Preview update'),
            ),
            FilledButton.icon(
              onPressed: busy || confirmation.isEmpty
                  ? null
                  : () => _apply(confirmation),
              icon: const Icon(Icons.system_update_alt, size: 18),
              label: Text(strings.isChinese ? '确认更新' : 'Confirm update'),
            ),
            FilterChip(
              label: Text(
                strings.isChinese ? '启用自动更新' : 'Enable automatic updates',
              ),
              selected: _enabled,
              onSelected: busy
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            OutlinedButton(
              onPressed: busy ? null : _configure,
              child: Text(strings.isChinese ? '保存配置' : 'Save config'),
            ),
            OutlinedButton(
              onPressed: busy ? null : _runConfigured,
              child: Text(
                strings.isChinese ? '立即运行配置更新' : 'Run configured updates now',
              ),
            ),
          ],
        ),
      ],
    );
  }

  String get _agent => widget.agentController.text.trim();
  String get _skill => _skillController.text.trim();
  String get _github => _githubController.text.trim();
  String get _mirror => _mirrorController.text.trim();
  String get _installRoot => widget.installRootController.text.trim();
  bool get _sourceValid => _github.isEmpty || _mirror.isEmpty;

  Future<void> _preview() async {
    if (_agent.isEmpty || _skill.isEmpty || !_sourceValid) return;
    await widget.controller.previewSkillUpdate(
      agent: _agent,
      skillId: _skill,
      githubUrl: _github,
      mirrorPath: _mirror,
      installRoot: _installRoot,
    );
  }

  Future<void> _apply(String confirmation) async {
    if (_agent.isEmpty || _skill.isEmpty || !_sourceValid) return;
    await widget.controller.applySkillUpdate(
      agent: _agent,
      skillId: _skill,
      confirmation: confirmation,
      githubUrl: _github,
      mirrorPath: _mirror,
      installRoot: _installRoot,
    );
  }

  Future<void> _configure() async {
    if (_agent.isEmpty || _skill.isEmpty || !_sourceValid) return;
    await widget.controller.configureSkillAutoUpdate(
      agent: _agent,
      skillId: _skill,
      enabled: _enabled,
      githubUrl: _github,
      mirrorPath: _mirror,
    );
  }

  Future<void> _runConfigured() async {
    if (_agent.isEmpty) return;
    await widget.controller.runConfiguredSkillUpdates(
      agent: _agent,
      skillId: _skill,
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    super.key,
    required this.controller,
    required this.label,
    this.width = 220,
  });

  final TextEditingController controller;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: TextField(
      controller: controller,
      decoration: InputDecoration(
        isDense: true,
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}
