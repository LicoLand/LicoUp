import 'dart:async';

import 'package:flutter_client/src/application/features/settings/controller/client_log_export_controller.dart';
import 'package:flutter_client/src/contracts/client_log_export.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('log export slice serializes duplicate export requests', () async {
    final exporter = _DeferredClientLogExporter();
    final statuses = <ClientLogExportStatusUpdate>[];
    final controller = ClientLogExportController(
      exporter: exporter,
      portableData: Object(),
      onStatus: statuses.add,
    );
    addTearDown(controller.dispose);

    final first = controller.export(' test-data/export.log ');
    final duplicate = controller.export('test-data/duplicate.log');

    expect(controller.busy, isTrue);
    expect(exporter.calls, 1);
    await duplicate;
    exporter.complete(
      const ClientLogExportResult(
        path: 'test-data/export.log',
        bytes: 4,
        sourceExists: true,
      ),
    );
    await first;

    expect(controller.busy, isFalse);
    expect(controller.exportedPath, 'test-data/export.log');
    expect(statuses.last.english, 'Client logs exported.');
  });

  test('log export slice reports bounded failures without a path', () async {
    ClientLogExportStatusUpdate? lastUpdate;
    final controller = ClientLogExportController(
      exporter: _FailingClientLogExporter(),
      portableData: Object(),
      onStatus: (update) => lastUpdate = update,
    );
    addTearDown(controller.dispose);

    await controller.export('test-data/export.log');

    expect(controller.busy, isFalse);
    expect(controller.exportedPath, isEmpty);
    expect(lastUpdate?.caption, 'Error');
    expect(lastUpdate?.error, isNotNull);
  });
}

final class _DeferredClientLogExporter implements ClientLogExporter {
  final Completer<ClientLogExportResult> _result = Completer();
  int calls = 0;

  void complete(ClientLogExportResult result) => _result.complete(result);

  @override
  Future<ClientLogExportResult> exportLogs({
    required Object portableData,
    required String destinationPath,
  }) {
    calls++;
    return _result.future;
  }
}

final class _FailingClientLogExporter implements ClientLogExporter {
  @override
  Future<ClientLogExportResult> exportLogs({
    required Object portableData,
    required String destinationPath,
  }) => Future.error(StateError('export_failed'));
}
