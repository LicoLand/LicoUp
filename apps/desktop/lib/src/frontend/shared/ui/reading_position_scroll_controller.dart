import 'dart:ui' show clampDouble;

import 'package:flutter/widgets.dart';

/// A [ScrollController] for reverse chat-style transcripts that keeps the
/// reader's position pinned while content grows at the zero end (streamed
/// replies, newly arrived messages).
///
/// In a `reverse: true` list the scroll offset is measured from the newest
/// end, so growth there silently shifts everything a scrolled-up reader sees
/// by the grown amount: Flutter's default dimension handling preserves the
/// numeric offset, not the visible content. This position applies the exact
/// extent delta as a layout-time correction through the viewport's
/// correction loop, so the visible rows do not move and no intermediate
/// shifted frame is ever painted.
///
/// Holding disengages while the reader sits at the newest edge (natural
/// bottom pinning takes over there). Far-end appends — history pages
/// prepended at the oldest end — are already position-stable, so callers arm
/// [ReadingPositionScrollController.notifyFarEndAppend] around a page merge
/// to skip exactly one hold.
class ReadingPositionScrollController extends ScrollController {
  ReadingPositionScrollController();

  bool _suppressNextHold = false;

  /// Arms a one-shot hold suppression for the next content-dimension change.
  /// Call when a history page is about to land at the far (oldest) end.
  void notifyFarEndAppend() {
    _suppressNextHold = true;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ReadingPositionScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      consumeSuppression: () {
        final suppressed = _suppressNextHold;
        _suppressNextHold = false;
        return suppressed;
      },
    );
  }
}

class _ReadingPositionScrollPosition extends ScrollPositionWithSingleContext {
  _ReadingPositionScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.consumeSuppression,
  });

  /// Reading positions closer than this to the newest edge follow new
  /// content instead of holding still; mirrors the transcript's at-latest
  /// threshold.
  static const double _atNewestThreshold = 48;

  /// Returns true once after a far-end append was announced.
  final bool Function() consumeSuppression;

  /// Pointer-driven scroll (drag, hold, or fling). Layout-time correction
  /// must not move pixels while one of these owns the gesture.
  bool get _userIsScrolling {
    final current = activity;
    if (current == null) {
      return false;
    }
    return current.isScrolling || current is HoldScrollActivity;
  }

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final extentDelta =
        newPosition.maxScrollExtent - oldPosition.maxScrollExtent;
    if (extentDelta != 0.0 && oldPosition.maxScrollExtent > 0) {
      // Consume the one-shot suppression on the first extent change after it
      // was armed, regardless of where the reader sits, so a stale flag can
      // never eat a later near-end correction.
      final suppressed = consumeSuppression();
      // Hold the visible rows while content appends at the newest end and
      // the reader is parked away from that edge. At-newest uses reverse
      // pinning. A live drag or fling owns the pixels; correcting
      // mid-gesture fights the pointer and feels like bounce.
      final holdingAwayFromNewest = pixels > _atNewestThreshold;
      if (!suppressed && holdingAwayFromNewest && !_userIsScrolling) {
        final held = clampDouble(
          pixels + extentDelta,
          newPosition.minScrollExtent,
          newPosition.maxScrollExtent,
        );
        if (held != pixels) {
          correctPixels(held);
          return false;
        }
      }
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}
