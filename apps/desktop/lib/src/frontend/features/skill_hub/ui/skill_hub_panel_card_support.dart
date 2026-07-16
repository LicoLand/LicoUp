import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:flutter_client/src/application/features/skill_hub/models/skill_category_catalog.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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
  });

  final ClientController controller;
  final List<String> loaderAgentIds;
  final String version;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
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
                              status: 'detected',
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

class SkillEmptyPlaceholder extends StatelessWidget {
  const SkillEmptyPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.extension_outlined, size: 64, color: colors.textMuted),
            const SizedBox(height: 16),
            Text(
              strings.noSkillsFound,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.refreshSkillsHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.textMuted),
            ),
          ],
        ),
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
              color: colors.primary,
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
