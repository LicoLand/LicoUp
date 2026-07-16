import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('localization barrel exposes both core and label APIs', () {
    final chinese = LicoStrings.forLocale(const Locale('zh'));
    final english = LicoStrings.forLocale(const Locale('en'));

    expect(chinese.appTitle, 'Lico Arc');
    expect(english.appTitle, 'Lico Arc');
    expect(chinese.clearSearch, '清除搜索');
    expect(english.clearSearch, 'Clear search');
  });

  test('localization libraries form an acyclic public boundary', () {
    const root = 'lib/src/frontend/l10n';
    final barrel = File('$root/lico_strings.dart').readAsStringSync();
    final base = File('$root/lico_strings_base.dart').readAsStringSync();
    final labels = File('$root/lico_strings_labels.dart').readAsStringSync();

    expect(barrel, contains("export 'lico_strings_base.dart';"));
    expect(barrel, contains("export 'lico_strings_labels.dart';"));
    expect(base, isNot(contains('lico_strings_labels.dart')));
    expect(base, isNot(contains('lico_strings.dart')));
    expect(labels, contains('/l10n/lico_strings_base.dart'));
    expect(labels, isNot(contains('/l10n/lico_strings.dart')));

    final partDirective = RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true);
    for (final source in [barrel, base, labels]) {
      expect(partDirective.hasMatch(source), isFalse);
    }
  });

  test('localization consumers depend only on the public barrel', () {
    final l10nDirectory = Directory('lib/src/frontend/l10n').absolute.path;
    final implementationImport = RegExp(
      r"import 'package:flutter_client/src/frontend/l10n/"
      r"lico_strings_(?:base|labels)\.dart';",
    );

    final consumers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .where((file) => !file.absolute.path.startsWith(l10nDirectory));

    for (final file in consumers) {
      expect(
        implementationImport.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: file.uri.pathSegments.last,
      );
    }
  });
}
