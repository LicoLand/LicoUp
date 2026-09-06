import 'dart:convert';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/presentation/targets/targets_effect.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';
import 'package:licoup/src/projections/targets/targets_projection_producer.dart';

const _manualTargetOptions = <ManualTargetOptionProjection>[
  ManualTargetOptionProjection(id: 'antigravity', label: 'Antigravity'),
  ManualTargetOptionProjection(id: 'claude-code', label: 'Claude Code'),
  ManualTargetOptionProjection(id: 'codex', label: 'Codex'),
  ManualTargetOptionProjection(id: 'cursor', label: 'Cursor'),
  ManualTargetOptionProjection(id: 'copilot', label: 'GitHub Copilot'),
  ManualTargetOptionProjection(
    id: 'hermes',
    label: 'Hermes Agent',
    supportsVirtualMachine: true,
  ),
  ManualTargetOptionProjection(id: 'kilo-code', label: 'Kilo Code'),
  ManualTargetOptionProjection(id: 'kimi', label: 'Kimi'),
  ManualTargetOptionProjection(id: 'kimi-code', label: 'Kimi Code'),
  ManualTargetOptionProjection(
    id: 'openclaw',
    label: 'OpenClaw',
    supportsVirtualMachine: true,
  ),
  ManualTargetOptionProjection(id: 'opencode', label: 'OpenCode'),
];

final class TargetsFeatureComposition {
  TargetsFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _beginRendererIntent = beginRendererIntent {
    _projection = TargetsProjectionProducer(
      controller: controller.targetController,
      readSelectedTargetId: () => controller.selectedConversationAgentId,
      manualTargetOptions: _manualTargetOptions,
    );
    _effects = SemanticEffectChannel<TargetsEffect>();
    _intents = SemanticIntentChannel<TargetsIntent>(_handleIntent);
    binding = TargetsBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final TargetsProjectionProducer _projection;
  late final SemanticEffectChannel<TargetsEffect> _effects;
  late final SemanticIntentChannel<TargetsIntent> _intents;
  late final TargetsBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(TargetsIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    final owner = _controller.targetController;
    switch (intent) {
      case ScanTargets(:final force):
        await owner.scan(forceRescanKnown: force);
        _rejectOwnerFailure('', trace);
      case AddManualTarget(
        :final targetId,
        :final configPath,
        :final binaryPath,
        :final historyRoot,
        :final location,
        :final host,
        :final port,
        :final user,
        :final remoteExecutable,
        :final workingDirectory,
        :final runtimeProtocol,
      ):
        await owner.addManualTarget(
          target: targetId,
          configPath: configPath,
          binaryPath: binaryPath,
          historyRoot: historyRoot,
          location: location,
          runtimeConnection: location == 'virtual-machine'
              ? <String, dynamic>{
                  'kind': 'ssh',
                  'host': host,
                  'port': ?port,
                  if (user.isNotEmpty) 'user': user,
                  'remoteExecutable': remoteExecutable,
                  'workingDirectory': workingDirectory,
                  if (runtimeProtocol.isNotEmpty)
                    'runtimeProtocol': runtimeProtocol,
                }
              : const <String, dynamic>{},
        );
        _rejectOwnerFailure(targetId, trace);
      case SelectTarget(:final targetId):
        await _controller.selectConversationAgent(targetId);
        _projection.refreshSelection(trace: trace);
      case ToggleTargetPinned(:final targetId):
        await owner.toggleConversationTargetPinned(targetId);
        _rejectOwnerFailure(targetId, trace);
      case InspectTarget(:final targetId):
        await owner.inspectTarget(targetId);
        if (owner.lastErrorCode.isNotEmpty || owner.inspection == null) {
          _rejectOwnerFailure(
            targetId,
            trace,
            fallback: 'target_inspect_failed',
          );
        } else {
          _effects.emit(
            TargetInspectionReady(
              targetId,
              const JsonEncoder.withIndent('  ').convert(owner.inspection),
              trace: trace,
            ),
          );
        }
    }
  }

  void _rejectOwnerFailure(
    String targetId,
    TraceContext? trace, {
    String fallback = '',
  }) {
    final reason = _controller.targetController.lastErrorCode.isNotEmpty
        ? _controller.targetController.lastErrorCode
        : fallback;
    if (reason.isEmpty) return;
    _effects.emit(TargetActionRejected(targetId, reason, trace: trace));
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
  }
}
