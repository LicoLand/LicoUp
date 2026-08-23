import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:licoup/src/application/features/skill_hub/models/skill_category_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class SkillCardTitle extends StatelessWidget {
  const SkillCardTitle({super.key, required this.title, required this.color});

  static const int maxLines = 2;
  static const double fontSize = 15;

  final String title;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
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
  Widget build(BuildContext context) {
    return SizedBox(
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
}

class SkillCardHeader extends StatelessWidget {
  const SkillCardHeader({
    super.key,
    required this.controller,
    required this.skillId,
    required this.title,
    required this.description,
    required this.isPublic,
    required this.colors,
  });

  final ClientController controller;
  final String skillId;
  final String title;
  final String description;
  final bool isPublic;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final override = controller.skillHubPreferences.overrideFor(skillId);
    final iconId = resolveSkillIconId(
      skillId: skillId,
      title: title,
      description: description,
      overrideIconId: override.iconId,
    );
    final colorToken = override.colorToken.trim().isEmpty
        ? 'primary'
        : override.colorToken.trim();
    final iconColor = resolveSkillIconColor(colors, colorToken);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SkillCategoryIconBadge(
          iconId: iconId,
          color: iconColor,
          onTap: () {
            showSkillIconPicker(
              context: context,
              controller: controller,
              skillId: skillId,
              title: title,
              description: description,
              currentIconId: iconId,
              currentColorToken: colorToken,
            );
          },
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (isPublic ? colors.success : colors.warning).withValues(
              alpha: 0.15,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            isPublic ? strings.publicLabel : strings.privateLabel,
            style: TextStyle(
              color: isPublic ? colors.success : colors.warning,
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
  const SkillCardFooter({
    super.key,
    required this.controller,
    required this.loaderAgentIds,
    required this.version,
    required this.colors,
    this.invocationCount = 0,
  });

  final ClientController controller;
  final List<String> loaderAgentIds;
  final String version;
  final LicoThemeColors colors;

  /// All-time invocation count joined from the usage report; the affordance
  /// stays hidden while the report is absent or the count is zero.
  final int invocationCount;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Container(
      height: 38,
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(top: BorderSide(color: colors.line.withAlpha(40))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: loaderAgentIds.length,
              itemBuilder: (context, index) {
                final agentId = canonicalSkillAgentId(loaderAgentIds[index]);
                final matchingTarget = _skillLoaderTarget(
                  controller.scannedTargets,
                  agentId,
                );
                final label = skillLoaderAgentLabel(agentId);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Tooltip(
                    message: label,
                    child: Center(
                      child: AgentBrandIcon(
                        target:
                            matchingTarget ??
                            TargetCandidate(
                              target: agentId,
                              label: label,
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
          if (invocationCount > 0) ...[
            Tooltip(
              key: const Key('skill-card-invocations'),
              message: strings.skillInvocationsCount(invocationCount),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt_rounded, size: 13, color: colors.textMuted),
                  const SizedBox(width: 3),
                  Text(
                    formatAgentUsageNumber(invocationCount),
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
          if (version.isNotEmpty && version != 'local')
            Text(
              'v$version',
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
    final strings = LicoStrings.of(context);
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
            strings.scanning,
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

TargetCandidate? _skillLoaderTarget(
  Iterable<TargetCandidate> targets,
  String agentId,
) {
  for (final target in targets) {
    if (canonicalSkillAgentId(target.target) == agentId ||
        canonicalSkillAgentId(target.id) == agentId) {
      return target;
    }
  }
  return null;
}
