import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/execution_process/conversation_execution_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/execution_process/execution_document.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'chunks preserve all original text and never separate CRLF or emoji',
    () {
      final raw =
          '  \t{"unknown_field":"[.*]"}\r\n'
          '${List.filled(1600, '😀').join()}'
          '${List.generate(200, (index) => '\r\n\tline $index').join()}'
          '\r\n\r\n  ';
      final chunks = executionTextChunks(raw);
      expect(chunks.length, greaterThan(2));
      expect(
        chunks.map((chunk) => raw.substring(chunk.start, chunk.end)).join(),
        raw,
      );
      for (final chunk in chunks.skip(1)) {
        expect(
          raw.codeUnitAt(chunk.start),
          isNot(inInclusiveRange(0xdc00, 0xdfff)),
        );
        expect(raw.substring(chunk.start - 1, chunk.start + 1), isNot('\r\n'));
      }
    },
  );

  test(
    'search includes all records, literal symbols and cross-chunk matches',
    () {
      final raw = '${'a' * 4093}Needle\r\n\t[.*]  \r\n';
      final records = [
        ConversationExecutionRecord(id: 'old', rawText: raw),
        const ConversationExecutionRecord(id: 'new', rawText: 'NEEDLE needle'),
      ];
      final matches = searchExecutionRecords(records, 'needle');
      expect(matches.map((match) => match.recordIndex), [0, 1, 1]);
      expect(matches.first.start, 4093);
      expect(
        searchExecutionRecords(records, '[.*]').single.start,
        raw.indexOf('[.*]'),
      );
      expect(searchExecutionRecords(records, '\r\n').length, 2);
      expect(searchExecutionRecords(records, '').isEmpty, isTrue);
    },
  );

  test(
    'layout yields after eight paragraphs and drops a superseded request',
    () async {
      final raw = 'x' * (2 * 1024 * 1024);
      final document = ExecutionDocument(
        records: [ConversationExecutionRecord(id: 'large', rawText: raw)],
        width: 640,
        textStyle: const TextStyle(fontSize: 13),
        headerStyle: const TextStyle(fontSize: 12),
        textScaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        locale: const Locale('en'),
        headerLabels: const ['tool.output'],
      );
      var current = true;
      var yields = 0;
      final complete = await document.prepare(
        isCurrent: () => current,
        yieldToUi: () async {
          yields += 1;
          expect(document.rows, hasLength(8));
          current = false;
        },
      );
      expect(complete, isFalse);
      expect(yields, 1);
      expect(document.records.single.rawText, raw);
      expect(document.rows, hasLength(8));
    },
  );
}
