import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_lifecycle_coordinator.dart';
import 'package:licoup/src/application/controller/client_lifecycle_diagnostic_journal.dart';
import 'package:licoup/src/contracts/client_lifecycle_diagnostics.dart';
import 'package:licoup/src/platform/storage/client_lifecycle_diagnostic_log.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

final class _CollectingSink implements ClientLifecycleDiagnosticSink {
  final records = <ClientLifecycleDiagnosticRecord>[];

  @override
  Future<void> record(ClientLifecycleDiagnosticRecord record) async {
    records.add(record);
  }
}

void main() {
  // Synthetic account segments stay split so the committed source never
  // embeds a real-looking home path; the sanitizer still sees one.
  const macHome =
      '/Users/'
      'alice';
  const linuxHome =
      '/home/'
      'bob';

  test('journal sanitizes paths and bounds the recorded evidence', () async {
    final sink = _CollectingSink();
    final journal = ClientLifecycleDiagnosticJournal(
      sink: sink,
      now: () => DateTime.utc(2026, 10, 7, 8, 30),
      homeDirectory: () => macHome,
    );

    journal.recordFailure(
      const ClientLifecycleReport(
        code: 'client_initialize_failed',
        stepId: 'client_storage_root',
      ),
      StateError('open $macHome/Library/private.db failed'),
      StackTrace.fromString(
        '#0 open ($macHome/app/file.dart:1)\n'
        '#1 main ($linuxHome/work/main.dart:2)',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(sink.records, hasLength(1));
    final record = sink.records.single;
    expect(
      ClientLifecycleDiagnosticRecord.schemaVersion,
      'licoup.client-lifecycle-diagnostic.v1',
    );
    expect(record.createdAt, DateTime.utc(2026, 10, 7, 8, 30));
    expect(record.code, 'client_initialize_failed');
    expect(record.stepId, 'client_storage_root');
    expect(record.errorType, 'StateError');
    expect(record.detail, contains('~/Library/private.db'));
    expect(record.detail, isNot(contains(macHome)));
    expect(record.stack, isNot(contains(macHome)));
    expect(record.stack, isNot(contains(linuxHome)));
    expect(record.detail.length, lessThanOrEqualTo(321));
    expect(record.stack.length, lessThanOrEqualTo(641));
  });

  test('journal bounds oversized error text', () async {
    final sink = _CollectingSink();
    final journal = ClientLifecycleDiagnosticJournal(sink: sink);

    journal.recordFailure(
      const ClientLifecycleReport(
        code: 'client_background_step_failed',
        stepId: 'client_update_check',
      ),
      StateError('x' * 4096),
      StackTrace.fromString('#0 huge (${'y' * 4096})'),
    );
    await Future<void>.delayed(Duration.zero);

    final record = sink.records.single;
    expect(record.detail.length, lessThanOrEqualTo(321));
    expect(record.stack.length, lessThanOrEqualTo(641));
  });

  test(
    'journal swallows sink failures so diagnostics never mask the report',
    () async {
      final journal = ClientLifecycleDiagnosticJournal(sink: _ThrowingSink());

      journal.recordFailure(
        const ClientLifecycleReport(
          code: 'client_initialize_failed',
          stepId: 'client_catalog',
        ),
        StateError('synthetic'),
        StackTrace.empty,
      );
      await Future<void>.delayed(Duration.zero);
    },
  );

  test('lifecycle diagnostic log persists bounded json lines', () async {
    final root = await Directory.systemTemp.createTemp(
      'licoup-lifecycle-diagnostics-',
    );
    addTearDown(() => root.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: root);
    final log = ClientLifecycleDiagnosticLog(portableData: portableData);

    await log.record(
      ClientLifecycleDiagnosticRecord(
        createdAt: DateTime.utc(2026, 10, 7, 8, 30),
        code: 'client_initialize_failed',
        stepId: 'client_storage_root',
        errorType: 'StateError',
        detail: 'sanitized detail',
        stack: '#0 frame',
      ),
    );
    await log.flush();

    final clientDirectory = await portableData.clientDirectory();
    final file = File(
      p.join(clientDirectory.path, 'diagnostics', 'client-lifecycle.jsonl'),
    );
    final record = jsonDecode((await file.readAsLines()).single) as Map;
    expect(record.keys.toSet(), {
      'schemaVersion',
      'createdAt',
      'code',
      'stepId',
      'errorType',
      'detail',
      'stack',
    });
    expect(record['schemaVersion'], 'licoup.client-lifecycle-diagnostic.v1');
    expect(record['code'], 'client_initialize_failed');
    expect(record['stepId'], 'client_storage_root');
    expect(record.toString(), isNot(contains(root.path)));
  });

  test('lifecycle diagnostic log rotates under the byte cap', () async {
    final root = await Directory.systemTemp.createTemp(
      'licoup-lifecycle-rotation-',
    );
    addTearDown(() => root.delete(recursive: true));
    final portableData = PortableDataRoot(dataDirectoryOverride: root);
    final log = ClientLifecycleDiagnosticLog(portableData: portableData);
    final record = ClientLifecycleDiagnosticRecord(
      createdAt: DateTime.utc(2026, 10, 7, 8, 30),
      code: 'client_background_step_failed',
      stepId: 'opencode_serve',
      errorType: 'StateError',
      detail: 'z' * 1024,
      stack: 's' * 1024,
    );

    for (var i = 0; i < 40; i += 1) {
      await log.record(record);
    }
    await log.flush();

    final clientDirectory = await portableData.clientDirectory();
    final file = File(
      p.join(clientDirectory.path, 'diagnostics', 'client-lifecycle.jsonl'),
    );
    final bytes = await file.readAsBytes();
    expect(
      bytes.length,
      lessThanOrEqualTo(ClientLifecycleDiagnosticLog.maxBytes),
    );
    final text = utf8.decode(bytes);
    expect(text.startsWith('{'), isTrue);
    expect(text.trim().isNotEmpty, isTrue);
  });
}

final class _ThrowingSink implements ClientLifecycleDiagnosticSink {
  @override
  Future<void> record(ClientLifecycleDiagnosticRecord record) async {
    throw StateError('sink exploded');
  }
}
