import 'dart:ui' show clampDouble;

import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// A [ScrollController] for reverse chat-style transcripts that keeps the
/// reader's position pinned while content grows at the zero end (streamed
/// replies, newly arrived messages).
///
/// In a `reverse: true` list the scroll offset is measured from the newest
/// end, so growth there silently shifts everything a scrolled-up reader sees
/// by the grown amount: Flutter's default dimension handling preserves the
/// numeric offset, not the visible content. This position applies a measured
/// message offset as a layout-time correction through the viewport's
/// correction loop, so the visible rows do not move and no intermediate
/// shifted frame is ever painted.
///
/// Holding disengages while the reader sits at the newest edge or scrolls.
/// Mounted rows register their stable identity with [ReadingPositionAnchor].
/// Call [captureReadingAnchor] before replacing the transcript's widget data.
class ReadingPositionScrollController extends ScrollController {
  ReadingPositionScrollController();

  final Map<Object, _ReadingPositionAnchorBox> _anchors = {};
  ({ScrollPosition position, Object id, double offset})? _readingAnchor;

  /// A different transcript owns its own reading position, even when its
  /// keyed scrollable briefly shares this controller during replacement.
  void clearReadingAnchor() => _readingAnchor = null;

  /// Capture a visible message before replacing the lazy transcript. The
  /// viewport's maximum extent is an estimate for variable-height rows;
  /// measuring this message after layout keeps that estimate out of anchoring.
  void captureReadingAnchor() {
    clearReadingAnchor();
    if (positions.length != 1) return;
    final position = positions.single;
    if (!position.hasContentDimensions ||
        position.pixels <= 48 ||
        position.isScrollingNotifier.value) {
      return;
    }
    var nearest = double.infinity;
    for (final entry in _anchors.entries) {
      final box = entry.value;
      if (!box.attached || !box.hasSize) continue;
      final contentOffset = box.contentOffset;
      final offset = contentOffset == null
          ? null
          : position.viewportDimension - (contentOffset - position.pixels);
      if (offset == null ||
          offset + box.size.height < 0 ||
          offset > position.viewportDimension) {
        continue;
      }
      final distance = (offset - position.viewportDimension * 0.4).abs();
      if (distance >= nearest) continue;
      nearest = distance;
      _readingAnchor = (
        position: position,
        id: entry.key,
        offset: contentOffset! - position.pixels,
      );
    }
  }

  double? _readingAnchorDelta(ScrollPosition position) {
    final anchor = _readingAnchor;
    if (anchor == null || !identical(anchor.position, position)) return null;
    final offset = _anchors[anchor.id]?.contentOffset;
    final delta = offset == null
        ? null
        : offset - position.pixels - anchor.offset;
    return delta;
  }

  void _clearPositionAnchor(ScrollPosition position) {
    if (identical(_readingAnchor?.position, position)) clearReadingAnchor();
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    final position = _ReadingPositionScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      anchorDelta: _readingAnchorDelta,
      clearAnchor: _clearPositionAnchor,
    );
    // Scrollable replaces its position when its physics changes, passing the
    // previous position for absorption. That remains the same viewport and
    // must retain its captured anchor; a newly keyed viewport has no oldPosition.
    final anchor = _readingAnchor;
    if (anchor != null && identical(anchor.position, oldPosition)) {
      _readingAnchor = (
        position: position,
        id: anchor.id,
        offset: anchor.offset,
      );
    }
    return position;
  }
}

class _ReadingPositionScrollPosition extends ScrollPositionWithSingleContext {
  _ReadingPositionScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.anchorDelta,
    required this.clearAnchor,
  });

  /// Reading positions closer than this to the newest edge follow new
  /// content instead of holding still; mirrors the transcript's at-latest
  /// threshold.
  static const double _atNewestThreshold = 48;

  final double? Function(ScrollPosition) anchorDelta;
  final void Function(ScrollPosition) clearAnchor;

  @override
  void dispose() {
    clearAnchor(this);
    super.dispose();
  }

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
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final measuredDelta = anchorDelta(this);
    if (measuredDelta != null &&
        !_userIsScrolling &&
        pixels > _atNewestThreshold) {
      final corrected = clampDouble(
        pixels + measuredDelta,
        minScrollExtent,
        maxScrollExtent,
      );
      if ((corrected - pixels).abs() > 0.5) {
        correctPixels(corrected);
        return false;
      }
    }
    clearAnchor(this);
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

/// Registers only mounted lazy rows. No GlobalKeys or transcript-wide widget
/// lookup are needed, and a recreated row can recover the same native identity.
class ReadingPositionAnchor extends SingleChildRenderObjectWidget {
  const ReadingPositionAnchor({
    super.key,
    required this.controller,
    required this.anchorId,
    this.isRow = false,
    required super.child,
  });

  final ScrollController? controller;
  final Object anchorId;
  final bool isRow;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _ReadingPositionAnchorBox(
        controller is ReadingPositionScrollController
            ? controller as ReadingPositionScrollController
            : null,
        anchorId,
        isRow,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _ReadingPositionAnchorBox).update(
      controller is ReadingPositionScrollController
          ? controller as ReadingPositionScrollController
          : null,
      anchorId,
      isRow,
    );
  }
}

class _ReadingPositionAnchorBox extends RenderProxyBox {
  _ReadingPositionAnchorBox(this.controller, this.anchorId, this.isRow);

  ReadingPositionScrollController? controller;
  Object anchorId;
  bool isRow;
  double layoutHeight = 0;

  double? get contentOffset {
    if (!attached || !hasSize) return null;
    _ReadingPositionAnchorBox? row;
    RenderObject? ancestor = this;
    while (ancestor != null) {
      if (ancestor is _ReadingPositionAnchorBox && ancestor.isRow) {
        row = ancestor;
      }
      if (ancestor.parent is RenderSliverMultiBoxAdaptor) {
        final data = ancestor.parentData;
        if (row == null ||
            data is! SliverMultiBoxAdaptorParentData ||
            data.layoutOffset == null) {
          return null;
        }
        final withinRow = identical(row, this)
            ? 0.0
            : localToGlobal(Offset.zero, ancestor: row).dy;
        return data.layoutOffset! + row.layoutHeight - withinRow;
      }
      ancestor = ancestor.parent;
    }
    return null;
  }

  void update(ReadingPositionScrollController? next, Object id, bool row) {
    if (identical(controller, next) && anchorId == id && isRow == row) return;
    _unregister();
    controller = next;
    anchorId = id;
    isRow = row;
    if (attached) controller?._anchors[anchorId] = this;
  }

  @override
  void performLayout() {
    super.performLayout();
    layoutHeight = size.height;
  }

  void _unregister() {
    if (identical(controller?._anchors[anchorId], this)) {
      controller?._anchors.remove(anchorId);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    controller?._anchors[anchorId] = this;
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }
}
