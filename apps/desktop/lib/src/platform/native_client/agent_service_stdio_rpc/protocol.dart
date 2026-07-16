import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

const String stdioRpcProtocol = 'lico-client.stdio.v1';
const int stdioRpcMaxFrameBytes = 16 * 1024 * 1024;
const int stdioRpcMaxStderrBytes = 512 * 1024;
const int stdioRpcMaxErrorCodeBytes = 64;
const int stdioRpcMaxArgs = 256;
const int stdioRpcMaxArgumentCodeUnits = 1024 * 1024;
const Duration stdioRpcShutdownTimeout = Duration(seconds: 2);

int _workflowSequence = 0;

String newStdioRpcWorkflowId() {
  _workflowSequence = (_workflowSequence + 1) & 0x7fffffff;
  final instant = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  return 'lico-arc-$instant-${_workflowSequence.toRadixString(36)}';
}

Uint8List encodeStdioRpcFrame(Map<String, dynamic> request) {
  late Uint8List encoded;
  try {
    encoded = Uint8List.fromList(utf8.encode(jsonEncode(request)));
  } on Object {
    throw const LicoClientRpcException('invalid_request');
  }
  if (encoded.length + 1 > stdioRpcMaxFrameBytes) {
    throw const LicoClientRpcException('request_too_large');
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
  if (args.isEmpty || args.length > stdioRpcMaxArgs) {
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
