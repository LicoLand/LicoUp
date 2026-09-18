import 'dart:async';

/// Mutable priority marker carried through a [Zone] so that commands spawned
/// by one logical task inherit the task's priority without threading a
/// parameter through every layer of the call stack. Flipping [background]
/// while the task is still in flight boosts the remainder of its queued
/// commands to foreground.
final class RpcPriorityToken {
  RpcPriorityToken({required bool background}) : _background = background;

  bool _background;

  /// When true, queued RPC commands spawned in this zone yield to pending
  /// foreground commands. The in-flight command is never preempted.
  bool get background => _background;

  set background(bool value) {
    if (_background == value) return;
    _background = value;
    final listeners = _listeners?.toList(growable: false);
    if (listeners != null) {
      for (final listener in listeners) {
        listener(value);
      }
    }
  }

  Set<void Function(bool background)>? _listeners;

  /// Adds a listener invoked whenever [background] changes.
  void addListener(void Function(bool background) listener) {
    (_listeners ??= {}).add(listener);
  }

  /// Removes a previously registered listener.
  void removeListener(void Function(bool background) listener) {
    _listeners?.remove(listener);
  }
}

const Symbol rpcPriorityZoneKey = #licoRpcPriority;

/// Returns the priority token bound to the current zone, if any.
RpcPriorityToken? currentRpcPriorityToken() =>
    Zone.current[rpcPriorityZoneKey] as RpcPriorityToken?;

/// Runs [body] in a zone where spawned RPC commands carry [token].
Future<T> runWithRpcPriorityToken<T>(
  RpcPriorityToken token,
  Future<T> Function() body,
) {
  return runZoned(
    body,
    zoneValues: <Symbol, Object>{rpcPriorityZoneKey: token},
  );
}
