import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_search_capsule.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_window_drag_region.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// Shared conversation-column chrome: the macOS traffic-light row at the card
/// top-left (replacing the old sticky title), optional search, optional
/// filters, optional contextual actions, a scrollable list slot, and optional
/// bottom nav. A [title] replaces the traffic-light zone for shells that host
/// the window controls outside this column. Dedicated lists supply the slot;
/// this widget owns only the foundation styles. Width and the drag-resize
/// handle belong to the shell column.
/// The ghost circular icon button the sidebar's top row and list headers
/// share — same component and metrics everywhere so search and compose
/// read as one action family.
final class MessagingGhostIconButton extends StatelessWidget {
  const MessagingGhostIconButton({
    super.key,
    this.inkWellKey,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.dimension = 30,
    this.iconExtent = 17,
  });

  final Key? inkWellKey;
  final String tooltip;
  final VoidCallback onPressed;
  final IconData icon;
  final double dimension;
  final double iconExtent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Tooltip(
      message: tooltip,
      waitDuration: LicoMotion.tooltipWait,
      child: InkWell(
        key: inkWellKey,
        onTap: onPressed,
        customBorder: const CircleBorder(),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(12),
        child: SizedBox.square(
          dimension: dimension,
          child: Icon(icon, size: iconExtent, color: colors.textMuted),
        ),
      ),
    );
  }
}

final class MessagingSidebarFoundation extends StatelessWidget {
  const MessagingSidebarFoundation({
    super.key,
    this.title,
    this.headingActions,
    this.onSearch,
    this.topSearchRow = false,
    this.searchBottomPadding = LicoContentSpacing.compact,
    this.filters,
    this.contextualAction,
    required this.list,
    this.bottomNav,
  });

  final String? title;

  /// Whether the column's first row is the centred search row (the search
  /// capsule plus [headingActions]) instead of the title/traffic-light row —
  /// the flat shells' sidebar header, vertically centred on the native
  /// lights.
  final bool topSearchRow;
  final List<Widget>? headingActions;
  final VoidCallback? onSearch;
  final double searchBottomPadding;
  final Widget? filters;
  final Widget? contextualAction;
  final Widget list;
  final Widget? bottomNav;

  static const double _titledInset = 12;

  @override
  Widget build(BuildContext context) {
    final title = this.title;
    final inset = title == null ? LicoContentSpacing.compact : _titledInset;
    return ColoredBox(
      key: const Key('messaging-sidebar-foundation'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (topSearchRow)
            _topSearchRow(context)
          else if (title == null)
            _trafficLightRow(context)
          else
            _titleRow(context, title),
          if (onSearch != null && !topSearchRow)
            Padding(
              padding: EdgeInsets.fromLTRB(
                inset,
                0,
                inset,
                searchBottomPadding,
              ),
              child: MessagingSearchCapsule(
                key: const Key('messaging-sidebar-search'),
                onTap: onSearch!,
              ),
            ),
          if (filters case final filters?)
            if (topSearchRow)
              // The flat sidebar's first content band shares the rail
              // avatar's top and height: one compact gap under the top row.
              Padding(
                padding: const EdgeInsets.only(top: LicoContentSpacing.compact),
                child: SizedBox(
                  key: const Key('messaging-sidebar-filters'),
                  height: MessagingDesktopMetrics.sidebarIndexRowExtent,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: filters,
                    ),
                  ),
                ),
              )
            else
              Padding(
                key: const Key('messaging-sidebar-filters'),
                padding: EdgeInsets.fromLTRB(
                  inset,
                  onSearch == null ? 0 : 2,
                  inset,
                  10,
                ),
                child: filters,
              ),
          ?contextualAction,
          Expanded(
            child: topSearchRow && filters == null
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: LicoContentSpacing.compact,
                    ),
                    child: list,
                  )
                : list,
          ),
          ?bottomNav,
        ],
      ),
    );
  }

  Widget _trafficLightRow(BuildContext context) {
    final suppression = MessagingTrafficLightSuppression.maybeOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        0,
        0,
        LicoContentSpacing.compact,
        LicoContentSpacing.compact,
      ),
      child: SizedBox(
        height: MessagingDesktopMetrics.trafficLightRowExtent,
        child: Row(
          key: const Key('messaging-sidebar-traffic-light-row'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (suppression == null)
              const MessagingTrafficLightAnchor()
            else
              SizedBox(width: suppression.reservedExtent),
            const Spacer(),
            ...?headingActions,
          ],
        ),
      ),
    );
  }

  /// The flat sidebar's first row: the search capsule stretched across the
  /// column with the heading actions pinned trailing, vertically centred on
  /// the native lights. Empty pixels drag the window and double-tap zooms
  /// it — the row's own controls claim their hits above the drag layer.
  Widget _topSearchRow(BuildContext context) {
    final onSearch = this.onSearch;
    // Ghost icon actions right-aligned on the lights' line: the leading
    // side stays empty under the traffic-light cluster.
    return SizedBox(
      key: const Key('messaging-sidebar-search-row'),
      height: MessagingDesktopMetrics.sidebarTopRowExtent,
      child: Stack(
        children: [
          const Positioned.fill(
            child: LicoWindowDragRegion(child: SizedBox.expand()),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                LicoContentSpacing.compact,
                0,
                LicoContentSpacing.compact,
                0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (onSearch != null)
                    MessagingGhostIconButton(
                      inkWellKey: const Key('messaging-sidebar-search'),
                      tooltip: LicoStrings.of(context).sidebarSearchHint,
                      onPressed: onSearch,
                      icon: Icons.search_rounded,
                    ),
                  ...?headingActions,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleRow(BuildContext context, String title) {
    final colors = context.layoutPalette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
      child: SizedBox(
        height: 32,
        child: Row(
          key: const Key('messaging-sidebar-title-row'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Text(
                title,
                key: const Key('messaging-sidebar-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 18,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            ...?headingActions,
          ],
        ),
      ),
    );
  }
}
