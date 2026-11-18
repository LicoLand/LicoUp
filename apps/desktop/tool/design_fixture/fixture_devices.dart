/// Synthetic `devices` CLI for the design fixture.
///
/// `--dart-define=FIXTURE_DEVICES=<state>` seeds the Devices surface:
/// `unenrolled`, `legacy` (unenrolled with pre-0.3.0 pairings detected),
/// `enrolled`, `pairing` (an offered code awaiting the other device) or
/// `paired` (the default: two paired desktops with message results). Every
/// command answers in memory with the C2 JSON shapes; nothing leaves the
/// process.
library;

import 'dart:convert';

const _fixtureDevices = String.fromEnvironment(
  'FIXTURE_DEVICES',
  defaultValue: 'paired',
);

const _station = 'https://station.example.test';
const _mailbox = '7f3a9c2e5b1d4a60';
const _code =
    'lap1.eyJvZmZlciI6InN5bnRoZXRpYy1vZmZlciIsInBlZXIiOiJmaXh0dXJlLWRlc2t0b3AifQ';

final class FixtureDevicesCli {
  FixtureDevicesCli() {
    switch (_fixtureDevices) {
      case 'unenrolled':
        break;
      case 'legacy':
        _legacyPairings = true;
      case 'enrolled':
        _enroll();
      case 'pairing':
        _enroll();
        _pairings.add(_pairing('pair-offer-1', 'offerer', 'awaiting-claim'));
      default:
        _enroll();
        _peers.addAll([
          _peer('peer-studio-mac', 'Studio Mac', '2026-11-02T09:12:00Z'),
          _peer('peer-travel-air', 'Travel Air', '2026-11-05T18:40:00Z'),
        ]);
        _pairings.add(_pairing('pair-claim-7', 'claimer', 'completed'));
        _results.add({
          'commandId': 'cmd-fixture-1',
          'peerId': 'peer-studio-mac',
          'status': 'completed',
          'output': {
            'text':
                'The build on Studio Mac finished: 214 tests passed, '
                'no warnings.',
          },
          'completedAt': '2026-11-08T10:24:31Z',
        });
        _results.add({
          'commandId': 'cmd-fixture-2',
          'peerId': 'peer-studio-mac',
          'status': 'failed',
          'output': {'code': 'agent_not_installed', 'agent': 'cursor'},
          'completedAt': '2026-11-08T10:21:02Z',
        });
    }
  }

  bool _enrolled = false;
  bool _legacyPairings = false;
  final List<Map<String, Object?>> _peers = [];
  final List<Map<String, Object?>> _pairings = [];
  final List<Map<String, Object?>> _results = [];
  int _sequence = 0;

  /// Answers one `devices` command, or null when [args] is another command.
  Map<String, dynamic>? answer(List<String> args, [String stdinText = '']) {
    if (args.isEmpty || args.first != 'devices') return null;
    final command = args
        .skip(1)
        .takeWhile((a) => !a.startsWith('--'))
        .join(' ');
    final input = stdinText.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(stdinText) as Map<String, dynamic>;
    switch (command) {
      case 'status':
        return {
          'ok': true,
          'enrolled': _enrolled,
          'legacyPairingsDetected': _legacyPairings,
          'station': _enrolled ? _station : null,
          'mailboxId': _enrolled ? _mailbox : null,
          'peers': _peers,
          'pairings': _pairings,
        };
      case 'enroll':
        _enroll();
        return {'ok': true, 'mailboxId': _mailbox};
      case 'pair offer':
        final id = 'pair-offer-${++_sequence}';
        _pairings.add(_pairing(id, 'offerer', 'awaiting-claim'));
        return {'ok': true, 'pairingId': id, 'code': _code};
      case 'pair claim':
        final id = 'pair-claim-${++_sequence}';
        _pairings.add(_pairing(id, 'claimer', 'completed'));
        _peers.add(
          _peer(
            'peer-claimed-$_sequence',
            '${input['label'] ?? ''}'.isEmpty
                ? 'New desktop'
                : '${input['label']}',
            '2026-11-08T11:00:00Z',
          ),
        );
        return {'ok': true, 'pairingId': id};
      case 'pair cancel':
        final id = _option(args, '--pairing-id');
        _pairings.removeWhere((p) => p['pairingId'] == id);
        return {'ok': true};
      case 'unpair':
        final id = _option(args, '--peer-id');
        _peers.removeWhere((p) => p['peerId'] == id);
        return {'ok': true};
      case 'message send':
        final id = 'cmd-fixture-${++_sequence + 10}';
        _results.insert(0, {
          'commandId': id,
          'peerId': _option(args, '--peer-id'),
          'status': 'completed',
          'output': {
            'text':
                'Synthetic reply from ${_option(args, '--agent')}: '
                '${input['body']}',
          },
          'completedAt': '2026-11-08T11:0${_sequence % 10}:00Z',
        });
        return {'ok': true, 'commandId': id};
      case 'message results':
        return {'ok': true, 'results': _results};
    }
    return {
      'ok': false,
      'error': {'code': 'cli_command_unknown'},
    };
  }

  void _enroll() => _enrolled = true;

  static Map<String, Object?> _peer(String id, String label, String at) => {
    'peerId': id,
    'label': label,
    'pairedAt': at,
  };

  static Map<String, Object?> _pairing(String id, String role, String state) =>
      {
        'pairingId': id,
        'role': role,
        'state': state,
        'createdAt': '2026-11-08T09:58:00Z',
      };

  static String _option(List<String> args, String name) {
    final index = args.indexOf(name);
    return index < 0 || index + 1 >= args.length ? '' : args[index + 1];
  }
}
