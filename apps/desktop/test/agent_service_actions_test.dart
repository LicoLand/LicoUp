import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  group('AgentServiceActions Pairing Commands', () {
    late AgentService service;
    late List<String> capturedArgs;

    setUp(() {
      capturedArgs = [];
      service = AgentService(
        runCliExecutable: (executable, args, env) async {
          capturedArgs = args;
          // Return a dummy successful JSON response to satisfy the JSON decoder
          if (args.contains('list')) {
            if (args.contains('pair')) {
              return ProcessResult(0, 0, '{"pairings": []}', '');
            } else if (args.contains('skill')) {
              return ProcessResult(0, 0, '{"skills": []}', '');
            }
            return ProcessResult(0, 0, '{"items": []}', '');
          }
          return ProcessResult(0, 0, '{"status": "ok"}', '');
        },
      );
    });

    test('requestPairing uses agents pair prefix', () async {
      await service.requestPairing(agent: 'codex', target: 'codex');
      expect(capturedArgs, [
        'agents',
        'pair',
        'request',
        '--agent',
        'codex',
        '--target',
        'codex',
      ]);
    });

    test('approvePairing uses agents pair prefix', () async {
      await service.approvePairing(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'approve', '--agent', 'codex']);
    });

    test('revokePairing uses agents pair prefix', () async {
      await service.revokePairing(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'revoke', '--agent', 'codex']);
    });

    test('listPairings uses agents pair prefix', () async {
      await service.listPairings(agent: 'codex');
      expect(capturedArgs, ['agents', 'pair', 'list', '--agent', 'codex']);
    });

    test('listSkills keeps skill list prefix', () async {
      await service.listSkills(agent: 'codex');
      expect(capturedArgs, ['skill', 'list', '--agent', 'codex']);
    });
  });
}
