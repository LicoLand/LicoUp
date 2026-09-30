import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation/conversation_plane_builder.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shell/client_shell.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_source_port.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';

import '../fixtures/client_controller/support/fake_agent_service.dart';
import '../support/fake_conversation_transport.dart';

/// Hybrid acceptance evidence for the minimum action-to-frame path.
///
/// A shell action sent as a sealed `ConversationIntent` reaches the native port
/// as one typed operation with its exact session and turn scope; the admitted
/// native result becomes visible on its own plane while every neighbour keeps
/// object identity; and the frame rendered through `ConversationPlaneBuilder`
/// follows the admitted value and its withdrawal without re-reading a
/// projection owner.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('a shell action reaches its native owner as one typed operation', () {
    test('submit arrives as one send carrying its session scope', () async {
      final fixture = await _IntentFixture.create();
      addTearDown(fixture.dispose);

      fixture.composition.binding.intents.send(
        PostConversationMessage(
          conversationId: fixture.scopeKey,
          content: 'who owns this turn',
          addressedMembershipIds: const <String>[],
          dispatchCanonical: false,
        ),
      );
      await fixture.settleUntil(
        () => fixture.port.callsOf(NativeOperation.send).isNotEmpty,
      );

      expect(
        fixture.port.recordedMethods,
        <NativeOperation>[NativeOperation.send],
        reason: 'one action is one operation, and no other entry is touched',
      );
      final call = fixture.port.single(NativeOperation.send);
      expect(
        call.scope,
        isA<AgentConversationSessionScope>(),
        reason: 'the port receives a typed scope, never an argument array',
      );
      final session = call.scope as AgentConversationSessionScope;
      expect(session.agentId, 'codex');
      expect(
        session.sessionId,
        isEmpty,
        reason:
            'a first send opens the conversation, so it declares no session',
      );
      expect(call.text, 'who owns this turn');
    });

    test('cancel arrives as one typed turn scope', () async {
      final gate = Completer<void>();
      final fixture = await _IntentFixture.create(gate: gate);
      addTearDown(fixture.dispose);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      fixture.composition.binding.intents.send(
        PostConversationMessage(
          conversationId: fixture.scopeKey,
          content: 'start a turn',
          addressedMembershipIds: const <String>[],
          dispatchCanonical: false,
        ),
      );
      await fixture.settleUntil(
        () => fixture.port.callsOf(NativeOperation.send).isNotEmpty,
      );

      fixture.composition.binding.intents.send(
        const InterruptConversationTurn('new:codex', ''),
      );
      await fixture.settleUntil(
        () => fixture.port.callsOf(NativeOperation.cancel).isNotEmpty,
      );

      final cancel = fixture.port.single(NativeOperation.cancel);
      expect(
        cancel.scope,
        isA<AgentSessionTurnScope>(),
        reason: 'a cancel is one typed turn operation, not a command array',
      );
      final turn = cancel.scope as AgentSessionTurnScope;
      expect(turn.session.agentId, 'codex');
      expect(
        turn.session.sessionId,
        'session-one',
        reason: 'the native-declared session identity is what the port sees',
      );
      expect(turn.turnId, isEmpty);
      expect(fixture.port.recordedMethods, <NativeOperation>[
        NativeOperation.send,
        NativeOperation.cancel,
      ]);
    });

    test(
      'an approval decision resends the same turn with the tool allowed',
      () async {
        final gate = Completer<void>();
        final fixture = await _IntentFixture.create(
          gate: gate,
          streamEvents: const <Map<String, dynamic>>[
            <String, dynamic>{
              'event': 'permission.denied',
              'payload': <String, dynamic>{'toolName': 'shell.exec'},
            },
          ],
        );
        addTearDown(fixture.dispose);
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });

        fixture.composition.binding.intents.send(
          PostConversationMessage(
            conversationId: fixture.scopeKey,
            content: 'needs a tool',
            addressedMembershipIds: const <String>[],
            dispatchCanonical: false,
          ),
        );
        await fixture.settleUntil(
          () => fixture.service.runtimeMessageCalls == 1,
        );
        gate.complete();
        await fixture.settleUntil(
          () => !fixture.controller.isSendingConversationMessage,
        );

        fixture.composition.binding.intents.send(
          const RetryConversationPermission(remember: true),
        );
        await fixture.settleUntil(
          () => fixture.service.runtimeMessageCalls == 2,
        );

        final retry = fixture.port.last(NativeOperation.send);
        expect(retry.text, 'needs a tool');
        expect(retry.allowedTools, <String>['shell.exec']);
        expect(retry.scope, isA<AgentConversationSessionScope>());
        expect(
          fixture.port.callsOf(NativeOperation.cancel),
          isEmpty,
          reason: 'an approval decision is not a transport cancel',
        );
      },
    );
  });

  group('a native result is admitted to exactly its own plane', () {
    testWidgets('only the owning plane changes and the frame follows it', (
      tester,
    ) async {
      final harness = await _ComposedShellHarness.create(tester);
      addTearDown(() => harness.close(tester));

      // The composed shell itself is mounted: it reads the same bound owner.
      await harness.pump(tester);
      // The composed shell serves live planes: the root binds the runtime-backed
      // owner over this composition's producer channels, not the disabled port.
      final port = harness.readConversationPort(tester);
      expect(port, isNot(isA<DisabledConversationSourcePort>()));
      final runtime = harness.composition.presentationRuntime;
      final before = _PlaneIdentities.of(port, runtime);

      // One shell action, one admitting plane: the draft revision is admitted
      // to the composer plane while every other plane keeps object identity.
      harness.composition.conversation.intents.send(
        UpdateConversationDraft(harness.scopeKey, 'draft admitted here'),
      );
      await harness.advance(tester);
      expect(
        port.composer.visibleValue?.draft,
        'draft admitted here',
        reason: 'the admitted draft must reach its own plane',
      );
      before.expectChangedPlanes(
        port,
        runtime,
        changed: <String>[conversationPlaneComposer],
        reason: 'one action is admitted to one plane',
      );

      // The same composed shell carries the submit to its native owner as
      // exactly one typed operation.
      harness.composition.conversation.intents.send(
        PostConversationMessage(
          conversationId: harness.scopeKey,
          content: 'draft admitted here',
          addressedMembershipIds: const <String>[],
          dispatchCanonical: false,
        ),
      );
      await harness.advance(tester);
      expect(
        harness.port.recordedMethods,
        <NativeOperation>[NativeOperation.send],
        reason: 'the composed submit is one typed native operation',
      );
      final call = harness.port.single(NativeOperation.send);
      expect(call.scope, isA<AgentConversationSessionScope>());
      expect((call.scope as AgentConversationSessionScope).agentId, 'codex');
      expect(call.text, 'draft admitted here');
    });

    testWidgets('the rendered subtree follows admission and withdrawal', (
      tester,
    ) async {
      final harness = await _ComposedShellHarness.create(tester);
      addTearDown(() => harness.close(tester));

      await harness.pump(tester, mountShell: false);
      final port = harness.readConversationPort(tester);
      final runtime = harness.composition.presentationRuntime;

      harness.composition.conversation.intents.send(
        UpdateConversationDraft(harness.scopeKey, 'frame follows this'),
      );
      await harness.advance(tester);
      expect(port.composer.visibleValue?.draft, 'frame follows this');
      expect(find.text('draft:frame follows this'), findsOneWidget);
      expect(find.text('no conversation selected'), findsNothing);

      // A withdrawn plane renders its empty state, and the frame never falls
      // back to re-reading the projection owner that still holds the draft.
      runtime.revoke(port.composer.fieldGroup.resource);
      await harness.advance(tester);
      expect(port.composer.visibleValue, isNull);
      expect(find.text('draft:frame follows this'), findsNothing);
      expect(find.text('no conversation selected'), findsOneWidget);

      // A real producer read while withdrawn does not revive the plane.
      harness.composition.conversation.intents.send(
        UpdateConversationDraft(harness.scopeKey, 'revived by a producer read'),
      );
      await harness.advance(tester);
      expect(
        harness.controller.conversationPresentationSignals.composerDraftFor(
          harness.scopeKey,
        ),
        'revived by a producer read',
        reason: 'the projection owner does hold a new value',
      );
      expect(find.text('draft:revived by a producer read'), findsNothing);
      expect(find.text('no conversation selected'), findsOneWidget);
    });
  });
}

/// Every native operation the composed path can reach, including the generic
/// canonical-command entry, so an action that fell back to it is recorded
/// rather than invisible.
enum NativeOperation {
  open,
  send,
  cancel,
  steer,
  attach,
  active,
  cleanup,
  capabilities,

  /// The generic canonical-command entry. A stateful conversation action that
  /// reached this one is recorded here and fails the typed-operation oracle.
  clientCommand,
}

/// One recorded native operation with the typed scope it carried.
final class NativeCall {
  const NativeCall({
    required this.operation,
    required this.scope,
    this.text,
    this.allowedTools,
  });

  final NativeOperation operation;
  final Object scope;
  final String? text;
  final List<String>? allowedTools;
}

/// Recording [ConversationNativePort].
///
/// Every method delegates to the production stdio adapter over a synthetic
/// transport, so the composed path performs its real encoding while this
/// wrapper keeps the typed operation and the exact scope object it received.
/// The synthetic transport rejects a CLI argument array, so an implementation
/// that formatted one fails instead of passing silently.
final class RecordingConversationNativePort implements ConversationNativePort {
  RecordingConversationNativePort();

  ConversationNativePort? _delegate;

  /// Binds the synthetic endpoint after the service that owns its frames.
  void bind(ConversationNativePort delegate) => _delegate = delegate;

  ConversationNativePort get delegate =>
      _delegate ??
      (throw StateError('recording_port_unbound: bind the synthetic peer'));

  final List<NativeCall> calls = <NativeCall>[];

  List<NativeOperation> get recordedMethods =>
      calls.map((call) => call.operation).toList(growable: false);

  List<NativeCall> callsOf(NativeOperation operation) => calls
      .where((call) => call.operation == operation)
      .toList(growable: false);

  NativeCall single(NativeOperation operation) => callsOf(operation).single;

  NativeCall last(NativeOperation operation) => callsOf(operation).last;

  @override
  Future<Map<String, dynamic>> open(
    AgentConversationSessionScope session, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) {
    calls.add(NativeCall(operation: NativeOperation.open, scope: session));
    return delegate.open(session, bind: bind);
  }

  @override
  Stream<Map<String, dynamic>> send(
    AgentConversationSessionScope session, {
    required String text,
    List<ConversationAttachment> attachments = const [],
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) {
    calls.add(
      NativeCall(
        operation: NativeOperation.send,
        scope: session,
        text: text,
        allowedTools: bind.allowedTools,
      ),
    );
    return delegate.send(
      session,
      text: text,
      attachments: attachments,
      bind: bind,
    );
  }

  @override
  Future<Map<String, dynamic>> active({
    required String agentId,
    String sessionId = '',
    String conversationId = '',
    Duration waitForChange = Duration.zero,
  }) {
    calls.add(NativeCall(operation: NativeOperation.active, scope: agentId));
    return delegate.active(
      agentId: agentId,
      sessionId: sessionId,
      conversationId: conversationId,
      waitForChange: waitForChange,
    );
  }

  @override
  Stream<Map<String, dynamic>> attach(
    PersistentConversationTurnScope turn, {
    int afterCursor = 0,
  }) {
    calls.add(NativeCall(operation: NativeOperation.attach, scope: turn));
    return delegate.attach(turn, afterCursor: afterCursor);
  }

  @override
  Future<Map<String, dynamic>> steer(
    AgentConversationTurnScope turn, {
    required String text,
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) {
    calls.add(
      NativeCall(operation: NativeOperation.steer, scope: turn, text: text),
    );
    return delegate.steer(turn, text: text, bind: bind);
  }

  @override
  Future<Map<String, dynamic>> cancel(AgentConversationTurnScope turn) {
    calls.add(NativeCall(operation: NativeOperation.cancel, scope: turn));
    return delegate.cancel(turn);
  }

  @override
  Future<Map<String, dynamic>> cleanup(AgentConversationSessionScope session) {
    calls.add(NativeCall(operation: NativeOperation.cleanup, scope: session));
    return delegate.cleanup(session);
  }

  @override
  Future<Map<String, dynamic>> capabilities(
    String agentId, {
    AgentDispatchBind bind = const AgentDispatchBind(),
  }) {
    calls.add(
      NativeCall(operation: NativeOperation.capabilities, scope: agentId),
    );
    return delegate.capabilities(agentId, bind: bind);
  }

  @override
  Future<Map<String, dynamic>> executeClientConversation(
    ClientConversationCommand command,
  ) {
    calls.add(
      NativeCall(operation: NativeOperation.clientCommand, scope: command),
    );
    return delegate.executeClientConversation(command);
  }
}

/// The synthetic service whose own native port is the recording one.
///
/// [ClientController] builds its conversation service from
/// `agentService.conversationNativePort` and accepts an injected client port
/// only for the canonical branch, so the recording port is installed as the
/// service's own port for the semantic submit path to traverse it.
final class _RecordingFakeAgentService extends FakeAgentService {
  _RecordingFakeAgentService(this.recording);

  final RecordingConversationNativePort recording;

  @override
  ConversationNativePort get conversationNativePort => recording;
}

/// One plane's identity before an admission and the runtime snapshot it owned.
final class _PlaneIdentity {
  const _PlaneIdentity(this.plane, this.snapshot);

  final ConversationPlanePort<Object?> plane;
  final ResourceSnapshot<Object?>? snapshot;
}

/// Every conversation plane's object identity, captured for comparison.
final class _PlaneIdentities {
  const _PlaneIdentities(this._entries);

  static _PlaneIdentities of(
    ConversationSourcePort port,
    PresentationRuntime runtime,
  ) {
    final entries = <String, _PlaneIdentity>{};
    for (final entry in _planes(port)) {
      entries[entry.key] = _PlaneIdentity(
        entry.plane,
        runtime.current(entry.plane.fieldGroup),
      );
    }
    return _PlaneIdentities(entries);
  }

  static List<({String key, ConversationPlanePort<Object?> plane})> _planes(
    ConversationSourcePort port,
  ) => <({String key, ConversationPlanePort<Object?> plane})>[
    (key: conversationPlaneProjection, plane: port.projection),
    (key: conversationPlaneNativeCatalog, plane: port.nativeCatalog),
    (key: conversationPlaneCanonicalEvents, plane: port.canonicalEvents),
    (key: conversationPlanePersistentTurns, plane: port.persistentTurns),
    (key: conversationPlaneComposer, plane: port.composer),
    (key: conversationPlaneAttachments, plane: port.attachments),
    (key: conversationPlaneTabActivity, plane: port.tabActivity),
    (key: conversationPlaneArchive, plane: port.archive),
    if (port.execution != null)
      (key: conversationPlaneExecution, plane: port.execution!),
  ];

  final Map<String, _PlaneIdentity> _entries;

  int get length => _entries.length;

  /// Asserts exactly [changed] was admitted again: every other plane keeps its
  /// port object, its admitted value, and its runtime snapshot.
  void expectChangedPlanes(
    ConversationSourcePort port,
    PresentationRuntime runtime, {
    required List<String> changed,
    required String reason,
  }) {
    expect(length, 9, reason: 'all nine planes keep their own resource');
    final planes = _planes(port);
    final admitted = <String>[];
    for (final entry in planes) {
      final before = _entries[entry.key];
      expect(before, isNotNull, reason: 'plane ${entry.key}: $reason');
      expect(
        identical(entry.plane, before!.plane),
        isTrue,
        reason: 'plane ${entry.key} keeps its stable resource binding',
      );
      final snapshotChanged = !identical(
        runtime.current(entry.plane.fieldGroup),
        before.snapshot,
      );
      if (snapshotChanged) admitted.add(entry.key);
      if (!changed.contains(entry.key)) {
        expect(
          identical(entry.plane.visibleValue, before.plane.visibleValue),
          isTrue,
          reason: 'plane ${entry.key} must keep object identity: $reason',
        );
        expect(
          snapshotChanged,
          isFalse,
          reason: 'plane ${entry.key} must keep its admitted snapshot',
        );
      }
    }
    expect(
      admitted,
      changed,
      reason: 'only the owning plane is admitted again: $reason',
    );
  }
}

/// The headline intent path over the real application controller.
final class _IntentFixture {
  _IntentFixture._(this.controller, this.composition, this.service, this.port);

  static Future<_IntentFixture> create({
    Completer<void>? gate,
    List<Map<String, dynamic>> streamEvents = const [],
  }) async {
    final port = RecordingConversationNativePort();
    final service = _RecordingFakeAgentService(port)
      ..runtimeSessionIdResult = 'session-one'
      ..runtimeNativeSessionIdResult = 'session-one';
    port.bind(
      FakeConversationTransport(
        command: service.handleFakeConversationCommand,
        events: service.streamFakeConversation,
      ).native,
    );
    if (gate != null) service.runtimeMessageGate = gate;
    if (streamEvents.isNotEmpty) {
      service.runtimeMessageStreamEventQueue = <List<Map<String, dynamic>>>[
        streamEvents,
      ];
    }
    final controller = ClientController(
      agentService: service,
      conversationNativePort: port,
      mobileClientRuntimePlatformOverride: false,
    );
    controller
      ..scannedTargets = <TargetCandidate>[_codexTarget()]
      ..selectedConversationAgentId = 'codex';
    return _IntentFixture._(
      controller,
      ConversationFeatureComposition(controller),
      service,
      port,
    );
  }

  final ClientController controller;
  final ConversationFeatureComposition composition;
  final _RecordingFakeAgentService service;
  final RecordingConversationNativePort port;

  /// The composer scope key of the selected Conversation.
  String get scopeKey => controller.conversationComposerScopeKey;

  Future<void> settleUntil(
    bool Function() predicate, {
    int attempts = 120,
  }) async {
    for (var attempt = 0; attempt < attempts && !predicate(); attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(predicate(), isTrue);
  }

  Future<void> dispose() async {
    await composition.close();
    await controller.close();
  }
}

/// The composed minimum shell with its one app-scope presentation runtime.
final class _ComposedShellHarness {
  _ComposedShellHarness._(
    this.controller,
    this.composition,
    this.port,
    this._container,
    this._owner,
  );

  /// Builds the composed shell and its one plane owner with real asynchronous
  /// work allowed.
  ///
  /// Layout resolution, the app-scope runtime and the plane owner's resource
  /// handshake finish real futures, which a fake-async widget turn never
  /// advances. The owner is the composition's own binding, read once from the
  /// container that the mounted tree then uses, so exactly one owner serves the
  /// conversation planes.
  static Future<_ComposedShellHarness> create(WidgetTester tester) async {
    final created = await tester.runAsync(() async {
      final port = RecordingConversationNativePort();
      final service = _RecordingFakeAgentService(port)
        ..runtimeSessionIdResult = 'session-one'
        ..runtimeNativeSessionIdResult = 'session-one';
      port.bind(
        FakeConversationTransport(
          command: service.handleFakeConversationCommand,
          events: service.streamFakeConversation,
        ).native,
      );
      final controller = ClientController(
        agentService: service,
        conversationNativePort: port,
        mobileClientRuntimePlatformOverride: false,
        // Layout resolution must not depend on the host's own preferences file.
        presentationPreferencesRepository: const _MemoryPreferencesRepository(),
      );
      controller
        ..scannedTargets = <TargetCandidate>[_codexTarget()]
        ..selectedConversationAgentId = 'codex';
      await controller.layoutManager.initialize();
      final composition = ClientAppComposition(controller: controller);
      final container = ProviderContainer(
        overrides: composition.presentationOverrides,
      );
      final owner = container.read(conversationSourcePortProvider);
      // Admit the initial channel values while real time still passes.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return (controller, port, composition, container, owner);
    });
    final (controller, port, composition, container, owner) = created!;
    return _ComposedShellHarness._(
      controller,
      composition,
      port,
      container,
      owner,
    );
  }

  final ClientController controller;
  final ClientAppComposition composition;
  final RecordingConversationNativePort port;
  final ProviderContainer _container;
  final ConversationSourcePort _owner;
  bool _closed = false;

  /// The composer scope key of the selected Conversation.
  String get scopeKey => controller.conversationComposerScopeKey;

  /// Mounts the composed shell, or only the conversation plane frame.
  ///
  /// The mounted tree reads the same container the plane owner came from, so
  /// the shell and the frame observe one owner and one resource set.
  Future<void> pump(WidgetTester tester, {bool mountShell = true}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: _container,
        child: MaterialApp(
          supportedLocales: LicoStrings.supportedLocales,
          localizationsDelegates: const <LocalizationsDelegate<Object?>>[
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          theme: buildLicoTheme(
            platformBrightness: Brightness.dark,
          ).copyWith(platform: TargetPlatform.macOS),
          home: mountShell
              ? ClientShell(
                  binding: composition.binding,
                  renderer: composition.renderer,
                )
              : const _ConversationPlaneFrame(),
        ),
      ),
    );
    // Runtime admission completes only while real asynchronous work may run,
    // so the first frames alternate a real turn with a pumped frame.
    await _pumpFrames(tester, frames: 8);
  }

  /// The runtime-backed plane owner the composition bound at the root scope.
  ConversationSourcePort readConversationPort(WidgetTester tester) => _owner;

  /// Lets the dispatched action and its admission settle on real time.
  ///
  /// The frame budget is fixed: the composed path is driven structurally by the
  /// intents above, never by waiting on a condition.
  Future<void> advance(WidgetTester tester, {int frames = 24}) =>
      _pumpFrames(tester, frames: frames);

  /// Closes the owned graph with real asynchronous work allowed.
  Future<void> close(WidgetTester tester) async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpFrames(tester, frames: 2);
    await tester.runAsync(() async {
      _container.dispose();
      await composition.dispose();
    });
  }
}

/// One conversation plane rendered from the port composition bound at the root.
///
/// The frame reads that port and never a projection owner, so an admitted value
/// and a withdrawal are both visible here and a producer re-read is not.
class _ConversationPlaneFrame extends StatelessWidget {
  const _ConversationPlaneFrame();

  @override
  Widget build(BuildContext context) {
    final planes = conversationSourcePortOf(context);
    return Scaffold(
      body: ConversationPlaneBuilder<ComposerProjection, String>(
        plane: planes.composer,
        select: (composer) => composer.draft,
        builder: (context, draft) => Text('draft:$draft'),
        emptyBuilder: (context) => const Text('no conversation selected'),
      ),
    );
  }
}

/// Lets runtime admissions and widget rebuilds settle while real time passes.
Future<void> _pumpFrames(WidgetTester tester, {required int frames}) async {
  for (var frame = 0; frame < frames; frame++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 5));
  }
}

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
    'conversationProtocol': 'synthetic-native-protocol',
    'conversationReadiness': 'ready',
  },
);

/// Layout preferences held in memory so a fake-async widget test never waits
/// on a real file read.
final class _MemoryPreferencesRepository
    implements PresentationPreferencesRepository {
  const _MemoryPreferencesRepository();

  @override
  Future<PresentationPreferencesLoadResult> load() async =>
      PresentationPreferencesLoadResult(
        preferences: PresentationPreferences(
          layoutProfileId: LayoutProfileId.parse('dashboard'),
          appearancePresetId: AppearancePresetIds.defaultSystem,
          localePreference: LocalePreference.system,
        ),
      );

  @override
  Future<PresentationPreferences> setReduceMotion(bool enabled) async =>
      throw UnimplementedError();

  @override
  Future<PresentationPreferences> setLoadingEffect(String id) async =>
      throw UnimplementedError();

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) async =>
      throw UnimplementedError();

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) async =>
      throw UnimplementedError();

  @override
  Future<PresentationPreferences> setLocalePreference(
    String preference,
  ) async => throw UnimplementedError();
}
