import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';

void main() {
  test(
    'large replies yield the UI event loop and preserve following frame order',
    () async {
      final process = _SyntheticProcess();
      final session = StdioRpcSession(process);
      addTearDown(() async {
        await session.close(kill: false);
        await process.output.close();
        await process.errors.close();
      });
      final first = session.expectFrame(requestId: 'large');
      final second = session.expectFrame(requestId: 'small');
      final completions = <String>[];
      first.then((_) => completions.add('large'));
      second.then((_) => completions.add('small'));
      final payload = List.filled(200000, 'synthetic').join();
      process.output.add(
        utf8.encode(
          '${jsonEncode({
            'id': 'large',
            'result': {'text': payload},
          })}\n${jsonEncode({'id': 'small', 'result': {}})}\n',
        ),
      );
      // Closing the producer must not overtake its final decoded replies.
      final drained = process.output.close();
      await Future<void>.delayed(Duration.zero);
      expect(
        completions,
        isEmpty,
        reason: 'large JSON decoding leaves an event-loop turn for the UI',
      );
      final replies = await Future.wait([first, second]);
      expect(completions, ['large', 'small']);
      expect((replies.first.envelope!['result'] as Map)['text'], payload);
      await drained;
    },
  );

  test(
    'malformed envelopes fail pending requests without exposing data',
    () async {
      final process = _SyntheticProcess();
      final session = StdioRpcSession(process);
      final reply = session.expectFrame(requestId: 'request');
      process.output.add(utf8.encode('invalid synthetic JSON\n'));
      expect((await reply).envelope, isNull);
      expect(session.usable, isFalse);
      await session.close(kill: false);
      await process.output.close();
      await process.errors.close();
    },
  );
}

class _SyntheticProcess extends Fake implements Process {
  final output = StreamController<List<int>>();
  final errors = StreamController<List<int>>();
  final _input = StreamController<List<int>>()..stream.listen((_) {});
  final _exit = Completer<int>();
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  late final IOSink stdin = IOSink(_input.sink);
  @override
  Future<int> get exitCode => _exit.future;
}
