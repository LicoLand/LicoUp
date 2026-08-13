import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/lico_typography.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The panel-level section header: an optional leading glyph and a bold
/// title, as used by settings and the mobile relay panel.
///
/// These headers introduce a whole card or region, so they take a title role;
/// group labels *inside* a list or menu use [LicoGroupHeader] instead.
class LicoSectionHeader extends StatelessWidget {
  const LicoSectionHeader({
    super.key,
    required this.title,
    this.leading,
    this.padding = EdgeInsets.zero,
  });

  final String title;

  /// Optional glyph before the title. The caller owns the icon itself because
  /// some surfaces use a brand or provider mark rather than a material icon.
  final Widget? leading;

  /// Outer padding. Surfaces whose layout scope owns section rhythm pass it
  /// in; inline usages keep the zero default.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[
            leading!,
            const SizedBox(width: LicoContentSpacing.compact),
          ],
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// The small muted group label used inside menus, palettes, and sidebars.
///
/// Six features grew their own copy of this row — a menu section, a search
/// palette group, two sidebar variants — with font weight and tracking
/// drifting between them. The shared recipe takes the refined sidebar form
/// (11px, w600, +0.4 tracking, `textMuted`) which now also owns
/// [LicoTypography.eyebrow].
///
/// Pass [count] for a trailing tally, and [onToggle] plus [expanded] to make
/// the row a collapse control with a chevron; the hover wash comes from
/// `hoverOverlay`, never a locally invented white/black alpha.
class LicoGroupHeader extends StatelessWidget {
  const LicoGroupHeader({
    super.key,
    required this.label,
    this.leading,
    this.count,
    this.padding = const EdgeInsets.fromLTRB(12, 10, 12, 4),
    this.onToggle,
    this.expanded,
    this.toggleKey,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: 6,
      vertical: 4,
    ),
  });

  final String label;

  /// Optional glyph before the label — a material icon sized to the label or
  /// a brand mark such as [AgentBrandIcon].
  final Widget? leading;

  /// Optional trailing tally rendered in the numeric label role.
  final int? count;

  /// Outer padding around the row.
  final EdgeInsetsGeometry padding;

  /// When set, the row becomes a tap target that toggles a collapsed group.
  final VoidCallback? onToggle;

  /// Drives the chevron direction when [onToggle] is set.
  final bool? expanded;

  /// Key stamped on the toggle hit area so tests can find it.
  final Key? toggleKey;

  /// Inner padding of the tappable row when [onToggle] is set.
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final labelStyle = LicoTypography.eyebrow(color: colors.textMuted);
    final labelRow = Row(
      children: [
        if (onToggle != null) ...[
          Icon(
            expanded ?? false
                ? Icons.expand_more_rounded
                : Icons.chevron_right_rounded,
            size: 15,
            color: colors.textMuted,
          ),
          const SizedBox(width: LicoContentSpacing.inline),
        ] else if (leading != null) ...[
          leading!,
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelStyle,
          ),
        ),
        if (count != null)
          Text('$count', style: Theme.of(context).textTheme.labelSmall),
      ],
    );
    return Padding(
      padding: padding,
      child: onToggle == null
          ? labelRow
          : Material(
              color: Colors.transparent,
              child: InkWell(
                key: toggleKey,
                onTap: onToggle,
                borderRadius: BorderRadius.circular(LicoRadius.chip),
                hoverColor: colors.hoverOverlay,
                child: Padding(padding: contentPadding, child: labelRow),
              ),
            ),
    );
  }
}
