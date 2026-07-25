import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:licoup/src/platform/storage/single_instance_guard.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SingleInstanceGuard', () {
    late Directory stateDir;
    late File lockFile;

    setUp(() async {
      stateDir = await Directory.systemTemp.createTemp('lico-instance-');
      lockFile = File('${stateDir.path}/client.instance.lock');
    });

    tearDown(() async {
      if (await stateDir.exists()) {
        await stateDir.delete(recursive: true);
      }
    });

    test('first launch acquires the instance lock', () async {
      final guard = await SingleInstanceGuard.tryAcquire(lockFile);
      expect(guard, isNotNull);
      await guard!.release();
    });

    test('second launch fails while the first instance holds the lock',
        () async {
      final first = await SingleInstanceGuard.tryAcquire(lockFile);
      expect(first, isNotNull);
      final second = await SingleInstanceGuard.tryAcquire(lockFile);
      expect(second, isNull);
      await first!.release();
    });

    test('lock can be reclaimed after release', () async {
      final first = await SingleInstanceGuard.tryAcquire(lockFile);
      await first!.release();
      final second = await SingleInstanceGuard.tryAcquire(lockFile);
      expect(second, isNotNull);
      await second!.release();
    });

    test('an existing unlocked file can be acquired', () async {
      await lockFile.writeAsString('');
      final guard = await SingleInstanceGuard.tryAcquire(lockFile);
      expect(guard, isNotNull);
      await guard!.release();
    });

    test('lock path stays inside the canonical client state root', () async {
      final dataDir = Directory('${stateDir.path}/portable');
      final first = await SingleInstanceGuard.lockFileFor(
        PortableDataRoot(dataDirectoryOverride: dataDir),
      );
      final again = await SingleInstanceGuard.lockFileFor(
        PortableDataRoot(dataDirectoryOverride: dataDir),
      );
      expect(again.path, first.path);
      expect(p.dirname(first.path), p.join(dataDir.path, 'client-state'));
      final other = await SingleInstanceGuard.lockFileFor(
        PortableDataRoot(
          dataDirectoryOverride: Directory('${stateDir.path}/other'),
        ),
      );
      expect(other.path, isNot(first.path));
    });
  });
}
