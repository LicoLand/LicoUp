import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_store.dart';

/// The local user's avatar identity for this session.
///
/// The identity is durable: [hydrateSelfMascotIdentity] loads the stored id
/// once per process — and, only when no document exists yet, initializes the
/// bundled ice-cream pick and persists it. The self-profile picker writes the
/// explicit choice back to the same notifier, and the persist listener saves
/// every change — the rail avatar, transcript self marks, group mosaics and
/// member cards all read this single source so the same face shows on every
/// surface and on every later launch.
final selfMascotIdentity = ValueNotifier<String>(
  SelfMascotStore.lastKnownId ?? ClientPlatformPorts.selfMascotSeed,
);

bool _selfMascotHydrationStarted = false;
bool _selfMascotPersistAttached = false;

/// Loads the durable mascot id once per process. A stored id replaces the
/// provisional pick; a missing document persists the current pick so the
/// first-run face becomes the permanent identity. Persistence failures keep
/// the in-memory identity — the avatar always stays usable.
Future<void> hydrateSelfMascotIdentity() async {
  if (_selfMascotHydrationStarted) {
    return;
  }
  _selfMascotHydrationStarted = true;
  _attachSelfMascotPersistListener();
  final store = ClientPlatformPorts.selfMascotStore();
  final data = ClientPlatformPorts.portableData ?? const Object();
  try {
    final stored = await store.load(data);
    if (stored != null) {
      selfMascotIdentity.value = stored;
    } else {
      // First run: the randomly seeded face becomes the durable identity.
      SelfMascotStore.lastKnownId = selfMascotIdentity.value;
      unawaited(store.save(data, selfMascotIdentity.value).catchError((_) {}));
    }
  } catch (_) {}
}

/// Persists every identity change through the store installed at fire time —
/// one listener for the process lifetime, so repeated hydration or a
/// reinstalled port never stacks duplicate writes.
void _attachSelfMascotPersistListener() {
  if (_selfMascotPersistAttached) {
    return;
  }
  _selfMascotPersistAttached = true;
  selfMascotIdentity.addListener(() {
    final id = selfMascotIdentity.value;
    SelfMascotStore.lastKnownId = id;
    unawaited(
      ClientPlatformPorts.selfMascotStore()
          .save(ClientPlatformPorts.portableData ?? const Object(), id)
          .catchError((_) {}),
    );
  });
}

@visibleForTesting
void resetSelfMascotHydrationForTests() => _selfMascotHydrationStarted = false;
