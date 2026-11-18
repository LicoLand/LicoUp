import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/conversation_profile.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';

/// The durable conversation-profile registry for this process.
///
/// [hydrateConversationProfiles] loads the stored list once per process;
/// every mutation through [addConversationProfile] or
/// [attachConversationProfileConversation] is written back by the persist
/// listener. Contact rows, the create dialog, member-avatar resolution and
/// group member pickers all read this single source.
final conversationProfiles = ValueNotifier<List<ConversationProfile>>(
  const <ConversationProfile>[],
);

bool _profileHydrationStarted = false;
bool _profilePersistAttached = false;
bool _profileHydrating = false;

/// Loads the durable registry once per process. Persistence failures keep
/// the in-memory list — the profile surfaces always stay usable.
Future<void> hydrateConversationProfiles() async {
  if (_profileHydrationStarted) {
    return;
  }
  _profileHydrationStarted = true;
  _attachProfilePersistListener();
  final store = ClientPlatformPorts.conversationProfileStore();
  final data = ClientPlatformPorts.portableData ?? const Object();
  try {
    _profileHydrating = true;
    conversationProfiles.value = await store.load(data);
  } catch (_) {
  } finally {
    _profileHydrating = false;
  }
}

/// Registers a newly created profile and persists it.
void addConversationProfile(ConversationProfile profile) {
  if (conversationProfiles.value.any((entry) => entry.id == profile.id)) {
    return;
  }
  conversationProfiles.value = List<ConversationProfile>.unmodifiable([
    ...conversationProfiles.value,
    profile,
  ]);
}

/// Records the canonical conversation id materialized for [profileId].
void attachConversationProfileConversation(
  String profileId,
  String conversationId,
) {
  if (conversationId.trim().isEmpty) return;
  conversationProfiles.value = List<ConversationProfile>.unmodifiable([
    for (final profile in conversationProfiles.value)
      if (profile.id == profileId && profile.conversationId != conversationId)
        profile.copyWith(conversationId: conversationId)
      else
        profile,
  ]);
}

/// The profile registered under [id], or null.
ConversationProfile? conversationProfileById(String id) {
  for (final profile in conversationProfiles.value) {
    if (profile.id == id) return profile;
  }
  return null;
}

/// The profile whose direct Conversation is [conversationId], or null.
ConversationProfile? conversationProfileByConversationId(
  String conversationId,
) {
  for (final profile in conversationProfiles.value) {
    if (profile.conversationId == conversationId) return profile;
  }
  return null;
}

/// Resolves a canonical principal id (`profile:<id>`) to its profile.
ConversationProfile? conversationProfileForPrincipal(String principalId) {
  const prefix = 'profile:';
  if (!principalId.startsWith(prefix)) return null;
  return conversationProfileById(principalId.substring(prefix.length));
}

/// Persists every registry change through the store installed at fire
/// time — one listener for the process lifetime.
void _attachProfilePersistListener() {
  if (_profilePersistAttached) {
    return;
  }
  _profilePersistAttached = true;
  conversationProfiles.addListener(() {
    if (_profileHydrating) return;
    unawaited(
      ClientPlatformPorts.conversationProfileStore()
          .save(
            ClientPlatformPorts.portableData ?? const Object(),
            conversationProfiles.value,
          )
          .catchError((_) {}),
    );
  });
}

@visibleForTesting
void resetConversationProfilesForTests() {
  conversationProfiles.value = const <ConversationProfile>[];
  _profileHydrationStarted = false;
}
