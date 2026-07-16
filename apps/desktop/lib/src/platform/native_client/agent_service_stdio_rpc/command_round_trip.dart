import 'dart:typed_data';

import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/request_writer.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/response_codec.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session.dart';
import 'package:flutter_client/src/platform/native_client/agent_service_stdio_rpc/session_manager.dart';
import 'package:flutter_client/src/platform/native_client/native_cli_ports.dart';

/// Owns one non-replayable stdio command round trip.
///
/// Frame construction remains in [command_exchange.dart]. Session lifecycle,
/// write ambiguity, response identity validation, and transport invalidation
/// are closed here so every command shape follows the same failure policy.
Future<Map<String, dynamic>> exchangeStdioRpcCommandFrame({
  required Uint8List encoded,
  required String requestId,
  required String workflowId,
  required StdioRpcSessionManager sessionManager,
}) async {
  final session = await sessionManager.ensureSession();
  late Future<StdioRpcFrame> responseFuture;
  try {
    responseFuture = session.expectFrame();
  } on Object {
    await sessionManager.discard(session: session, kill: true);
    throw const LicoClientRpcException('transport_failed');
  }

  // A write may reach native code even when flush fails. Commands are never
  // replayed against a replacement process after this point.
  try {
    await writeStdioRpcFrame(session, encoded);
  } on Object {
    session.abandonExpectedFrame();
    await sessionManager.discard(session: session, kill: true);
    throw const LicoClientRpcException('transport_failed');
  }

  late StdioRpcFrame responseFrame;
  try {
    responseFrame = await responseFuture;
  } on Object {
    await sessionManager.discard(session: session, kill: true);
    throw const LicoClientRpcException('transport_failed');
  }
  final responseBytes = responseFrame.bytes;
  if (responseBytes == null) {
    await sessionManager.discard(session: session, kill: true);
    throw const LicoClientRpcException('transport_failed');
  }

  late StdioRpcCommandReply reply;
  try {
    reply = decodeStdioRpcCommandReply(
      responseBytes,
      requestId: requestId,
      workflowId: workflowId,
    );
  } on StdioRpcProtocolViolation {
    await sessionManager.discard(session: session, kill: true);
    throw const LicoClientRpcException('invalid_response');
  }
  final result = reply.result;
  if (result != null) return result;
  throw LicoClientRpcException(reply.errorCode ?? 'command_failed');
}
