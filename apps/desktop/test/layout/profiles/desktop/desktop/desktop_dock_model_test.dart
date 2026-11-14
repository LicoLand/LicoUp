import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';
import 'package:licoup/src/frontend/shared/desktop_dock_layout_store.dart';

import '../../../fixtures/desktop_dock_store_fixture.dart';

final class _MemoryDockStore extends DesktopDockLayoutStore {
  _MemoryDockStore([List<DesktopDockStoredEntry> entries = const []])
    : snapshot = DesktopDockLayoutSnapshot(entries: entries);

  DesktopDockLayoutSnapshot snapshot;
  int saves = 0;

  @override
  Future<DesktopDockLayoutSnapshot> load(Object portableData) async => snapshot;

  @override
  Future<void> save(
    Object portableData,
    DesktopDockLayoutSnapshot snapshot,
  ) async {
    saves += 1;
    this.snapshot = snapshot;
  }
}

List<Object> _shape(List<DesktopDockEntry> entries) => [
  for (final entry in entries)
    switch (entry) {
      DesktopDockAppEntry(app: final app) => app,
      DesktopDockFolderEntry(children: final children) => children,
    },
];

List<String> _storedNames(DesktopDockLayoutSnapshot snapshot) => [
  for (final entry in snapshot.entries)
    switch (entry) {
      DesktopDockStoredAppEntry(app: final app) => app,
      DesktopDockStoredFolderEntry(id: final id, children: final children) =>
        '$id(${children.join(',')})',
    },
];

Future<DesktopDockModel> _loaded(_MemoryDockStore store) async {
  final model = DesktopDockModel(store: store, portableData: Object());
  addTearDown(model.dispose);
  await model.load();
  return model;
}

void main() {
  group('arrangement on load', () {
    test('an empty store yields every built-in app in catalog order', () async {
      final model = await _loaded(_MemoryDockStore());

      expect(model.ready, isTrue);
      expect(_shape(model.entries), desktopDockApps);
      expect(model.pinnedPlugins, isEmpty);
    });

    test('the catalog default is visible before the store settles', () {
      final model = DesktopDockModel(
        store: _MemoryDockStore(),
        portableData: Object(),
      );
      addTearDown(model.dispose);

      expect(model.ready, isFalse);
      expect(_shape(model.entries), desktopDockApps);
    });

    test('the stored order wins and missing apps join after their nearest '
        'catalog predecessor', () async {
      final model = await _loaded(
        _MemoryDockStore(const [
          DesktopDockStoredAppEntry('devices'),
          DesktopDockStoredAppEntry('agentHub'),
          DesktopDockStoredAppEntry('modelsGateway'),
        ]),
      );

      // collaboration has no predecessor and goes first; monitoring follows
      // agentHub, its nearest predecessor present in the stored order.
      expect(_shape(model.entries), [
        DesktopAppId.collaboration,
        DesktopAppId.devices,
        DesktopAppId.agentHub,
        DesktopAppId.monitoring,
        DesktopAppId.modelsGateway,
      ]);
    });

    test(
      'a missing app joins after a folder that holds its predecessor',
      () async {
        final model = await _loaded(
          _MemoryDockStore(const [
            DesktopDockStoredAppEntry('collaboration'),
            DesktopDockStoredFolderEntry(
              id: 'folder-7',
              children: ['agentHub', 'devices'],
            ),
            DesktopDockStoredAppEntry('modelsGateway'),
          ]),
        );

        expect(_shape(model.entries), [
          DesktopAppId.collaboration,
          [DesktopAppId.agentHub, DesktopAppId.devices],
          DesktopAppId.monitoring,
          DesktopAppId.modelsGateway,
        ]);
      },
    );

    test('unknown, non-dock and repeated names drop; one-child folders '
        'dissolve', () async {
      final model = await _loaded(
        _MemoryDockStore(const [
          DesktopDockStoredAppEntry('notAnApp'),
          DesktopDockStoredAppEntry('settings'),
          DesktopDockStoredAppEntry('skillHub'),
          DesktopDockStoredAppEntry('monitoring'),
          DesktopDockStoredAppEntry('monitoring'),
          DesktopDockStoredFolderEntry(
            id: 'folder-1',
            children: ['monitoring', 'agentHub', 'notAnApp'],
          ),
        ]),
      );

      // agentHub survives from the dissolved folder; the missing gateway
      // and relay follow monitoring, their nearest catalog predecessor.
      expect(_shape(model.entries), [
        DesktopAppId.collaboration,
        DesktopAppId.monitoring,
        DesktopAppId.modelsGateway,
        DesktopAppId.devices,
        DesktopAppId.agentHub,
      ]);
      expect(model.entries.whereType<DesktopDockFolderEntry>(), isEmpty);
    });

    test('stored plugin entries restore the pinned plugin windows', () async {
      final model = await _loaded(
        _MemoryDockStore(const [
          DesktopDockStoredAppEntry('plugin:sketch'),
          DesktopDockStoredAppEntry('plugin:notes'),
          DesktopDockStoredAppEntry('plugin:sketch'),
          DesktopDockStoredAppEntry('plugin:'),
        ]),
      );

      expect(model.pinnedPlugins, ['sketch', 'notes']);
      expect(_shape(model.entries), desktopDockApps);
    });
  });

  group('rearranging', () {
    test('moveEntry relocates entries by gap index', () async {
      final model = await _loaded(_MemoryDockStore());

      expect(model.moveEntry('app:collaboration', 3), isTrue);
      expect(_shape(model.entries), [
        DesktopAppId.agentHub,
        DesktopAppId.monitoring,
        DesktopAppId.collaboration,
        DesktopAppId.modelsGateway,
        DesktopAppId.devices,
      ]);
      expect(model.moveEntry('app:collaboration', 0), isTrue);
      expect(_shape(model.entries), desktopDockApps);
      expect(model.moveEntry('app:collaboration', 0), isFalse);
      expect(model.moveEntry('app:collaboration', 1), isFalse);
    });

    test('merging two apps creates a folder at the target slot', () async {
      final model = await _loaded(_MemoryDockStore());

      expect(model.mergeEntries('app:devices', 'app:monitoring'), isTrue);
      expect(_shape(model.entries), [
        DesktopAppId.collaboration,
        DesktopAppId.agentHub,
        [DesktopAppId.monitoring, DesktopAppId.devices],
        DesktopAppId.modelsGateway,
      ]);
    });

    test('merging onto a folder appends; folders never nest', () async {
      final model = await _loaded(_MemoryDockStore());
      model.mergeEntries('app:devices', 'app:monitoring');
      final folder = model.entries.whereType<DesktopDockFolderEntry>().single;

      expect(model.mergeEntries('app:agentHub', folder.storageId), isTrue);
      expect(
        model.entries.whereType<DesktopDockFolderEntry>().single.children,
        [DesktopAppId.monitoring, DesktopAppId.devices, DesktopAppId.agentHub],
      );
      expect(
        model.mergeEntries(folder.storageId, 'app:collaboration'),
        isFalse,
      );
    });

    test('extracting the last-but-one child dissolves the folder', () async {
      final model = await _loaded(_MemoryDockStore());
      model.mergeEntries('app:devices', 'app:monitoring');
      final folder = model.entries.whereType<DesktopDockFolderEntry>().single;

      expect(
        model.extractFromFolder(
          folder.id,
          DesktopAppId.devices,
          insertIndex: 0,
        ),
        isTrue,
      );
      expect(_shape(model.entries), [
        DesktopAppId.devices,
        DesktopAppId.collaboration,
        DesktopAppId.agentHub,
        DesktopAppId.monitoring,
        DesktopAppId.modelsGateway,
      ]);
    });

    test('pinning plugins keeps their order and persists after the '
        'built-in group', () async {
      final store = _MemoryDockStore();
      final model = await _loaded(store);

      expect(model.pinPlugin('sketch'), isTrue);
      expect(model.pinPlugin('sketch'), isFalse);
      expect(model.pinPlugin('notes'), isTrue);
      expect(model.unpinPlugin('sketch'), isTrue);
      expect(model.unpinPlugin('sketch'), isFalse);
      await pumpEventQueue();

      expect(model.pinnedPlugins, ['notes']);
      expect(store.saves, 3);
      expect(_storedNames(store.snapshot), [
        'collaboration',
        'agentHub',
        'monitoring',
        'modelsGateway',
        'devices',
        'plugin:notes',
      ]);
    });
  });

  test('the arrangement survives a restart through the file store', () async {
    final directory = Directory.systemTemp.createTempSync(
      'desktop_dock_restart_test',
    );
    final portableData = createDesktopDockPortableData(directory);
    final store = ObservedDesktopDockLayoutStore(
      createDesktopDockLayoutStore(),
    );
    final first = DesktopDockModel(store: store, portableData: portableData);
    DesktopDockModel? second;
    addTearDown(() async {
      await store.waitForWrites();
      second?.dispose();
      first.dispose();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    await first.load();
    first
      ..mergeEntries('app:modelsGateway', 'app:monitoring')
      ..moveEntry('app:devices', 0)
      ..pinPlugin('sketch');
    expect(store.writeCount, 3);
    await store.waitForWrites();

    final restarted = DesktopDockModel(
      store: createDesktopDockLayoutStore(),
      portableData: portableData,
    );
    second = restarted;
    await restarted.load();

    expect(_shape(restarted.entries), [
      DesktopAppId.devices,
      DesktopAppId.collaboration,
      DesktopAppId.agentHub,
      [DesktopAppId.monitoring, DesktopAppId.modelsGateway],
    ]);
    expect(restarted.pinnedPlugins, ['sketch']);
  });
}
