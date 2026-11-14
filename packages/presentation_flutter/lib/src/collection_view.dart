import 'dart:ui' show clampDouble;
import 'package:flutter/material.dart';
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
class ReadingPositionScrollController extends ScrollController {
  ReadingPositionScrollController();

  final Map<Object, _ReadingPositionAnchorBox> _anchors =
      <Object, _ReadingPositionAnchorBox>{};
  ({ScrollPosition position, Object id, double offset})? _readingAnchor;

  /// Clear the captured reading anchor.
  void clearReadingAnchor() => _readingAnchor = null;

  /// Capture the currently visible reading anchor before replacing data.
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
      if (contentOffset == null) continue;
      final offset =
          position.viewportDimension - (contentOffset - position.pixels);
      if (offset + box.size.height < 0 || offset > position.viewportDimension) {
        continue;
      }
      final distance = (offset - position.viewportDimension * 0.4).abs();
      if (distance >= nearest) continue;
      nearest = distance;
      _readingAnchor = (
        position: position,
        id: entry.key,
        offset: contentOffset - position.pixels,
      );
    }
  }

  double? _readingAnchorDelta(ScrollPosition position) {
    final anchor = _readingAnchor;
    if (anchor == null || !identical(anchor.position, position)) return null;
    final offset = _anchors[anchor.id]?.contentOffset;
    if (offset == null) return null;
    return offset - position.pixels - anchor.offset;
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

  static const double _atNewestThreshold = 48;

  final double? Function(ScrollPosition) anchorDelta;
  final void Function(ScrollPosition) clearAnchor;

  @override
  void dispose() {
    clearAnchor(this);
    super.dispose();
  }

  bool get _userIsScrolling {
    final current = activity;
    if (current == null) return false;
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

/// Registers mounted lazy rows with a [ReadingPositionScrollController].
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

/// Generic, high-performance lazy collection view for LicoUp presentations.
///
/// Features:
/// - Lazy list layout via [ListView.builder] with stable key indexing.
/// - Automatic reading-position anchoring in [reverse] mode via
///   [ReadingPositionScrollController] and [ReadingPositionAnchor].
/// - Pagination triggering on near-edge scrolls via [onLoadEarlier].
/// - Optional [header], [footer], and [emptyBuilder].
/// - Optional [wrapWithRepaintBoundary] per row to isolate streaming repaints.
class CollectionView<Item> extends StatefulWidget {
  const CollectionView({
    super.key,
    required this.items,
    required this.itemBuilder,
    required this.itemKey,
    this.controller,
    this.reverse = false,
    this.padding,
    this.physics,
    this.header,
    this.footer,
    this.emptyBuilder,
    this.onLoadEarlier,
    this.isLoadingEarlier = false,
    this.hasEarlier = false,
    this.earlierError = '',
    this.earlierPageLeadIn = 200.0,
    this.scrollCacheExtent = 2.0,
    this.wrapWithRepaintBoundary = false,
  });

  /// The list of items to display.
  final List<Item> items;

  /// Pure builder for rendering each item at its index.
  final Widget Function(BuildContext context, Item item, int index) itemBuilder;

  /// Function returning a stable identity key for an item.
  final Object Function(Item item) itemKey;

  /// Optional scroll controller. If omitted and [reverse] is true,
  /// a [ReadingPositionScrollController] is automatically created.
  final ScrollController? controller;

  /// Whether the collection scrolls in reverse (e.g. newest items at offset 0).
  final bool reverse;

  /// Padding around the scrollable area.
  final EdgeInsetsGeometry? padding;

  /// Custom scroll physics.
  final ScrollPhysics? physics;

  /// Optional widget displayed at the top of the collection.
  final Widget? header;

  /// Optional widget displayed at the bottom of the collection.
  final Widget? footer;

  /// Widget rendered when [items] is empty.
  final Widget Function(BuildContext context)? emptyBuilder;

  /// Callback to load earlier items when scrolled near the end.
  final Future<void> Function()? onLoadEarlier;

  /// Whether an earlier page request is in flight.
  final bool isLoadingEarlier;

  /// Whether earlier items are available to load.
  final bool hasEarlier;

  /// Error message code from earlier page loads, if any.
  final String earlierError;

  /// Viewport distance before reaching the edge to trigger [onLoadEarlier].
  final double earlierPageLeadIn;

  /// Viewport multiplier for off-screen render cache extent.
  final double scrollCacheExtent;

  /// Whether each item row is wrapped in a [RepaintBoundary].
  final bool wrapWithRepaintBoundary;

  @override
  State<CollectionView<Item>> createState() => _CollectionViewState<Item>();
}

class _CollectionViewState<Item> extends State<CollectionView<Item>> {
  ScrollController? _internalController;
  bool _pageRequestInFlight = false;
  Map<Object, int> _keyIndexMap = const {};

  @override
  void initState() {
    super.initState();
    _indexItems();
  }

  /// Item keys are indexed once per item list instead of once per build, so a
  /// lazy transcript does not walk every item on each frame it paints.
  void _indexItems() {
    _keyIndexMap = <Object, int>{
      for (var i = 0; i < widget.items.length; i++)
        widget.itemKey(widget.items[i]): i,
    };
  }

  ScrollController get _effectiveController =>
      widget.controller ??
      (_internalController ??= widget.reverse
          ? ReadingPositionScrollController()
          : ScrollController());

  @override
  void didUpdateWidget(covariant CollectionView<Item> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.items, oldWidget.items)) {
      // New content is about to be laid out. Capture the visible reading anchor
      // first, so a reader who is scrolled up keeps their place even when the
      // caller forgot to announce the replacement.
      final controller = oldWidget.controller ?? _internalController;
      if (oldWidget.reverse && controller is ReadingPositionScrollController) {
        controller.captureReadingAnchor();
      }
      _indexItems();
    }
    if (widget.controller != oldWidget.controller) {
      if (oldWidget.controller == null) {
        _internalController?.dispose();
        _internalController = null;
      }
    }
  }

  @override
  void dispose() {
    _internalController?.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0 ||
        widget.isLoadingEarlier ||
        _pageRequestInFlight ||
        !widget.hasEarlier ||
        widget.onLoadEarlier == null) {
      return false;
    }

    final isMovingEarlier = switch (notification) {
      ScrollUpdateNotification(:final scrollDelta) => (scrollDelta ?? 0) > 0,
      OverscrollNotification(:final overscroll) => overscroll > 0,
      _ => false,
    };

    if (!isMovingEarlier) return false;

    final metrics = notification.metrics;
    final leadIn = widget.earlierPageLeadIn;
    if (metrics.pixels < metrics.maxScrollExtent - leadIn) {
      return false;
    }

    _pageRequestInFlight = true;
    widget.onLoadEarlier!().whenComplete(() {
      if (mounted) {
        setState(() {
          _pageRequestInFlight = false;
        });
      }
    });

    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty && widget.emptyBuilder != null) {
      final empty = widget.emptyBuilder!(context);
      if (widget.header != null || widget.footer != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.header != null) widget.header!,
            Expanded(child: empty),
            if (widget.footer != null) widget.footer!,
          ],
        );
      }
      return empty;
    }

    final hasEarlierRow =
        widget.hasEarlier ||
        widget.isLoadingEarlier ||
        widget.earlierError.isNotEmpty;

    final itemsCount = widget.items.length;
    // In reverse mode: earlier row is at the end of the list (index = itemsCount)
    final totalCount = itemsCount + (hasEarlierRow ? 1 : 0);

    final listView = ListView.builder(
      controller: _effectiveController,
      reverse: widget.reverse,
      padding: widget.padding,
      physics: widget.physics,
      scrollCacheExtent: ScrollCacheExtent.viewport(widget.scrollCacheExtent),
      itemCount: totalCount,
      findChildIndexCallback: (Key key) {
        if (key case ValueKey<Object>(:final value)) {
          return _keyIndexMap[value];
        }
        return null;
      },
      itemBuilder: (context, index) {
        if (hasEarlierRow && index == itemsCount) {
          return _EarlierPageRow(
            isLoading: widget.isLoadingEarlier,
            error: widget.earlierError,
            onRetry: widget.onLoadEarlier,
          );
        }

        final item = widget.items[index];
        final id = widget.itemKey(item);
        Widget child = widget.itemBuilder(context, item, index);

        if (widget.wrapWithRepaintBoundary) {
          child = RepaintBoundary(child: child);
        }

        if (widget.reverse) {
          return ReadingPositionAnchor(
            key: ValueKey<Object>(id),
            controller: _effectiveController,
            anchorId: id,
            isRow: true,
            child: child,
          );
        }

        return KeyedSubtree(key: ValueKey<Object>(id), child: child);
      },
    );

    Widget result = NotificationListener<ScrollNotification>(
      onNotification: _handleScrollNotification,
      child: listView,
    );

    if (widget.header != null || widget.footer != null) {
      result = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.header != null) widget.header!,
          Expanded(child: result),
          if (widget.footer != null) widget.footer!,
        ],
      );
    }

    return result;
  }
}

class _EarlierPageRow extends StatelessWidget {
  const _EarlierPageRow({
    required this.isLoading,
    required this.error,
    this.onRetry,
  });

  final bool isLoading;
  final String error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextButton(
            onPressed: onRetry,
            child: Text('Retry loading earlier ($error)'),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
