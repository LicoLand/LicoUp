import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

/// Shared FIFO pending policy for ordered commands and parallel reads. Entries
/// carrying a background [RpcPriorityToken] yield to pending foreground work;
/// flipping a token to foreground mid-flight boosts its pending entry
/// retroactively, and when every pending entry is background the oldest one
/// runs next.
final class RpcOperationPendingQueue<T> {
  final List<({T run, RpcPriorityToken? priority})> _pending = [];

  bool get isEmpty => _pending.isEmpty;

  void add(T run, {RpcPriorityToken? priority}) {
    _pending.add((run: run, priority: priority));
  }

  T takeNext() {
    for (var index = 0; index < _pending.length; index += 1) {
      if (_pending[index].priority?.background != true) {
        return _pending.removeAt(index).run;
      }
    }
    return _pending.removeAt(0).run;
  }
}
