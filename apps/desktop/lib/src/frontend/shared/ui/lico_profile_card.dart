import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

// Shared Demo `.profile-card` primitives: gradient cover band, avatar ring,
// status pill, facts grid, capability chips and action pills. Agent Hub's
// detail card and the member profile popover both compose these.

/// A four-point sparkle for the profile cover — the demo's `✦` glyph, drawn
/// as a rotated square so it never depends on font coverage.
final class LicoCoverStar extends StatelessWidget {
  const LicoCoverStar({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(size * 0.22),
        ),
      ),
    );
  }
}

/// The profile card's gradient cover band. In the dark preset it is the
/// `linear-gradient(140deg, #241A4E, #120E26)` sky with scattered ✦ stars;
/// light presets keep the pale violet wash of the demo's light cover.
final class LicoProfileCover extends StatelessWidget {
  const LicoProfileCover({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors.isDark
              ? const [Color(0xFF241A4E), Color(0xFF120E26)]
              : [colors.accentSurface, colors.surface],
        ),
      ),
      child: colors.isDark
          ? Stack(
              children: [
                for (final (left, top, size) in [
                  (18.0, 22.0, 10.0),
                  (204.0, 30.0, 7.0),
                  (128.0, 12.0, 5.0),
                  (250.0, 52.0, 4.0),
                ])
                  Positioned(
                    left: left,
                    top: top,
                    child: LicoCoverStar(
                      size: size,
                      color: const Color(0x80FFF6D8),
                    ),
                  ),
                Positioned(
                  right: 16,
                  top: 14,
                  child: LicoCoverStar(size: 16, color: colors.primaryStrong),
                ),
              ],
            )
          : null,
    );
  }
}

/// The demo's avatar ring: a gold gradient ring in the dark preset, a flat
/// `--bg-raised` ring in light presets.
final class LicoProfileAvatarRing extends StatelessWidget {
  const LicoProfileAvatarRing({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final dark = colors.isDark;
    return Container(
      padding: EdgeInsets.all(dark ? 1.5 : 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: dark
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.primaryStrong,
                  colors.primary,
                  const Color(0xFFB8860B),
                ],
              )
            : null,
        color: dark ? null : colors.surfaceRaised,
      ),
      child: child,
    );
  }
}

/// The demo's `.pc-status` pill: a dot inside a subtle bordered capsule.
final class LicoProfileStatusPill extends StatelessWidget {
  const LicoProfileStatusPill({
    super.key,
    required this.label,
    required this.dotColor,
  });

  final String label;
  final Color dotColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: continuousHairlineDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(999),
        stroke: colors.line,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(shape: BoxShape.circle, color: dotColor),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// The demo's `.pc-facts`: a two-column grid of small stat tiles.
final class LicoProfileFactGrid extends StatelessWidget {
  const LicoProfileFactGrid({
    super.key,
    required this.facts,
    this.firstValueKey,
  });

  final List<(String, String)> facts;

  /// Optional key applied to the first fact's value text so existing tests
  /// keep their `agent-hub-version-*` anchor.
  final Key? firstValueKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    // Larger text needs taller cells: the 2.7 base ratio assumes the default
    // scale, so divide by the user's text scale (clamped so cells stay sane).
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.7 / textScale,
      children: [
        for (final (index, fact) in facts.indexed)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: continuousHairlineDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(10),
              stroke: colors.line,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  fact.$1,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.textMuted),
                ),
                const SizedBox(height: 1),
                Text(
                  fact.$2,
                  key: index == 0 ? firstValueKey : null,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The demo's `.pc-caps span`: a brand-tinted capability chip.
final class LicoProfileCapChip extends StatelessWidget {
  const LicoProfileCapChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: continuousHairlineDecoration(
        color: colors.brandSurface,
        borderRadius: BorderRadius.circular(999),
        stroke: colors.brandBorder,
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: colors.accent),
      ),
    );
  }
}

enum LicoProfileActionKind { filled, quiet, danger }

/// One `.pc-actions .btn`: equal-width capsule — brand-filled, quiet
/// raised-surface, or danger-outlined — matching the demo's action row.
final class LicoProfileAction extends StatelessWidget {
  const LicoProfileAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.trailingIcon,
    this.kind = LicoProfileActionKind.quiet,
    this.enabled = true,
    this.actionKey,
  });

  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final IconData? trailingIcon;
  final LicoProfileActionKind kind;
  final bool enabled;

  /// Lands on the inner tap target so tests can find `InkWell` by key.
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final filled = kind == LicoProfileActionKind.filled;
    final Color foreground;
    final Color background;
    final Color borderColor;
    if (!enabled) {
      foreground = colors.textDisabled;
      background = filled
          ? colors.surfaceLow.withValues(alpha: 0.5)
          : Colors.transparent;
      borderColor = colors.line.withValues(alpha: 0.5);
    } else if (kind == LicoProfileActionKind.danger) {
      foreground = colors.error;
      background = Colors.transparent;
      borderColor = colors.error.withAlpha(120);
    } else if (filled) {
      foreground = colors.textOnPrimary;
      background = colors.primary;
      borderColor = colors.primary;
    } else {
      foreground = colors.textSecondary;
      background = colors.surfaceLow;
      borderColor = colors.line;
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: actionKey,
        onTap: enabled ? onPressed : null,
        borderRadius: _profileChipBorderRadius,
        child: Ink(
          decoration: continuousHairlineDecoration(
            color: background,
            borderRadius: _profileChipBorderRadius,
            stroke: borderColor,
            strokeWidth: MessagingDesktopMetrics.hairline,
          ),
          child: ConstrainedBox(
            constraints: kind == LicoProfileActionKind.quiet
                ? const BoxConstraints()
                : const BoxConstraints(minHeight: 36, minWidth: 88),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: kind == LicoProfileActionKind.quiet ? 12 : 16,
                vertical: kind == LicoProfileActionKind.quiet ? 7 : 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 13, color: foreground),
                    const SizedBox(width: LicoContentSpacing.inline),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: kind == LicoProfileActionKind.quiet
                          ? TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            )
                          : textTheme.labelSmall?.copyWith(
                              fontSize: 12,
                              height: 1,
                              fontWeight: FontWeight.w600,
                              color: foreground,
                            ),
                    ),
                  ),
                  if (trailingIcon != null) ...[
                    const SizedBox(width: 4),
                    Icon(trailingIcon, size: 13, color: colors.textMuted),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

const BorderRadius _profileChipBorderRadius = BorderRadius.all(
  Radius.circular(999),
);
