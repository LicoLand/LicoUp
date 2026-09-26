import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';

/// The conversation plane port of the surrounding container.
///
/// Outside a [ProviderScope] the disabled port is returned: every plane stays
/// invisible and no consumer fabricates content for it.
ConversationSourcePort conversationSourcePortOf(BuildContext context) {
  try {
    final container = ProviderScope.containerOf(context, listen: false);
    return container.read(conversationSourcePortProvider);
  } on Object {
    return const DisabledConversationSourcePort();
  }
}

/// Builds one conversation plane from its runtime-backed port.
///
/// The builder subscribes only to this plane's reads and renders the selected
/// value while the plane is visible. A withdrawn plane renders its empty
/// state: a value a consumer read earlier is never shown again, and a rebuild
/// or a restyle never re-reads the plane by itself.
final class ConversationPlaneBuilder<T, S> extends StatefulWidget {
  const ConversationPlaneBuilder({
    super.key,
    required this.plane,
    required this.select,
    required this.builder,
    this.emptyBuilder,
  });

  final ConversationPlanePort<T> plane;
  final S Function(T value) select;
  final Widget Function(BuildContext context, S selected) builder;

  /// Shown while the plane has no visible value; nothing by default.
  final WidgetBuilder? emptyBuilder;

  @override
  State<ConversationPlaneBuilder<T, S>> createState() =>
      _ConversationPlaneBuilderState<T, S>();
}

class _ConversationPlaneBuilderState<T, S>
    extends State<ConversationPlaneBuilder<T, S>> {
  StreamSubscription<ConversationPlaneRead<T>>? _subscription;
  T? _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ConversationPlaneBuilder<T, S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.plane, widget.plane)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  void _subscribe() {
    _value = widget.plane.visibleValue;
    _subscription = widget.plane.reads.listen(_handleRead);
  }

  void _handleRead(ConversationPlaneRead<T> read) {
    if (!mounted) return;
    switch (read) {
      case ConversationPlaneVisible<T>(:final value):
        setState(() => _value = value);
      case ConversationPlaneWithdrawn<T>():
        setState(() => _value = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = _value;
    if (value == null) {
      final emptyBuilder = widget.emptyBuilder;
      return emptyBuilder == null
          ? const SizedBox.shrink()
          : emptyBuilder(context);
    }
    return widget.builder(context, widget.select(value));
  }
}
