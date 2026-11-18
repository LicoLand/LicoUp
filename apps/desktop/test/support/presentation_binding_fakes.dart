import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class StaticProjectionSource<T> implements ProjectionSource<T> {
  const StaticProjectionSource(this.current);

  @override
  final T current;

  @override
  Stream<ProjectionUpdate<T>> get changes => const Stream.empty();
}

/// A projection the test replaces; every [set] publishes synchronously.
final class MutableProjectionSource<T> implements ProjectionSource<T> {
  MutableProjectionSource(this._current);

  final StreamController<ProjectionUpdate<T>> _changes =
      StreamController<ProjectionUpdate<T>>.broadcast(sync: true);
  T _current;

  @override
  T get current => _current;

  @override
  Stream<ProjectionUpdate<T>> get changes => _changes.stream;

  void set(T next) {
    _current = next;
    _changes.add(ProjectionUpdate<T>(next));
  }

  Future<void> close() => _changes.close();
}

final class RecordingIntentSink<T> implements IntentSink<T> {
  final List<T> sent = <T>[];

  @override
  void send(T intent) => sent.add(intent);
}

final class SilentEffectSource<T> implements EffectSource<T> {
  const SilentEffectSource();

  @override
  Stream<T> get effects => const Stream.empty();
}

/// A conversation binding over [projection] and [canonicalEvents]; every
/// other projection is empty and static.
ConversationBinding conversationBindingFake({
  required ProjectionSource<ConversationProjection> projection,
  required ProjectionSource<CanonicalConversationProjection> canonicalEvents,
  IntentSink<ConversationIntent>? intents,
}) => ConversationBinding(
  projection: projection,
  nativeCatalog: StaticProjectionSource(
    NativeConversationCatalogProjection(
      sessions: const <NativeConversationSessionProjection>[],
      hasMore: false,
      phase: PresentationPhase.ready,
    ),
  ),
  canonicalEvents: canonicalEvents,
  persistentTurns: StaticProjectionSource(
    PersistentTurnProjection(
      conversationId: '',
      memberships: const <MembershipTurnProjection>[],
    ),
  ),
  composer: StaticProjectionSource(
    ComposerProjection(
      conversationId: '',
      draft: '',
      inputEnabled: true,
      sendLabel: 'Send',
    ),
  ),
  attachments: StaticProjectionSource(
    ConversationAttachmentsProjection(
      conversationId: '',
      attachments: const <ConversationAttachmentProjection>[],
      acceptsImages: true,
    ),
  ),
  tabActivity: StaticProjectionSource(
    ConversationTabActivityProjection(
      conversationId: '',
      active: true,
      unreadCount: 0,
      requiresAttention: false,
    ),
  ),
  notifications: StaticProjectionSource(
    ConversationNotificationsProjection(notices: const []),
  ),
  archive: StaticProjectionSource(
    ConversationArchiveProjection(
      conversations: const [],
      phase: PresentationPhase.ready,
    ),
  ),
  intents: intents ?? RecordingIntentSink<ConversationIntent>(),
  effects: const SilentEffectSource<ConversationEffect>(),
);
