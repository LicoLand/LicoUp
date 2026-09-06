import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/messaging/messaging_search_capsule.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_traffic_light_anchor.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// Shared conversation-column chrome: the macOS traffic-light row at the card
/// top-left (replacing the old sticky title), optional search, optional
/// contextual actions, a scrollable list slot, and optional bottom nav.
/// Dedicated lists supply the slot; this widget owns only the foundation
/// styles. Width and the drag-resize handle belong to the shell column.
final class MessagingSidebarFoundation extends StatelessWidget {
  const MessagingSidebarFoundation({
    super.key,
    this.headingActions,
    this.onSearch,
    this.searchBottomPadding = LicoContentSpacing.compact,
    this.contextualAction,
    required this.list,
    this.bottomNav,
  });

  final List<Widget>? headingActions;
  final VoidCallback? onSearch;
  final double searchBottomPadding;
  final Widget? contextualAction;
  final Widget list;
  final Widget? bottomNav;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const Key('messaging-sidebar-foundation'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
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
                  const MessagingTrafficLightAnchor(),
                  const Spacer(),
                  ...?headingActions,
                ],
              ),
            ),
          ),
          if (onSearch != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                LicoContentSpacing.compact,
                0,
                LicoContentSpacing.compact,
                searchBottomPadding,
              ),
              child: MessagingSearchCapsule(
                key: const Key('messaging-sidebar-search'),
                onTap: onSearch!,
              ),
            ),
          ?contextualAction,
          Expanded(child: list),
          ?bottomNav,
        ],
      ),
    );
  }
}
