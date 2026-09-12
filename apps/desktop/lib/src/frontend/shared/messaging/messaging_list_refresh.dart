import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';

/// Short catalogs still accept a pull, and releasing overscroll hands control
/// back to Flutter's ballistic spring.
const messagingListScrollPhysics = BouncingScrollPhysics(
  parent: AlwaysScrollableScrollPhysics(),
);

/// Pull feedback for catalogs whose refresh is an intent and whose loading
/// state comes back through a projection. Refresh never holds the scrollable
/// at a negative offset or guesses when asynchronous work has completed.
class MessagingListRefresh extends StatefulWidget {
  const MessagingListRefresh({
    super.key,
    required this.child,
    this.onRefresh,
    this.refreshing = false,
  });

  final Widget child;
  final VoidCallback? onRefresh;
  final bool refreshing;

  @override
  State<MessagingListRefresh> createState() => _MessagingListRefreshState();
}

class _MessagingListRefreshState extends State<MessagingListRefresh> {
  static const _triggerExtent = 80.0;
  final _pullProgress = ValueNotifier<double>(0);
  bool _trackingPull = false;

  @override
  void dispose() {
    _pullProgress.dispose();
    super.dispose();
  }

  void _releasePull() {
    if (!_trackingPull) return;
    _trackingPull = false;
    final armed = _pullProgress.value >= 1;
    _pullProgress.value = 0;
    if (armed && !widget.refreshing) widget.onRefresh?.call();
  }

  bool _handleScroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) {
      _trackingPull =
          notification.dragDetails != null &&
          notification.metrics.extentBefore == 0 &&
          widget.onRefresh != null &&
          !widget.refreshing;
      _pullProgress.value = 0;
    } else if (notification is ScrollUpdateNotification && _trackingPull) {
      if (notification.dragDetails == null) {
        // Ballistic updates start as the fingers release, before the spring
        // has returned to the edge. ScrollEnd arrives after that return.
        _releasePull();
      } else {
        _pullProgress.value =
            ((notification.metrics.minScrollExtent -
                        notification.metrics.pixels) /
                    _triggerExtent)
                .clamp(0.0, 1.0);
      }
    } else if (notification is ScrollEndNotification) {
      _releasePull();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: ValueListenableBuilder<double>(
                  valueListenable: _pullProgress,
                  builder: (context, progress, _) => AnimatedSwitcher(
                    duration: context.motion(LicoMotion.micro),
                    child: !widget.refreshing && progress == 0
                        ? const SizedBox.shrink()
                        : Opacity(
                            key: const Key('messaging-list-refresh-feedback'),
                            opacity: widget.refreshing ? 1 : progress,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.surface,
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(7),
                                child: SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    key: const Key(
                                      'messaging-list-refresh-indicator',
                                    ),
                                    value: widget.refreshing
                                        ? context.allowsAmbientMotion
                                              ? null
                                              : 1
                                        : progress,
                                    semanticsLabel: MaterialLocalizations.of(
                                      context,
                                    ).refreshIndicatorSemanticLabel,
                                    color: colors.primary,
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
