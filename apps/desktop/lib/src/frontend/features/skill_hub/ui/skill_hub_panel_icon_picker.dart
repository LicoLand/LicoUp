import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/models/skill_category_catalog.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

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

Color resolveSkillIconColor(LicoThemeColors colors, String colorToken) {
  switch (colorToken.trim()) {
    case 'info':
      return colors.info;
    case 'success':
      return colors.success;
    case 'warning':
      return colors.warning;
    case 'error':
      return colors.error;
    case 'violet':
      return const Color(0xFF8B7CF6);
    case 'cyan':
      return const Color(0xFF38BDF8);
    case 'orange':
      return const Color(0xFFFB923C);
    case 'rose':
      return const Color(0xFFFB7185);
    case 'slate':
      return colors.textMuted;
    case 'primary':
    default:
      return colors.primary;
  }
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
        borderRadius: BorderRadius.circular(8),
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
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
      ),
    );
  }
}

Future<void> showSkillIconPicker({
  required BuildContext context,
  required ClientController controller,
  required String skillId,
  required String title,
  required String description,
  required String currentIconId,
  required String currentColorToken,
}) async {
  var selectedIconId = currentIconId;
  var selectedColorToken = currentColorToken.trim().isEmpty
      ? 'primary'
      : currentColorToken.trim();

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final colors = dialogContext.licoColors;
      final strings = LicoStrings.of(dialogContext);
      return StatefulBuilder(
        builder: (context, setState) {
          final previewColor = resolveSkillIconColor(
            colors,
            selectedColorToken,
          );
          return AlertDialog(
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
                          color: resolveSkillIconColor(colors, token),
                          selected: selectedColorToken == token,
                          onTap: () {
                            setState(() => selectedColorToken = token);
                          },
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
                    itemCount: skillCategoryDefinitions.length,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 5,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                        ),
                    itemBuilder: (context, index) {
                      final category = skillCategoryDefinitions[index];
                      final selected = selectedIconId == category.iconId;
                      return Tooltip(
                        message: category.label,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(10),
                          onTap: () {
                            setState(() => selectedIconId = category.iconId);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            decoration: BoxDecoration(
                              color: selected
                                  ? previewColor.withValues(alpha: 0.14)
                                  : colors.surfaceLow,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: selected
                                    ? previewColor
                                    : colors.line.withValues(alpha: 0.5),
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: Center(
                              child: SvgPicture.asset(
                                skillCategoryIconAssetPath(category.iconId),
                                width: 20,
                                height: 20,
                                colorFilter: ColorFilter.mode(
                                  selected ? previewColor : colors.text,
                                  BlendMode.srcIn,
                                ),
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
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(strings.cancel),
              ),
              FilledButton(
                onPressed: () async {
                  await controller.updateSkillVisualOverride(
                    skillId: skillId,
                    iconId: selectedIconId,
                    colorToken: selectedColorToken,
                  );
                  if (dialogContext.mounted) {
                    Navigator.of(dialogContext).pop();
                  }
                },
                child: Text(strings.apply),
              ),
            ],
          );
        },
      );
    },
  );
}

class _SkillColorDot extends StatelessWidget {
  const _SkillColorDot({
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
