import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/desktop_app_catalog.dart';
import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/dock/desktop_dock_model.dart';

import '../../../fixtures/desktop_dock_store_fixture.dart';
import 'desktop_desktop_test_harness.dart' show buildDesktopTestDockModel;

void main() {
  group('open and close lifecycle', () {
    test('openApp appends new apps and ignores duplicates', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();

      expect(controller.openApp(DesktopAppId.monitoring), isTrue);
      expect(controller.openApp(DesktopAppId.monitoring), isFalse);
      expect(controller.openApp(DesktopAppId.skillHub), isTrue);

      expect(controller.openApps, {
        DesktopAppId.monitoring,
        DesktopAppId.skillHub,
      });
      expect(controller.entries, hasLength(2));
    });

    test('closeApp removes app entries', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub);

      expect(controller.closeApp(DesktopAppId.monitoring), isTrue);
      expect(controller.openApps, {DesktopAppId.skillHub});
      expect(controller.closeApp(DesktopAppId.monitoring), isFalse);
    });
  });

  group('reorder', () {
    test('moveEntry relocates entries by gap index', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);

      // Move monitoring (index 0) past skillHub+agentHub (gap 3).
      expect(controller.moveEntry('app:monitoring', 3), isTrue);
      expect(
        controller.entries
            .map((entry) => (entry as DesktopDockAppEntry).app)
            .toList(),
        [DesktopAppId.skillHub, DesktopAppId.agentHub, DesktopAppId.monitoring],
      );

      // Move it back to the front (gap 0).
      expect(controller.moveEntry('app:monitoring', 0), isTrue);
      expect(
        (controller.entries.first as DesktopDockAppEntry).app,
        DesktopAppId.monitoring,
      );
    });

    test('moveEntry onto the same slot is a no-op', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller.openApp(DesktopAppId.monitoring);
      expect(controller.moveEntry('app:monitoring', 0), isFalse);
      expect(controller.moveEntry('app:monitoring', 1), isFalse);
    });
  });

  group('folders', () {
    test('merging two apps creates a folder at the target slot', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);

      expect(controller.mergeEntries('app:skillHub', 'app:monitoring'), isTrue);
      expect(controller.entries, hasLength(2));
      final folder = controller.entries.first as DesktopDockFolderEntry;
      expect(folder.children, [DesktopAppId.monitoring, DesktopAppId.skillHub]);
      expect(
        (controller.entries.last as DesktopDockAppEntry).app,
        DesktopAppId.agentHub,
      );
    });

    test('merging onto a folder appends the dragged app', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);
      controller.mergeEntries('app:skillHub', 'app:monitoring');

      final folderId =
          (controller.entries.first as DesktopDockFolderEntry).storageId;
      expect(controller.mergeEntries('app:agentHub', folderId), isTrue);
      final folder = controller.entries.single as DesktopDockFolderEntry;
      expect(folder.children, [
        DesktopAppId.monitoring,
        DesktopAppId.skillHub,
        DesktopAppId.agentHub,
      ]);
    });

    test('folders cannot be merged (no nesting)', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);
      controller.mergeEntries('app:skillHub', 'app:monitoring');
      final folderId =
          (controller.entries.first as DesktopDockFolderEntry).storageId;
      expect(controller.mergeEntries(folderId, 'app:agentHub'), isFalse);
    });

    test('closing a folder child dissolves a two-child folder', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub);
      controller.mergeEntries('app:skillHub', 'app:monitoring');

      expect(controller.closeApp(DesktopAppId.skillHub), isTrue);
      final entry = controller.entries.single as DesktopDockAppEntry;
      expect(entry.app, DesktopAppId.monitoring);
    });

    test('extractFromFolder returns the app to the entry list', () async {
      final controller = buildDesktopTestDockModel();
      await controller.load();
      controller
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);
      controller.mergeEntries('app:skillHub', 'app:monitoring');
      final folder = controller.entries.first as DesktopDockFolderEntry;

      expect(
        controller.extractFromFolder(folder.id, DesktopAppId.skillHub),
        isTrue,
      );
      expect(controller.entries, hasLength(3));
      expect(controller.openApps, {
        DesktopAppId.monitoring,
        DesktopAppId.skillHub,
        DesktopAppId.agentHub,
      });
      expect(controller.entries.whereType<DesktopDockFolderEntry>(), isEmpty);
    });
  });

  group('persistence', () {
    test('layout survives a controller restart', () async {
      final directory = Directory.systemTemp.createTempSync(
        'desktop_dock_restart_test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final portableData = createDesktopDockPortableData(directory);

      final first = DesktopDockModel(
        store: createDesktopDockLayoutStore(),
        portableData: portableData,
      );
      await first.load();
      first
        ..openApp(DesktopAppId.monitoring)
        ..openApp(DesktopAppId.skillHub)
        ..openApp(DesktopAppId.agentHub);
      first.mergeEntries('app:skillHub', 'app:monitoring');
      first.moveEntry('app:agentHub', 0);

      // The persists are fire-and-forget: poll a restarting controller until
      // the serialized writes land instead of waiting a fixed delay. The
      // match must be the final shape — intermediate states can share the
      // entry count.
      bool matchesFinalShape(DesktopDockModel controller) {
        if (controller.entries.length != 2) return false;
        final first = controller.entries.first;
        final last = controller.entries.last;
        return first is DesktopDockAppEntry &&
            first.app == DesktopAppId.agentHub &&
            last is DesktopDockFolderEntry &&
            last.children.length == 2 &&
            last.children.first == DesktopAppId.monitoring &&
            last.children.last == DesktopAppId.skillHub;
      }

      DesktopDockModel? second;
      for (var attempt = 0; attempt < 100; attempt++) {
        final candidate = DesktopDockModel(
          store: createDesktopDockLayoutStore(),
          portableData: portableData,
        );
        await candidate.load();
        if (matchesFinalShape(candidate)) {
          second = candidate;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(second, isNotNull, reason: 'dock layout never persisted');
      expect(
        (second!.entries.first as DesktopDockAppEntry).app,
        DesktopAppId.agentHub,
      );
      final folder = second.entries.last as DesktopDockFolderEntry;
      expect(folder.children, [DesktopAppId.monitoring, DesktopAppId.skillHub]);
    });

    test('unknown stored app names are dropped on load', () async {
      final directory = Directory.systemTemp.createTempSync(
        'desktop_dock_unknown_app_test',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final portableData = createDesktopDockPortableData(directory);
      // `PortableDataRoot.clientDirectory()` is `<root>/client-state`.
      final stateDir = Directory('${directory.path}/client-state');
      stateDir.createSync(recursive: true);
      File('${stateDir.path}/desktop-dock-layout.json').writeAsStringSync(
        '{"schemaVersion": 1, "entries": ['
        '{"type": "app", "app": "notAnApp"},'
        '{"type": "app", "app": "monitoring"}'
        ']}',
      );

      final controller = DesktopDockModel(
        store: createDesktopDockLayoutStore(),
        portableData: portableData,
      );
      await controller.load();
      expect(controller.openApps, {DesktopAppId.monitoring});
    });
  });
}
