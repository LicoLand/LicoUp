import 'dart:async';

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';

final class StdioRpcConversationExpectation {
  const StdioRpcConversationExpectation({
    required this.controller,
    required this.decoder,
  });

  final StreamController<StdioRpcConversationFrame> controller;
  final StdioRpcConversationDecoder decoder;
}
