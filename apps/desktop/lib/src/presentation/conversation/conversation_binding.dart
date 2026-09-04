import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

final class ConversationBinding {
  const ConversationBinding({
    required this.projection,
    required this.nativeCatalog,
    required this.canonicalEvents,
    required this.persistentTurns,
    required this.composer,
    required this.attachments,
    required this.tabActivity,
    required this.notifications,
    required this.archive,
    required this.intents,
    required this.effects,
  });

  final ProjectionSource<ConversationProjection> projection;
  final ProjectionSource<NativeConversationCatalogProjection> nativeCatalog;
  final ProjectionSource<CanonicalConversationProjection> canonicalEvents;
  final ProjectionSource<PersistentTurnProjection> persistentTurns;
  final ProjectionSource<ComposerProjection> composer;
  final ProjectionSource<ConversationAttachmentsProjection> attachments;
  final ProjectionSource<ConversationTabActivityProjection> tabActivity;
  final ProjectionSource<ConversationNotificationsProjection> notifications;
  final ProjectionSource<ConversationArchiveProjection> archive;
  final IntentSink<ConversationIntent> intents;
  final EffectSource<ConversationEffect> effects;
}
