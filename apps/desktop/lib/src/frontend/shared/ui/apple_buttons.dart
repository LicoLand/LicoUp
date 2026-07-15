import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/apple_glass.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Shared Apple-leaning button styles for remaining page actions.
abstract final class AppleControlButtons {
  static ButtonStyle glassFilled(LicoThemeColors colors) {
    return ButtonStyle(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return Colors.white.withAlpha(colors.isDark ? 10 : 8);
        }
        if (states.contains(WidgetState.pressed)) {
          return Colors.white.withAlpha(colors.isDark ? 44 : 36);
        }
        return Colors.white.withAlpha(colors.isDark ? 28 : 24);
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textMuted.withAlpha(120);
        }
        return colors.text.withAlpha(240);
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: Colors.white.withAlpha(
            colors.isDark ? (enabled ? 56 : 28) : (enabled ? 80 : 40),
          ),
          width: AppleControlMetrics.hairline,
        );
      }),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.08,
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
        ),
      ),
    );
  }

  static ButtonStyle glassOutlined(LicoThemeColors colors) {
    return ButtonStyle(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return Colors.transparent;
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)) {
          return Colors.white.withAlpha(colors.isDark ? 18 : 14);
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textMuted.withAlpha(120);
        }
        return colors.text.withAlpha(230);
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: Colors.white.withAlpha(
            colors.isDark ? (enabled ? 52 : 24) : (enabled ? 70 : 36),
          ),
          width: AppleControlMetrics.hairline,
        );
      }),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          letterSpacing: -0.08,
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      ),
      minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
        ),
      ),
    );
  }

  static ButtonStyle glassText(LicoThemeColors colors) {
    return TextButton.styleFrom(
      foregroundColor: colors.info,
      disabledForegroundColor: colors.textMuted.withAlpha(110),
      textStyle: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.08,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      minimumSize: const Size(0, 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
      ),
    );
  }
}

/// Compact glass action used by toolbars and page headers.
class AppleGlassActionButton extends StatelessWidget {
  const AppleGlassActionButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        child: AppleGlassSurface(
          borderRadius: BorderRadius.circular(
            AppleControlMetrics.controlCornerRadius,
          ),
          focused: emphasized && enabled,
          fillAlpha: emphasized && enabled ? 36 : (enabled ? 22 : 12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 15,
                    color: enabled
                        ? colors.text.withAlpha(235)
                        : colors.textMuted.withAlpha(120),
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled
                          ? colors.text.withAlpha(235)
                          : colors.textMuted.withAlpha(120),
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.08,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
