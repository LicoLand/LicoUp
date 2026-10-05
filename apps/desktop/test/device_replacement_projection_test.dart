import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/mobile_relay/policy/device_replacement_policy.dart';
import 'package:licoup/src/presentation/mobile_relay/device_replacement_projection.dart';
import 'package:licoup/src/projections/mobile_relay/device_replacement_projection_source.dart';

import 'fixtures/device_replacement/scenarios.dart';

void main() {
  group('separate facts', () {
    test('the six fact groups stay independent and compare by value', () {
      final projection = authorizedReplacementScenario();
      expect(projection.authority.activation, DeviceEndpointActivation.active);
      expect(
        projection.transferVerification.stage,
        DeviceTransferVerificationStage.committed,
      );
      expect(
        projection.pendingCleanup.outcome,
        DeviceCleanupOutcome.notRequested,
      );
      expect(
        projection.remoteWork.stopOwnership,
        DeviceStopOwnership.localOwner,
      );
      expect(projection.eraseReview.nativeAuthenticationPresent, isTrue);

      // One group moving leaves the other five exactly as they were.
      final moved = syntheticDeviceReplacementProjection(
        pendingCleanup: restrictedCleanupScenario().pendingCleanup,
      );
      expect(moved.authority, projection.authority);
      expect(moved.identityRevocation, projection.identityRevocation);
      expect(moved.transferVerification, projection.transferVerification);
      expect(moved.remoteWork, projection.remoteWork);
      expect(moved.eraseReview, projection.eraseReview);
      expect(moved.pendingCleanup, isNot(projection.pendingCleanup));
      expect(moved, isNot(projection));
    });

    test(
      'the source joins five inputs and publishes only a real change',
      () async {
        final inputs = SyntheticDeviceReplacementInputs(
          authorizedReplacementScenario(),
        );
        final source = DeviceReplacementProjectionSource(
          authority: inputs,
          transferVerification: inputs,
          cleanup: inputs,
          remoteWork: inputs,
          eraseReview: inputs,
        );
        addTearDown(source.dispose);
        final updates = <DeviceReplacementProjection>[];
        final subscription = source.changes.listen(
          (update) => updates.add(update.value),
        );
        addTearDown(subscription.cancel);

        inputs.publish(authorizedReplacementScenario());
        await _flush();
        expect(updates, isEmpty, reason: 'an equal projection emits nothing');

        inputs.publish(freshIdentityScenario());
        await _flush();
        expect(updates, hasLength(1));
        expect(updates.single.authority.identityRotationEpoch, 9);
        expect(
          updates.single.transferVerification,
          authorizedReplacementScenario().transferVerification,
          reason: 'the transfer fact did not move with the authority fact',
        );
        expect(source.current, updates.single);

        await source.dispose();
        inputs.publish(allStageSettlementScenario());
        await _flush();
        expect(
          updates,
          hasLength(1),
          reason: 'a disposed source emits nothing',
        );
      },
    );
  });

  group('offered intents follow the current authority', () {
    test(
      'the review is offered before the confirmation and the submit after it',
      () {
        expect(
          DeviceReplacementPolicy.offeredActions(
            syntheticDeviceReplacementProjection(
              eraseReview: syntheticEraseReview(confirmed: false),
            ),
          ),
          const [
            DeviceReplacementAction.reviewErase,
            DeviceReplacementAction.requestRemoteStop,
            DeviceReplacementAction.refreshRemoteWorkState,
            DeviceReplacementAction.refreshTransferVerification,
          ],
        );
        expect(
          DeviceReplacementPolicy.offeredActions(
            authorizedReplacementScenario(),
          ),
          const [
            DeviceReplacementAction.submitEraseConfirmation,
            DeviceReplacementAction.requestRemoteStop,
            DeviceReplacementAction.refreshRemoteWorkState,
            DeviceReplacementAction.refreshTransferVerification,
          ],
        );
      },
    );

    test(
      'a fresh identity epoch is not covered by the recorded authorization',
      () {
        final offered = DeviceReplacementPolicy.offeredActions(
          freshIdentityScenario(),
        );
        expect(
          offered,
          isNot(contains(DeviceReplacementAction.submitEraseConfirmation)),
        );
        expect(
          offered,
          isNot(contains(DeviceReplacementAction.requestRemoteStop)),
        );
        expect(
          DeviceReplacementPolicy.eraseConfirmationRefusal(
            freshIdentityScenario(),
          ),
          DeviceReplacementPolicy.eraseRefusalOutboundNotAuthorized,
        );
      },
    );

    test('the pre-package in-kernel path is not package authority', () {
      final projection = syntheticDeviceReplacementProjection(
        authority: syntheticAuthorityFacts(
          outboundAuthority: DeviceOutboundAuthoritySource.legacyInKernel,
        ),
      );
      final offered = DeviceReplacementPolicy.offeredActions(projection);
      expect(
        offered,
        isNot(contains(DeviceReplacementAction.submitEraseConfirmation)),
      );
      expect(
        offered,
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
      expect(DeviceReplacementPolicy.eraseConfirmation(projection), isNull);
    });

    test('a stop is offered only to the owner that has not asked yet', () {
      expect(
        DeviceReplacementPolicy.offeredActions(
          syntheticDeviceReplacementProjection(
            remoteWork: syntheticRemoteWork(
              stopOwnership: DeviceStopOwnership.remoteRequester,
            ),
          ),
        ),
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
      expect(
        DeviceReplacementPolicy.offeredActions(
          syntheticDeviceReplacementProjection(
            remoteWork: syntheticRemoteWork(stopAlreadyRequested: true),
          ),
        ),
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
      expect(
        DeviceReplacementPolicy.offeredActions(
          syntheticDeviceReplacementProjection(
            remoteWork: syntheticRemoteWork(
              stopOwnership: DeviceStopOwnership.unknown,
            ),
          ),
        ),
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
    });

    test('a revoked identity authorizes no outbound intent', () {
      final projection = revokedWithLostReceiptScenario();
      final offered = DeviceReplacementPolicy.offeredActions(projection);
      expect(
        offered,
        isNot(contains(DeviceReplacementAction.submitEraseConfirmation)),
      );
      expect(
        offered,
        isNot(contains(DeviceReplacementAction.requestRemoteStop)),
      );
      expect(DeviceReplacementPolicy.eraseConfirmation(projection), isNull);
    });
  });

  group('cleanup states stay truthful', () {
    test('offline is never an erased or complete badge', () {
      for (final outcome in [
        DeviceCleanupOutcome.offline,
        DeviceCleanupOutcome.platformDenied,
        DeviceCleanupOutcome.partial,
      ]) {
        final presentation = DeviceReplacementPolicy.cleanupPresentation(
          syntheticCleanupFacts(
            stage: DeviceCleanupStage.complete,
            outcome: outcome,
            receiptKind: DeviceCleanupReceiptKind.finalCleanup,
            receiptIssued: true,
            receiptDelivered: true,
            replacementEndpointConfirmed: true,
          ),
        );
        expect(presentation.erasedBadgeVisible, isFalse, reason: '$outcome');
        expect(
          presentation.status,
          isNot(DeviceCleanupStatus.confirmedComplete),
          reason: '$outcome',
        );
      }
    });

    test('a file-stage receipt is partial and never complete', () {
      final presentation = DeviceReplacementPolicy.cleanupPresentation(
        restrictedCleanupScenario().pendingCleanup,
      );
      expect(presentation.status, DeviceCleanupStatus.partial);
      expect(presentation.localSettlementComplete, isFalse);
      expect(presentation.erasedBadgeVisible, isFalse);
      expect(presentation.pendingEntryLabels, hasLength(2));
    });

    test(
      'all-stage settlement, receipt delivery and replacement confirmation are '
      'three separate observations',
      () {
        final settled = DeviceReplacementPolicy.cleanupPresentation(
          allStageSettlementScenario().pendingCleanup,
        );
        expect(settled.status, DeviceCleanupStatus.confirmedComplete);
        expect(settled.localSettlementComplete, isTrue);
        expect(settled.receiptDelivered, isTrue);
        expect(settled.replacementEndpointConfirmed, isTrue);
        expect(settled.erasedBadgeVisible, isTrue);

        final lost = DeviceReplacementPolicy.cleanupPresentation(
          lostReceiptScenario().pendingCleanup,
        );
        expect(lost.status, DeviceCleanupStatus.confirmedComplete);
        expect(lost.localSettlementComplete, isTrue);
        expect(lost.receiptDelivered, isFalse);
        expect(lost.replacementEndpointConfirmed, isFalse);
        expect(
          lost.erasedBadgeVisible,
          isFalse,
          reason: 'a lost receipt is never converted into erased evidence',
        );
        expect(
          lost.receiptDeliveryFailureCode,
          'cleanup_receipt_path_unavailable',
        );
      },
    );

    test(
      'a completion claim without the facts behind it degrades to partial',
      () {
        final presentation = DeviceReplacementPolicy.cleanupPresentation(
          syntheticCleanupFacts(
            stage: DeviceCleanupStage.filesSettled,
            outcome: DeviceCleanupOutcome.confirmedComplete,
            receiptKind: DeviceCleanupReceiptKind.fileStage,
            pendingEntryCount: 3,
            receiptIssued: true,
            receiptDelivered: true,
            replacementEndpointConfirmed: true,
          ),
        );
        expect(presentation.status, DeviceCleanupStatus.partial);
        expect(presentation.erasedBadgeVisible, isFalse);
      },
    );

    test('an unrequested cleanup is neither pending nor complete', () {
      final presentation = DeviceReplacementPolicy.cleanupPresentation(
        syntheticCleanupFacts(),
      );
      expect(presentation.status, DeviceCleanupStatus.notRequested);
      expect(presentation.erasedBadgeVisible, isFalse);
      expect(
        DeviceReplacementPolicy.offeredActions(authorizedReplacementScenario()),
        isNot(contains(DeviceReplacementAction.reviewPendingCleanup)),
      );
    });
  });

  group('unknown and late remote effects', () {
    test('an unknown effect offers no replay and carries no authority', () {
      const effect = DeviceRemoteEffectFacts(
        effectId: 'effect-unknown',
        label: 'Stop the selected work',
        state: DeviceRemoteEffectState.unknown,
      );
      final presentation = DeviceReplacementPolicy.effectPresentation(effect);
      expect(presentation.carriesOrdinaryAuthority, isFalse);
      expect(presentation.actionable, isFalse);
      expect(presentation.offeredActions, const [
        DeviceReplacementAction.refreshRemoteWorkState,
      ]);
      expect(
        presentation.reasonCode,
        DeviceReplacementPolicy.remoteEffectUnknown,
      );
      for (final action in presentation.offeredActions) {
        expect(action.name, isNot(contains('replay')));
        expect(action.name, isNot(contains('resend')));
      }
    });

    test('a late remote result keeps no ordinary authority', () {
      final late = DeviceReplacementPolicy.effectPresentation(
        syntheticRemoteEffect(lateResult: true),
      );
      expect(late.effect.state, DeviceRemoteEffectState.confirmed);
      expect(late.carriesOrdinaryAuthority, isFalse);
      expect(late.actionable, isFalse);
      expect(late.reasonCode, DeviceReplacementPolicy.remoteEffectLateResult);

      final current = DeviceReplacementPolicy.effectPresentation(
        syntheticRemoteEffect(),
      );
      expect(current.carriesOrdinaryAuthority, isTrue);
      expect(
        current.actionable,
        isFalse,
        reason: 'the control ledger never re-asks an answered request',
      );
      expect(
        current.reasonCode,
        DeviceReplacementPolicy.remoteEffectAlreadyAnswered,
      );
    });

    test('the vocabulary carries no action that re-drives an effect', () {
      for (final action in DeviceReplacementAction.values) {
        expect(action.name, isNot(contains('replay')), reason: action.name);
        expect(action.name, isNot(contains('resend')), reason: action.name);
        expect(
          action.name,
          isNot(contains('retryEffect')),
          reason: action.name,
        );
      }
    });
  });

  group('the app-only erase review', () {
    test(
      'an explicit review with native authentication builds a confirmation',
      () {
        final confirmation = DeviceReplacementPolicy.eraseConfirmation(
          authorizedReplacementScenario(),
        );
        expect(confirmation, isNotNull);
        expect(confirmation!.targetEndpointId, syntheticOldEndpointId);
        expect(confirmation.targetDeviceLabel, 'Old laptop');
        expect(confirmation.affectedDataCategoryLabels, hasLength(2));
        expect(
          confirmation.consequenceStatement,
          deviceAppOnlyEraseConsequenceStatement,
        );
        expect(confirmation.executesAfterReconnect, isTrue);
        expect(
          confirmation.postReconnectStatement,
          deviceAppOnlyErasePostReconnectStatement,
        );
      },
    );

    test('every unexplicit review field refuses the confirmation', () {
      final reviews = <String, DeviceEraseReviewFacts>{
        'not presented': syntheticEraseReview(reviewPresented: false),
        'no target': syntheticEraseReview(targetEndpointId: ''),
        'no device label': syntheticEraseReview(targetDeviceLabel: ''),
        'no data categories': syntheticEraseReview(
          affectedDataCategoryLabels: const [],
        ),
        'unnamed consequence': syntheticEraseReview(consequenceStatement: ''),
        'unnamed reconnect behaviour': syntheticEraseReview(
          postReconnectStatement: '',
        ),
        'reconnect not explained': syntheticEraseReview(
          executesAfterReconnect: false,
        ),
        'explicit confirmation not required': syntheticEraseReview(
          requiresExplicitConfirmation: false,
        ),
        'native authentication not required': syntheticEraseReview(
          requiresNativeAuthentication: false,
        ),
      };
      for (final entry in reviews.entries) {
        final projection = syntheticDeviceReplacementProjection(
          eraseReview: entry.value,
        );
        expect(
          DeviceReplacementPolicy.eraseConfirmation(projection),
          isNull,
          reason: entry.key,
        );
        expect(
          DeviceReplacementPolicy.eraseConfirmationRefusal(projection),
          DeviceReplacementPolicy.eraseRefusalReviewNotExplicit,
          reason: entry.key,
        );
      }
    });

    test('an unconfirmed review is refused', () {
      final projection = syntheticDeviceReplacementProjection(
        eraseReview: syntheticEraseReview(confirmed: false),
      );
      expect(DeviceReplacementPolicy.eraseConfirmation(projection), isNull);
      expect(
        DeviceReplacementPolicy.eraseConfirmationRefusal(projection),
        DeviceReplacementPolicy.eraseRefusalNotConfirmed,
      );
    });

    test('ordinary sign-in never stands in for native authentication', () {
      final projection = syntheticDeviceReplacementProjection(
        eraseReview: syntheticEraseReview(
          ordinarySignInPresent: true,
          nativeAuthenticationPresent: false,
        ),
      );
      expect(
        DeviceReplacementPolicy.eraseConfirmationRefusal(projection),
        DeviceReplacementPolicy.eraseRefusalNativeAuthenticationMissing,
      );
      expect(DeviceReplacementPolicy.eraseConfirmation(projection), isNull);
      expect(
        DeviceReplacementPolicy.offeredActions(projection),
        isNot(contains(DeviceReplacementAction.submitEraseConfirmation)),
      );
    });

    test('the vocabulary requests no key export', () {
      final names = [
        for (final action in DeviceReplacementAction.values) action.name,
      ];
      for (final name in names) {
        expect(name, isNot(matches(RegExp('export|key|secret|phrase'))));
      }
      final confirmation = DeviceReplacementPolicy.eraseConfirmation(
        authorizedReplacementScenario(),
      )!;
      expect(
        confirmation.affectedDataCategoryLabels,
        authorizedReplacementScenario().eraseReview.affectedDataCategoryLabels,
        reason: 'the confirmation carries the bounded review facts only',
      );
    });
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);
