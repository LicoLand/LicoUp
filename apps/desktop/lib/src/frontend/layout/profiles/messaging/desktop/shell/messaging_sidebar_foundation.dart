import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/components/messaging_search_capsule.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Shared conversation-column chrome: sticky title and optional search,
/// optional contextual actions, a scrollable list slot, and optional bottom
/// nav. Dedicated lists supply the slot; this widget owns only the foundation
/// styles. Width and the drag-resize handle belong to the shell column.
final class MessagingSidebarFoundation extends StatelessWidget {
  const MessagingSidebarFoundation({
    super.key,
    required this.heading,
    this.headingKey,
    this.headingActions,
    this.onSearch,
    this.searchBottomPadding = LicoContentSpacing.compact,
    this.contextualAction,
    required this.list,
    this.bottomNav,
  });

  final String heading;
  final Key? headingKey;
  final List<Widget>? headingActions;
  final VoidCallback? onSearch;
  final double searchBottomPadding;
  final Widget? contextualAction;
  final Widget list;
  final Widget? bottomNav;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return ColoredBox(
      key: const Key('messaging-sidebar-foundation'),
      color: Colors.transparent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              LicoContentSpacing.item,
              LicoContentSpacing.compact,
              LicoContentSpacing.compact,
              LicoContentSpacing.compact,
            ),
            child: SizedBox(
              height: 36,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        heading,
                        key: headingKey,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
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
