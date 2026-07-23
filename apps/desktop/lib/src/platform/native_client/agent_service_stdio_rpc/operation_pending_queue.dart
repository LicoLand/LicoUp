import 'dart:async';

import 'package:flutter_client/src/platform/native_client/native_rpc_priority.dart';

/// FIFO pending queue for one stdio session. Entries carrying a background
/// [RpcPriorityToken] are skipped while any foreground entry is pending;
/// flipping a token to foreground mid-flight boosts its pending entry
/// retroactively, and when every pending entry is background the oldest one
/// runs next.
final class RpcOperationPendingQueue {
  final List<({Future<void> Function() run, RpcPriorityToken? priority})>
  _pending = [];

  bool get isEmpty => _pending.isEmpty;

  void add(Future<void> Function() run, {RpcPriorityToken? priority}) {
    _pending.add((run: run, priority: priority));
  }

  Future<void> Function() takeNext() {
    for (var index = 0; index < _pending.length; index += 1) {
      if (_pending[index].priority?.background != true) {
        return _pending.removeAt(index).run;
      }
    }
    return _pending.removeAt(0).run;
  }
}
