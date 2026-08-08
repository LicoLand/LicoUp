import 'dart:async';

/// Mutable priority marker carried through a [Zone] so that commands spawned
/// by one logical task inherit the task's priority without threading a
/// parameter through every layer of the call stack. Flipping [background]
/// while the task is still in flight boosts the remainder of its queued
/// commands to foreground.
final class RpcPriorityToken {
  RpcPriorityToken({required this.background});

  /// When true, queued RPC commands spawned in this zone yield to pending
  /// foreground commands. The in-flight command is never preempted.
  bool background;
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
