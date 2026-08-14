import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_controller.dart';
import 'package:licoup/src/application/features/agents/contracts/adaptive_flywheel_gateway.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_dialog.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  test('loads, binds, and authorizes an immutable Graph', () async {
    final runner = _StrategyRunner();
    final controller = AdaptiveFlywheelController(gateway: runner);

    await controller.initialize();
    expect(controller.definitions.single.name, 'LicoUp Basic Strategy');
    expect(controller.inspection?.states.map((state) => state.id), [
      'authorize',
      'work',
      'complete',
    ]);

    await controller.saveActorBindings({
      for (final slot in const ['designer', 'worker', 'reviewer'])
        slot: AdaptiveFlywheelBinding(
          slotId: slot,
          valueId: 'codex',
          model: 'gpt-5',
          reasoningEffort: 'high',
        ),
    });
    expect(runner.actions, contains('strategy.binding.update'));
    expect(
      runner.actions,
      containsAll([
        'strategy.authorization.preview',
        'strategy.authorization.grant',
      ]),
    );
    expect(runner.actions, isNot(contains('strategy.runtime.discover')));
    expect(runner.actions, isNot(contains('strategy.run.start')));
  });

  test(
    'leaves authorization pending when no compatible runtime is detected',
    () async {
      final runner = _StrategyRunner(includeRuntime: false);
      final controller = AdaptiveFlywheelController(gateway: runner);

      await controller.initialize();
      await controller.saveActorBindings({
        for (final slot in const ['designer', 'worker', 'reviewer'])
          slot: AdaptiveFlywheelBinding(slotId: slot, valueId: 'codex'),
      });

      expect(controller.inspection?.diagnosticCode, 'binding_incomplete');
      expect(runner.actions, isNot(contains('strategy.authorization.preview')));
      expect(runner.actions, isNot(contains('strategy.authorization.grant')));
    },
  );

  testWidgets('restores the capsule editor and filters uncallable Agents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runner = _StrategyRunner();
    final agentService = AgentService(
      processIo: runner,
      persistentStdioRpcEnabled: false,
    );
    final clientController = ClientController(agentService: agentService);
    clientController.scannedTargets = [
      _target('codex', callable: true),
      _target('unadapted', callable: false),
    ];
    addTearDown(clientController.dispose);
    addTearDown(agentService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: const [Locale('zh')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showAdaptiveFlywheelDialog(context, clientController),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('adaptive-flywheel-dialog')), findsOneWidget);
    expect(
      find.byKey(const Key('adaptive-flywheel-import-package')),
      findsOneWidget,
    );
    expect(find.text('设计师'), findsOneWidget);
    expect(find.text('执行者'), findsOneWidget);
    expect(find.text('审查官'), findsOneWidget);
    expect(find.text('Focused acceptance'), findsNothing);
    expect(find.text('Python runtime'), findsNothing);
    expect(find.textContaining('new'), findsNothing);
    expect(find.text('状态机 Graph'), findsNothing);

    await tester.tap(find.byKey(const Key('adaptive-flywheel-workflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('adaptive-flywheel-workflow-diagram')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workflow-node-authorize')), findsOneWidget);
    expect(find.byKey(const Key('workflow-node-work')), findsOneWidget);
    expect(find.byKey(const Key('workflow-node-complete')), findsOneWidget);
    await tester.tap(find.byKey(const Key('adaptive-flywheel-workflow-close')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('adaptive-flywheel-designer-add')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('adaptive-flywheel-designer-option-codex')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('adaptive-flywheel-designer-option-unadapted')),
      findsNothing,
    );
    expect(runner.actions, isNot(contains('strategy.runtime.discover')));
    expect(runner.actions, isNot(contains('strategy.run.start')));
  });
}

final class _StrategyRunner
    implements AgentCommandRunner, AdaptiveFlywheelGateway {
  _StrategyRunner({this.includeRuntime = true});

  final bool includeRuntime;
  final List<String> actions = [];
  final Map<String, Map<String, dynamic>> bindings = {};
  bool authorized = false;

  @override
  Future<Object?> execute(Map<String, dynamic> request) async {
    final output = await runCliWithStdin(const [
      'strategy',
      'execute',
      '--stdin-json',
      'true',
    ], jsonEncode(request));
    return output['result'];
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async {
    expect(args, ['strategy', 'execute', '--stdin-json', 'true']);
    final request = jsonDecode(stdinText) as Map<String, dynamic>;
    final action = request['action'] as String;
    actions.add(action);
    final result = switch (action) {
      'strategy.definition.list' => [_summary],
      'strategy.definition.inspect' => _inspection(),
      'strategy.binding.update' => _bind(request),
      'strategy.binding.remove' => _remove(request),
      'strategy.authorization.preview' => {
        'authorizationDigest': List.filled(64, 'a').join(),
      },
      'strategy.authorization.grant' => _authorize(),
      _ => throw StateError('unexpected action $action'),
    };
    return {'ok': true, 'result': result};
  }

  Map<String, dynamic> _bind(Map<String, dynamic> request) {
    authorized = false;
    final binding = <String, dynamic>{
      'slotId': request['slotId'],
      'valueId': request['valueId'],
      'model': request['model'],
      'reasoningEffort': request['reasoningEffort'],
      'revision': 1,
    };
    bindings[request['slotId'] as String] = binding;
    return binding;
  }

  Map<String, dynamic> _remove(Map<String, dynamic> request) {
    bindings.remove(request['slotId']);
    authorized = false;
    return {'removed': true};
  }

  Map<String, dynamic> _authorize() {
    authorized = true;
    return {'active': true};
  }

  Map<String, dynamic> _inspection() => {
    'projection': {
      'schema': 'licoup.adaptive-flywheel.state.v1',
      'definition': _summary,
      'status': authorized ? 'pending' : 'authorization-required',
      'currentStates': <String>[],
      'neighborStates': <String>[],
      'allowedOperations': [
        'strategy.definition.inspect',
        'strategy.binding.update',
        'strategy.binding.remove',
        if (_allBindingsComplete && !authorized) 'strategy.authorization.grant',
      ],
      'bindings': [
        ...bindings.values,
        if (includeRuntime)
          {
            'slotId': 'python',
            'valueId': 'runtime-python-fixture',
            'revision': 1,
          },
      ],
      if (!_allBindingsComplete) 'diagnostic': {'code': 'binding_incomplete'},
      'historyCount': 0,
    },
    'workflow': {
      'initial': 'authorize',
      'actorSlots': [
        {
          'id': 'designer',
          'kind': 'actor',
          'label': 'Designer',
          'required': true,
        },
        {'id': 'worker', 'kind': 'actor', 'label': 'Worker', 'required': true},
        {
          'id': 'reviewer',
          'kind': 'actor',
          'label': 'Reviewer',
          'required': true,
        },
        {
          'id': 'python',
          'kind': 'runtime',
          'label': 'Python runtime',
          'required': true,
        },
      ],
      'states': [
        {'id': 'authorize', 'kind': 'authorization', 'label': 'Authorize'},
        {'id': 'work', 'kind': 'actor', 'label': 'Work'},
        {'id': 'complete', 'kind': 'succeed', 'label': 'Complete'},
      ],
      'transitions': [
        {'from': 'authorize', 'to': 'work', 'event': 'success'},
        {'from': 'work', 'to': 'complete', 'event': 'success'},
      ],
    },
  };

  bool get _allActorsBound =>
      const ['designer', 'worker', 'reviewer'].every(bindings.containsKey);

  bool get _allBindingsComplete => _allActorsBound && includeRuntime;

  static const _summary = <String, dynamic>{
    'definitionId': 'licoup-basic',
    'name': 'LicoUp Basic Strategy',
    'version': '1.0.0',
    'revisionDigest': 'revision',
    'semanticsDigest': 'semantics',
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

TargetCandidate _target(String id, {required bool callable}) {
  return TargetCandidate(
    target: id,
    label: id == 'codex' ? 'Codex' : 'Unadapted',
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: callable ? '/synthetic/bin/$id' : null,
    adapterStatus: callable ? 'implemented' : 'unsupported',
    adapterCapabilities: {
      'conversationDriver': callable ? 'implemented' : 'unsupported',
    },
    modelCatalog: const {
      'models': [
        {
          'name': 'gpt-5',
          'displayName': 'GPT-5',
          'reasoningEfforts': ['medium', 'high'],
        },
      ],
    },
  );
}
