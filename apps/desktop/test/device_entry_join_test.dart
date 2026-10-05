import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/policy/device_replacement_policy.dart';
import 'package:licoup/src/composition/features/mobile_relay/device_entry_join.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/presentation/mobile_relay/device_replacement_projection.dart';

import 'fixtures/device_replacement/scenarios.dart';

void main() {
  group('the optional package gate', () {
    test(
      'every resolved answer publishes its own refusal and recovery action',
      () {
        final answers = <EndpointCollaborationAvailability, Object>{
          const EndpointCollaborationAvailability.active('0.3.0'): (
            refusal: null,
            action: EndpointCollaborationRecoveryAction.none,
            available: true,
          ),
          const EndpointCollaborationAvailability.disabled('0.3.0'): (
            refusal: EndpointOutboundRefusal.packageDisabled,
            action: EndpointCollaborationRecoveryAction.enablePackage,
            available: false,
          ),
          const EndpointCollaborationAvailability.capabilityUndeclared(
            '0.3.0',
          ): (
            refusal: EndpointOutboundRefusal.capabilityUndeclared,
            action: EndpointCollaborationRecoveryAction.installCapableVersion,
            available: false,
          ),
          const EndpointCollaborationAvailability.missing(): (
            refusal: EndpointOutboundRefusal.packageMissing,
            action: EndpointCollaborationRecoveryAction.installPackage,
            available: false,
          ),
          const EndpointCollaborationAvailability.unreadable(): (
            refusal: EndpointOutboundRefusal.storeUnreadable,
            action: EndpointCollaborationRecoveryAction.repairStore,
            available: false,
          ),
        };
        for (final entry in answers.entries) {
          final composition = SyntheticDeviceEntryComposition(
            projection: authorizedReplacementScenario(),
            availability: entry.key,
          );
          addTearDown(composition.dispose);
          final recovery = composition.join.recovery;
          final expected =
              entry.value
                  as ({
                    EndpointOutboundRefusal? refusal,
                    EndpointCollaborationRecoveryAction action,
                    bool available,
                  });
          expect(
            composition.join.availability,
            entry.key,
            reason: '${entry.key}',
          );
          expect(
            composition.join.refusal,
            expected.refusal,
            reason: '${entry.key}',
          );
          expect(recovery.action, expected.action, reason: '${entry.key}');
          expect(recovery.capabilityAvailable, expected.available);
          expect(
            recovery.localClientUsable,
            isTrue,
            reason: 'the local client never depends on the optional package',
          );
          if (!expected.available) {
            expect(
              composition.join.offeredActions,
              isEmpty,
              reason: 'a refused package offers no intent at all',
            );
            expect(composition.join.offersReplacementControl, isFalse);
            expect(composition.join.eraseConfirmation, isNull);
          }
        }
      },
    );

    test('each refusal publishes the reason the native owner publishes', () {
      expect(
        EndpointOutboundRefusal.packageMissing.reason,
        'endpoint_collaboration_package_absent',
      );
      expect(
        EndpointOutboundRefusal.packageDisabled.reason,
        'endpoint_collaboration_package_disabled',
      );
      expect(
        EndpointOutboundRefusal.capabilityUndeclared.reason,
        'endpoint_collaboration_capability_undeclared',
      );
      expect(
        EndpointOutboundRefusal.storeUnreadable.reason,
        'endpoint_collaboration_store_unreadable',
      );
    });

    test('the gate refuses before the control entry is asked', () {
      final composition = SyntheticDeviceEntryComposition(
        projection: authorizedReplacementScenario(),
        availability: const EndpointCollaborationAvailability.disabled('0.3.0'),
      );
      addTearDown(composition.dispose);

      expect(composition.join.offeredActions, isEmpty);
      expect(composition.control.asked, isEmpty);
      expect(
        composition.join.admit(DeviceReplacementAction.requestRemoteStop),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.packageUnavailable,
        ),
      );
      expect(composition.control.asked, isEmpty);
    });

    test(
      'an active package offers what the facts authorize and the entry admits',
      () {
        final authorized = SyntheticDeviceEntryComposition(
          projection: authorizedReplacementScenario(),
        );
        addTearDown(authorized.dispose);
        expect(authorized.join.offeredActions, const [
          DeviceReplacementAction.submitEraseConfirmation,
          DeviceReplacementAction.requestRemoteStop,
          DeviceReplacementAction.refreshRemoteWorkState,
          DeviceReplacementAction.refreshTransferVerification,
        ]);
        expect(authorized.join.offersReplacementControl, isTrue);
        expect(authorized.join.eraseConfirmation, isNotNull);

        final narrow = SyntheticDeviceEntryComposition(
          projection: authorizedReplacementScenario(),
          control: SyntheticDeviceReplacementControl(
            admitted: const {DeviceReplacementAction.refreshRemoteWorkState},
          ),
        );
        addTearDown(narrow.dispose);
        expect(narrow.join.offeredActions, const [
          DeviceReplacementAction.refreshRemoteWorkState,
        ]);
        expect(
          narrow.join.offersReplacementControl,
          isFalse,
          reason: 'the control entry admitted no replacement or control action',
        );
      },
    );

    test('a replacement the control entry cannot drive is not offered', () {
      final composition = SyntheticDeviceEntryComposition(
        projection: authorizedReplacementScenario(),
        control: SyntheticDeviceReplacementControl(
          admitted: const {},
          refusal: DeviceReplacementControlRefusal.nativeEntryAbsent,
        ),
      );
      addTearDown(composition.dispose);
      expect(composition.join.offeredActions, isEmpty);
      expect(
        composition.join.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.nativeEntryAbsent,
        ),
      );
    });
  });

  group('two-endpoint composition facts', () {
    test(
      'authorization and a fresh identity epoch are separate answers',
      () async {
        final composition = SyntheticDeviceEntryComposition(
          projection: authorizedReplacementScenario(),
        );
        addTearDown(composition.dispose);
        expect(composition.join.offersReplacementControl, isTrue);

        composition.publish(freshIdentityScenario());
        await _flush();
        expect(
          composition.join.offersReplacementControl,
          isFalse,
          reason: 'the recorded authorization covers an earlier identity epoch',
        );
        expect(composition.join.eraseConfirmation, isNull);
        expect(
          composition.join.offeredActions,
          isNot(contains(DeviceReplacementAction.requestRemoteStop)),
        );
      },
    );

    test(
      'full, partial and failed transfers stay distinct through the join',
      () async {
        final composition = SyntheticDeviceEntryComposition(
          projection: fullTransferScenario(),
        );
        addTearDown(composition.dispose);
        expect(
          composition.join.deviceState.current.transferVerification.stage,
          DeviceTransferVerificationStage.committed,
        );

        composition.publish(partialTransferScenario());
        await _flush();
        expect(
          composition.join.deviceState.current.transferVerification.stage,
          DeviceTransferVerificationStage.verified,
        );
        expect(
          composition
              .join
              .deviceState
              .current
              .transferVerification
              .committedUnitCount,
          0,
        );

        composition.publish(sourceOnFailureScenario());
        await _flush();
        expect(
          composition.join.deviceState.current.transferVerification.stage,
          DeviceTransferVerificationStage.failed,
        );
      },
    );

    test('an unobserved effect stays visible and is never re-driven', () async {
      final composition = SyntheticDeviceEntryComposition(
        projection: incompleteEffectsScenario(),
      );
      addTearDown(composition.dispose);
      final effect =
          composition.join.deviceState.current.remoteWork.effects.single;
      expect(effect.state, DeviceRemoteEffectState.unknown);
      final presentation = DeviceReplacementPolicy.effectPresentation(effect);
      expect(presentation.carriesOrdinaryAuthority, isFalse);
      expect(presentation.actionable, isFalse);
      expect(
        presentation.offeredActions,
        const [DeviceReplacementAction.refreshRemoteWorkState],
        reason: 'an unknown effect is re-read, never re-driven',
      );
      expect(
        composition.join.offeredActions,
        contains(DeviceReplacementAction.refreshRemoteWorkState),
        reason: 'the unobserved effect stays visible and refreshable',
      );
      for (final action in composition.join.offeredActions) {
        expect(action.name, isNot(contains('replay')));
        expect(action.name, isNot(contains('resend')));
      }
    });

    test('a reconnect keeps the last answer and offers only a retry', () async {
      final composition = SyntheticDeviceEntryComposition(
        projection: reconnectReplayScenario(),
      );
      addTearDown(composition.dispose);
      expect(composition.join.deviceState.current.authority.reachable, isFalse);
      expect(
        composition.join.offeredActions,
        contains(DeviceReplacementAction.reconnectEndpoint),
      );
      final late =
          composition.join.deviceState.current.remoteWork.effects.single;
      expect(late.state, DeviceRemoteEffectState.confirmed);
      expect(late.lateResult, isTrue);
      expect(
        DeviceReplacementPolicy.carriesOrdinaryAuthority(late),
        isFalse,
        reason: 'a late result describes an older attempt',
      );
      expect(
        composition.join.offeredActions,
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
    });

    test('real stop ownership decides whether the stop is offered', () async {
      final composition = SyntheticDeviceEntryComposition(
        projection: authorizedReplacementScenario(),
      );
      addTearDown(composition.dispose);
      expect(
        composition.join.offeredActions,
        contains(DeviceReplacementAction.requestRemoteStop),
      );

      composition.publish(
        syntheticDeviceReplacementProjection(
          remoteWork: syntheticRemoteWork(
            stopOwnership: DeviceStopOwnership.remoteRequester,
          ),
        ),
      );
      await _flush();
      expect(
        composition.join.offeredActions,
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
        reason: 'the requester already owns this stop',
      );

      composition.publish(
        syntheticDeviceReplacementProjection(
          remoteWork: syntheticRemoteWork(
            stopOwnership: DeviceStopOwnership.noOwner,
          ),
        ),
      );
      await _flush();
      expect(
        composition.join.offeredActions,
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
        reason: 'nothing owns the work, so there is no stop to ask for',
      );
    });

    test('the entry names the fact that refused an action', () {
      final inactive = SyntheticDeviceEntryComposition(
        projection: syntheticDeviceReplacementProjection(
          authority: syntheticAuthorityFacts(
            activation: DeviceEndpointActivation.inactive,
          ),
        ),
      );
      addTearDown(inactive.dispose);
      expect(inactive.join.offersReplacementControl, isFalse);
      expect(
        inactive.join.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.endpointNotAuthorized,
        ),
      );

      final unconfirmed = SyntheticDeviceEntryComposition(
        projection: syntheticDeviceReplacementProjection(
          eraseReview: syntheticEraseReview(confirmed: false),
        ),
      );
      addTearDown(unconfirmed.dispose);
      expect(
        unconfirmed.join.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.reviewNotConfirmed,
        ),
      );

      final unsigned = SyntheticDeviceEntryComposition(
        projection: syntheticDeviceReplacementProjection(
          eraseReview: syntheticEraseReview(nativeAuthenticationPresent: false),
        ),
      );
      addTearDown(unsigned.dispose);
      expect(
        unsigned.join.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.nativeAuthenticationMissing,
        ),
      );

      final revoked = SyntheticDeviceEntryComposition(
        projection: revokedWithLostReceiptScenario(),
      );
      addTearDown(revoked.dispose);
      expect(
        revoked.join.admit(DeviceReplacementAction.requestRemoteStop),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.identityRevoked,
        ),
      );
      expect(
        revoked.join.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.identityRevoked,
        ),
      );
    });
  });

  group('cleanup settlement, receipt delivery and confirmation', () {
    test(
      'the restricted app-only cleanup never becomes an erased badge',
      () async {
        final composition = SyntheticDeviceEntryComposition(
          projection: restrictedCleanupScenario(),
        );
        addTearDown(composition.dispose);
        final presentation = composition.join.cleanupPresentation;
        expect(presentation.status, DeviceCleanupStatus.partial);
        expect(presentation.localSettlementComplete, isFalse);
        expect(presentation.erasedBadgeVisible, isFalse);
        expect(presentation.pendingEntryLabels, hasLength(2));
        expect(
          composition.join.deviceState.current.pendingCleanup.receiptKind,
          DeviceCleanupReceiptKind.fileStage,
        );
      },
    );

    test(
      'all-stage settlement, receipt delivery and replacement confirmation are '
      'distinguished',
      () async {
        final composition = SyntheticDeviceEntryComposition(
          projection: allStageSettlementScenario(),
        );
        addTearDown(composition.dispose);
        final settled = composition.join.cleanupPresentation;
        expect(settled.status, DeviceCleanupStatus.confirmedComplete);
        expect(settled.receiptDelivered, isTrue);
        expect(settled.replacementEndpointConfirmed, isTrue);
        expect(settled.erasedBadgeVisible, isTrue);

        composition.publish(lostReceiptScenario());
        await _flush();
        final lost = composition.join.cleanupPresentation;
        expect(lost.status, DeviceCleanupStatus.confirmedComplete);
        expect(lost.localSettlementComplete, isTrue);
        expect(lost.receiptDelivered, isFalse);
        expect(
          lost.erasedBadgeVisible,
          isFalse,
          reason: 'a lost receipt never becomes erased evidence',
        );
        expect(
          lost.receiptDeliveryFailureCode,
          'cleanup_receipt_path_unavailable',
        );
      },
    );

    test('a lost receipt never renews a revoked endpoint admission', () {
      final composition = SyntheticDeviceEntryComposition(
        projection: revokedWithLostReceiptScenario(),
      );
      addTearDown(composition.dispose);
      final projection = composition.join.deviceState.current;
      expect(projection.identityRevocation.revoked, isTrue);
      expect(projection.identityRevocation.absorbing, isTrue);
      expect(composition.join.cleanupPresentation.erasedBadgeVisible, isFalse);
      expect(
        composition.join.offersReplacementControl,
        isFalse,
        reason: 'nothing here restores a revoked endpoint',
      );
      expect(composition.join.eraseConfirmation, isNull);
    });
  });

  group('production composition', () {
    test(
      'the relay feature composition owns the join and publishes it',
      () async {
        final controller = ClientController();
        final feature = MobileRelayFeatureComposition(
          relay: controller.mobileRelayController,
          secureMesh: controller.secureMeshController,
          homeLayout: controller.mobileHomeLayoutController,
          readMobileRuntime: () => controller.mobileClientRuntimePlatform,
        );
        addTearDown(() async {
          await feature.dispose();
          controller.dispose();
        });

        expect(identical(feature.deviceEntry.relay, feature.binding), isTrue);
        expect(
          feature.deviceEntry.availability.state,
          EndpointCollaborationState.missing,
          reason: 'no Dart bridge carries the host package resolution',
        );
        expect(
          feature.deviceEntry.refusal?.reason,
          'endpoint_collaboration_package_absent',
        );
        expect(
          feature.deviceEntry.recovery.action,
          EndpointCollaborationRecoveryAction.installPackage,
        );
        expect(feature.deviceEntry.recovery.localClientUsable, isTrue);
        expect(feature.deviceEntry.offeredActions, isEmpty);
        expect(feature.deviceEntry.offersReplacementControl, isFalse);
        expect(feature.deviceEntry.eraseConfirmation, isNull);
        expect(
          feature.deviceEntry.admit(DeviceReplacementAction.requestRemoteStop),
          const DeviceReplacementControlAdmission.refused(
            DeviceReplacementControlRefusal.packageUnavailable,
          ),
        );
        expect(
          feature.deviceEntry.cleanupPresentation.status,
          DeviceCleanupStatus.notRequested,
        );
      },
    );

    test('the production join drives no device the native owners cannot', () {
      final composition = SyntheticDeviceEntryComposition(
        projection: authorizedReplacementScenario(),
      );
      addTearDown(composition.dispose);
      final production = DeviceEntryJoin.production(
        relay: composition.relayFixture.binding,
        package: composition.package,
        deviceState: composition.deviceState,
      );
      addTearDown(production.dispose);

      expect(production.availability.permitsOutbound, isTrue);
      expect(
        production.offeredActions,
        isEmpty,
        reason: 'the shipped control entry refuses every action',
      );
      expect(
        production.admit(DeviceReplacementAction.submitEraseConfirmation),
        const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.nativeEntryAbsent,
        ),
      );
      expect(
        production.eraseConfirmation,
        isNotNull,
        reason: 'the package gate is open; the control entry is what refuses',
      );
    });
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);
