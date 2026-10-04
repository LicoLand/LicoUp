import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/presentation/work_control_models.dart';
import 'package:licoup/src/contracts/work_control_gateway.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';

/// Desktop manual-stop and force-stop lane over the owned structured transport.
///
/// This is the production implementation of [WorkControlGateway]: it is the
/// only owner that reaches the native control plane, and it does so through the
/// same owned transport the conversation lane uses. The three methods are
/// schema-declared `inFlightControl` conversation methods, so
/// [NativeStdioRpcTransport.executeStructured] admits them on the dedicated
/// conversation session and never queues them behind bulk output.
///
/// Every answer is projected from the host's own bounded shape by the
/// `*fromJson` readers, which are fail closed by construction: an answer that
/// is not an explicit success can never become a fabricated completion. A
/// transport failure, a non-desktop host, or a malformed answer therefore
/// reports the matching `unavailable` answer. Force-stop parameters are taken
/// verbatim from the caller so the host re-verifies the exact scope revision
/// the preview returned.
final class NativeWorkControlGateway implements WorkControlGateway {
  const NativeWorkControlGateway({
    required NativeStdioRpcTransport transport,
    required bool desktopRuntime,
  }) : _transport = transport,
       _desktopRuntime = desktopRuntime;

  /// A host without the local owned runtime keeps the fail-closed answer.
  ///
  /// The same boundary applies to the conversation lane: only a desktop host
  /// owns the local native process that can resolve a work owner.
  static const String unsupportedHostCode = 'work_control_unsupported_host';

  final NativeStdioRpcTransport _transport;
  final bool _desktopRuntime;

  @override
  Future<WorkStopResult> stopWork(WorkStopRequest request) async {
    if (!_desktopRuntime) {
      return const WorkStopResult.unavailable(unsupportedHostCode);
    }
    final Map<String, dynamic> answer;
    try {
      answer = await _transport.executeStructured(
        ConversationProtocolMethod.agentConversationStop.wireName,
        request.toJson(),
      );
    } on Object {
      // One control request whose outcome is unknown is never retried here and
      // never reported as accepted.
      return const WorkStopResult.unavailable('work_stop_transport_failed');
    }
    return WorkStopResult.fromJson(answer);
  }

  @override
  Future<ForceStopPreview> previewForceStop({String scopeId = ''}) async {
    if (!_desktopRuntime) {
      return const ForceStopPreview.unavailable(unsupportedHostCode);
    }
    final trimmedScopeId = scopeId.trim();
    final Map<String, dynamic> answer;
    try {
      answer = await _transport.executeStructured(
        ConversationProtocolMethod.agentConversationForcePreview.wireName,
        // An empty scope is omitted so the host answers `scope-required` with
        // its own candidate scopes instead of this client guessing one.
        <String, dynamic>{
          if (trimmedScopeId.isNotEmpty) 'scopeId': trimmedScopeId,
        },
      );
    } on Object {
      return const ForceStopPreview.unavailable(
        'force_stop_preview_transport_failed',
      );
    }
    return ForceStopPreview.fromJson(answer);
  }

  @override
  Future<ForceStopConfirmation> confirmForceStop({
    required String scopeId,
    required String confirmationToken,
    required bool confirmed,
  }) async {
    if (!_desktopRuntime) {
      return const ForceStopConfirmation.unavailable(unsupportedHostCode);
    }
    final Map<String, dynamic> answer;
    try {
      answer = await _transport.executeStructured(
        ConversationProtocolMethod.agentConversationForceConfirm.wireName,
        <String, dynamic>{
          'scopeId': scopeId.trim(),
          'confirmationToken': confirmationToken.trim(),
          'confirmed': confirmed,
        },
      );
    } on Object {
      return const ForceStopConfirmation.unavailable(
        'force_stop_confirm_transport_failed',
      );
    }
    return ForceStopConfirmation.fromJson(answer);
  }
}
