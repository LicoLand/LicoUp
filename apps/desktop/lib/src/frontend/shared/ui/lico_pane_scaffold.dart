import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';

/// Generic feature-pane layout: title bar on top, padded content container
/// below. Agent Hub, Skill Hub, Plugin Management, Devices, Monitoring,
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
          // When the shell hosts the title row (Desktop's work-area row
          // already carries the app identity), the page title is not
          // repeated: the scaffold hides its title bar and posts the
          // action row into the host's action slot instead.
          if (LicoPaneActionsHostScope.maybeOf(context) == null)
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
            )
          else
            _LicoPaneHostedActions(
              refreshTooltip: refreshTooltip,
              onRefresh: onRefresh,
              refreshing: refreshing,
              refreshButtonKey: refreshButtonKey,
              refreshingIconKey: refreshingIconKey,
              trailing: trailing,
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

/// Shell-owned channel for a pane's title-bar actions: a layout that owns
/// the destination title row (Desktop's work-area row) hosts this scope so
/// panes publish their actions instead of repeating the body title.
final class LicoPaneActionsHostScope extends InheritedWidget {
  const LicoPaneActionsHostScope({
    super.key,
    required this.actions,
    required super.child,
  });

  /// The hosted actions slot content; the page writes it, the shell reads
  /// it. Null between page swaps.
  final ValueNotifier<Widget?> actions;

  static LicoPaneActionsHostScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LicoPaneActionsHostScope>();

  @override
  bool updateShouldNotify(LicoPaneActionsHostScope oldWidget) =>
      !identical(actions, oldWidget.actions);
}

/// Publishes the pane's title-bar actions into [LicoPaneActionsHostScope]
/// and clears them on unmount; renders nothing itself.
final class _LicoPaneHostedActions extends StatefulWidget {
  const _LicoPaneHostedActions({
    required this.refreshTooltip,
    required this.onRefresh,
    required this.refreshing,
    required this.refreshButtonKey,
    required this.refreshingIconKey,
    required this.trailing,
  });

  final String refreshTooltip;
  final VoidCallback? onRefresh;
  final bool refreshing;
  final Key? refreshButtonKey;
  final Key? refreshingIconKey;
  final Widget? trailing;

  @override
  State<_LicoPaneHostedActions> createState() => _LicoPaneHostedActionsState();
}

final class _LicoPaneHostedActionsState extends State<_LicoPaneHostedActions> {
  ValueNotifier<Widget?>? _notifier;
  Widget? _posted;

  Widget _buildActions() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (widget.trailing != null) ...[
        widget.trailing!,
        const SizedBox(width: LicoContentSpacing.compact),
      ],
      LicoPaneRefreshButton(
        key: widget.refreshButtonKey,
        tooltip: widget.refreshTooltip,
        onPressed: widget.onRefresh,
        refreshing: widget.refreshing,
        refreshingIconKey: widget.refreshingIconKey,
      ),
    ],
  );

  void _publish() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = _notifier;
      if (notifier == null) return;
      _posted = _buildActions();
      notifier.value = _posted;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _notifier = LicoPaneActionsHostScope.maybeOf(context)?.actions;
    _publish();
  }

  @override
  void didUpdateWidget(_LicoPaneHostedActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  @override
  void deactivate() {
    final notifier = _notifier;
    if (notifier != null && identical(notifier.value, _posted)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(notifier.value, _posted)) notifier.value = null;
      });
    }
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
