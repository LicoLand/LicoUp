import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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
      child: Row(
        children: [
          _SkillCategoryChip(
            label: strings.allSkills,
            isSelected: selectedCategory == 'all',
            onTap: () => onChanged('all'),
            colors: colors,
          ),
          const SizedBox(width: 8),
          _SkillCategoryChip(
            label: strings.publicSkills,
            isSelected: selectedCategory == 'public',
            onTap: () => onChanged('public'),
            colors: colors,
          ),
          const SizedBox(width: 8),
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
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: SkillEmptyPlaceholder(),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.35,
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

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(
          context,
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
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: colors.text,
                      ),
                    ),
                    if (author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.textMuted,
                          height: 1.2,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Expanded(
                      child: Text(
                        description.isNotEmpty
                            ? description
                            : strings.noDescription,
                        maxLines: author.isNotEmpty ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textMuted,
                          height: 1.35,
                        ),
                      ),
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
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(
    BuildContext context, {
    required String title,
    required String author,
    required String version,
    required String path,
    required bool isPublic,
    required String description,
  }) {
    final strings = LicoStrings.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${strings.skillId}: $title'),
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
              const SizedBox(height: 8),
              Text('${strings.description}: $description'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(strings.close),
          ),
        ],
      ),
    );
  }
}
