import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';

const _skillIconIds = <String>[
  'plug',
  'zap',
  'globe',
  'wrench',
  'list-checks',
  'message-circle',
  'palette',
  'book-open',
  'brain',
  'activity',
  'shield',
  'wallet-cards',
  'shapes',
  'package',
];

const _skillIconColorTokens = <String>[
  'primary',
  'info',
  'success',
  'warning',
  'error',
  'violet',
  'cyan',
  'orange',
  'rose',
  'slate',
];

String skillCategoryIconAssetPath(String iconId) =>
    'assets/skill-category-icons/$iconId.svg';

Color resolveSkillIconColor(LicoThemeColors colors, String colorToken) {
  return switch (colorToken.trim()) {
    'info' => colors.accent,
    'success' => colors.success,
    'warning' => colors.warning,
    'error' => colors.error,
    'violet' => const Color(0xFF8B7CF6),
    'cyan' => const Color(0xFF38BDF8),
    'orange' => const Color(0xFFFB923C),
    'rose' => const Color(0xFFFB7185),
    'slate' => colors.textMuted,
    _ => colors.primary,
  };
}

class SkillCategoryIconBadge extends StatelessWidget {
  const SkillCategoryIconBadge({
    super.key,
    required this.iconId,
    required this.color,
    this.size = 36,
    this.iconSize = 18,
    this.onTap,
  });

  final String iconId;
  final Color color;
  final double size;
  final double iconSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final child = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LicoRadius.chip),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      alignment: Alignment.center,
      child: SvgPicture.asset(
        skillCategoryIconAssetPath(iconId),
        width: iconSize,
        height: iconSize,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        placeholderBuilder: (_) => Icon(
          Icons.extension_outlined,
          size: iconSize,
          color: colors.textMuted,
        ),
      ),
    );
    if (onTap == null) return child;
    return Tooltip(
      message: LicoStrings.of(context).customizeSkillIcon,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          child: child,
        ),
      ),
    );
  }
}

Future<void> showSkillIconPicker({
  required BuildContext context,
  required IntentSink<SkillHubIntent> intents,
  required String skillId,
  required String currentIconId,
  required String currentColorToken,
}) async {
  var selectedIconId = currentIconId;
  var selectedColorToken = currentColorToken.trim().isEmpty
      ? 'primary'
      : currentColorToken.trim();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final colors = context.licoColors;
        final strings = LicoStrings.of(context);
        final previewColor = resolveSkillIconColor(colors, selectedColorToken);
        return AlertDialog(
          key: const Key('skill-icon-picker'),
          title: Text(strings.customizeSkillIcon),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  strings.skillIconColor,
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final token in _skillIconColorTokens)
                      _SkillColorDot(
                        key: Key('skill-color-$token'),
                        color: resolveSkillIconColor(colors, token),
                        selected: selectedColorToken == token,
                        onTap: () => setState(() => selectedColorToken = token),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  strings.skillIconGlyph,
                  style: TextStyle(fontSize: 12, color: colors.textMuted),
                ),
                const SizedBox(height: 10),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _skillIconIds.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 5,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemBuilder: (context, index) {
                    final iconId = _skillIconIds[index];
                    final selected = selectedIconId == iconId;
                    return InkWell(
                      key: Key('skill-icon-$iconId'),
                      borderRadius: BorderRadius.circular(LicoRadius.floating),
                      onTap: () => setState(() => selectedIconId = iconId),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        decoration: BoxDecoration(
                          color: selected
                              ? previewColor.withValues(alpha: 0.14)
                              : colors.surfaceLow,
                          borderRadius: BorderRadius.circular(
                            LicoRadius.floating,
                          ),
                          border: Border.all(
                            color: selected
                                ? previewColor
                                : colors.line.withValues(alpha: 0.5),
                            width: selected ? 1.5 : 1,
                          ),
                        ),
                        child: Center(
                          child: SvgPicture.asset(
                            skillCategoryIconAssetPath(iconId),
                            width: 20,
                            height: 20,
                            colorFilter: ColorFilter.mode(
                              selected ? previewColor : colors.text,
                              BlendMode.srcIn,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.cancel),
            ),
            FilledButton(
              key: const Key('skill-icon-apply'),
              onPressed: () {
                intents.send(
                  SetSkillVisual(skillId, selectedIconId, selectedColorToken),
                );
                Navigator.pop(dialogContext);
              },
              child: Text(strings.apply),
            ),
          ],
        );
      },
    ),
  );
}

class _SkillColorDot extends StatelessWidget {
  const _SkillColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? colors.text : colors.line.withValues(alpha: 0.4),
            width: selected ? 2.2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}
