import 'client_controller_scenario_dependencies.dart';

Future<void> deleteTempDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt += 1) {
    if (!await directory.exists()) {
      return;
    }
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 4) {
        rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
    }
  }
}

class ThrowingPortableDataRoot extends PortableDataRoot {
  @override
  Future<Directory> dataDirectory() async {
    throw Exception('boot error');
  }
}
