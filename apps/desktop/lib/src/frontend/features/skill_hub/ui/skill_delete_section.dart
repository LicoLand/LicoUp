import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

class SkillDeleteSection extends StatefulWidget {
  const SkillDeleteSection({
    super.key,
    required this.controller,
    required this.agentController,
    required this.installRootController,
    required this.agentOptions,
  });

  final SkillDeleteViewModel controller;
  final TextEditingController agentController;
  final TextEditingController installRootController;
  final List<String> agentOptions;

  @override
  State<SkillDeleteSection> createState() => _SkillDeleteSectionState();
}

class _SkillDeleteSectionState extends State<SkillDeleteSection> {
  final _skillController = TextEditingController();
  final Set<String> _agents = {};

  @override
  void initState() {
    super.initState();
    _selectCurrent();
  }

  @override
  void didUpdateWidget(covariant SkillDeleteSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selectCurrent();
  }

  @override
  void dispose() {
    _skillController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final busy = widget.controller.isSkillDeleteBusy;
    final plan = widget.controller.skillDeletePlan;
    final confirmation = plan?['deleteAllowed'] == false
        ? ''
        : (plan?['confirmation'] ?? '').toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.isChinese ? '多智能体删除' : 'Multi-agent removal',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: 220,
          child: TextField(
            key: const ValueKey('skill-delete-skill-id'),
            controller: _skillController,
            decoration: InputDecoration(
              isDense: true,
              labelText: strings.isChinese ? '技能 ID' : 'Skill ID',
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          strings.isChinese
              ? '删除目标智能体（可多选）'
              : 'Delete from agents (multi-select)',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final agent in widget.agentOptions)
              FilterChip(
                key: ValueKey('skill-delete-agent-$agent'),
                label: Text(agent),
                selected: _agents.contains(agent),
                onSelected: busy
                    ? null
                    : (selected) => setState(() {
                        selected ? _agents.add(agent) : _agents.remove(agent);
                      }),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : _preview,
              icon: const Icon(Icons.delete_sweep_outlined, size: 18),
              label: Text(strings.isChinese ? '检查删除' : 'Preview removal'),
            ),
            FilledButton.icon(
              onPressed: busy || confirmation.isEmpty
                  ? null
                  : () => _apply(confirmation),
              icon: const Icon(Icons.delete_forever_outlined, size: 18),
              label: Text(strings.isChinese ? '确认删除' : 'Confirm removal'),
            ),
          ],
        ),
      ],
    );
  }

  String get _skill => _skillController.text.trim();
  String get _installRoot => widget.installRootController.text.trim();

  void _selectCurrent() {
    final current = widget.agentController.text.trim();
    if (_agents.isEmpty && current.isNotEmpty) _agents.add(current);
  }

  Future<void> _preview() async {
    if (_skill.isEmpty || _agents.isEmpty) return;
    await widget.controller.previewSkillDelete(
      agents: _agents,
      skillId: _skill,
      installRoot: _installRoot,
    );
  }

  Future<void> _apply(String confirmation) async {
    if (_skill.isEmpty || _agents.isEmpty) return;
    await widget.controller.applySkillDelete(
      agents: _agents,
      skillId: _skill,
      confirmation: confirmation,
      installRoot: _installRoot,
    );
  }
}
