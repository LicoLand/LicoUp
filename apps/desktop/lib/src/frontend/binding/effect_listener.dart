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
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(EffectListener<E> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source)) {
      _release();
      _subscribe();
    }
  }

  void _subscribe() {
    // A rebind or a disposal advances the generation before the previous
    // subscription is cancelled, so an effect already in flight from the
    // replaced source is dropped instead of being delivered twice or after
    // the region is gone.
    final generation = ++_generation;
    _subscription = widget.source.effects.listen((effect) {
      if (!mounted || generation != _generation) return;
      widget.onEffect(effect);
    });
  }

  void _release() {
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    unawaited(subscription?.cancel());
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
