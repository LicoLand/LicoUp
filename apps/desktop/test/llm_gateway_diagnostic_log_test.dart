import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
import 'package:licoup/src/platform/storage/llm_gateway_diagnostic_log.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'Gateway diagnostics persist only the bounded recovery projection',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'licoup-gateway-diagnostics-',
      );
      addTearDown(() => root.delete(recursive: true));
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final log = LlmGatewayDiagnosticLog(portableData: portableData);

      await log.record(
        LlmGatewayDiagnosticRecord(
          event: LlmGatewayDiagnosticEvent.recoveryAttemptFailed,
          createdAt: DateTime.utc(2026, 8, 13, 8, 30),
          runtimeState: 'unhealthy',
          errorCode: 'timeout',
          attempt: 2,
        ),
      );

      final clientDirectory = await portableData.clientDirectory();
      final file = File(
        p.join(
          clientDirectory.path,
          'diagnostics',
          'llm-gateway-recovery.jsonl',
        ),
      );
      final record = jsonDecode((await file.readAsLines()).single) as Map;
      expect(record.keys.toSet(), {
        'schemaVersion',
        'createdAt',
        'event',
        'runtimeState',
        'errorCode',
        'attempt',
      });
      expect(record['event'], 'recovery_attempt_failed');
      expect(record['runtimeState'], 'unhealthy');
      expect(record['errorCode'], 'timeout');
      expect(record['attempt'], 2);
      expect(record.toString(), isNot(contains(root.path)));
    },
  );
}
