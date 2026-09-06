import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_effect_producer.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_station.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';

/// Maps one semantic user intent to exactly one existing Application action.
final class MobileRelayIntentAdapter implements IntentSink<MobileRelayIntent> {
  const MobileRelayIntentAdapter({
    required MobileRelayController relay,
    required SecureMeshController secureMesh,
    required MobileHomeLayoutController homeLayout,
    required MobileRelayEffectProducer effects,
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _relay = relay,
       _secureMesh = secureMesh,
       _homeLayout = homeLayout,
       _effects = effects,
       _beginRendererIntent = beginRendererIntent;

  final MobileRelayController _relay;
  final SecureMeshController _secureMesh;
  final MobileHomeLayoutController _homeLayout;
  final MobileRelayEffectProducer _effects;
  final RendererIntentTraceFactory? _beginRendererIntent;

  @override
  void send(MobileRelayIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    unawaited(_dispatch(intent, trace));
  }

  Future<void> _dispatch(MobileRelayIntent intent, TraceContext? trace) async {
    try {
      switch (intent) {
        case RefreshMobileRelay():
          await _relay.refreshPairingStatus();
        case RefreshRelayApprovals():
          await _secureMesh.refreshApprovalInbox();
        case ConfigureRelayStation(:final address):
          await _relay.configureStation(stationBaseUrl: address);
          final expected = canonicalMobileRelayStationOrigin(address);
          if (expected == null || _relay.config.stationBaseUrl != expected) {
            _reject('mobile_relay_station_configuration_failed', trace);
          }
        case CreateRelayPairing():
          await _relay.createPairing();
          final presentation = _relay.pairingPresentation;
          if (presentation == null || presentation.pairingCode.isEmpty) {
            _reject(
              canonicalMobileRelayStationOrigin(_relay.config.stationBaseUrl) ==
                      null
                  ? 'mobile_relay_station_required'
                  : 'mobile_relay_pairing_create_failed',
              trace,
            );
          } else {
            _effects.emit(
              RelayPairingReady(presentation.pairingCode, trace: trace),
            );
          }
        case CopyRelayPairingCode(:final pairingCode):
          final copied = await _relay.copyPairingCode(pairingCode);
          if (copied) {
            _effects.emit(RelayPairingCodeCopied(trace: trace));
          } else {
            _reject('mobile_relay_pairing_copy_failed', trace);
          }
        case ClaimRelayPairing(:final invite):
          final previousResult = _relay.actionResult;
          await _relay.claimPairingInvite(invite);
          final result = _relay.actionResult;
          if (identical(previousResult, result) || result?['ok'] != true) {
            _reject('mobile_relay_pairing_claim_failed', trace);
          } else {
            _effects.emit(RelayPairingClaimed(trace: trace));
          }
        case SelectRelayPeer(:final peerId):
          await _relay.selectDevice(peerId);
          final selected = _relay.config.deviceTabs.any(
            (peer) =>
                (peer.id == peerId || peer.pairingId == peerId) &&
                (peer.id == _relay.config.pcClientId ||
                    peer.pairingId == _relay.config.pairingId),
          );
          if (!selected) _reject('mobile_relay_device_switch_failed', trace);
        case ToggleRelayHomeEntryPinned(:final entryId):
          await _homeLayout.togglePinned(entryId);
        case ReorderRelayHomePinnedEntries(
          :final pinnedEntryIds,
          :final oldIndex,
          :final newIndex,
        ):
          await _homeLayout.reorderPinnedEntries(
            pinnedEntryIds,
            oldIndex,
            newIndex,
          );
        case ResolveRelayApproval(:final approvalId, :final approved):
          if (!_secureMesh.canResolveApproval(approvalId)) {
            _reject('secure_mesh_approval_response_invalid', trace);
            return;
          }
          await _secureMesh.resolveApproval(
            pendingOperationId: approvalId,
            allow: approved,
          );
          final resolved = _secureMesh.approvalInbox.any(
            (approval) =>
                approval.pendingOperationId == approvalId &&
                approval.status == SecureMeshApprovalStatus.resolved,
          );
          if (!resolved) {
            _reject('secure_mesh_approval_resolve_failed', trace);
          }
        case SetRelayTransferSource(
          :final fileName,
          :final totalSize,
          :final mimeType,
        ):
          _secureMesh.setFileDraft(
            fileName: fileName,
            totalSize: totalSize,
            mimeType: mimeType,
          );
          if (_secureMesh.fileDraft == null) {
            _reject('secure_mesh_file_sync_source_invalid', trace);
          }
        case SetRelayTransferDestination(:final destinationRoot):
          _secureMesh.setFileDestination(destinationRoot);
          if (_secureMesh.fileDraft?.destinationRoot !=
              destinationRoot.trim()) {
            _reject('secure_mesh_file_sync_destination_invalid', trace);
          }
        case PrepareRelayTransfer():
          await _secureMesh.prepareFileTransfer();
          if (_secureMesh.fileDraft?.status !=
              SecureMeshFileSyncStatus.awaitingConfirmation) {
            _reject('secure_mesh_file_sync_prepare_failed', trace);
          }
        case ConfirmRelayTransfer(:final transferId, :final approved):
          final draft = _secureMesh.fileDraft;
          if (draft == null || draft.id != transferId) {
            _reject('secure_mesh_file_sync_confirmation_unavailable', trace);
            return;
          }
          await _secureMesh.confirmFileReceive(userConfirmed: approved);
          final expected = approved
              ? SecureMeshFileSyncStatus.confirmed
              : SecureMeshFileSyncStatus.rejected;
          if (_secureMesh.fileDraft?.status != expected) {
            _reject('secure_mesh_file_sync_confirm_failed', trace);
          }
      }
    } catch (_) {
      _reject('mobile_relay_action_failed', trace);
    }
  }

  void _reject(String reasonCode, TraceContext? trace) {
    _effects.emit(RelayActionRejected(reasonCode, trace: trace));
  }
}
