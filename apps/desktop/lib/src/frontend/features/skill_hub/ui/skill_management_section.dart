import 'package:flutter/material.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_delete_section.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_update_section.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_usage_section.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

/// Composition boundary for independently testable update, removal, and usage
/// capabilities. Each child depends on only its dedicated view-model port.
class SkillManagementSection extends StatelessWidget {
  const SkillManagementSection({
    super.key,
    required this.updateController,
    required this.deleteController,
    required this.usageController,
    required this.agentController,
    required this.installRootController,
    required this.agentOptions,
  });

  final SkillUpdateViewModel updateController;
  final SkillDeleteViewModel deleteController;
  final SkillUsageViewModel usageController;
  final TextEditingController agentController;
  final TextEditingController installRootController;
  final List<String> agentOptions;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            strings.isChinese
                ? '技能更新、删除与用量'
                : 'Skill updates, removal, and usage',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            strings.isChinese
                ? '只有在你明确选择来源并启用后，客户端才会在后台检查该来源；不会发现或访问其它来源。删除始终需要手动确认，用量仅在本机聚合。'
                : 'Background checks start only after you choose a source and enable them. No other source is discovered; removal stays manual and usage stays locally aggregated.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          SkillUpdateSection(
            controller: updateController,
            agentController: agentController,
            installRootController: installRootController,
          ),
          const Divider(height: 32),
          SkillDeleteSection(
            controller: deleteController,
            agentController: agentController,
            installRootController: installRootController,
            agentOptions: agentOptions,
          ),
          const Divider(height: 32),
          SkillUsageSection(
            controller: usageController,
            agentController: agentController,
          ),
        ],
      ),
    );
  }
}
