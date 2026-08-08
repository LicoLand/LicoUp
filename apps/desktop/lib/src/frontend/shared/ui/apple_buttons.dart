import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';

/// Shared Apple-leaning button styles for remaining page actions.
abstract final class AppleControlButtons {
  static ButtonStyle glassFilled(LicoThemeColors colors) {
    return ButtonStyle(
      elevation: const WidgetStatePropertyAll(0),
      backgroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.surfaceLow.withValues(alpha: 0.5);
        }
        if (states.contains(WidgetState.pressed)) {
          return Color.alphaBlend(colors.pressedOverlay, colors.surfaceRaised);
        }
        if (states.contains(WidgetState.hovered)) {
          return Color.alphaBlend(colors.hoverOverlay, colors.surfaceRaised);
        }
        return colors.surfaceRaised;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textDisabled;
        }
        return colors.text;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: enabled ? colors.line : colors.line.withValues(alpha: 0.5),
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
          return colors.hoverOverlay;
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) {
          return colors.textDisabled;
        }
        return colors.text;
      }),
      side: WidgetStateProperty.resolveWith((states) {
        final enabled = !states.contains(WidgetState.disabled);
        return BorderSide(
          color: enabled ? colors.line : colors.line.withValues(alpha: 0.5),
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
      foregroundColor: colors.accent,
      disabledForegroundColor: colors.textDisabled,
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
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 15,
                    color: enabled ? colors.text : colors.textDisabled,
                  ),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: enabled ? colors.text : colors.textDisabled,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
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
