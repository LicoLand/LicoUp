/// Process-free services for the design fixture: a synthetic AgentService
/// whose every command seam returns canned data, wired to
/// [FakeConversationTransport] so the production stdio adapter is exercised
/// without a CLI process.
///
/// Fail-closed contract: every production spawn lane that stays reachable
/// below the overrides is wired to a deny implementation that records the
/// attempt in [fixtureSpawnAttempts] and throws [StateError]. A missed path
/// crashes loudly instead of silently starting the native core or reading a
/// real Agent store.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/directory_opener.dart';
import 'package:licoup/src/contracts/generated/client_state.g.dart';
import 'package:licoup/src/contracts/generated/conversation_protocol.g.dart';
import 'package:licoup/src/contracts/presentation/built_in_layout_spec.dart';
import 'package:licoup/src/contracts/presentation/client_current_view.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/contracts/work_control_gateway.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/presentation/layout/built_in_layout_catalog.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/native_client/data_home_executor.dart';
import 'package:licoup/src/platform/native_client/native_cli_ports.dart';
import 'package:licoup/src/platform/runtime_platform_bridge.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

import '../../test/collaboration/support/collaboration_fixture.dart';
import '../../test/layout/fixtures/production_client_shell_fixture.dart'
    show InMemoryPresentationPreferencesRepository;
import '../../test/plugin_window/support/plugin_window_fixture.dart';
import '../../test/support/fake_conversation_transport.dart';

import 'fixture_data.dart';
import 'fixture_devices.dart';

const _fixtureLayout = String.fromEnvironment(
  'FIXTURE_LAYOUT',
  defaultValue: 'dashboard-a',
);
const _fixtureTheme = String.fromEnvironment(
  'FIXTURE_THEME',
  defaultValue: 'dark',
);

/// Dev-only destination selection (`--dart-define=FIXTURE_DESTINATION=<name>`):
/// after the first frame the fixture calls `controller.selectSection` — the
/// same call the shell destination intent makes — so a capture lands on a
/// chosen destination without synthetic clicks.
const _fixtureDestination = String.fromEnvironment('FIXTURE_DESTINATION');

/// The collaboration run bound to the group conversation.
final FakeCollaborationRunPort fixtureCollaborationPort =
    FakeCollaborationRunPort();

/// The plugin host publishing the two demo plugin windows.
final FakePluginWindowHostPort fixturePluginHost = FakePluginWindowHostPort();

/// Every native process spawn the fixture has blocked. Tests assert this
/// stays empty; at runtime each entry is also thrown as a [StateError].
final List<String> fixtureSpawnAttempts = <String>[];

/// The transport backing the conversation lane; its recorded `requests` are
/// the complete list of native conversation calls the fixture answered.
final FakeConversationTransport fixtureConversationTransport =
    FakeConversationTransport(command: _fixtureCommand, events: _fixtureEvents);

Never _denySpawn(String executable) {
  fixtureSpawnAttempts.add(executable);
  throw StateError('design fixture must not spawn processes: $executable');
}

/// Process context handed to every native component the fixture still
/// instantiates: the CLI binary never resolves, and any spawn attempt is a
/// recorded [StateError].
final class _FixtureProcessContext
    implements NativeCliProcessContext, NativeCliDataHomeMutationContext {
  const _FixtureProcessContext();

  @override
  Duration get requestTimeout => const Duration(seconds: 5);

  @override
  Future<File?> resolveCliBinary() async => null;

  @override
  Future<Map<String, String>?> buildEnvironment() async => const {};

  @override
  Future<Map<String, String>?> buildDataHomeMutationEnvironment() async =>
      const {};

  @override
  Future<Process> startProcess(
    String executable,
    List<String> arguments,
    Map<String, String>? environment, {
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => _denySpawn(executable);
}

final class _FixtureCommandExecutor implements NativeCommandExecutor {
  const _FixtureCommandExecutor();

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      _denySpawn('licoup ${arguments.join(' ')}');
}

/// Deny-all persistent transport: `rpc stdio`/`rpc conversation-host`
/// sessions are how the real native core gets started.
final class _FixtureRpcTransport implements NativeStdioRpcTransport {
  const _FixtureRpcTransport();

  @override
  Future<Map<String, dynamic>> execute(List<String> arguments) =>
      _denySpawn('licoup rpc stdio ${arguments.join(' ')}');

  @override
  Future<Map<String, dynamic>> executeStructured(
    String method,
    Map<String, dynamic> params,
  ) => _denySpawn('licoup rpc stdio ($method)');

  @override
  Stream<Map<String, dynamic>> streamConversation(
    Map<String, dynamic> request,
  ) => Stream.error(
    StateError(
      'design fixture must not spawn processes: licoup rpc '
      'conversation-host',
    ),
  );

  @override
  Future<void> dispose() async {}
}

/// Deny-all private runner lane (stdin writes, NDJSON streams, catalog and
/// MCP actions bottom out here).
final class _FixtureProcessIo implements AgentCommandRunner {
  const _FixtureProcessIo();

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) =>
      _denySpawn('licoup ${args.join(' ')}');

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => _denySpawn('licoup ${args.join(' ')} --stdin-json');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      Stream.error(
        StateError(
          'design fixture must not spawn processes: licoup '
          '${args.join(' ')}',
        ),
      );

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => Stream.error(
    StateError(
      'design fixture must not spawn processes: licoup '
      '${args.join(' ')} --stdin-json',
    ),
  );
}

/// Platform bridge without the `open`/`xdg-open`/`explorer` spawns.
final class _FixturePlatformBridge extends RuntimePlatformBridge {
  const _FixturePlatformBridge();

  @override
  Future<DirectoryOpenResult> openDirectory(String directoryPath) =>
      _denySpawn('open $directoryPath');

  @override
  Future<bool> openHttps(Uri uri) => _denySpawn('open $uri');
}

/// Open attach streams: each turn's initial frames are queued and the stream
/// stays open so the turns remain live for the fixture's lifetime.
final List<StreamController<Map<String, dynamic>>> _attachStreams = [];

Future<Map<String, dynamic>> _fixtureCommand(
  ConversationProtocolMethod method,
  Map<String, dynamic> params,
) async {
  switch (method) {
    case ConversationProtocolMethod.clientConversationExecute:
      return {
        'ok': true,
        'result': switch (params['action']) {
          'conversation.list' => fixtureConversationList(),
          'conversation.get' => fixtureConversationGet(),
          'conversation.events.page' => fixtureEventPage(),
          'list-pending-completion-notices' => {
            'pendingCompletionNotices': const <Object>[],
          },
          _ => const <String, dynamic>{},
        },
      };
    case ConversationProtocolMethod.agentConversationActive:
      return fixtureActiveTurns();
    default:
      return const {'ok': true};
  }
}

Stream<Map<String, dynamic>> _fixtureEvents(
  ConversationProtocolMethod method,
  Map<String, dynamic> params,
) {
  if (method != ConversationProtocolMethod.agentConversationAttach) {
    return const Stream.empty();
  }
  final controller = StreamController<Map<String, dynamic>>();
  _attachStreams.add(controller);
  scheduleMicrotask(() {
    if (controller.isClosed) return;
    for (final frame in fixtureAttachFrames(
      (params['turnHandle'] ?? '').toString(),
    )) {
      controller.add(frame);
    }
  });
  return controller.stream;
}

/// Synthetic [AgentService]: every seam that could reach a process is either
/// overridden with canned data or wired to a deny implementation that throws.
/// The fixture never spawns the CLI, the native core or a real Agent.
final class FixtureAgentService extends AgentService {
  FixtureAgentService()
    : super(
        conversationNativePort: fixtureConversationTransport.native,
        processContext: const _FixtureProcessContext(),
        oneShotCommandExecutor: const _FixtureCommandExecutor(),
        stdioRpcTransport: const _FixtureRpcTransport(),
        processIo: const _FixtureProcessIo(),
        workControlGateway: const UnavailableWorkControlGateway(),
        persistentStdioRpcEnabled: false,
      );

  final List<TargetCandidate> _targets = fixtureTargets();
  final FixtureDevicesCli _devices = FixtureDevicesCli();

  @override
  Future<Set<String>> targetCatalogIds() async =>
      _targets.map((target) => target.target).toSet();

  @override
  Future<List<TargetCandidate>> scanTargets() async => _targets;

  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(
        targetId: targetId,
        candidate: _targets
            .where((target) => target.target == targetId)
            .firstOrNull,
      ),
  ]);

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    final devices = _devices.answer(args);
    if (devices != null) return devices;
    if (args.length >= 2 && args[0] == 'agent-hub' && args[1] == 'catalog') {
      return fixtureAgentHubCatalog();
    }
    return const {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) async => _devices.answer(args, stdinText) ?? const {'ok': true};

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();

  @override
  Future<ClientStateGetResult> getClientState(
    ClientStateGetRequest request,
  ) async => ClientStateGetResult(
    collection: request.collection,
    document: ClientStateDocument(
      schemaVersion: clientStateSchemaVersion,
      collection: request.collection,
    ),
  );

  @override
  Future<ClientStateSetResult> setClientState(
    ClientStateSetRequest request,
  ) async => ClientStateSetResult(
    collection: request.collection,
    document: request.document,
    activity: ClientStateActivity(
      schemaVersion: clientStateSchemaVersion,
      eventId: 'fixture-state-write',
      type: 'set',
      target: request.document.collection.wireName,
      createdAt: '1970-01-01T00:00:00.000Z',
    ),
  );

  // Data-home executors spawn the CLI directly; the fixture root is already
  // correct, so these answer without touching the process context.
  @override
  Future<Map<String, dynamic>> dataHomeStatus() async => const {'ok': true};

  @override
  Future<Map<String, dynamic>> relocateDataHome(
    String destinationParent, {
    DataHomePhaseHandler? onPhase,
  }) async => const {'ok': false, 'error': 'fixture_data_home_readonly'};

  @override
  Future<Map<String, dynamic>> recoverDataHome(
    String dataHome, {
    DataHomePhaseHandler? onPhase,
  }) async => const {'ok': true};

  @override
  Future<Map<String, dynamic>> cleanupPreviousDataHome(
    String expectedPreviousRootPath, {
    DataHomePhaseHandler? onPhase,
  }) async => const {'ok': true};

  // Catalog-convergence and OpenCode-serve lanes bottom out in the deny
  // runner; answer them synthetically so bootstrap never reaches for a
  // process at all.
  @override
  Future<Map<String, dynamic>> runCatalogCommand(
    String operation, {
    Map<String, dynamic> params = const {},
  }) async {
    switch (operation) {
      case 'status':
        return const <String, dynamic>{
          'schemaVersion': 'v0.0.1:licoup:catalog-convergence-1',
          'partitionCount': 0,
          'inFlightCount': 0,
          'pendingInvalidationCount': 0,
          'reconnectFence': false,
          'lastKnownAudienceRevision': -1,
          'uiObservedRevision': -1,
          'cohort': <Object>[],
        };
      case 'invalidate':
        return const <String, dynamic>{'acceptedPartitionKeys': <String>[]};
      case 'refresh':
        return const <String, dynamic>{'outcome': 'unchanged'};
      case 'list':
        return const <String, dynamic>{
          'ok': false,
          'reasonCode': 'fixture_unavailable',
          'tools': <Object>[],
        };
      case 'observe':
        return const <String, dynamic>{'observed': false};
      default:
        return const <String, dynamic>{'ok': true};
    }
  }

  @override
  Future<Map<String, dynamic>> opencodeServeStatus() async =>
      const <String, dynamic>{
        'ok': false,
        'status': 'unavailable',
        'errorCode': 'fixture_opencode_disabled',
      };

  @override
  Future<Map<String, dynamic>> ensureOpencodeServe({
    int port = 24173,
    String? executable,
    String? attachUrl,
  }) async => const <String, dynamic>{
    'ok': false,
    'status': 'unavailable',
    'errorCode': 'fixture_opencode_disabled',
  };
}

/// Builds the fixture controller: in-memory presentation preferences seeded
/// from FIXTURE_LAYOUT / FIXTURE_THEME, the synthetic agent service, a
/// portable data root pinned to [home], and deny implementations for the
/// remaining platform spawns (external URL opener, directory opener).
ClientController buildFixtureController({String? home}) {
  final catalog = createBuiltInLayoutCatalog();
  final layoutProfile = _fixtureLayout == 'desktop'
      ? BuiltInLayoutSpec.desktop.id
      : BuiltInLayoutSpec.dashboard.id;
  final layoutStyles = _fixtureLayout == 'dashboard-b'
      ? {BuiltInLayoutSpec.dashboard.id: BuiltInLayoutSpec.dashboardCardStyleId}
      : const <LayoutProfileId, LayoutStyleId>{};
  final preset = _fixtureTheme == 'light'
      ? AppearancePresetIds.taroWaffle
      : AppearancePresetIds.starlitGold;
  final initial = PresentationPreferences(
    layoutProfileId: layoutProfile,
    appearancePresetId: preset,
    localePreference: LocalePreference.system,
    layoutStyleIds: layoutStyles,
  );
  final manager = LayoutManager(
    catalog: catalog,
    preferencesRepository: InMemoryPresentationPreferencesRepository(initial),
    canonicalFallback: PresentationPreferences(
      layoutProfileId: catalog.defaultProfile.id,
      appearancePresetId: preset,
      localePreference: LocalePreference.system,
    ),
  );
  return ClientController(
    portableData: PortableDataRoot(
      dataDirectoryOverride: Directory(home ?? fixtureHome),
    ),
    agentService: FixtureAgentService(),
    layoutCatalog: catalog,
    layoutManager: manager,
    runtimePlatformBridge: const _FixturePlatformBridge(),
    // The bench's destination must come from FIXTURE_DESTINATION, not a
    // persisted current-view document left in the stable fixture home by a
    // previous session — a no-op store removes that late restore override.
    currentViewStore: const _FixtureCurrentViewStore(),
  );
}

/// The bench never restores or persists a "current view": the fixture
/// data root lives in a stable temp directory, so a stale saved section
/// would otherwise override FIXTURE_DESTINATION after the first frame.
final class _FixtureCurrentViewStore implements ClientCurrentViewStore {
  const _FixtureCurrentViewStore();

  @override
  Future<ClientCurrentView?> load(Object portableData) async => null;

  @override
  Future<void> save(Object portableData, ClientCurrentView view) async {}
}

/// Publishes the plugin catalog and emits the running collaboration
/// snapshot. The plugin catalog buffers until the source subscribes; the
/// collaboration stream is broadcast, so the snapshot is re-emitted each
/// time a new conversation binding starts watching.
void seedFixtureSurfaces() {
  fixturePluginHost.publish([
    pluginManifest('figma-bridge', name: 'Figma Bridge'),
    pluginManifest('whiteboard', name: 'Whiteboard'),
  ]);
  var lastEmitCount = -1;
  Timer.periodic(const Duration(milliseconds: 250), (_) {
    final watchers = fixtureCollaborationPort.watchCount;
    if (watchers > 0 && watchers != lastEmitCount) {
      lastEmitCount = watchers;
      fixtureCollaborationPort.emit(
        collabSnapshotV2(status: CollaborationRunStatus.running),
      );
    }
  });
}

/// Applies [FIXTURE_DESTINATION], when set, as the shell's own destination
/// selection. Call after the first frame so the layout host is mounted.
void applyFixtureDestination(ClientController controller) {
  if (_fixtureDestination.isEmpty) return;
  final section = ClientSection.values
      .where((value) => value.name == _fixtureDestination)
      .firstOrNull;
  if (section == null) {
    throw FormatException('FIXTURE_DESTINATION unknown: $_fixtureDestination');
  }
  controller.selectSection(section);
  if (_fixtureOpenConversation) {
    // Land the selection once the agents workspace is mounted; the call is
    // safe before, but delaying avoids racing the first-frame composition.
    unawaited(
      Future<void>.delayed(const Duration(seconds: 1), () {
        return controller.clientConversationController.selectConversation(
          fixtureGroupId,
        );
      }),
    );
  }
}

/// Dev-only conversation opener (`--dart-define=FIXTURE_OPEN_CONVERSATION=1`):
/// after the destination lands, selects the seeded "Design review crew"
/// group so the chat pane renders a real transcript.
const _fixtureOpenConversation = bool.fromEnvironment(
  'FIXTURE_OPEN_CONVERSATION',
);

/// Dev-only destination tour (`--dart-define=FIXTURE_TOUR=1`): cycles the
/// shell destinations through the same `selectSection` path a click uses,
/// every [fixtureTourStep] ms. Temporary — page-switch measurement.
const _fixtureTour = bool.fromEnvironment('FIXTURE_TOUR');
const fixtureTourStep = Duration(seconds: 5);

/// The tour order: collaboration app (agents section), every hosted
/// destination, back to agents — run twice (first mounts, then revisits).
const fixtureTourSections = <ClientSection>[
  ClientSection.agents,
  ClientSection.agentHub,
  ClientSection.monitoring,
  ClientSection.models,
  ClientSection.devices,
  ClientSection.skillHub,
  ClientSection.pluginManagement,
  ClientSection.settings,
];

/// Starts the tour and the frame-timing logger after the first frame.
/// Lines append to `$LICOUP_HOME/tour-timings.log` (a file inside the
/// fixture home, writable under the app sandbox): frame rows print
/// dest=NAME since=MS build=MS raster=MS span=MS; selections print
/// tour select NAME.
void applyFixtureTour(ClientController controller) {
  if (!_fixtureTour) return;
  var selected = ClientSection.agents;
  var selectedAt = Duration.zero;
  final clock = Stopwatch()..start();
  // Directory.systemTemp is the app's own container tmp under the macOS
  // sandbox — always writable; LICOUP_HOME may live outside it.
  final log = File('${Directory.systemTemp.path}/licoup-tour-timings.log');
  log.writeAsStringSync('', mode: FileMode.write);
  void emit(String line) =>
      log.writeAsStringSync('$line\n', mode: FileMode.append);
  SchedulerBinding.instance.addTimingsCallback((timings) {
    for (final timing in timings) {
      final since = clock.elapsed - selectedAt;
      emit(
        'tour frame dest=${selected.name} since=${since.inMilliseconds} '
        'build=${timing.buildDuration.inMicroseconds / 1000} '
        'raster=${timing.rasterDuration.inMicroseconds / 1000} '
        'span=${timing.totalSpan.inMicroseconds / 1000}',
      );
    }
  });
  Timer.periodic(fixtureTourStep, (timer) {
    final index = timer.tick - 1;
    if (index >= fixtureTourSections.length * 2) {
      timer.cancel();
      return;
    }
    selected = fixtureTourSections[index % fixtureTourSections.length];
    selectedAt = clock.elapsed;
    emit('tour select ${selected.name}');
    controller.selectSection(selected);
  });
}
