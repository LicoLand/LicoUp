import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

void main() {
  test('locks app portrait without changing system rotation', () {
    const androidNamespace = 'http://schemas.android.com/apk/res/android';
    final projectRoot = Directory.current.path;
    final manifestPath = p.join(
      projectRoot,
      'android',
      'app',
      'src',
      'main',
      'AndroidManifest.xml',
    );
    final manifest = File(manifestPath).readAsStringSync();
    final document = XmlDocument.parse(manifest);
    final activities = document.findAllElements('activity').toList();

    expect(activities, hasLength(1));
    expect(
      activities.single.getAttribute('name', namespaceUri: androidNamespace),
      r'${mainActivityClass}',
    );
    final gradle = File(
      p.join(projectRoot, 'android', 'app', 'build.gradle.kts'),
    ).readAsStringSync();
    expect(
      gradle,
      contains(
        'manifestPlaceholders["mainActivityClass"] = "land.lico.licoup.MainActivity"',
      ),
    );
    expect(
      gradle,
      contains(
        'manifestPlaceholders["mainActivityClass"] = "land.lico.licoup.DebugMainActivity"',
      ),
    );
    for (final activity in activities) {
      expect(
        activity.getAttribute(
          'screenOrientation',
          namespaceUri: androidNamespace,
        ),
        'portrait',
        reason:
            '${activity.getAttribute('name', namespaceUri: androidNamespace)} '
            'must stay app-local portrait without changing system rotation.',
      );
    }

    final sourceText = [
      manifest,
      ..._readSourceFiles(p.join(projectRoot, 'android', 'app', 'src')),
      ..._readSourceFiles(p.join(projectRoot, 'lib')),
    ].join('\n');

    for (final forbidden in [
      'android.permission.WRITE_SETTINGS',
      'Settings.System',
      'accelerometer_rotation',
      'user_rotation',
      'setRequestedOrientation',
      'SystemChrome.setPreferredOrientations',
      'DeviceOrientation',
    ]) {
      expect(sourceText, isNot(contains(forbidden)));
    }
  });
}

Iterable<String> _readSourceFiles(String root) sync* {
  final directory = Directory(root);
  if (!directory.existsSync()) {
    return;
  }

  const extensions = <String>{'.dart', '.java', '.kt', '.xml'};
  for (final entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File || !extensions.contains(p.extension(entity.path))) {
      continue;
    }
    yield entity.readAsStringSync();
  }
}
