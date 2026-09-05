import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';

void main() {
  test(
    'adaptive projection owns immutable semantic collections and equality',
    () {
      final definitions = <AdaptiveFlywheelDefinitionProjection>[
        const AdaptiveFlywheelDefinitionProjection(
          id: 'definition',
          name: 'Synthetic Graph',
          version: '1.0.0',
          revision: 'revision-a',
          authorized: false,
        ),
      ];
      final first = AdaptiveFlywheelProjection(
        definitions: definitions,
        selectedRevision: 'revision-a',
        inspection: null,
        callableAgents: const [],
        assistant: const AdaptiveFlywheelAssistantProjection.empty(),
        busy: false,
        error: '',
      );
      definitions.clear();
      final second = AdaptiveFlywheelProjection(
        definitions: const [
          AdaptiveFlywheelDefinitionProjection(
            id: 'definition',
            name: 'Synthetic Graph',
            version: '1.0.0',
            revision: 'revision-a',
            authorized: false,
          ),
        ],
        selectedRevision: 'revision-a',
        inspection: null,
        callableAgents: const [],
        assistant: const AdaptiveFlywheelAssistantProjection.empty(),
        busy: false,
        error: '',
      );

      expect(first.definitions, hasLength(1));
      expect(() => first.definitions.clear(), throwsUnsupportedError);
      expect(first, second);
      expect(first.hashCode, second.hashCode);
    },
  );

  test(
    'composition projects graph facts and preserves binding call order',
    () async {
      final runner = _AdaptiveRunner();
      final service = AgentService(
        processIo: runner,
        persistentStdioRpcEnabled: false,
      );
      final controller = ClientController(agentService: service)
        ..scannedTargets = [_callableTarget()];
      final composition = AgentsFeatureComposition(controller);
      addTearDown(() async {
        await composition.close();
        controller.dispose();
        await service.dispose();
      });

      final initialized = composition.binding.projection.changes.firstWhere(
        (update) =>
            !update.value.adaptiveFlywheel.busy &&
            update.value.adaptiveFlywheel.inspection != null,
      );
      composition.binding.intents.send(const InitializeAdaptiveFlywheel());
      final projection = (await initialized).value.adaptiveFlywheel;

      expect(projection.definitions.single.name, 'Synthetic Graph');
      expect(projection.selectedRevision, 'revision-a');
      expect(projection.inspection!.states.map((state) => state.id), [
        'authorize',
        'complete',
      ]);
      expect(projection.callableAgents.single.id, 'codex');
      expect(projection.callableAgents.single.models.single.id, 'gpt-5');
      expect(projection.callableAgents.single.models.single.reasoningEfforts, [
        'medium',
        'high',
      ]);
      await pumpEventQueue();

      final effects = <AgentsEffect>[];
      final effectSubscription = composition.binding.effects.effects.listen(
        effects.add,
      );
      addTearDown(effectSubscription.cancel);
      composition.binding.intents.send(
        SaveAdaptiveFlywheelActorBindings(
          assignments: const [
            AdaptiveFlywheelAssignmentIntent(
              slotId: 'entry',
              ordinal: 0,
              agentId: 'codex',
              modelId: 'gpt-5',
              reasoningEffort: 'high',
            ),
          ],
        ),
      );
      await pumpEventQueue(times: 20);

      expect(runner.actions, [
        'strategy.definition.list',
        'strategy.definition.inspect',
        'strategy.binding.replace',
        'strategy.definition.inspect',
        'strategy.authorization.preview',
        'strategy.authorization.grant',
        'strategy.definition.inspect',
      ]);
      expect(
        effects.map(
          (effect) => switch (effect) {
            AdaptiveFlywheelActionRejected(:final reasonCode) => reasonCode,
            _ => effect.runtimeType.toString(),
          },
        ),
        ['AdaptiveFlywheelSaveCompleted'],
      );
      expect(effects.whereType<AdaptiveFlywheelSaveCompleted>(), hasLength(1));
    },
  );
}

final class _AdaptiveRunner implements AgentCommandRunner {
  final List<String> actions = [];
  Map<String, dynamic>? binding;
  bool authorized = false;

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    expect(args, ['strategy', 'execute', '--stdin-json', 'true']);
    final request = Map<String, dynamic>.from(jsonDecode(stdinText) as Map);
    final action = request['action'].toString();
    actions.add(action);
    final result = switch (action) {
      'strategy.definition.list' => [_definition],
      'strategy.definition.inspect' => _inspection(),
      'strategy.binding.replace' => _replace(request),
      'strategy.authorization.preview' => {
        'authorizationDigest': List.filled(64, 'a').join(),
      },
      'strategy.authorization.grant' => _authorize(),
      _ => throw StateError('unexpected action $action'),
    };
    return {'ok': true, 'result': result};
  }

  List<Map<String, dynamic>> _replace(Map<String, dynamic> request) {
    final candidate = Map<String, dynamic>.from(
      (request['candidates'] as List).single as Map,
    );
    binding = {
      'slotId': request['slotId'],
      'ordinal': 0,
      'valueId': candidate['valueId'],
      'model': candidate['model'],
      'reasoningEffort': candidate['reasoningEffort'],
      'revision': 1,
    };
    return [binding!];
  }

  Map<String, dynamic> _authorize() {
    authorized = true;
    return {'active': true};
  }

  Map<String, dynamic> _inspection() => {
    'projection': {
      'status': authorized ? 'pending' : 'authorization-required',
      'currentStates': const <String>[],
      'neighborStates': const <String>[],
      'allowedOperations': [
        'strategy.definition.inspect',
        if (binding != null && !authorized) 'strategy.authorization.grant',
        if (authorized) 'strategy.run.start',
      ],
      'bindings': [?binding],
    },
    'workflow': {
      'initial': 'authorize',
      'actorSlots': const [
        {
          'id': 'entry',
          'kind': 'actor',
          'label': 'Entry',
          'required': true,
          'entry': true,
        },
      ],
      'states': const [
        {'id': 'authorize', 'kind': 'authorization', 'label': 'Authorize'},
        {'id': 'complete', 'kind': 'succeed', 'label': 'Complete'},
      ],
      'transitions': const [
        {'from': 'authorize', 'to': 'complete', 'event': 'success'},
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      throw UnimplementedError();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

const _definition = <String, dynamic>{
  'definitionId': 'synthetic',
  'name': 'Synthetic Graph',
  'version': '1.0.0',
  'revisionDigest': 'revision-a',
  'semanticsDigest': 'semantics-a',
};

TargetCandidate _callableTarget() => TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/codex',
  adapterStatus: 'implemented',
  adapterCapabilities: const {'conversationDriver': 'implemented'},
  modelCatalog: const {
    'models': [
      {
        'name': 'gpt-5',
        'displayName': 'GPT-5',
        'reasoningEfforts': ['medium', 'high'],
        'defaultReasoningEffort': 'medium',
      },
    ],
  },
);
