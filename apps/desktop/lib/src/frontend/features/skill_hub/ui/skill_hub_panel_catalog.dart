import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class SkillCategoryFilter extends StatelessWidget {
  const SkillCategoryFilter({
    super.key,
    required this.selectedCategory,
    required this.onChanged,
  });

  final String selectedCategory;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _SkillCategoryChip(
            label: strings.allSkills,
            isSelected: selectedCategory == 'all',
            onTap: () => onChanged('all'),
            colors: colors,
          ),
          _SkillCategoryChip(
            label: strings.publicSkills,
            isSelected: selectedCategory == 'public',
            onTap: () => onChanged('public'),
            colors: colors,
          ),
          _SkillCategoryChip(
            label: strings.privateSkills,
            isSelected: selectedCategory == 'private',
            onTap: () => onChanged('private'),
            colors: colors,
          ),
        ],
      ),
    );
  }
}

class _SkillCategoryChip extends StatelessWidget {
  const _SkillCategoryChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? colors.primary : colors.surfaceLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? colors.primary
                : colors.line.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? colors.textOnPrimary : colors.text,
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class SkillCollection extends StatelessWidget {
  const SkillCollection({
    super.key,
    required this.controller,
    required this.selectedCategory,
  });

  final ClientController controller;
  final String selectedCategory;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final skills = controller.skillHubSkills.where((skill) {
      final isPublic = skill['isPublic'] == true;
      if (selectedCategory == 'public') return isPublic;
      if (selectedCategory == 'private') return !isPublic;
      return true;
    }).toList();

    if (controller.isSkillHubBusy && skills.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: SkillScanningPlaceholder(),
      );
    }
    if (skills.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: LicoEmptyState(
          icon: Icons.extension_outlined,
          iconSize: 64,
          title: strings.noSkillsFound,
          message: strings.refreshSkillsHint,
          padding: const EdgeInsets.all(32),
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 248,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          return _SkillCard(controller: controller, skill: skills[index]);
        }, childCount: skills.length),
      ),
    );
  }
}

class _SkillCard extends StatelessWidget {
  const _SkillCard({required this.controller, required this.skill});

  final ClientController controller;
  final Map<String, dynamic> skill;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final title = (skill['title'] ?? skill['skillId'] ?? '').toString();
    final author = (skill['author'] ?? '').toString().trim();
    final description = (skill['description'] ?? '').toString();
    final version = (skill['version'] ?? 'local').toString();
    final isPublic = skill['isPublic'] == true;
    final path = (skill['path'] ?? '').toString();
    final skillId = (skill['skillId'] ?? title).toString();
    final usedBy = List<String>.from(skill['usedByAgents'] ?? const <String>[]);
    final detectedAgentIds = controller.scannedTargets
        .where((target) => target.visibleInClient)
        .map((target) => target.target);
    final loaderAgentIds =
        (usedBy.isEmpty
                ? skillLoaderAgentIdsForPath(
                    path: path,
                    isPublic: isPublic,
                    detectedAgentIds: detectedAgentIds,
                  )
                : usedBy.map(canonicalSkillAgentId))
            .toSet()
            .toList(growable: false);
    final strings = LicoStrings.of(context);
    final invocationCount =
        skillUsageTotalsBySkill(
          controller.skillUsageReport,
        )[normalizeSkillUsageId(skillId)] ??
        0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(
          context,
          skillId: skillId,
          title: title,
          author: author,
          version: version,
          path: path,
          isPublic: isPublic,
          description: description,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkillCardHeader(
                      controller: controller,
                      skillId: skillId,
                      title: title,
                      description: description,
                      isPublic: isPublic,
                      colors: colors,
                    ),
                    const SizedBox(height: 12),
                    SkillCardTitle(title: title, color: colors.text),
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: true,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textMuted,
                          height: 1.2,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    SkillCardDescription(
                      text: description.isNotEmpty
                          ? description
                          : strings.noDescription,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            SkillCardFooter(
              controller: controller,
              loaderAgentIds: loaderAgentIds,
              version: version,
              colors: colors,
              invocationCount: invocationCount,
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(
    BuildContext context, {
    required String skillId,
    required String title,
    required String author,
    required String version,
    required String path,
    required bool isPublic,
    required String description,
  }) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final report = controller.skillUsageReport;
    final normalizedId = normalizeSkillUsageId(skillId);
    final allTimeCount = report == null
        ? null
        : skillUsageTotalsBySkill(report)[normalizedId] ?? 0;
    final windowedCount = report == null
        ? null
        : skillUsageWindowedBySkill(report)[normalizedId] ?? 0;
    var movingToTrash = false;
    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${strings.skillId}: $skillId'),
                if (author.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('${strings.author}: $author'),
                ],
                const SizedBox(height: 8),
                Text('${strings.version}: $version'),
                const SizedBox(height: 8),
                Text('${strings.path}: $path'),
                const SizedBox(height: 8),
                Text(
                  '${strings.type}: '
                  '${isPublic ? strings.publicLabel : strings.privateLabel}',
                ),
                if (allTimeCount != null && windowedCount != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    key: const Key('skill-detail-all-time-invocations'),
                    '${strings.allTimeInvocations}: $allTimeCount',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    key: const Key('skill-detail-windowed-invocations'),
                    '${strings.lastDays(30)}: $windowedCount',
                  ),
                ],
                const SizedBox(height: 8),
                Text('${strings.description}: $description'),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('skill-delete-button'),
              onPressed: movingToTrash || path.trim().isEmpty
                  ? null
                  : () async {
                      final confirmed = await _confirmMoveToTrash(
                        dialogContext,
                        strings: strings,
                        title: title,
                      );
                      if (!confirmed || !dialogContext.mounted) return;
                      setDialogState(() => movingToTrash = true);
                      final moved = await _moveSkillToTrash(
                        skillId: skillId,
                        path: path,
                      );
                      if (!dialogContext.mounted) return;
                      if (!moved) {
                        setDialogState(() => movingToTrash = false);
                        _showTrashMessage(messenger, strings.skillTrashFailed);
                        return;
                      }
                      controller.removeSkillHubEntryAtPath(path);
                      Navigator.of(dialogContext).pop();
                      _showTrashMessage(
                        messenger,
                        strings.skillMovedToSystemTrash(title),
                      );
                    },
              icon: movingToTrash
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.delete_outline),
              label: Text(strings.delete),
              style: TextButton.styleFrom(foregroundColor: colors.error),
            ),
            TextButton(
              onPressed: movingToTrash
                  ? null
                  : () => Navigator.of(dialogContext).pop(),
              child: Text(strings.close),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmMoveToTrash(
    BuildContext context, {
    required LicoStrings strings,
    required String title,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (confirmationContext) => AlertDialog(
            title: Text(strings.deleteSkillTitle),
            content: Text(strings.trashSkillMessage(title)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(confirmationContext).pop(false),
                child: Text(strings.cancel),
              ),
              FilledButton(
                key: const ValueKey('skill-move-to-trash-confirm'),
                onPressed: () => Navigator.of(confirmationContext).pop(true),
                child: Text(strings.moveToSystemTrash),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _moveSkillToTrash({
    required String skillId,
    required String path,
  }) async {
    await controller.previewSkillDelete(skillId: skillId, path: path);
    final plan = controller.skillDeletePlan;
    final confirmation = (plan?['confirmation'] ?? '').toString();
    if (plan?['ok'] != true ||
        plan?['trashAllowed'] != true ||
        confirmation.isEmpty) {
      return false;
    }
    await controller.applySkillDelete(
      skillId: skillId,
      path: path,
      confirmation: confirmation,
    );
    final result = controller.skillDeleteResult;
    return result?['ok'] == true && result?['status'] == 'trashed';
  }

  void _showTrashMessage(ScaffoldMessengerState? messenger, String message) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}
