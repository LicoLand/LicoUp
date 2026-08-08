import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'local candidates and supported SSH VM candidates enter conversations',
    () {
      final workingDirectory = _guestPath(['srv', 'project']);
      final local = TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
      );
      final remote = TargetCandidate(
        target: 'codex',
        label: 'Remote Codex',
        kind: 'cli',
        status: 'detected',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
        location: 'docker',
      );
      final virtualMachine = TargetCandidate(
        target: 'openclaw',
        label: 'OpenClaw',
        kind: 'cli',
        status: 'configured',
        configured: true,
        confidence: 1,
        binaryPath: 'openclaw',
        adapterStatus: 'implemented',
        adapterCapabilities: const {'conversationDriver': 'implemented'},
        location: 'virtual-machine',
        runtimeConnection: {
          'kind': 'ssh',
          'host': 'vm.example',
          'remoteExecutable': 'openclaw',
          'workingDirectory': workingDirectory,
        },
      );
      final unsupportedVirtualMachine = TargetCandidate(
        target: 'codex',
        label: 'Codex',
        kind: 'cli',
        status: 'configured',
        configured: true,
        confidence: 1,
        adapterStatus: 'implemented',
        location: 'virtual-machine',
        runtimeConnection: {
          'kind': 'ssh',
          'host': 'vm.example',
          'remoteExecutable': 'codex',
          'workingDirectory': workingDirectory,
        },
      );

      expect(local.isConversationAgent, isTrue);
      expect(remote.isConversationAgent, isFalse);
      expect(virtualMachine.isConversationAgent, isTrue);
      expect(virtualMachine.canRelayRuntime, isTrue);
      expect(virtualMachine.remoteWorkingDirectory, workingDirectory);
      expect(unsupportedVirtualMachine.isConversationAgent, isFalse);
    },
  );

  test('Hermes VM accepts only its fixed TUI Gateway runtime protocol', () {
    final workingDirectory = _guestPath(['workspace']);
    TargetCandidate candidate(String target, String protocol) =>
        TargetCandidate(
          target: target,
          label: target,
          kind: 'vm-cli',
          status: 'detected',
          configured: true,
          confidence: 1,
          binaryPath: _guestPath(['venv', 'bin', 'python']),
          adapterStatus: 'implemented',
          adapterCapabilities: const {'conversationDriver': 'implemented'},
          location: 'virtual-machine',
          runtimeConnection: {
            'kind': 'ssh',
            'host': 'orb',
            'user': 'agent-vm',
            'remoteExecutable': _guestPath(['venv', 'bin', 'python']),
            'workingDirectory': workingDirectory,
            'runtimeProtocol': protocol,
          },
        );

    expect(
      candidate(
        'hermes',
        'hermes-tui-gateway',
      ).hasValidVirtualMachineConnection,
      isTrue,
    );
    expect(
      candidate(
        'openclaw',
        'hermes-tui-gateway',
      ).hasValidVirtualMachineConnection,
      isFalse,
    );
    expect(
      candidate('hermes', 'arbitrary-command').hasValidVirtualMachineConnection,
      isFalse,
    );
  });
}

String _guestPath(List<String> segments) => ['', ...segments].join('/');
