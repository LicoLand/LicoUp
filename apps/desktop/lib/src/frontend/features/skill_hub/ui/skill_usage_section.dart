import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

class SkillUsageSection extends StatefulWidget {
  const SkillUsageSection({
    super.key,
    required this.controller,
    required this.agentController,
  });

  final SkillUsageViewModel controller;
  final TextEditingController agentController;

  @override
  State<SkillUsageSection> createState() => _SkillUsageSectionState();
}

class _SkillUsageSectionState extends State<SkillUsageSection> {
  final _skillController = TextEditingController();
  int _days = 30;

  @override
  void dispose() {
    _skillController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final busy = widget.controller.isSkillUsageBusy;
    final report = widget.controller.skillUsageReport;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.isChinese ? '本机调用频率' : 'Local invocation frequency',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          strings.isChinese
              ? '仅统计智能体运行时上报的结构化技能调用，并按天在本机聚合。'
              : 'Counts structured skill calls emitted by agent runtimes and aggregates them locally by day.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 220,
              child: TextField(
                key: const ValueKey('skill-usage-skill-id'),
                controller: _skillController,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: strings.isChinese
                      ? '技能筛选（可选）'
                      : 'Skill filter (optional)',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            DropdownButton<int>(
              key: const ValueKey('skill-usage-window'),
              value: _days,
              items: [
                for (final days in const [7, 30, 90, 365])
                  DropdownMenuItem(
                    value: days,
                    child: Text(
                      strings.isChinese ? '最近 $days 天' : 'Last $days days',
                    ),
                  ),
              ],
              onChanged: busy
                  ? null
                  : (value) => setState(() => _days = value ?? 30),
            ),
            OutlinedButton.icon(
              onPressed: busy ? null : _load,
              icon: const Icon(Icons.query_stats_outlined, size: 18),
              label: Text(
                strings.isChinese ? '统计调用频率' : 'Load invocation frequency',
              ),
            ),
            if (report != null)
              Text(
                strings.isChinese
                    ? '调用总数：${report['totalInvocations'] ?? 0}'
                    : 'Total invocations: ${report['totalInvocations'] ?? 0}',
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _load() => widget.controller.loadSkillUsage(
    days: _days,
    agent: widget.agentController.text.trim(),
    skillId: _skillController.text.trim(),
  );
}
