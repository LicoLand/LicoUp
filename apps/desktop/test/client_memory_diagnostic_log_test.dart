import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/platform/storage/client_memory_diagnostic_log.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

void main() {
  test('memory diagnostics persist only counts and RSS', () async {
    final root = await Directory.systemTemp.createTemp(
      'licoup-memory-diagnostics-',
    );
    addTearDown(() => root.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: root);
    final log = ClientMemoryDiagnosticLog(portableData: portableData);

    await log.record(
      ClientMemoryDiagnosticRecord(
        event: ClientMemoryDiagnosticEvent.liveTurnOpened,
        createdAt: DateTime.utc(2026, 9, 7, 8, 30),
        surface: ClientMemoryDiagnosticSurface.canonical,
        rssBytes: 120 * 1024 * 1024,
        maxRssBytes: 128 * 1024 * 1024,
        eventCount: 40,
        loadedEventCount: 20,
        liveTurnCount: 1,
        livePartCount: 3,
        liveMessageCount: 2,
        cachedConversationCount: 1,
      ),
    );

    final clientDirectory = await portableData.clientDirectory();
    final file = File(
      p.join(clientDirectory.path, 'diagnostics', 'client-memory.jsonl'),
    );
    final record = jsonDecode((await file.readAsLines()).single) as Map;
    expect(record.keys.toSet(), {
      'schemaVersion',
      'createdAt',
      'event',
      'surface',
      'rssBytes',
      'maxRssBytes',
      'eventCount',
      'loadedEventCount',
      'liveTurnCount',
      'livePartCount',
      'liveMessageCount',
      'cachedConversationCount',
    });
    expect(record['schemaVersion'], 'licoup.client-memory-diagnostic.v1');
    expect(record['event'], 'live_turn_opened');
    expect(record['surface'], 'canonical');
    expect(record['rssBytes'], 120 * 1024 * 1024);
    expect(record['livePartCount'], 3);
    expect(record.toString(), isNot(contains(root.path)));
    expect(record.toString(), isNot(contains('/Users/')));
  });

  test('rotation keeps the newest complete lines under the byte cap', () {
    final older = utf8.encode(
      '${jsonEncode({'event': 'sample', 'n': 1})}\n'
      '${jsonEncode({'event': 'sample', 'n': 2})}\n',
    );
    final incoming = utf8.encode(
      '${jsonEncode({'event': 'sample', 'n': 3})}\n',
    );
    final retained = retainMemoryDiagnosticTail(older, incoming, 80);
    final text = utf8.decode(retained);
    expect(text, contains('"n":3'));
    expect(text.startsWith('{'), isTrue);
    expect(retained.length, lessThanOrEqualTo(80));
  });
}
