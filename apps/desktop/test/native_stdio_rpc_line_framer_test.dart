import 'dart:convert';
import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/line_framer.dart';
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

  test('line framer enforces 16 MiB boundary constraint', () {
    const maxBound = 16 * 1024 * 1024;
    final framer = StdioRpcLineFramer(maxFrameBytes: maxBound);
    var framesCount = 0;
    var lastFrameLength = 0;
    var oversizedCount = 0;

    // Test a frame right at the 16 MiB limit: payload of 16 MiB - 1 byte, plus '\n' = 16 MiB total.
    final atLimitPayload = Uint8List(maxBound - 1);
    atLimitPayload.fillRange(0, atLimitPayload.length, 0x61); // 'a'
    final atLimitChunk = Uint8List(maxBound);
    atLimitChunk.setRange(0, atLimitPayload.length, atLimitPayload);
    atLimitChunk[maxBound - 1] = 0x0a; // '\n'

    framer.accept(
      atLimitChunk,
      onFrame: (bytes) {
        framesCount += 1;
        lastFrameLength = bytes.length;
      },
      onOversizedFrame: () => oversizedCount += 1,
    );

    expect(oversizedCount, 0);
    expect(framesCount, 1);
    expect(lastFrameLength, maxBound - 1);

    // Test a frame exceeding 16 MiB limit by 1 byte: 16 MiB bytes + '\n' = 16 MiB + 1.
    final oversizedChunk = Uint8List(maxBound + 1);
    oversizedChunk.fillRange(0, maxBound, 0x62); // 'b'
    oversizedChunk[maxBound] = 0x0a; // '\n'

    framer.accept(
      oversizedChunk,
      onFrame: (bytes) => framesCount += 1,
      onOversizedFrame: () => oversizedCount += 1,
    );

    expect(oversizedCount, 1);
    expect(framesCount, 1); // No frame was delivered for the oversized one
  });
}
