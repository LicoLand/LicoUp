import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';

typedef EffectCallback<E> = void Function(E effect);

final class EffectListener<E> extends StatefulWidget {
  const EffectListener({
    super.key,
    required this.source,
    required this.onEffect,
    required this.child,
  });

  final EffectSource<E> source;
  final EffectCallback<E> onEffect;
  final Widget child;

  @override
  State<EffectListener<E>> createState() => _EffectListenerState<E>();
}

final class _EffectListenerState<E> extends State<EffectListener<E>> {
  StreamSubscription<E>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(EffectListener<E> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _subscription?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _subscription = widget.source.effects.listen(
      (effect) => widget.onEffect(effect),
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
