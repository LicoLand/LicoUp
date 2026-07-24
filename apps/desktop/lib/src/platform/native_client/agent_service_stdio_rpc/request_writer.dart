import 'dart:typed_data';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/session.dart';

Future<void> writeStdioRpcFrame(
  StdioRpcSession session,
  Uint8List frame,
) async {
  session.process.stdin.add(frame);
  session.process.stdin.add(const [0x0a]);
  await session.process.stdin.flush();
}
