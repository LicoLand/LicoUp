import 'dart:convert';
import 'dart:typed_data';

import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

// Constants and the command frame builder are owned by the generated
// conversation protocol contract (schemas/conversation_protocol/). These
// aliases keep the transport API stable while every wire value stays
// schema-derived. The wire protocol version is `licoup.stdio.v1`
// (conversationProtocolVersion); it is declared once in the schema and every
// frame is built and validated by the generated builder.
const String stdioRpcProtocol = conversationProtocolVersion;
const int stdioRpcMaxFrameBytes = conversationProtocolMaxFrameBytes;
const int stdioRpcMaxStderrBytes = conversationProtocolMaxStderrBytes;
const int stdioRpcMaxErrorCodeBytes = conversationProtocolMaxErrorCodeBytes;
const int stdioRpcMaxArgs = conversationProtocolMaxArgs;
const Duration stdioRpcShutdownTimeout = Duration(seconds: 2);

int _workflowSequence = 0;

String newStdioRpcWorkflowId() {
  _workflowSequence = (_workflowSequence + 1) & 0x7fffffff;
  final instant = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'lico-up-$instant-${_workflowSequence.toRadixString(36)}';
}

/// Encode one bounded command frame through the generated command builder.
/// The map is validated by the schema-derived decoder before re-encoding, so
/// any hand-written frame drift becomes an `invalid_request` failure here.
Uint8List encodeStdioRpcFrame(Map<String, dynamic> request) {
  late Uint8List encoded;
  try {
    final command = ConversationCommand.decode(
      Uint8List.fromList(utf8.encode(jsonEncode(request))),
    );
    encoded = command.encode();
  } on FormatException catch (error) {
    if (error.message == 'request_too_large') {
      throw const LicoClientRpcException('request_too_large');
    }
    throw const LicoClientRpcException('invalid_request');
  } on Object {
    throw const LicoClientRpcException('invalid_request');
  }
  return encoded;
}

bool validStdioRpcErrorCode(String value) {
  if (value.isEmpty || value.length > stdioRpcMaxErrorCodeBytes) {
    return false;
  }
  for (final codeUnit in value.codeUnits) {
    final lowercase = codeUnit >= 0x61 && codeUnit <= 0x7a;
    final digit = codeUnit >= 0x30 && codeUnit <= 0x39;
    if (!lowercase && !digit && codeUnit != 0x5f) {
      return false;
    }
  }
  return true;
}

bool validStdioRpcArgs(List<String> args) {
  if (args.isEmpty || args.length > conversationProtocolMaxClientArgs) {
    return false;
  }
  var codeUnits = 0;
  for (final arg in args) {
    codeUnits += arg.length;
    if (codeUnits > stdioRpcMaxArgumentCodeUnits) {
      return false;
    }
  }
  return true;
}

const int stdioRpcMaxArgumentCodeUnits = 1024 * 1024;
