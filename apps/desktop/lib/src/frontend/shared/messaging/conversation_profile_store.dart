import 'package:licoup/src/contracts/conversation_profile.dart';

/// Renderer-facing port for the durable conversation-profile registry
/// (`conversation-profiles.json`).
///
/// The profile surfaces depend on this port; the platform layer ships the
/// file-backed implementation without naming it here, and the composition
/// root adapts one onto the other (`PlatformConversationProfileStoreAdapter`).
/// The `portableData` argument stays an opaque [Object] so the port never
/// names the platform data-root type.
abstract class ConversationProfileStore {
  const ConversationProfileStore();

  /// The stored profiles in creation order; an empty document or a missing
  /// file yields an empty list so first-run starts with no profiles.
  Future<List<ConversationProfile>> load(Object portableData);

  /// Persists the complete registry with an atomic replace.
  Future<void> save(Object portableData, List<ConversationProfile> profiles);
}
