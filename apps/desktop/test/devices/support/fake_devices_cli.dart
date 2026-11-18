import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/devices/devices_notice_repository.dart';

/// Synthetic CLI executor answering the C2 `devices` command group in memory.
///
/// Every call is recorded with its stdin payload; [failures] maps a command
/// (`'pair claim'`) to the snake_case code its next invocation fails with.
final class FakeDevicesCli implements AgentCommandRunner {
  FakeDevicesCli({
    this.enrolled = false,
    this.legacyPairingsDetected = false,
    List<Map<String, Object?>> peers = const [],
    List<Map<String, Object?>> pairings = const [],
    List<Map<String, Object?>> results = const [],
  }) : peers = [...peers],
       pairings = [...pairings],
       results = [...results];

  bool enrolled;
  bool legacyPairingsDetected;
  final List<Map<String, Object?>> peers;
  final List<Map<String, Object?>> pairings;
  final List<Map<String, Object?>> results;
  final List<List<String>> calls = [];
  final List<Map<String, dynamic>> stdinPayloads = [];
  final Map<String, String> failures = {};

  /// Whether `message send` records its result immediately.
  bool answerMessagesImmediately = false;
  int _sequence = 0;

  static Map<String, Object?> peer(String id, String label) => {
    'peerId': id,
    'label': label,
    'pairedAt': '2026-11-08T09:00:00Z',
  };

  static Map<String, Object?> pairing(String id, String role, String state) => {
    'pairingId': id,
    'role': role,
    'state': state,
    'createdAt': '2026-11-08T09:30:00Z',
  };

  static Map<String, Object?> result(
    String commandId,
    String peerId, {
    String status = 'completed',
    Map<String, Object?> output = const {'text': 'synthetic reply'},
    String completedAt = '2026-11-08T10:00:00Z',
  }) => {
    'commandId': commandId,
    'peerId': peerId,
    'status': status,
    'output': output,
    'completedAt': completedAt,
  };

  int callsOf(String command) =>
      calls.where((call) => _command(call) == command).length;

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async =>
      _answer(args, const {});

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    final payload = jsonDecode(stdinText) as Map<String, dynamic>;
    stdinPayloads.add(payload);
    return _answer(args, payload);
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();

  Map<String, dynamic> _answer(List<String> args, Map<String, dynamic> input) {
    calls.add(List<String>.unmodifiable(args));
    final command = _command(args);
    final failure = failures.remove(command);
    if (failure != null) throw Exception('licoup command failed: $failure');
    switch (command) {
      case 'status':
        return {
          'ok': true,
          'enrolled': enrolled,
          'legacyPairingsDetected': legacyPairingsDetected,
          'station': enrolled ? 'https://station.example.test' : null,
          'mailboxId': enrolled ? '0a1b2c3d' : null,
          'peers': peers,
          'pairings': pairings,
        };
      case 'enroll':
        enrolled = true;
        return {'ok': true, 'mailboxId': '0a1b2c3d'};
      case 'pair offer':
        final id = 'pair-offer-${++_sequence}';
        pairings.add(pairing(id, 'offerer', 'awaiting-claim'));
        return {'ok': true, 'pairingId': id, 'code': 'code-$id'};
      case 'pair claim':
        final id = 'pair-claim-${++_sequence}';
        pairings.add(pairing(id, 'claimer', 'awaiting-reply'));
        return {'ok': true, 'pairingId': id};
      case 'pair cancel':
        final id = _option(args, '--pairing-id');
        pairings.removeWhere((entry) => entry['pairingId'] == id);
        return {'ok': true};
      case 'unpair':
        final id = _option(args, '--peer-id');
        peers.removeWhere((entry) => entry['peerId'] == id);
        return {'ok': true};
      case 'message send':
        final id = 'cmd-${++_sequence}';
        if (answerMessagesImmediately) {
          results.add(result(id, _option(args, '--peer-id')));
        }
        return {'ok': true, 'commandId': id};
      case 'message results':
        return {'ok': true, 'results': results};
    }
    throw StateError('unexpected command: $args');
  }

  static String _command(List<String> args) =>
      args.skip(1).takeWhile((arg) => !arg.startsWith('--')).join(' ');

  static String _option(List<String> args, String name) {
    final index = args.indexOf(name);
    return index < 0 ? '' : args[index + 1];
  }
}

/// In-memory acknowledgement record; [unreadable] simulates a stored record
/// that exists but cannot be read.
final class FakeDevicesNoticeRepository implements DevicesNoticeRepository {
  FakeDevicesNoticeRepository({
    this.acknowledged = false,
    this.unreadable = false,
  });

  bool acknowledged;
  bool unreadable;
  int writes = 0;

  @override
  Future<bool> readLegacyPairingNoticeAcknowledged() async {
    if (unreadable) {
      throw const FormatException('devices_notice_document_invalid');
    }
    return acknowledged;
  }

  @override
  Future<void> writeLegacyPairingNoticeAcknowledged() async {
    writes += 1;
    acknowledged = true;
  }
}
