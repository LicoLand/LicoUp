import 'dart:io';

import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('history panel composes bounded rendering and pure policy modules', () {
    const root = 'lib/src/frontend/features/agents/ui';
    const componentLimits = {
      'history_session_panel.dart': 360,
      'history_session_models.dart': 200,
      'history_session_search.dart': 200,
      'history_session_header.dart': 250,
      'history_session_list.dart': 500,
    };
    final panel = File('$root/history_session_panel.dart').readAsStringSync();
    for (final entry in componentLimits.entries) {
      final source = File('$root/${entry.key}').readAsStringSync();
      expect(source.split('\n').length, lessThan(entry.value));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }

    expect(panel, contains('history_session_models.dart'));
    expect(panel, contains('history_session_search.dart'));
    expect(panel, contains('history_session_header.dart'));
    expect(panel, contains('history_session_list.dart'));
    expect(panel, isNot(contains('class HistorySessionGroupedRow')));
    expect(panel, isNot(contains('RegExp _search')));

    final models = File('$root/history_session_models.dart').readAsStringSync();
    final search = File('$root/history_session_search.dart').readAsStringSync();
    expect(models, isNot(contains('package:flutter/')));
    expect(search, isNot(contains('package:flutter/')));
    expect(search, isNot(contains('history_session_list.dart')));
  });

  test('history search ranks title prefixes ahead of other field matches', () {
    const titlePrefix = HistorySessionPanelItem(
      id: 'title-prefix',
      title: 'Migration matrix',
      meta: 'codex',
    );
    const metadataPrefix = HistorySessionPanelItem(
      id: 'metadata-prefix',
      title: 'Architecture notes',
      meta: 'migration-project',
    );
    const previewContains = HistorySessionPanelItem(
      id: 'preview-contains',
      title: 'Release notes',
      preview: 'Continue migration work',
    );

    expect(
      historySessionPrefixMatches(const [
        previewContains,
        metadataPrefix,
        titlePrefix,
      ], 'mig').map((item) => item.id),
      ['title-prefix', 'metadata-prefix', 'preview-contains'],
    );
  });
}
