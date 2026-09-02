import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/conversation_state_holder.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/projections/projection_consumer.dart';

/// One conversation-scoped L6 consumer over generated deltas.
///
/// [accept] is the only mutation entry. Consumers expose immutable projection
/// snapshots as a stream and never infer command success or turn lifecycle.
final class ConversationProjectionConsumer
    implements ProjectionConsumer<ConversationScopeProjection> {
  ConversationProjectionConsumer({
    required this.scopeKey,
    required this.participantAgentId,
    required this.participantLabel,
    this.participantRole = '',
    ConversationStateHolder? holder,
  }) : _holder = holder ?? ConversationStateHolder(),
       _ownsHolder = holder == null;

  final String scopeKey;
  final String participantAgentId;
  final String participantLabel;
  final String participantRole;
  final ConversationStateHolder _holder;
  final bool _ownsHolder;
  final StreamController<ConversationScopeProjection> _controller =
      StreamController<ConversationScopeProjection>.broadcast(sync: true);
  bool _disposed = false;

  @override
  ConversationScopeProjection get current => _holder.projectionFor(scopeKey);

  @override
  Stream<ConversationScopeProjection> get projections => _controller.stream;

  void accept(ConversationDelta delta) {
    if (_disposed) return;
    final changed = _holder.applyDelta(
      delta,
      scopeKey: scopeKey,
      participantAgentId: participantAgentId,
      participantLabel: participantLabel,
      participantRole: participantRole,
    );
    if (changed) _controller.add(current);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_ownsHolder) _holder.dispose();
    await _controller.close();
  }
}
