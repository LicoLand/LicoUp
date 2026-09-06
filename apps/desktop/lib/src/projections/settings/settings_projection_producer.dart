import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/catalog_convergence/controller/catalog_convergence_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class SettingsProjectionProducer
    implements ProjectionSource<SettingsProjection> {
  SettingsProjectionProducer(this._controller) : _current = _read(_controller) {
    _applicationSubscriptions = <StreamSubscription<ApplicationChange>>[
      _controller.appearancePreferenceOwner.changes.listen(
        _onApplicationChange,
      ),
      _controller.localePreferenceOwner.changes.listen(_onApplicationChange),
      _controller.clientUpdateController.changes.listen(_onApplicationChange),
      _controller.clientLogExportController.changes.listen(
        _onApplicationChange,
      ),
      _controller.clientConversationController.changes.listen(
        _onApplicationChange,
      ),
      _controller.catalogConvergenceController.changes.listen(
        _onApplicationChange,
      ),
    ];
    _layoutSubscription = _controller.layoutManager.changes.listen((change) {
      _publish(change.cause);
    });
  }

  final ClientController _controller;
  final StreamController<ProjectionUpdate<SettingsProjection>> _changes =
      StreamController<ProjectionUpdate<SettingsProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<ApplicationChange>>
  _applicationSubscriptions;
  late final StreamSubscription<ApplicationChange> _layoutSubscription;
  SettingsProjection _current;
  bool _disposed = false;

  @override
  SettingsProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SettingsProjection>> get changes => _changes.stream;

  void _onApplicationChange(ApplicationChange change) => _publish(change.cause);

  void refresh([ApplicationCause? cause]) => _publish(cause);

  void _publish([ApplicationCause? cause]) {
    if (_disposed) return;
    final next = _read(_controller);
    if (_same(_current, next)) return;
    _current = next;
    _changes.add(
      ProjectionUpdate<SettingsProjection>(
        next,
        trace: cause?.traceId == null
            ? null
            : TraceContext(traceId: cause!.traceId),
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _layoutSubscription.cancel();
    for (final subscription in _applicationSubscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static SettingsProjection _read(ClientController controller) {
    final layout = controller.layoutManager;
    final layoutState = layout.state;
    final conversations = controller.clientConversationController;
    final update = controller.clientUpdateStatus;
    final catalog = controller.catalogConvergenceController;
    final catalogStatus = catalog.status;
    final conversationFailure = conversations.failureCode.trim();
    final layoutFailure = layoutState.errorCode?.name ?? '';
    final failure = conversationFailure.isNotEmpty
        ? conversationFailure
        : layoutFailure;
    final busy =
        layoutState.status == LayoutSelectionStatus.loading ||
        layoutState.status == LayoutSelectionStatus.committing ||
        controller.isClientUpdateBusy ||
        controller.isExportingClientLogs ||
        controller.isSavingSnapshotRoot ||
        conversations.loading;
    return SettingsProjection(
      appearancePresetId: controller.appearancePresetId,
      appearancePresets: [
        for (final config in controller.appearancePresetConfigs)
          SettingsAppearancePresetProjection(
            id: config.id,
            englishLabel: config.labelFor(),
            chineseLabel: config.labelFor('zh-CN'),
            mode: switch (config.mode) {
              AppearancePresetMode.system => SettingsAppearanceMode.system,
              AppearancePresetMode.light => SettingsAppearanceMode.light,
              AppearancePresetMode.dark => SettingsAppearanceMode.dark,
            },
            lightPresetId: config.lightPresetId ?? '',
            darkPresetId: config.darkPresetId ?? '',
          ),
      ],
      localeChoices: [
        for (final preference in LocalePreference.values)
          PresentationChoice(
            id: preference,
            label: preference,
            selected:
                LocalePreference.normalize(controller.localePreference) ==
                preference,
          ),
      ],
      layoutChoices: [
        for (final profile in layout.catalog.profiles)
          PresentationChoice(
            id: profile.id.value,
            label: profile.label.english,
            description: profile.description.english,
            selected: profile.id == layoutState.effectiveId,
            enabled:
                layoutState.status != LayoutSelectionStatus.committing &&
                profile.selectable,
          ),
      ],
      archivedConversations: [
        for (final conversation in conversations.archivedConversations)
          ArchivedConversationProjection(
            id: conversation.id,
            title: conversation.title,
            isGroup: conversation.isGroup,
            membershipCount: conversation.membershipCount,
            updatedAtUnixMs: conversation.updatedAtUnixMs,
          ),
      ],
      layoutPhase: switch (layoutState.status) {
        LayoutSelectionStatus.loading => PresentationPhase.loading,
        LayoutSelectionStatus.committing => PresentationPhase.applying,
        LayoutSelectionStatus.stable => PresentationPhase.ready,
        LayoutSelectionStatus.error => PresentationPhase.failed,
      },
      layoutFailureReasonCode: layoutFailure,
      appearancePresetDirectoryPath: controller.appearancePresetDirectoryPath,
      appearancePresetLoadErrorCount:
          controller.appearancePresetLoadErrors.length,
      portableDataPath: controller.portableDataPath,
      snapshotRootPath: controller.snapshotRootDraft,
      savingSnapshotRoot: controller.isSavingSnapshotRoot,
      clientLogExportPath: controller.clientLogExportPath,
      exportingClientLogs: controller.isExportingClientLogs,
      clientUpdate: SettingsClientUpdateProjection(
        phase: update.phase,
        runningVersion: update.runningVersion,
        runningReleaseTrack: update.runningReleaseTrack,
        targetReleaseTrack: update.targetReleaseTrack,
        availableVersion: update.availableVersion,
        githubReleaseUrl: update.githubReleaseUrl,
        artifactSha256: update.artifactSha256,
        updateAvailable: update.updateAvailable,
      ),
      clientUpdateRepo: controller.clientUpdateRepo,
      catalog: SettingsCatalogProjection(
        phase: switch (catalog.phase) {
          CatalogConvergencePhase.disabled => SettingsCatalogPhase.disabled,
          CatalogConvergencePhase.idle => SettingsCatalogPhase.idle,
          CatalogConvergencePhase.reconciling =>
            SettingsCatalogPhase.reconciling,
          CatalogConvergencePhase.ready => SettingsCatalogPhase.ready,
          CatalogConvergencePhase.blocked => SettingsCatalogPhase.blocked,
          CatalogConvergencePhase.failed => SettingsCatalogPhase.failed,
        },
        reasonCode: catalog.reasonCode,
        busy: catalog.busy,
        partitionCount: catalogStatus.partitionCount,
        pendingInvalidationCount: catalogStatus.pendingInvalidationCount,
        appliedCohortCount: catalogStatus.appliedCohortCount,
        uiObservedRevision: catalogStatus.uiObservedRevision,
      ),
      phase: failure.isNotEmpty
          ? PresentationPhase.failed
          : busy
          ? PresentationPhase.applying
          : PresentationPhase.ready,
      notice: failure.isEmpty
          ? null
          : PresentationNotice(
              id: conversationFailure.isNotEmpty
                  ? 'settings-conversation-${conversations.failureStage}'
                  : 'settings-layout-failure',
              title: 'Settings action failed',
              message: 'Review the action and try again.',
              severity: PresentationNoticeSeverity.error,
              reasonCode: failure,
            ),
    );
  }

  static bool _same(SettingsProjection left, SettingsProjection right) =>
      left.appearancePresetId == right.appearancePresetId &&
      samePresentationList(left.appearancePresets, right.appearancePresets) &&
      samePresentationList(left.localeChoices, right.localeChoices) &&
      samePresentationList(left.layoutChoices, right.layoutChoices) &&
      samePresentationList(
        left.archivedConversations,
        right.archivedConversations,
      ) &&
      left.layoutPhase == right.layoutPhase &&
      left.layoutFailureReasonCode == right.layoutFailureReasonCode &&
      left.appearancePresetDirectoryPath ==
          right.appearancePresetDirectoryPath &&
      left.appearancePresetLoadErrorCount ==
          right.appearancePresetLoadErrorCount &&
      left.portableDataPath == right.portableDataPath &&
      left.snapshotRootPath == right.snapshotRootPath &&
      left.savingSnapshotRoot == right.savingSnapshotRoot &&
      left.clientLogExportPath == right.clientLogExportPath &&
      left.exportingClientLogs == right.exportingClientLogs &&
      left.clientUpdate == right.clientUpdate &&
      left.clientUpdateRepo == right.clientUpdateRepo &&
      left.catalog == right.catalog &&
      left.phase == right.phase &&
      left.notice == right.notice;
}
