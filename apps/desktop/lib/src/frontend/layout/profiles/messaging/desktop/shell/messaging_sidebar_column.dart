import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/layout/layout_state_store.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_scope.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/presentation/messaging_desktop_destination_presentations.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';

/// Shell-owned sidebar width. Stays mounted across destination switches so
/// the last drag width does not jump. Persists through the agents sidebar
/// channel, which is the single declared pane-extent for this column.
final class MessagingSidebarGeometry extends StatefulWidget {
  const MessagingSidebarGeometry({super.key, required this.child});

  final Widget child;

  @override
  State<MessagingSidebarGeometry> createState() =>
      _MessagingSidebarGeometryState();
}

final class _MessagingSidebarGeometryState
    extends State<MessagingSidebarGeometry> {
  double _width = MessagingDesktopMetrics.conversationListExtent;
  LayoutScopedState? _layoutState;
  String? _layoutIdentity;
  bool _hydrated = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = LayoutScope.maybeOf(context);
    final identity = scope == null
        ? null
        : '${scope.profileId.value}/${scope.environment.surface.name}';
    if (_layoutIdentity == identity) {
      _layoutState = scope?.state;
      return;
    }
    _layoutIdentity = identity;
    _layoutState = scope?.state;
    if (_hydrated) {
      return;
    }
    final stored = _layoutState?.readIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
    );
    if (stored is LayoutPaneExtentState) {
      _width = stored.extent.clamp(
        MessagingDesktopMetrics.conversationListMinExtent,
        MessagingDesktopMetrics.conversationListMaxExtent,
      );
    }
    _hydrated = true;
  }

  void _resize(double delta, double maxWidth) {
    final next = (_width + delta)
        .clamp(
          MessagingDesktopMetrics.conversationListMinExtent,
          maxWidth,
        )
        .toDouble();
    if (next == _width) {
      return;
    }
    setState(() => _width = next);
    _layoutState?.writeIfDeclaredFor(
      ClientSection.agents,
      LayoutStateChannels.agentsSidebar,
      LayoutPaneExtentState(_width),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MessagingSidebarGeometryScope(
      width: _width,
      onResize: _resize,
      child: widget.child,
    );
  }
}

/// Provides the shared sidebar column width to the shell and the agents
/// workspace. Destination lists read this; they do not own the split.
final class MessagingSidebarGeometryScope extends InheritedWidget {
  const MessagingSidebarGeometryScope({
    super.key,
    required this.width,
    required this.onResize,
    required super.child,
  });

  final double width;
  final void Function(double delta, double maxWidth) onResize;

  static MessagingSidebarGeometryScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MessagingSidebarGeometryScope>();

  @override
  bool updateShouldNotify(MessagingSidebarGeometryScope oldWidget) =>
      oldWidget.width != width;
}

/// One resizable sidebar column: framed list card, persisted width, and the
/// drag handle. Dedicated lists are only the [sidebar] slot.
final class MessagingSidebarColumn extends StatelessWidget {
  const MessagingSidebarColumn({
    super.key,
    required this.sidebar,
    required this.detail,
    this.sidebarCollapsed = false,
  });

  final Widget sidebar;
  final Widget detail;
  final bool sidebarCollapsed;

  @override
  Widget build(BuildContext context) {
    final geometry = MessagingSidebarGeometryScope.maybeOf(context);
    final presentation = messagingDesktopAgentsPresentation;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxSidebarWidth = math
            .max(
              MessagingDesktopMetrics.conversationListMinExtent,
              constraints.maxWidth -
                  MessagingDesktopMetrics.conversationListDividerWidth -
                  MessagingDesktopMetrics.conversationDetailMinExtent -
                  presentation.sidebarOuterHorizontalExtent -
                  presentation.detailOuterHorizontalExtent,
            )
            .clamp(
              MessagingDesktopMetrics.conversationListMinExtent,
              MessagingDesktopMetrics.conversationListMaxExtent,
            )
            .toDouble();
        final width =
            (geometry?.width ?? MessagingDesktopMetrics.conversationListExtent)
                .clamp(
                  MessagingDesktopMetrics.conversationListMinExtent,
                  maxSidebarWidth,
                )
                .toDouble();
        return Row(
          key: const Key('messaging-sidebar-split'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!sidebarCollapsed)
              presentation.frameSidebar(
                context,
                key: const Key('messaging-sidebar-column-card'),
                child: SizedBox(
                  key: const Key('messaging-sidebar-column'),
                  width: width,
                  child: sidebar,
                ),
              ),
            Expanded(
              child: _MessagingSidebarResizeHandle(
                width: MessagingDesktopMetrics.conversationListDividerWidth,
                enabled: !sidebarCollapsed,
                onDragDelta: (delta) =>
                    geometry?.onResize(delta, maxSidebarWidth),
                child: detail,
              ),
            ),
          ],
        );
      },
    );
  }
}

final class _MessagingSidebarResizeHandle extends StatelessWidget {
  const _MessagingSidebarResizeHandle({
    required this.width,
    required this.enabled,
    required this.onDragDelta,
    required this.child,
  });

  final double width;
  final bool enabled;
  final ValueChanged<double>? onDragDelta;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled || onDragDelta == null) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              key: const Key('messaging-sidebar-resize-handle'),
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  onDragDelta!(details.delta.dx),
              child: SizedBox(width: width),
            ),
          ),
        ),
      ],
    );
  }
}
