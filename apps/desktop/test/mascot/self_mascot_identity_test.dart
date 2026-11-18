import 'dart:io';

import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_identity.dart';
import 'package:licoup/src/frontend/shared/mascot/self_mascot_store.dart';
import 'package:licoup/src/platform/presentation/self_mascot_identity_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';

final class _FakeSelfMascotStore extends SelfMascotStore {
  _FakeSelfMascotStore(this.stored);

  String? stored;
  final List<String> saves = <String>[];

  @override
  Future<String?> load(Object portableData) async => stored;

  @override
  Future<void> save(Object portableData, String mascotId) async {
    stored = mascotId;
    saves.add(mascotId);
  }
}

void main() {
  late SelfMascotStore Function() previousStore;
  late Object? previousData;

  setUp(() {
    previousStore = ClientPlatformPorts.selfMascotStore;
    previousData = ClientPlatformPorts.portableData;
    ClientPlatformPorts.portableData = const Object();
    selfMascotIdentity.value = 'lico';
    resetSelfMascotHydrationForTests();
  });

  tearDown(() {
    ClientPlatformPorts.selfMascotStore = previousStore;
    ClientPlatformPorts.portableData = previousData;
    SelfMascotStore.lastKnownId = null;
    selfMascotIdentity.value = 'lico';
  });

  test('a stored id hydrates over the provisional pick', () async {
    final store = _FakeSelfMascotStore('mint');
    ClientPlatformPorts.selfMascotStore = () => store;

    await hydrateSelfMascotIdentity();

    expect(selfMascotIdentity.value, 'mint');
    expect(SelfMascotStore.lastKnownId, 'mint');
  });

  test('a missing document persists the first-run pick once', () async {
    final store = _FakeSelfMascotStore(null);
    ClientPlatformPorts.selfMascotStore = () => store;

    await hydrateSelfMascotIdentity();
    expect(selfMascotIdentity.value, 'lico');
    expect(store.saves, ['lico']);

    await hydrateSelfMascotIdentity();
    expect(store.saves, ['lico']);
  });

  test('picker changes write through the persist listener', () async {
    final store = _FakeSelfMascotStore('mint');
    ClientPlatformPorts.selfMascotStore = () => store;
    await hydrateSelfMascotIdentity();
    store.saves.clear();

    selfMascotIdentity.value = 'berry';
    await Future<void>.value();

    expect(store.saves, ['berry']);
    expect(store.stored, 'berry');
  });

  group('PlatformSelfMascotIdentityStore', () {
    late Directory temporaryRoot;
    late PortableDataRoot portableData;

    setUp(() async {
      temporaryRoot = await Directory.systemTemp.createTemp(
        'self-mascot-test-',
      );
      portableData = PortableDataRoot(dataDirectoryOverride: temporaryRoot);
    });

    tearDown(() async {
      if (await temporaryRoot.exists()) {
        await temporaryRoot.delete(recursive: true);
      }
    });

    test('a missing document loads null', () async {
      const store = PlatformSelfMascotIdentityStore();
      expect(await store.load(portableData), isNull);
    });

    test('a saved id round-trips through a fresh store instance', () async {
      const store = PlatformSelfMascotIdentityStore();
      await store.save(portableData, 'taro');

      const reopened = PlatformSelfMascotIdentityStore();
      expect(await reopened.load(portableData), 'taro');
    });
  });
}
