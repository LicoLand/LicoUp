import 'dart:io';

import 'package:flutter_client/src/platform/storage/client_log_export_service.dart';
import 'package:flutter_client/src/platform/storage/portable_data_root.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('exports the activity log to a selected file path', () async {
    final directory = await Directory.systemTemp.createTemp(
      'lico-client-log-service-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: directory);
    final source = await portableData.activityLogFile();
    await source.parent.create(recursive: true);
    await source.writeAsString('{"event":"one"}\n', flush: true);
    final destination = File(p.join(directory.path, 'logs', 'client.jsonl'));

    final result = await const ClientLogExportService().exportLogs(
      portableData: portableData,
      destinationPath: destination.path,
    );

    expect(result.path, destination.path);
    expect(result.sourceExists, isTrue);
    expect(result.bytes, greaterThan(0));
    expect(await destination.readAsString(), '{"event":"one"}\n');
  });

  test(
    'creates an empty export when the activity log does not exist',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-client-log-empty-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final destination = File(p.join(directory.path, 'client.jsonl'));

      final result = await const ClientLogExportService().exportLogs(
        portableData: PortableDataRoot(dataDirectoryOverride: directory),
        destinationPath: destination.path,
      );

      expect(result.sourceExists, isFalse);
      expect(result.bytes, 0);
      expect(await destination.exists(), isTrue);
    },
  );

  test(
    'rejects exporting over the source file without truncating it',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-client-log-same-file-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final source = await portableData.activityLogFile();
      await source.parent.create(recursive: true);
      await source.writeAsString('preserve\n', flush: true);

      await expectLater(
        const ClientLogExportService().exportLogs(
          portableData: portableData,
          destinationPath: source.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await source.readAsString(), 'preserve\n');
    },
  );

  test(
    'enforces the bounded export without replacing the destination',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-client-log-bounded-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final source = await portableData.activityLogFile();
      await source.parent.create(recursive: true);
      await source.writeAsString('too-large', flush: true);
      final destination = File(p.join(directory.path, 'export.jsonl'));
      await destination.writeAsString('preserve', flush: true);

      await expectLater(
        const ClientLogExportService(maxExportBytes: 4).exportLogs(
          portableData: portableData,
          destinationPath: destination.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.readAsString(), 'preserve');
    },
  );

  if (!Platform.isWindows) {
    test('rejects a symbolic-link log source', () async {
      final directory = await Directory.systemTemp.createTemp(
        'lico-client-log-source-link-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: directory);
      final source = await portableData.activityLogFile();
      await source.parent.create(recursive: true);
      final external = File(p.join(directory.path, 'external.jsonl'));
      await external.writeAsString('private\n', flush: true);
      await Link(source.path).create(external.path);
      final destination = File(p.join(directory.path, 'export.jsonl'));

      await expectLater(
        const ClientLogExportService().exportLogs(
          portableData: portableData,
          destinationPath: destination.path,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.exists(), isFalse);
    });

    test(
      'rejects a symbolic-link destination and preserves its target',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'lico-client-log-destination-link-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final portableData = PortableDataRoot(dataDirectoryOverride: directory);
        final source = await portableData.activityLogFile();
        await source.parent.create(recursive: true);
        await source.writeAsString('source\n', flush: true);
        final external = File(p.join(directory.path, 'external.jsonl'));
        await external.writeAsString('preserve\n', flush: true);
        final destination = Link(p.join(directory.path, 'export.jsonl'));
        await destination.create(external.path);

        await expectLater(
          const ClientLogExportService().exportLogs(
            portableData: portableData,
            destinationPath: destination.path,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(await external.readAsString(), 'preserve\n');
      },
    );
  }
}
