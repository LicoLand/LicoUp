import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/riverpod.dart';

import 'package:licoup/src/presentation/conversation/conversation_execution_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';

/// Resource scope of the conversation data planes.
///
/// One resource is one projected plane, so a plane's value is admitted, cited,
/// and withdrawn as one unit while the planes stay independent of each other:
/// withdrawing authority over one plane never marks the rest of the
/// conversation unreadable.
const ResourceScope conversationPlaneResourceScope = ResourceScope(
  'licoup.conversation.plane',
);

/// Stable plane names. They are part of the resource identity, so consumers
/// and fixtures can address one plane without constructing an owner.
const String conversationPlaneProjection = 'projection';
const String conversationPlaneNativeCatalog = 'nativeCatalog';
const String conversationPlaneCanonicalEvents = 'canonicalEvents';
const String conversationPlanePersistentTurns = 'persistentTurns';
const String conversationPlaneComposer = 'composer';
const String conversationPlaneAttachments = 'attachments';
const String conversationPlaneTabActivity = 'tabActivity';
const String conversationPlaneArchive = 'archive';
const String conversationPlaneExecution = 'execution';

/// The resource field group of one plane.
ResourceFieldGroup<T> conversationPlaneFieldGroupFor<T>(String planeName) =>
    ResourceFieldGroup<T>(
      resource: ResourceKey(
        scope: conversationPlaneResourceScope,
        stableKey: planeName,
      ),
      name: planeName,
    );

/// Why one conversation plane stopped being visible.
enum ConversationPlaneWithdrawal {
  /// The application withdrew authority over the plane. The plane's content
  /// must not be visible again until an explicit re-read admits a fresh
  /// incarnation.
  revoked,

  /// The owning scope ended.
  scopeEnded,
}

/// One plane read: an admitted value, or a withdrawal.
sealed class ConversationPlaneRead<T> {
  const ConversationPlaneRead();
}

/// The plane currently shows this admitted value.
final class ConversationPlaneVisible<T> extends ConversationPlaneRead<T> {
  const ConversationPlaneVisible(this.value);

  final T value;
}

/// The plane stopped being visible for [reason].
final class ConversationPlaneWithdrawn<T> extends ConversationPlaneRead<T> {
  const ConversationPlaneWithdrawn(this.reason);

  final ConversationPlaneWithdrawal reason;
}

/// One conversation plane the runtime actually admits.
///
/// The plane is a stable resource: the projection producer's channel remains
/// the single source of truth, and every channel value is admitted as a new
/// version of the same resource, so a scope or selection change is content,
/// not a new owner. A withdrawal makes the plane invisible until [reconnect]
/// performs a real re-read through the runtime.
abstract interface class ConversationPlanePort<T> {
  /// The resource field this plane is admitted as. Stable for the app scope.
  ResourceFieldGroup<T> get fieldGroup;

  /// The admitted value the runtime still shows, or null when nothing is
  /// visible for this plane (not read yet, or withdrawn).
  T? get visibleValue;

  /// Narrow reads of this plane: each admitted value and each withdrawal.
  ///
  /// A consumer of one plane never rebuilds for another plane's update.
  Stream<ConversationPlaneRead<T>> get reads;

  /// Re-reads the plane after a withdrawal.
  ///
  /// The provider's current value is admitted in a fresh incarnation, so
  /// everything derived from the withdrawn one can never install again. A
  /// withdraw that was not followed by real new content stays invisible.
  void reconnect();
}

/// The conversation data planes, as supplied by the projection producer.
///
/// The producer's channels are the only source of truth for these planes; the
/// runtime owner wraps them without rebuilding their content.
final class ConversationSourcePlanes {
  const ConversationSourcePlanes({
    required this.projection,
    required this.nativeCatalog,
    required this.canonicalEvents,
    required this.persistentTurns,
    required this.composer,
    required this.attachments,
    required this.tabActivity,
    required this.archive,
    this.execution,
  });

  final ProjectionSource<ConversationProjection> projection;
  final ProjectionSource<NativeConversationCatalogProjection> nativeCatalog;
  final ProjectionSource<CanonicalConversationProjection> canonicalEvents;
  final ProjectionSource<PersistentTurnProjection> persistentTurns;
  final ProjectionSource<ComposerProjection> composer;
  final ProjectionSource<ConversationAttachmentsProjection> attachments;
  final ProjectionSource<ConversationTabActivityProjection> tabActivity;
  final ProjectionSource<ConversationArchiveProjection> archive;

  /// The execution plane is read by the execution viewer; it is null when the
  /// gateway does not expose execution records.
  final ProjectionSource<ConversationExecutionProjection>? execution;
}

/// Narrow port the conversation surface consumes for its data planes.
///
/// The port exposes no lifecycle owner: the runtime, the producer
/// subscriptions, and the plane incarnations live behind an implementation
/// bound by composition, so the stable presentation plane stays free of
/// implementation state.
abstract interface class ConversationSourcePort {
  ConversationPlanePort<ConversationProjection> get projection;
  ConversationPlanePort<NativeConversationCatalogProjection> get nativeCatalog;
  ConversationPlanePort<CanonicalConversationProjection> get canonicalEvents;
  ConversationPlanePort<PersistentTurnProjection> get persistentTurns;
  ConversationPlanePort<ComposerProjection> get composer;
  ConversationPlanePort<ConversationAttachmentsProjection> get attachments;
  ConversationPlanePort<ConversationTabActivityProjection> get tabActivity;
  ConversationPlanePort<ConversationArchiveProjection> get archive;
  ConversationPlanePort<ConversationExecutionProjection>? get execution;
}

/// The port used when composition has not bound a plane owner.
///
/// Every plane is empty and invisible: a surface renders its own empty state
/// and never fabricates plane content.
final class DisabledConversationPlanePort<T>
    implements ConversationPlanePort<T> {
  const DisabledConversationPlanePort(this.fieldGroup);

  @override
  final ResourceFieldGroup<T> fieldGroup;

  @override
  T? get visibleValue => null;

  @override
  Stream<ConversationPlaneRead<T>> get reads =>
      const Stream<ConversationPlaneRead<Never>>.empty();

  @override
  void reconnect() {}
}

/// The disabled conversation plane port root.
final class DisabledConversationSourcePort implements ConversationSourcePort {
  const DisabledConversationSourcePort();

  @override
  ConversationPlanePort<ConversationProjection> get projection =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneProjection),
      );

  @override
  ConversationPlanePort<NativeConversationCatalogProjection>
  get nativeCatalog => DisabledConversationPlanePort(
    conversationPlaneFieldGroupFor(conversationPlaneNativeCatalog),
  );

  @override
  ConversationPlanePort<CanonicalConversationProjection> get canonicalEvents =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneCanonicalEvents),
      );

  @override
  ConversationPlanePort<PersistentTurnProjection> get persistentTurns =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlanePersistentTurns),
      );

  @override
  ConversationPlanePort<ComposerProjection> get composer =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneComposer),
      );

  @override
  ConversationPlanePort<ConversationAttachmentsProjection> get attachments =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneAttachments),
      );

  @override
  ConversationPlanePort<ConversationTabActivityProjection> get tabActivity =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneTabActivity),
      );

  @override
  ConversationPlanePort<ConversationArchiveProjection> get archive =>
      DisabledConversationPlanePort(
        conversationPlaneFieldGroupFor(conversationPlaneArchive),
      );

  @override
  ConversationPlanePort<ConversationExecutionProjection>? get execution => null;
}

/// The conversation plane port bound by composition.
///
/// Composition overrides this provider with the projection-layer owner over
/// the container's presentation runtime and the producer's plane channels.
/// Without that binding every plane stays invisible.
final conversationSourcePortProvider = Provider<ConversationSourcePort>(
  (ref) => const DisabledConversationSourcePort(),
  retry: (_, _) => null,
);
