import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/client_composition_set.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/llm_gateway_diagnostics.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_providers.dart';
import 'package:licoup/src/presentation/agents/agents_providers.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:licoup/src/presentation/models/models_providers.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_providers.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_providers.dart';
import 'package:licoup/src/presentation/search/search_providers.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_providers.dart';
import 'package:licoup/src/presentation/targets/targets_providers.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:riverpod/misc.dart' show Override, ProviderBase;

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../layout/fixtures/layout_destination_presentation_fixture.dart';
import '../layout/fixtures/production_client_shell_fixture.dart';

/// Composed-widget evidence for the minimum client composition.
///
/// The shell is mounted over a bounded controller whose native peer is a
/// scripted synthetic host: the three required operations are driven through
/// the rendered shell and each one is asserted at the owner that served it —
/// the conversation history read, the submitted local turn, and the stop of
/// that active turn. No live agent process, screenshot or golden file is used.
///
/// The same declaration is then proved closed: the composed client owns exactly
/// the features `ClientCompositionSet.minimum` names, an undeclared feature
/// installs no provider override and resolves to its documented disabled value,
/// and its destination renders as an empty surface.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a minimum composition opens history, submits a local conversation and '
    'stops the active turn',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final harness = await _ComposedShellHarness.create(
        tester,
        compositionSet: ClientCompositionSet.minimum,
      );
      addTearDown(() => harness.close(tester));

      await harness.mount(tester);
      await harness.openAgent(tester);
      expect(harness.controller.selectedConversationAgentId, 'codex');

      // The mounted composition owns exactly the declared features: every
      // declared owner is reachable and every undeclared one is not.
      for (final feature in _ClientFeature.values) {
        expect(
          _owns(harness.composition, feature),
          _declares(ClientCompositionSet.minimum, feature),
          reason: '${feature.name} owner',
        );
      }

      // The installed conversation feature serves the planes: the shell reads a
      // live owner, never the disabled port an uninstalled feature leaves.
      expect(
        harness.readConversationPort(tester),
        isNot(isA<DisabledConversationSourcePort>()),
        reason: 'the declared conversation owner must serve the plane port',
      );

      // 1. Opens history: the seeded native session reaches the shell through
      //    the conversation owner, and selecting it renders its stored
      //    messages.
      final sessionRow = find.byKey(
        const Key('agents-sidebar-conversation-session-one'),
      );
      expect(
        await harness.pumpUntil(tester, () => sessionRow.evaluate().isNotEmpty),
        isTrue,
        reason: 'the conversation owner must serve the native history catalog',
      );
      await tester.tap(sessionRow);
      await harness.pump(tester);
      expect(
        await harness.pumpUntil(
          tester,
          () => find.textContaining('Seeded question').evaluate().isNotEmpty,
        ),
        isTrue,
        reason: 'selecting the historical session must render its messages',
      );

      // 2. Submits a local conversation: the composed shell's composer sends
      //    one request to the native owner and the rendered turn follows it.
      await harness.startNewConversation(tester);
      await harness.send(tester, 'First question');
      expect(harness.host.requests, hasLength(1));
      expect(harness.host.requests.first['text'], 'First question');
      expect(
        await harness.pumpUntil(
          tester,
          () => find
              .textContaining('Reply 1', findRichText: true)
              .evaluate()
              .isNotEmpty,
        ),
        isTrue,
        reason: 'the native stream must reach the conversation plane and frame',
      );

      // 3. Stops the active turn: the same control cancels that exact turn.
      await tester.tap(
        find.byKey(const Key('agent-conversation-composer-send')),
      );
      await harness.pump(tester);
      expect(harness.host.runtimeCancelCalls, 1);
      expect(harness.controller.isSendingConversationMessage, isFalse);
      expect(tester.takeException(), isNull);

      await harness.close(tester);
    },
  );

  testWidgets('a feature the declaration does not name has no owner, no '
      'override and no surface', (tester) async {
    final set = ClientCompositionSet.minimum;
    final harness = await _ComposedShellHarness.create(
      tester,
      compositionSet: set,
    );
    addTearDown(() => harness.close(tester));

    // 1. No owner: every declared feature exposes its binding and every
    //    undeclared feature exposes none, so a composition that constructs
    //    fewer owners than the declaration names fails here as well.
    final declared = {
      for (final feature in _ClientFeature.values)
        if (_declares(set, feature)) feature,
    };
    final owned = {
      for (final feature in _ClientFeature.values)
        if (_owns(harness.composition, feature)) feature,
    };
    expect(
      declared,
      const {
        _ClientFeature.agents,
        _ClientFeature.conversation,
        _ClientFeature.targets,
        _ClientFeature.chrome,
        _ClientFeature.monitoring,
        _ClientFeature.mobileRelay,
      },
      reason:
          'the minimum set is the three required features, the relay the '
          'agents destination frames through, and the shell owners',
    );
    expect(owned, declared);

    // 2. No provider override: an undeclared feature installs nothing, and a
    //    state read of one of its providers resolves to that feature's
    //    documented disabled value instead of a live owner.
    final container = ProviderContainer(
      overrides: harness.composition.presentationOverrides,
    );
    addTearDown(container.dispose);
    final overridden = harness.composition.presentationOverrides
        .map((Override override) => override.origin)
        .toSet();
    for (final feature in _ClientFeature.values) {
      final provider = _sourceProviderOf(feature);
      if (provider == null) continue;
      expect(
        overridden.contains(provider),
        _declares(set, feature),
        reason: '${feature.name} provider override',
      );
      if (!_declares(set, feature)) {
        expect(
          await _resolvesToDisabledValue(container, provider),
          isTrue,
          reason: '${feature.name} state read',
        );
      }
    }

    // 3. No surface: a destination whose feature was not installed renders as
    //    an empty surface, while an installed destination renders.
    for (final section in const <ClientSection>[
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.models,
      ClientSection.settings,
      ClientSection.agentHub,
    ]) {
      await harness.showDestination(tester, section);
      expect(
        harness.destinationSurface(tester),
        Size.zero,
        reason: 'the ${section.name} destination of an absent feature',
      );
    }
    await harness.showDestination(tester, ClientSection.agents);
    expect(
      harness.destinationSurface(tester),
      isNot(Size.zero),
      reason: 'the installed agents destination renders its surface',
    );
    expect(tester.takeException(), isNull);

    await harness.close(tester);
  });
}

/// One feature composition the composition root can own.
enum _ClientFeature {
  agents,
  conversation,
  targets,
  chrome,
  monitoring,
  agentHub,
  mobileRelay,
  models,
  pluginManagement,
  search,
  settings,
  skillHub,
}

bool _declares(ClientCompositionSet set, _ClientFeature feature) =>
    switch (feature) {
      _ClientFeature.agents => set.agents,
      _ClientFeature.conversation => set.conversation,
      _ClientFeature.targets => set.targets,
      _ClientFeature.chrome => set.chrome,
      _ClientFeature.monitoring => set.monitoring,
      _ClientFeature.agentHub => set.agentHub,
      _ClientFeature.mobileRelay => set.mobileRelay,
      _ClientFeature.models => set.models,
      _ClientFeature.pluginManagement => set.pluginManagement,
      _ClientFeature.search => set.search,
      _ClientFeature.settings => set.settings,
      _ClientFeature.skillHub => set.skillHub,
    };

/// Reads the binding the composition exposes for one feature.
Object _ownerOf(ClientAppComposition composition, _ClientFeature feature) =>
    switch (feature) {
      _ClientFeature.agents => composition.agents,
      _ClientFeature.conversation => composition.conversation,
      _ClientFeature.targets => composition.targets,
      _ClientFeature.chrome => composition.chrome,
      _ClientFeature.monitoring => composition.monitoring,
      _ClientFeature.agentHub => composition.agentHub,
      _ClientFeature.mobileRelay => composition.mobileRelay,
      _ClientFeature.models => composition.models,
      _ClientFeature.pluginManagement => composition.pluginManagement,
      _ClientFeature.search => composition.search,
      _ClientFeature.settings => composition.settings,
      _ClientFeature.skillHub => composition.skillHub,
    };

bool _owns(ClientAppComposition composition, _ClientFeature feature) {
  try {
    _ownerOf(composition, feature);
    return true;
  } catch (_) {
    return false;
  }
}

/// The provider a feature's presentation region reads, or null for the
/// shell-owned chrome composition, which the renderer consumes directly.
ProviderBase<Object?>? _sourceProviderOf(_ClientFeature feature) =>
    switch (feature) {
      _ClientFeature.agents => agentsCatalogSourceProvider,
      _ClientFeature.conversation => conversationSourcePortProvider,
      _ClientFeature.targets => targetsCatalogSourceProvider,
      _ClientFeature.monitoring => monitoringUsageSourceProvider,
      _ClientFeature.agentHub => agentHubCatalogSourceProvider,
      _ClientFeature.mobileRelay => mobileRelayPairingSourceProvider,
      _ClientFeature.models => modelsCatalogSourceProvider,
      _ClientFeature.pluginManagement => pluginCatalogSourceProvider,
      _ClientFeature.search => searchSourceProvider,
      _ClientFeature.settings => settingsGeneralSourceProvider,
      _ClientFeature.skillHub => skillHubCatalogSourceProvider,
      _ClientFeature.chrome => null,
    };

/// Whether an uninstalled feature's provider read fails to resolve or resolves
/// to a source that cannot open — its documented disabled value.
Future<bool> _resolvesToDisabledValue(
  ProviderContainer container,
  ProviderBase<Object?> provider,
) async {
  final Object? resolved;
  try {
    resolved = container.read(provider);
  } catch (_) {
    return true;
  }
  try {
    await (resolved! as PresentationSource<Object?>).open();
    return false;
  } catch (_) {
    return true;
  }
}

/// The composed shell over a bounded controller and a scripted native peer.
final class _ComposedShellHarness {
  _ComposedShellHarness._(
    this._root,
    this.host,
    this.controller,
    this.composition,
  );

  static Future<_ComposedShellHarness> create(
    WidgetTester tester, {
    required ClientCompositionSet compositionSet,
  }) async {
    final created = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp(
        'minimum-shell-composition-',
      );
      final host = _SyntheticHost()..seedHistory();
      final controller = ClientController(
        agentService: host,
        portableData: PortableDataRoot(dataDirectoryOverride: root),
        memoryDiagnosticSink: const NoopClientMemoryDiagnosticSink(),
        presentationPreferencesRepository:
            InMemoryPresentationPreferencesRepository(_fixturePreferences()),
        llmGatewayMonitorInterval: Duration.zero,
        llmGatewayRecoveryRetryDelay: Duration.zero,
        llmGatewayDiagnosticSink: const NoopLlmGatewayDiagnosticSink(),
      );
      controller.scannedTargets = [_codexTarget()];
      await controller.layoutManager.initialize();
      final composition = ClientAppComposition(
        controller: controller,
        compositionSet: compositionSet,
      );
      return (root, host, controller, composition);
    });
    final (root, host, controller, composition) = created!;
    return _ComposedShellHarness._(root, host, controller, composition);
  }

  final Directory _root;
  final _SyntheticHost host;
  final ClientController controller;
  final ClientAppComposition composition;

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: composition.presentationOverrides,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<Object?>>[
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: ClientShell(
            binding: composition.binding,
            renderer: composition.renderer,
          ),
        ),
      ),
    );
    await pump(tester);
  }

  /// Selects the only agent so the shell shows its conversation surface.
  Future<void> openAgent(WidgetTester tester) async {
    final contact = find.text('Codex');
    expect(
      await pumpUntil(tester, () => contact.evaluate().isNotEmpty),
      isTrue,
      reason: 'the agents destination must render the seeded agent',
    );
    await tester.tap(contact.last);
    await pump(tester);
  }

  /// Starts a new local conversation from the shell's own control.
  Future<void> startNewConversation(WidgetTester tester) async {
    final create = find.byKey(const Key('messaging-create-conversation'));
    expect(
      await pumpUntil(tester, () => create.evaluate().isNotEmpty),
      isTrue,
      reason: 'the agents destination must offer the new-conversation control',
    );
    await tester.tap(create);
    await pump(tester);
    final newChat = find.text('New Chat');
    expect(
      await pumpUntil(tester, () => newChat.evaluate().isNotEmpty),
      isTrue,
    );
    await tester.tap(newChat.last);
    await pump(tester);
  }

  Future<void> send(WidgetTester tester, String text) async {
    final field = find.byKey(const Key('agent-conversation-composer-field'));
    expect(
      await pumpUntil(tester, () => field.evaluate().isNotEmpty),
      isTrue,
      reason: 'the conversation owner must expose its composer',
    );
    await tester.enterText(field, text);
    await pump(tester);
    await tester.tap(find.byKey(const Key('agent-conversation-composer-send')));
    await pump(tester);
  }

  /// Streams and storage flushes use real time, so pump bounded frames instead
  /// of settling on a synthetic clock.
  Future<void> pump(WidgetTester tester) async {
    for (var frame = 0; frame < 15; frame += 1) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 2)),
      );
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Reads the conversation plane port the composition bound at the root.
  ConversationSourcePort readConversationPort(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    return container.read(conversationSourcePortProvider);
  }

  /// Renders one shell destination through the renderer's own resolution.
  Future<void> showDestination(
    WidgetTester tester,
    ClientSection section,
  ) async {
    final agentsHomeKey = composition.renderer.createAgentsHomeKey();
    await tester.pumpWidget(
      ProviderScope(
        overrides: composition.presentationOverrides,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('en'),
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<Object?>>[
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.light,
          ).copyWith(platform: TargetPlatform.macOS),
          home: Scaffold(
            body: Center(
              // The installed agents destination renders through the layout
              // presentation scope the shell host normally supplies.
              child: FixtureLayoutPresentationScope(
                child: KeyedSubtree(
                  key: _destinationSurfaceKey,
                  child: Builder(
                    builder: (context) => composition.renderer.buildDestination(
                      context,
                      section,
                      agentsHomeKey: agentsHomeKey,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await pump(tester);
  }

  /// The size one rendered destination occupies: an absent feature's surface
  /// stays empty, an installed one renders its destination.
  Size destinationSurface(WidgetTester tester) =>
      tester.getSize(find.byKey(_destinationSurfaceKey));

  Future<bool> pumpUntil(
    WidgetTester tester,
    bool Function() ready, {
    int maxFrames = 80,
  }) async {
    for (var frame = 0; frame < maxFrames && !ready(); frame += 1) {
      await pump(tester);
    }
    return ready();
  }

  /// Unmounts the composed tree, lets its provider-owned workers shut down, and
  /// only then releases the composition and the bounded data root.
  Future<void> close(WidgetTester tester) async {
    if (_closed) return;
    _closed = true;
    host.finish();
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(tester);
    await tester.runAsync(() async {
      await composition.dispose();
      await controller.close();
      if (_root.existsSync()) _root.deleteSync(recursive: true);
    });
  }

  bool _closed = false;
}

/// The key of the mounted destination surface, so its size can be measured.
const Key _destinationSurfaceKey = Key('minimum-composition-destination');

/// A scripted native peer: one accepted local turn that stays open until the
/// caller finishes it or the shell cancels it.
final class _SyntheticHost extends FakeAgentService {
  static const String sessionId = 'session-one';

  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  Completer<void>? _terminal;
  bool _cancelled = false;

  void finish() {
    if (_terminal?.isCompleted == false) _terminal!.complete();
  }

  /// Seeds the native history the shell must be able to open.
  void seedHistory() {
    conversationSessions = {
      'codex': [
        {
          'id': sessionId,
          'nativeSessionId': sessionId,
          'agentId': 'codex',
          'title': 'Seeded question',
          'sourceKind': 'codex-native-history',
          'importMode': 'precise-adapter',
          'sourceTool': 'codex',
          'createdAt': '2030-01-01T00:00:00Z',
          'updatedAt': '2030-01-01T00:00:01Z',
          'messages': const [
            {
              'id': 'seeded-user',
              'role': 'user',
              'text': 'Seeded question',
              'createdAt': '2030-01-01T00:00:00Z',
            },
            {
              'id': 'seeded-assistant',
              'role': 'assistant',
              'text': 'Seeded answer',
              'createdAt': '2030-01-01T00:00:01Z',
            },
          ],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> handleFakeConversationCommand(
    ConversationProtocolMethod method,
    Map<String, dynamic> request,
  ) async {
    if (method == ConversationProtocolMethod.agentConversationCancel) {
      runtimeCancelCalls += 1;
      lastRuntimeCancelRequest = request;
      _cancelled = true;
      finish();
      return {'ok': true, 'status': 'cancel_requested'};
    }
    return super.handleFakeConversationCommand(method, request);
  }

  @override
  Stream<Map<String, dynamic>> streamFakeConversation(
    ConversationProtocolMethod method,
    Map<String, dynamic> request,
  ) async* {
    expect(method, ConversationProtocolMethod.agentConversationSend);
    requests.add(request);
    final turn = requests.length;
    final reply = 'Reply $turn';
    _terminal = Completer<void>();
    _cancelled = false;
    Map<String, dynamic> event(String kind, Map<String, dynamic> payload) => {
      'event': kind,
      'sessionId': sessionId,
      'turnId': 'turn-$turn',
      'turnHandle': 'handle-$turn',
      'conversationId': 'conversation-one',
      'membershipId': 'member-one',
      'payload': payload,
    };
    yield event('agent.turn.accepted', {
      'status': 'accepted',
      'lifecyclePrefix': ['submitted', 'accepted'],
    });
    yield event('agent.message.chunk', {
      'text': reply,
      'messageUnit': 'answer',
      'lifecyclePrefix': ['submitted', 'accepted', 'processing', 'responding'],
    });
    await _terminal!.future;
    yield event('conversation.user.message', {
      'text': request['text'],
      'role': 'user',
      'lifecyclePrefix': ['submitted'],
      'turnState': {
        'state': _cancelled ? 'cancelled' : 'succeeded',
        'inputEnabled': true,
        'cancelEnabled': false,
      },
    });
    yield {
      ...event('done', const <String, dynamic>{}),
      'ok': !_cancelled,
      'nativeSessionId': sessionId,
      'text': reply,
      'turnStatus': _cancelled ? 'cancelled' : 'completed',
      'terminalTransition': {'kind': _cancelled ? 'cancelled' : 'succeeded'},
    };
  }
}

PresentationPreferences _fixturePreferences() => PresentationPreferences(
  layoutProfileId: LayoutProfileId.parse('dashboard'),
  appearancePresetId: AppearancePresetIds.defaultSystem,
  localePreference: LocalePreference.english,
);

TargetCandidate _codexTarget() => TargetCandidate(
  target: 'codex',
  label: 'Codex',
  kind: 'cli',
  status: 'detected',
  configured: true,
  confidence: 1,
  binaryPath: '/synthetic/bin/codex',
  adapterStatus: 'implemented',
  adapterCapabilities: const <String, dynamic>{
    'conversationDriver': 'implemented',
    'conversationReadiness': 'ready',
  },
);
