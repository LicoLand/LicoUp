import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/devices/devices_models.dart';

/// A `devices` command that failed, carrying only its stable snake_case code.
final class DevicesCommandFailure implements Exception {
  const DevicesCommandFailure(this.code);

  final String code;

  @override
  String toString() => 'devices command failed ($code)';
}

/// Encodes the CLI `devices` command group and decodes its JSON answers.
///
/// Every command runs through the client's existing CLI runner (one-shot
/// argv or the persistent RPC `execute` wrapper); there is no structured RPC
/// method for devices. A failure becomes a [DevicesCommandFailure] whose code
/// is the CLI's own snake_case error code when one is available.
final class DevicesService {
  const DevicesService({required AgentCommandRunner runner}) : _runner = runner;

  final AgentCommandRunner _runner;

  Future<DevicesStatus> status() async =>
      DevicesStatus.fromJson(await _run(const ['devices', 'status']));

  Future<void> enroll({
    required String station,
    required String invitation,
    String? caPem,
  }) => _runWithStdin(
    const ['devices', 'enroll', '--stdin-json', 'true'],
    {'station': station, 'invitation': invitation, 'ca': caPem},
  );

  Future<DevicePairingOffer> offerPairing({String label = ''}) async =>
      DevicePairingOffer.fromJson(
        await _run([
          'devices',
          'pair',
          'offer',
          if (label.isNotEmpty) ...['--label', label],
        ]),
      );

  Future<void> claimPairing({required String code, String label = ''}) =>
      _runWithStdin(
        const ['devices', 'pair', 'claim', '--stdin-json', 'true'],
        {'code': code, 'label': label.isEmpty ? null : label},
      );

  Future<void> cancelPairing(String pairingId) =>
      _run(['devices', 'pair', 'cancel', '--pairing-id', pairingId]);

  Future<void> unpair(String peerId) =>
      _run(['devices', 'unpair', '--peer-id', peerId]);

  /// Sends one agent message to [agent] on the paired device [peerId] and
  /// returns the command id its result will carry.
  Future<String> sendMessage({
    required String peerId,
    required String agent,
    required String body,
    required String clientIntentId,
  }) async {
    final output = await _runWithStdin(
      [
        'devices',
        'message',
        'send',
        '--peer-id',
        peerId,
        '--agent',
        agent,
        '--stdin-json',
        'true',
      ],
      {'body': body, 'clientIntentId': clientIntentId},
    );
    final commandId = output['commandId'];
    if (commandId is! String || commandId.trim().isEmpty) {
      throw const DevicesCommandFailure('devices_message_send_invalid');
    }
    return commandId.trim();
  }

  Future<List<DeviceMessageResult>> messageResults() async =>
      deviceMessageResultsFromJson(
        await _run(const ['devices', 'message', 'results']),
      );

  Future<Map<String, dynamic>> _run(List<String> args) =>
      _guard(() => _runner.runCli(args));

  Future<Map<String, dynamic>> _runWithStdin(
    List<String> args,
    Map<String, Object?> payload,
  ) => _guard(() => _runner.runCliWithStdin(args, jsonEncode(payload)));

  Future<Map<String, dynamic>> _guard(
    Future<Map<String, dynamic>> Function() run,
  ) async {
    final Map<String, dynamic> output;
    try {
      output = await run();
    } on Object catch (error) {
      throw DevicesCommandFailure(devicesFailureCode(error));
    }
    if (output['ok'] != true) {
      throw DevicesCommandFailure(_outputErrorCode(output));
    }
    return output;
  }
}

final RegExp _stableCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final RegExp _failureMessageCode = RegExp(r'failed: ([a-z][a-z0-9_]{0,63})\b');

/// The stable code of a runner failure; free-form detail never escapes.
String devicesFailureCode(Object error) {
  if (error is DevicesCommandFailure) return error.code;
  if (error is FormatException && _stableCode.hasMatch(error.message)) {
    return error.message;
  }
  try {
    final code = (error as dynamic).code;
    if (code is String && _stableCode.hasMatch(code)) return code;
  } on Object {
    // Exceptions without a code fall through to the message or the default.
  }
  final match = _failureMessageCode.firstMatch(error.toString());
  return match?.group(1) ?? 'devices_command_failed';
}

String _outputErrorCode(Map<String, dynamic> output) {
  final error = output['error'];
  final candidate = error is Map ? error['code'] : output['errorCode'];
  return candidate is String && _stableCode.hasMatch(candidate)
      ? candidate
      : 'devices_command_failed';
}
