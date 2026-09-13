import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';

/// Generic feature-pane layout: title bar on top, padded content container
/// below. Agent Hub, Skill Hub, Plugin Management, Mobile Relay, Monitoring,
/// and the Models panes (模型网关/聊天频道) all inherit this so spacing cannot
/// drift between surfaces — inherit the structure first, then customize
/// through the title/refresh/leading/trailing/body slots.
///
/// Title-to-top equals title-to-container ([LicoContentSpacing.paneTitleGap]).
/// The title left edge lines up with the content container left edge. Cards
/// sit inside [LicoContentSpacing.paneContentPadding]. The title bar and
/// content slot share the same full width so refresh's right edge lines up
/// with the cards.
final class LicoPaneScaffold extends StatelessWidget {
  const LicoPaneScaffold({
    super.key,
    required this.title,
    required this.refreshTooltip,
    required this.onRefresh,
    required this.body,
    this.refreshing = false,
    this.refreshButtonKey,
    this.refreshingIconKey,
    this.titleBarKey,
    this.contentKey,
    this.leading,
    this.trailing,
    this.actionsOnSeparateLine = false,
  });

  final String title;
  final String refreshTooltip;
  final VoidCallback? onRefresh;
  final Widget body;
  final bool refreshing;
  final Key? refreshButtonKey;
  final Key? refreshingIconKey;
  final Key? titleBarKey;
  final Key? contentKey;
  final Widget? leading;
  final Widget? trailing;
  final bool actionsOnSeparateLine;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LicoPaneTitleBar(
            key: titleBarKey,
            title: title,
            refreshTooltip: refreshTooltip,
            onRefresh: onRefresh,
            refreshing: refreshing,
            refreshButtonKey: refreshButtonKey,
            refreshingIconKey: refreshingIconKey,
            leading: leading,
            trailing: trailing,
            actionsOnSeparateLine: actionsOnSeparateLine,
            padding: LicoContentSpacing.paneTitlePadding,
          ),
          Expanded(
            child: Padding(
              key: contentKey,
              padding: LicoContentSpacing.paneContentPadding,
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}
