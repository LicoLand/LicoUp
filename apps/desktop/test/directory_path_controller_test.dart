import 'package:flutter_client/src/application/features/settings/controller/directory_path_controller.dart';
import 'package:flutter_client/src/contracts/directory_opener.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'directory path controller validates and delegates the requested path',
    () async {
      final opener = _FakeDirectoryOpener();
      final updates = <DirectoryPathStatusUpdate>[];
      final controller = DirectoryPathController(
        opener: opener,
        defaultCaption: () => 'Directory',
        onStatus: updates.add,
      );

      await controller.open('   ');
      expect(opener.paths, isEmpty);
      expect(updates.last.error, isA<DirectoryPathException>());

      await controller.open(' workspace ', caption: ' Project files ');
      expect(opener.paths, ['workspace']);
      expect(updates.last.english, 'Directory opened.');
      expect(updates.last.caption, 'workspace');
      expect(updates.last.error, isNull);
    },
  );

  test('directory path controller projects bounded process failures', () async {
    final opener = _FakeDirectoryOpener()
      ..result = const DirectoryOpenResult(exitCode: 1);
    final updates = <DirectoryPathStatusUpdate>[];
    final controller = DirectoryPathController(
      opener: opener,
      defaultCaption: () => 'Directory',
      onStatus: updates.add,
    );

    await controller.open('workspace');

    expect(updates.single.english, 'Failed to open the directory.');
    expect(updates.single.error.toString(), 'directory_open_failed');
  });
}

final class _FakeDirectoryOpener implements DirectoryOpener {
  final List<String> paths = [];
  DirectoryOpenResult result = const DirectoryOpenResult(exitCode: 0);

  @override
  Future<DirectoryOpenResult> openDirectory(String directoryPath) async {
    paths.add(directoryPath);
    return result;
  }
}
