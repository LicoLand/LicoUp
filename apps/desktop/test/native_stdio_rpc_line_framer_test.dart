import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/line_framer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line framer joins chunks and normalizes CRLF boundaries', () {
    final frames = <String>[];
    var oversized = 0;
    final framer = StdioRpcLineFramer(maxFrameBytes: 64);

    void accept(String text) {
      framer.accept(
        utf8.encode(text),
        onFrame: (bytes) => frames.add(utf8.decode(bytes)),
        onOversizedFrame: () => oversized += 1,
      );
    }

    accept('first');
    accept('-frame\r\nsecond-frame\n');

    expect(frames, ['first-frame', 'second-frame']);
    expect(oversized, 0);
  });

  test('line framer rejects one oversized frame and resumes at newline', () {
    final frames = <Uint8List>[];
    var oversized = 0;
    final framer = StdioRpcLineFramer(maxFrameBytes: 5);

    framer.accept(
      utf8.encode('abcde\nok\n'),
      onFrame: frames.add,
      onOversizedFrame: () => oversized += 1,
    );

    expect(oversized, 1);
    expect(frames.map((bytes) => utf8.decode(bytes)), ['ok']);
  });
}
