import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The single empty-state recipe: a muted glyph, a bold title, an optional
/// hint, and an optional action.
///
/// Feature panels used to grow one of these per surface — agents, skill hub,
/// and mobile relay each had their own, drifting in icon size, title weight,
/// and spacing. The shared recipe follows the refined mobile/skill-hub
/// pattern: the title is bold and in `text`, because a bare muted line reads
/// as disabled rather than empty, and supporting copy sits in `textMuted`.
///
/// The action slot is a widget so the caller keeps ownership of the label,
/// icon, key, and callback; it is typically an [OutlinedButton].
class LicoEmptyState extends StatelessWidget {
  const LicoEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.padding = const EdgeInsets.all(28),
    this.iconSize = 36,
  });

  /// The glyph above the title, rendered in `textMuted`.
  final IconData icon;

  /// The primary statement of emptiness, e.g. "No skills found".
  final String title;

  /// Optional supporting copy under the title.
  final String? message;

  /// Optional action rendered below the copy, typically an [OutlinedButton].
  final Widget? action;

  /// Outer padding around the whole state.
  final EdgeInsetsGeometry padding;

  /// Glyph size. Full-panel states may raise it toward a hero moment; dense
  /// panes keep the default.
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colors.textMuted, size: iconSize),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(color: colors.textMuted),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 14), action!],
          ],
        ),
      ),
    );
  }
}
