import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/layout/layout_scope.dart';

/// Rebuilds [builder] on layout-state changes only when [valuesOf] actually
/// reports a different value list. A raw StreamBuilder on
/// `LayoutScopedState.changes` rebuilds for every channel write in the store
/// — scroll offsets, pane extents, unrelated tabs — which turns one settings
/// scroll frame into a full sidebar rebuild. This builder reads the values a
/// subtree actually depends on and skips the rebuild when they are unchanged.
final class LayoutValuesBuilder extends StatefulWidget {
  const LayoutValuesBuilder({
    super.key,
    required this.state,
    required this.valuesOf,
    required this.builder,
  });

  /// The scoped store to observe; null renders once without subscribing.
  final LayoutScopedState? state;

  /// Reads the values this subtree depends on. Compared with the previous
  /// list on every store change; a rebuild happens only on a real change.
  final List<Object?> Function(BuildContext context) valuesOf;

  final WidgetBuilder builder;

  @override
  State<LayoutValuesBuilder> createState() => _LayoutValuesBuilderState();
}

final class _LayoutValuesBuilderState extends State<LayoutValuesBuilder> {
  StreamSubscription<void>? _subscription;

  /// The value baseline captured at mount. Must be recorded eagerly — a lazy
  /// first read would see the already-updated values and mask the change.
  List<Object?>? _values;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _values ??= widget.valuesOf(context);
  }

  @override
  void didUpdateWidget(LayoutValuesBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _subscribe();
      _values = widget.valuesOf(context);
    }
  }

  void _subscribe() {
    final state = widget.state;
    _subscription = state?.changes.listen((_) => _sync());
  }

  void _sync() {
    if (!mounted) {
      return;
    }
    final next = widget.valuesOf(context);
    final current = _values ??= next;
    if (listEquals(current, next)) {
      return;
    }
    setState(() => _values = next);
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
