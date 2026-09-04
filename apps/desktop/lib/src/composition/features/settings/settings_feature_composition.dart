import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/composition/agent_resource_usage_gateway_adapter.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_effect.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/projections/settings/settings_autostart_projection_source.dart';
import 'package:licoup/src/projections/settings/settings_projection_producer.dart';
import 'package:licoup/src/projections/settings/settings_resource_usage_projection_source.dart';

final class SettingsFeatureComposition {
  SettingsFeatureComposition({
    required ClientController controller,
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _projection = SettingsProjectionProducer(controller),
       _effects = _SettingsEffects() {
    _resourceUsage = SettingsResourceUsageProjectionSource(
      client: createClientResourceUsageController(),
      agents: AgentResourceUsageController(
        gateway: AgentResourceUsageGatewayAdapter(
          runner: controller.agentService,
        ),
      ),
    );
    _autostart = SettingsAutostartProjectionSource(
      runner: controller.agentService,
      readGatewayPort: () => controller.llmGatewayLifecycleController.port,
    );
    _intents = _SettingsIntents(
      controller: controller,
      projection: _projection,
      resourceUsage: _resourceUsage,
      autostart: _autostart,
      effects: _effects,
      beginRendererIntent: beginRendererIntent,
    );
    binding = SettingsBinding(
      projection: _projection,
      resourceUsage: _resourceUsage,
      autostart: _autostart,
      intents: _intents,
      effects: _effects,
    );
  }

  final SettingsProjectionProducer _projection;
  final _SettingsEffects _effects;
  late final SettingsResourceUsageProjectionSource _resourceUsage;
  late final SettingsAutostartProjectionSource _autostart;
  late final _SettingsIntents _intents;
  late final SettingsBinding binding;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _autostart.dispose();
    await _resourceUsage.dispose();
    await _projection.dispose();
    await _effects.dispose();
  }
}

final class _SettingsEffects implements EffectSource<SettingsEffect> {
  final StreamController<SettingsEffect> _controller =
      StreamController<SettingsEffect>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<SettingsEffect> get effects => _controller.stream;

  void emit(SettingsEffect effect) {
    if (!_disposed) _controller.add(effect);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await closeBroadcastController(_controller);
  }
}

final class _SettingsIntents implements IntentSink<SettingsIntent> {
  _SettingsIntents({
    required ClientController controller,
    required SettingsProjectionProducer projection,
    required SettingsResourceUsageProjectionSource resourceUsage,
    required SettingsAutostartProjectionSource autostart,
    required _SettingsEffects effects,
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _projection = projection,
       _resourceUsage = resourceUsage,
       _autostart = autostart,
       _effects = effects,
       _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final SettingsProjectionProducer _projection;
  final SettingsResourceUsageProjectionSource _resourceUsage;
  final SettingsAutostartProjectionSource _autostart;
  final _SettingsEffects _effects;
  final RendererIntentTraceFactory? _beginRendererIntent;

  @override
  void send(SettingsIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    final cause = applicationCauseForTrace(trace);
    switch (intent) {
      case SetAppearancePreference(:final presetId):
        _run(
          () => _controller.setAppearancePreset(presetId, cause: cause),
          trace,
        );
      case SetLocalePreference(:final preference):
        _run(
          () => _controller.setLocalePreference(preference, cause: cause),
          trace,
        );
      case SetLayoutPreference(:final profileId):
        _run(
          () => _controller.layoutManager.selectLayout(
            LayoutProfileId.parse(profileId),
            cause: cause,
          ),
          trace,
        );
      case CheckForClientUpdate():
        _run(_controller.checkClientUpdateFromGithub, trace);
      case DownloadClientUpdate():
        _run(_controller.downloadClientUpdateFromGithub, trace);
      case ApplyClientUpdate():
        _run(
          () => _controller.applyClientUpdateThenExit(
            _controller.clientProcessLifecycle.exitSuccess,
          ),
          trace,
        );
      case HydrateClientUpdateIdentity():
        _run(_controller.hydrateClientUpdateIdentity, trace);
      case SetClientUpdateReleaseTrack(:final track):
        _controller.selectClientUpdateReleaseTrack(track);
        _projection.refresh(cause);
      case ExportClientDiagnostics(:final destinationPath):
        _run(() => _controller.exportClientLogs(destinationPath), trace);
      case OpenSettingsDirectory(
        :final directory,
        path: final requestedPath,
        :final caption,
      ):
        final path =
            requestedPath ??
            switch (directory) {
              SettingsDirectory.appearancePresets =>
                _controller.appearancePresetDirectoryPath,
              SettingsDirectory.portableData => _controller.portableDataPath,
              SettingsDirectory.conversationSnapshots =>
                _controller.snapshotRootDraft,
              SettingsDirectory.clientLogs => p.dirname(
                _controller.clientLogExportPath,
              ),
            };
        _run(
          () => _controller.openDirectoryPath(path, caption: caption),
          trace,
        );
      case ReloadAppearancePresets():
        _run(_controller.reloadAppearancePresets, trace);
      case RefreshConversationSnapshotLocation():
        _run(_controller.refreshConversationSnapshotRoot, trace);
      case SetConversationSnapshotLocation(:final path):
        _run(() => _controller.setConversationSnapshotRoot(path), trace);
      case RefreshArchivedConversations():
        _run(_controller.clientConversationController.refreshArchived, trace);
      case RestoreArchivedConversation(:final conversationId):
        _restoreArchived(conversationId, trace);
      case RefreshCatalogStatus():
        _run(_controller.catalogConvergenceController.bootstrap, trace);
      case StartSettingsResourceUsage():
        _resourceUsage.start();
      case StopSettingsResourceUsage():
        _resourceUsage.stop();
      case RefreshSettingsAutostart():
        _runAutostart(() => _autostart.refresh(trace: trace), trace);
      case SetSettingsAutostart(
        :final component,
        :final enabled,
        :final silent,
      ):
        _runAutostart(
          () => _autostart.set(
            component: component,
            enabled: enabled,
            silent: silent,
            trace: trace,
          ),
          trace,
        );
    }
  }

  void _run(FutureOr<Object?> Function() action, TraceContext? trace) {
    unawaited(
      Future<Object?>.sync(action)
          .then((_) {
            _projection.refresh(applicationCauseForTrace(trace));
          })
          .catchError((Object _) {
            _effects.emit(
              SettingsActionRejected('settings_action_failed', trace: trace),
            );
          }),
    );
  }

  void _runAutostart(Future<void> Function() action, TraceContext? trace) {
    unawaited(
      action().catchError((Object _) {
        _effects.emit(
          SettingsActionRejected('settings_action_failed', trace: trace),
        );
      }),
    );
  }

  void _restoreArchived(String conversationId, TraceContext? trace) {
    unawaited(() async {
      var restored = false;
      try {
        restored = await _controller.clientConversationController
            .restoreArchived(conversationId);
        _projection.refresh(applicationCauseForTrace(trace));
      } catch (_) {
        _effects.emit(
          SettingsActionRejected('settings_action_failed', trace: trace),
        );
      } finally {
        _effects.emit(
          ArchivedConversationRestoreCompleted(
            conversationId: conversationId,
            restored: restored,
            trace: trace,
          ),
        );
      }
    }());
  }
}
