import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/apple_glass.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Floating Apple-leaning snackbar / toast chrome for ephemeral notices.
SnackBar appleGlassSnackBar({
  required BuildContext context,
  required String message,
  Duration duration = const Duration(seconds: 2),
  SnackBarAction? action,
}) {
  final colors = context.licoColors;
  return SnackBar(
    behavior: SnackBarBehavior.floating,
    elevation: 0,
    duration: duration,
    backgroundColor: Colors.transparent,
    padding: EdgeInsets.zero,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    action: null,
    content: AppleGlassSurface(
      key: const Key('apple-glass-snackbar'),
      borderRadius: BorderRadius.circular(AppleControlMetrics.menuCornerRadius),
      fillAlpha: colors.isDark ? 36 : 48,
      borderAlpha: colors.isDark ? 64 : 90,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: colors.text.withAlpha(235),
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.08,
                ),
              ),
            ),
            if (action != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: action.onPressed,
                style: TextButton.styleFrom(
                  foregroundColor: colors.accent,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: Text(action.label),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Compact inline notice banner (parity gates, soft warnings).
class AppleGlassNoticeBanner extends StatelessWidget {
  const AppleGlassNoticeBanner({
    super.key,
    required this.message,
    this.messageKey,
    this.action,
    this.tone = AppleGlassNoticeTone.neutral,
  });

  final String message;
  final Key? messageKey;
  final Widget? action;
  final AppleGlassNoticeTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final accent = switch (tone) {
      AppleGlassNoticeTone.warning => colors.warning,
      AppleGlassNoticeTone.info => colors.accent,
      AppleGlassNoticeTone.neutral => colors.textMuted,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        // A notice is a low wash of its own signal color over the neutral
        // surface, so the tone is legible without a second surface token.
        color: tone == AppleGlassNoticeTone.neutral
            ? colors.surfaceLow
            : Color.alphaBlend(
                accent.withValues(alpha: colors.isDark ? 0.12 : 0.10),
                colors.surface,
              ),
        borderRadius: BorderRadius.circular(
          AppleControlMetrics.controlCornerRadius,
        ),
        border: Border.all(
          color: tone == AppleGlassNoticeTone.neutral
              ? colors.line
              : accent.withValues(alpha: 0.42),
          width: AppleControlMetrics.hairline,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                key: messageKey,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.04,
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(width: 6), action!],
          ],
        ),
      ),
    );
  }
}

enum AppleGlassNoticeTone { neutral, info, warning }
