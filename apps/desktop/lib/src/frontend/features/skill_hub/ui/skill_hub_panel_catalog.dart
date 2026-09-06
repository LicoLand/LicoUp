import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_search.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

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
      padding: const EdgeInsets.only(bottom: LicoContentSpacing.item),
      child: Wrap(
        spacing: LicoContentSpacing.compact,
        runSpacing: LicoContentSpacing.compact,
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

final class _SkillCategoryChip extends StatelessWidget {
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
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: context.motion(LicoMotion.short),
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

class SkillCollection extends StatelessWidget {
  const SkillCollection({
    super.key,
    required this.projection,
    required this.intents,
    required this.selectedCategory,
  });

  final SkillHubProjection projection;
  final IntentSink<SkillHubIntent> intents;
  final String selectedCategory;

  @override
  Widget build(BuildContext context) {
    final skills = filterAndRankSkillProjections(
      skills: projection.skills,
      category: selectedCategory,
      query: projection.query,
    );
    if (projection.phase == PresentationPhase.loading && skills.isEmpty) {
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
          title: LicoStrings.of(context).noSkillsFound,
          message: LicoStrings.of(context).refreshSkillsHint,
          padding: const EdgeInsets.all(32),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.zero,
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          mainAxisExtent: 248,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) => _SkillCard(
            skill: skills[index],
            intents: intents,
            usageAvailable: projection.usageAvailable,
          ),
          childCount: skills.length,
        ),
      ),
    );
  }
}

final class _SkillCard extends StatelessWidget {
  const _SkillCard({
    required this.skill,
    required this.intents,
    required this.usageAvailable,
  });

  final SkillProjectionItem skill;
  final IntentSink<SkillHubIntent> intents;
  final bool usageAvailable;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Card(
      key: Key('skill-card-${skill.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SkillCardHeader(skill: skill, intents: intents),
                    const SizedBox(height: 12),
                    SkillCardTitle(title: skill.name, color: colors.text),
                    if (skill.author.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        skill.author,
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
                      text: skill.description.isEmpty
                          ? strings.noDescription
                          : skill.description,
                      color: colors.textMuted,
                    ),
                  ],
                ),
              ),
            ),
            SkillCardFooter(skill: skill),
          ],
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context) async {
    final strings = LicoStrings.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('skill-detail-dialog'),
        title: Text(skill.name),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${strings.skillId}: ${skill.id}'),
              if (skill.author.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('${strings.author}: ${skill.author}'),
              ],
              const SizedBox(height: 8),
              Text('${strings.version}: ${skill.version}'),
              const SizedBox(height: 8),
              Text('${strings.path}: ${skill.pathLabel}'),
              const SizedBox(height: 8),
              Text(
                '${strings.type}: '
                '${skill.public ? strings.publicLabel : strings.privateLabel}',
              ),
              if (usageAvailable) ...[
                const SizedBox(height: 8),
                Text(
                  key: const Key('skill-detail-all-time-invocations'),
                  '${strings.allTimeInvocations}: ${skill.usageCount}',
                ),
                const SizedBox(height: 8),
                Text(
                  key: const Key('skill-detail-windowed-invocations'),
                  '${strings.lastDays(30)}: ${skill.windowedUsageCount}',
                ),
              ],
              const SizedBox(height: 8),
              Text('${strings.description}: ${skill.description}'),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            key: const Key('skill-delete-button'),
            onPressed: skill.pathLabel.isEmpty
                ? null
                : () {
                    Navigator.pop(dialogContext);
                    intents.send(
                      PreviewSkillRemoval(skill.id, skill.pathLabel),
                    );
                  },
            icon: const Icon(Icons.delete_outline),
            label: Text(LicoStrings.of(dialogContext).delete),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(LicoStrings.of(dialogContext).close),
          ),
        ],
      ),
    );
  }
}
