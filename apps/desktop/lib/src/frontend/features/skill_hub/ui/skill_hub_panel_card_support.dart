import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

class SkillCardTitle extends StatelessWidget {
  const SkillCardTitle({super.key, required this.title, required this.color});

  static const int maxLines = 2;
  static const double fontSize = 15;

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    title,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    softWrap: true,
    style: TextStyle(
      fontSize: fontSize,
      fontWeight: FontWeight.bold,
      color: color,
    ),
  );
}

class SkillCardDescription extends StatelessWidget {
  const SkillCardDescription({
    super.key,
    required this.text,
    required this.color,
  });

  static const int maxLines = 3;
  static const double fontSize = 12;
  static const double lineHeight = 1.35;
  static const double reservedHeight = fontSize * lineHeight * maxLines;

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: reservedHeight,
    width: double.infinity,
    child: Text(
      text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      softWrap: true,
      style: TextStyle(fontSize: fontSize, color: color, height: lineHeight),
    ),
  );
}

class SkillCardHeader extends StatelessWidget {
  const SkillCardHeader({
    super.key,
    required this.skill,
    required this.intents,
  });

  final SkillProjectionItem skill;
  final IntentSink<SkillHubIntent> intents;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final iconColor = resolveSkillIconColor(colors, skill.colorToken);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SkillCategoryIconBadge(
          iconId: skill.iconId,
          color: iconColor,
          onTap: () => showSkillIconPicker(
            context: context,
            intents: intents,
            skillId: skill.id,
            currentIconId: skill.iconId,
            currentColorToken: skill.colorToken,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (skill.public ? colors.success : colors.warning).withValues(
              alpha: 0.15,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            skill.public ? strings.publicLabel : strings.privateLabel,
            style: TextStyle(
              color: skill.public ? colors.success : colors.warning,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

class SkillCardFooter extends StatelessWidget {
  const SkillCardFooter({super.key, required this.skill});

  final SkillProjectionItem skill;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(top: BorderSide(color: colors.line.withAlpha(40))),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: skill.agents.length,
              itemBuilder: (context, index) {
                final agent = skill.agents[index];
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: agent.label,
                    child: Center(
                      child: AgentBrandIcon(
                        target: TargetCandidate(
                          target: agent.id,
                          label: agent.label,
                          kind: 'cli',
                          status: TargetCandidateStatus.detected,
                          configured: true,
                          confidence: 1,
                          adapterStatus: 'implemented',
                        ),
                        size: 20,
                        iconSize: 14,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (skill.usageCount > 0) ...[
            Tooltip(
              key: const Key('skill-card-invocations'),
              message: LicoStrings.of(
                context,
              ).skillInvocationsCount(skill.usageCount),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 13, color: colors.textMuted),
                  const SizedBox(width: 3),
                  Text(
                    formatAgentUsageNumber(skill.usageCount),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (skill.version.isNotEmpty && skill.version != 'local')
            Text(
              'v${skill.version}',
              style: TextStyle(fontSize: 11, color: colors.textMuted),
            ),
        ],
      ),
    );
  }
}

class SkillScanningPlaceholder extends StatelessWidget {
  const SkillScanningPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: colors.accent,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            LicoStrings.of(context).scanning,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}
