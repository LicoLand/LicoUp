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
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';

void main() {
  test('starts with an empty catalog until a package is imported', () async {
    final runner = _StrategyRunner(definitions: const []);
    final controller = AdaptiveFlywheelController(gateway: runner);

    await controller.initialize();
    expect(controller.definitions, isEmpty);
    expect(controller.inspection, isNull);
    expect(runner.actions, ['strategy.definition.list']);
  });

  test('loads, binds, and authorizes an immutable Graph', () async {
    final runner = _StrategyRunner();
    final controller = AdaptiveFlywheelController(gateway: runner);

    await controller.initialize();
    expect(controller.definitions.single.name, 'Synthetic Graph');
    expect(controller.inspection?.states.map((state) => state.id), [
      'authorize',
      'work',
      'complete',
    ]);

    await controller.saveActorBindings({
      for (final slot in const ['entry', 'worker-a'])
        slot: [
          AdaptiveFlywheelBinding(
            slotId: slot,
            valueId: 'codex',
            model: 'gpt-5',
            reasoningEffort: 'high',
          ),
        ],
    });
    expect(runner.actions, contains('strategy.binding.replace'));
    expect(runner.actions, isNot(contains('strategy.binding.update')));
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
        for (final slot in const ['entry', 'worker-a'])
          slot: [AdaptiveFlywheelBinding(slotId: slot, valueId: 'codex')],
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
    final selector = tester.getRect(
      find.byKey(const Key('adaptive-flywheel-definition')),
    );
    final import = tester.getRect(
      find.byKey(const Key('adaptive-flywheel-import-package')),
    );
    expect(selector.left, lessThan(import.left));
    expect(selector.height, kAdaptiveFlywheelToolbarControlHeight);
    expect(import.height, kAdaptiveFlywheelToolbarControlHeight);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('Entry'), findsOneWidget);
    expect(find.text('Worker A'), findsOneWidget);
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
    await tester.tap(find.byKey(const Key('adaptive-flywheel-workflow')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('adaptive-flywheel-workflow-diagram')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('adaptive-flywheel-entry-add')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('adaptive-flywheel-entry-option-codex')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('adaptive-flywheel-entry-option-unadapted')),
      findsNothing,
    );
    expect(runner.actions, isNot(contains('strategy.runtime.discover')));
    expect(runner.actions, isNot(contains('strategy.run.start')));
  });

  testWidgets('empty catalog asks the user to import a package first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runner = _StrategyRunner(definitions: const []);
    final agentService = AgentService(
      processIo: runner,
      persistentStdioRpcEnabled: false,
    );
    final clientController = ClientController(agentService: agentService);
    addTearDown(clientController.dispose);
    addTearDown(agentService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('zh')],
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

    expect(
      find.byKey(const Key('adaptive-flywheel-empty-catalog')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('adaptive-flywheel-definition')), findsNothing);
    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.textContaining('Import a ZIP package first'), findsWidgets);

    await tester.tap(find.byKey(const Key('adaptive-flywheel-empty-catalog')));
    await tester.pumpAndSettle();
    expect(find.byType(MessagingGlassOptionCard), findsOneWidget);
    expect(find.byType(MessagingGlassMenuItem), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  testWidgets('glass strategy selector can open and choose a definition', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runner = _StrategyRunner(
      definitions: [
        _StrategyRunner.summary,
        {
          'definitionId': 'imported-other',
          'name': 'Imported Other',
          'version': '2.0.0',
          'revisionDigest': 'revision-b',
          'semanticsDigest': 'semantics-b',
        },
      ],
    );
    final agentService = AgentService(
      processIo: runner,
      persistentStdioRpcEnabled: false,
    );
    final clientController = ClientController(agentService: agentService);
    addTearDown(clientController.dispose);
    addTearDown(agentService.dispose);

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: const [Locale('en'), Locale('zh')],
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

    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.text('Synthetic Graph · 1.0.0'), findsOneWidget);

    await tester.tap(find.byKey(const Key('adaptive-flywheel-definition')));
    await tester.pumpAndSettle();

    expect(find.byType(DropdownButton<String>), findsNothing);
    expect(find.byType(MessagingGlassOptionCard), findsOneWidget);
    expect(find.text('Imported Other · 2.0.0'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('adaptive-flywheel-option-revision-b')),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessagingGlassOptionCard), findsNothing);
    expect(find.text('Imported Other · 2.0.0'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
  });

  test('falls back when the selected revision leaves the catalog', () async {
    final runner = _StrategyRunner(
      definitions: [
        _StrategyRunner.summary,
        {
          'definitionId': 'imported-other',
          'name': 'Imported Other',
          'version': '2.0.0',
          'revisionDigest': 'revision-b',
          'semanticsDigest': 'semantics-b',
        },
      ],
    );
    final controller = AdaptiveFlywheelController(gateway: runner);

    await controller.initialize();
    expect(controller.selectedRevision, 'revision');

    runner.definitions.removeAt(0);
    await controller.refresh();
    expect(controller.selectedRevision, 'revision-b');
    expect(controller.error, isEmpty);

    runner.definitions.clear();
    await controller.refresh();
    expect(controller.selectedRevision, isEmpty);
    expect(controller.inspection, isNull);
    expect(controller.error, isEmpty);
  });
}

final class _StrategyRunner
    implements AgentCommandRunner, AdaptiveFlywheelGateway {
  _StrategyRunner({
    this.includeRuntime = true,
    List<Map<String, dynamic>>? definitions,
  }) : definitions = List<Map<String, dynamic>>.from(
         definitions ?? [_StrategyRunner.summary],
       );

  final bool includeRuntime;
  final List<Map<String, dynamic>> definitions;
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
    final Object result = switch (action) {
      'strategy.definition.list' => definitions,
      'strategy.definition.inspect' => _inspection(),
      'strategy.binding.update' => _bind(request),
      'strategy.binding.replace' => _replace(request),
      'strategy.binding.remove' => _remove(request),
      'strategy.authorization.preview' => {
        'authorizationDigest': List.filled(64, 'a').join(),
      },
      'strategy.authorization.grant' => _authorize(),
      _ => throw StateError('unexpected action $action'),
    };
    return {'ok': true, 'result': result};
  }

  List<Map<String, dynamic>> _replace(Map<String, dynamic> request) {
    authorized = false;
    final slotId = request['slotId'] as String;
    final candidates = (request['candidates'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .toList(growable: false);
    bindings.removeWhere((key, _) => key.startsWith('$slotId:'));
    final stored = <Map<String, dynamic>>[];
    for (var ordinal = 0; ordinal < candidates.length; ordinal += 1) {
      final candidate = candidates[ordinal];
      final binding = <String, dynamic>{
        'slotId': slotId,
        'ordinal': ordinal,
        'valueId': candidate['valueId'],
        'model': candidate['model'] ?? '',
        'reasoningEffort': candidate['reasoningEffort'] ?? '',
        'revision': 1,
      };
      bindings['$slotId:$ordinal'] = binding;
      stored.add(binding);
    }
    return stored;
  }

  Map<String, dynamic> _bind(Map<String, dynamic> request) {
    authorized = false;
    final binding = <String, dynamic>{
      'slotId': request['slotId'],
      'ordinal': 0,
      'valueId': request['valueId'],
      'model': request['model'],
      'reasoningEffort': request['reasoningEffort'],
      'revision': 1,
    };
    bindings['${request['slotId']}:0'] = binding;
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
      'definition': _StrategyRunner.summary,
      'status': authorized ? 'pending' : 'authorization-required',
      'currentStates': <String>[],
      'neighborStates': <String>[],
      'allowedOperations': [
        'strategy.definition.inspect',
        'strategy.binding.replace',
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
          'id': 'entry',
          'kind': 'actor',
          'label': 'Entry',
          'required': true,
          'entry': true,
        },
        {
          'id': 'worker-a',
          'kind': 'actor',
          'label': 'Worker A',
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

  bool get _allActorsBound => const [
    'entry',
    'worker-a',
  ].every((slot) => bindings.keys.any((key) => key.startsWith('$slot:')));

  bool get _allBindingsComplete => _allActorsBound && includeRuntime;

  static const summary = <String, dynamic>{
    'definitionId': 'synthetic-entry-worker',
    'name': 'Synthetic Graph',
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
