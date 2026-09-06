import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/desktop_dock_layout.dart';
import 'package:licoup/src/platform/layout/desktop_dock_layout_store.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

void main() {
  late Directory directory;
  late PortableDataRoot portableData;
  late PlatformDesktopDockLayoutStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync(
      'desktop_dock_layout_store_test',
    );
    portableData = PortableDataRoot(dataDirectoryOverride: directory);
    store = const PlatformDesktopDockLayoutStore();
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  Future<File> storeFile() async {
    final root = await portableData.clientDirectory();
    return File('${root.path}/${PlatformDesktopDockLayoutStore.fileName}');
  }

  test('missing file loads the default empty dock', () async {
    final snapshot = await store.load(portableData);
    expect(snapshot.entries, isEmpty);
  });

  test(
    'malformed file loads the default empty dock instead of throwing',
    () async {
      final file = await storeFile();
      await file.parent.create(recursive: true);
      await file.writeAsString('{ not json');
      final snapshot = await store.load(portableData);
      expect(snapshot.entries, isEmpty);
    },
  );

  test('foreign schema version loads the default empty dock', () async {
    final file = await storeFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 99,
        'entries': [
          {'type': 'app', 'app': 'monitoring'},
        ],
      }),
    );
    final snapshot = await store.load(portableData);
    expect(snapshot.entries, isEmpty);
  });

  test('round-trips apps and folders with order intact', () async {
    await store.save(
      portableData,
      const DesktopDockLayoutSnapshot(
        entries: [
          DesktopDockStoredAppEntry('conversation'),
          DesktopDockStoredFolderEntry(
            id: 'folder-1',
            children: ['skillHub', 'pluginManagement'],
          ),
          DesktopDockStoredAppEntry('monitoring'),
        ],
      ),
    );
    final snapshot = await store.load(portableData);
    expect(snapshot.entries, hasLength(3));
    expect(
      (snapshot.entries[0] as DesktopDockStoredAppEntry).app,
      'conversation',
    );
    final folder = snapshot.entries[1] as DesktopDockStoredFolderEntry;
    expect(folder.id, 'folder-1');
    expect(folder.children, ['skillHub', 'pluginManagement']);
    expect(
      (snapshot.entries[2] as DesktopDockStoredAppEntry).app,
      'monitoring',
    );
  });

  test('load skips malformed entries and dedupes first-wins', () async {
    final file = await storeFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'entries': [
          'garbage',
          {'type': 'app', 'app': 'monitoring'},
          {'type': 'app', 'app': 'monitoring'},
          {'type': 'app', 'app': ''},
          {'type': 'folder', 'id': 'folder-1', 'children': <String>[]},
          {
            'type': 'folder',
            'id': 'folder-2',
            'children': ['skillHub'],
          },
          {
            'type': 'folder',
            'children': ['agentHub'],
          },
          {
            'type': 'mystery',
            'id': 'folder-3',
            'children': ['agentHub'],
          },
        ],
      }),
    );
    final snapshot = await store.load(portableData);
    expect(snapshot.entries, hasLength(2));
    expect(
      (snapshot.entries[0] as DesktopDockStoredAppEntry).app,
      'monitoring',
    );
    // A single-child folder promotes its child to a plain app entry.
    expect((snapshot.entries[1] as DesktopDockStoredAppEntry).app, 'skillHub');
  });

  test('save promotes single-child folders and drops empty ones', () async {
    await store.save(
      portableData,
      const DesktopDockLayoutSnapshot(
        entries: [
          DesktopDockStoredFolderEntry(id: 'folder-1', children: ['skillHub']),
          DesktopDockStoredFolderEntry(id: 'folder-2', children: []),
          DesktopDockStoredAppEntry('monitoring'),
        ],
      ),
    );
    final raw = jsonDecode(await (await storeFile()).readAsString()) as Map;
    final entries = raw['entries'] as List;
    expect(entries, hasLength(2));
    expect(entries[0], {'type': 'app', 'app': 'skillHub'});
    expect(entries[1], {'type': 'app', 'app': 'monitoring'});
  });
}
