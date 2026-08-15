import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Ghost circular refresh control used by pane title bars.
///
/// Agent Hub and Plugin Management bind their own [onPressed] handlers; the
/// glyph, size, and tone stay here so both surfaces stay identical.
final class LicoPaneRefreshButton extends StatelessWidget {
  const LicoPaneRefreshButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.refreshing = false,
    this.refreshingIconKey,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final bool refreshing;
  final Key? refreshingIconKey;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final iconSize = LicoIconButtonSize.medium.iconSize;
    return LicoIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      size: LicoIconButtonSize.medium,
      shape: LicoIconButtonShape.circle,
      tone: LicoIconButtonTone.ghost,
      icon: refreshing
          ? LicoSpinningRefreshIcon(
              key: refreshingIconKey,
              size: iconSize,
              color: colors.textMuted,
            )
          : const Icon(Icons.refresh),
    );
  }
}

/// Full-width pane chrome: title on the left, [LicoPaneRefreshButton] on the
/// far right. Optional [trailing] sits immediately left of refresh and never
/// shares flex with the title, so refresh cannot bunch against the title.
final class LicoPaneTitleBar extends StatelessWidget {
  const LicoPaneTitleBar({
    super.key,
    required this.title,
    required this.refreshTooltip,
    required this.onRefresh,
    this.refreshing = false,
    this.refreshButtonKey,
    this.refreshingIconKey,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });

  final String title;
  final String refreshTooltip;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final Key? refreshButtonKey;
  final Key? refreshingIconKey;

  /// Optional actions immediately left of refresh. Feature panes leave this
  /// null; search lives in the left sidebar.
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: padding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: LicoContentSpacing.compact),
              trailing!,
            ],
            const SizedBox(width: LicoContentSpacing.compact),
            LicoPaneRefreshButton(
              key: refreshButtonKey,
              tooltip: refreshTooltip,
              onPressed: onRefresh,
              refreshing: refreshing,
              refreshingIconKey: refreshingIconKey,
            ),
          ],
        ),
      ),
    );
  }
}
