import 'dart:collection';

import 'package:flutter_client/src/contracts/mobile_relay/mobile_relay_models.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';

abstract final class MobileRelayPolicy {
  static MobileRelayConfig publicConfig(MobileRelayConfig config) {
    return config.copyWith(
      pcToken: '',
      mobileToken: '',
      pcTokenPresent: config.pcTokenPresent || config.pcToken.trim().isNotEmpty,
      mobileTokenPresent:
          config.mobileTokenPresent || config.mobileToken.trim().isNotEmpty,
      pairedDevices: [
        for (final device in config.pairedDevices)
          MobileRelayPairedDevice(
            id: device.id,
            label: device.label,
            pairingId: device.pairingId,
            mobileToken: '',
            credentialPresent:
                device.credentialPresent ||
                device.mobileToken.trim().isNotEmpty,
            gatewayUrl: device.gatewayUrl,
          ),
      ],
    );
  }

  static MobileRelayConfig mergeHydratedSecrets(
    MobileRelayConfig previous,
    MobileRelayConfig next,
  ) {
    if (next.pairingId.trim().isEmpty ||
        next.pairingId.trim() != previous.pairingId.trim()) {
      return next;
    }
    final previousDevices = <String, MobileRelayPairedDevice>{
      for (final device in previous.pairedDevices)
        if (device.pairingId.trim().isNotEmpty) device.pairingId: device,
    };
    return next.copyWith(
      pcToken: next.pcToken.trim().isEmpty ? previous.pcToken : next.pcToken,
      mobileToken: next.mobileToken.trim().isEmpty
          ? previous.mobileToken
          : next.mobileToken,
      pairedDevices: [
        for (final device in next.pairedDevices)
          if (device.mobileToken.trim().isNotEmpty ||
              previousDevices[device.pairingId]?.mobileToken.trim().isEmpty !=
                  false)
            device
          else
            MobileRelayPairedDevice(
              id: device.id,
              label: device.label,
              pairingId: device.pairingId,
              mobileToken: previousDevices[device.pairingId]!.mobileToken,
              credentialPresent: device.credentialPresent,
              gatewayUrl: device.gatewayUrl,
            ),
      ],
    );
  }

  static List<MobileRelayCommand> commands(Object? rawCommands) {
    if (rawCommands is! List) return const [];
    final commands = <MobileRelayCommand>[];
    for (final raw in rawCommands) {
      if (raw is! Map) continue;
      try {
        commands.add(
          MobileRelayCommand.fromJson(Map<String, dynamic>.from(raw)),
        );
      } on TypeError {
        continue;
      }
    }
    return List<MobileRelayCommand>.unmodifiable(commands);
  }

  static MobileRelayCommand publicCommand(MobileRelayCommand command) {
    return MobileRelayCommand(
      commandId: command.commandId,
      type: command.type,
      payload: const {},
      status: stableCode(command.status, fallback: 'unknown'),
      createdAt: _safeTimestamp(command.createdAt),
    );
  }

  static SecureMeshCommandExecutionRequest? executionRequest(
    MobileRelayCommand command,
  ) {
    final payload = command.payload;
    final wrappedPayload =
        _map(payload['secureCommandPayload']) ??
        _map(payload['commandPayload']) ??
        _map(payload['payload']);
    final commandPayload =
        wrappedPayload ??
        (command.type == 'secure_mesh.command' ? _map(payload) : null);
    if (commandPayload == null) return null;
    final context =
        _map(payload['secureCommandContext']) ??
        _map(payload['context']) ??
        const <String, dynamic>{};
    return SecureMeshCommandExecutionRequest(
      payload: commandPayload,
      context: context,
    );
  }

  static Map<String, dynamic> syncProjection({
    required Map<String, dynamic> result,
    required int commandCount,
    required int secureExecutionCount,
  }) => Map<String, dynamic>.unmodifiable({
    'ok': result['ok'] == true,
    if (_text(result['status']).isNotEmpty)
      'status': stableCode(result['status']),
    'commandCount': commandCount,
    'secureExecutionCount': secureExecutionCount,
  });

  static Map<String, dynamic> executionProjection({
    required String commandId,
    required bool succeeded,
    String errorCode = '',
  }) => Map<String, dynamic>.unmodifiable({
    'commandId': commandId,
    'ok': succeeded,
    if (errorCode.isNotEmpty) 'errorCode': stableCode(errorCode),
  });

  static bool rememberCommand(
    LinkedHashSet<String> processed,
    String commandId, {
    int maximum = 512,
  }) {
    final normalized = commandId.trim();
    if (normalized.isEmpty) return true;
    if (!processed.add(normalized)) return false;
    while (processed.length > maximum) {
      processed.remove(processed.first);
    }
    return true;
  }

  static String stableCode(
    Object? value, {
    String fallback = 'mobile_relay_failed',
  }) {
    final candidate = _text(value).toLowerCase();
    return RegExp(r'^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$').hasMatch(candidate)
        ? candidate
        : fallback;
  }

  static Map<String, dynamic>? _map(Object? value) {
    if (value is! Map) return null;
    try {
      return Map<String, dynamic>.from(value);
    } on TypeError {
      return null;
    }
  }

  static String _safeTimestamp(String value) =>
      DateTime.tryParse(value)?.toUtc().toIso8601String() ?? '';

  static String _text(Object? value) => value?.toString().trim() ?? '';
}
