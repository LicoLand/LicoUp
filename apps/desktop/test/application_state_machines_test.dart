import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/generated/state_machines.g.dart';
import 'package:licoup/src/application/features/layout/generated/layout_selection_state_machine.g.dart';
import 'package:licoup/src/contracts/generated/client_update_state_machine.g.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/presentation/generated/settings_state_machines.g.dart';

void main() {
  test('client lifecycle rejects edges absent from the declarative table', () {
    expect(
      transitionClientLifecyclePhase(
        ClientLifecyclePhase.idle,
        ClientLifecycleEvent.initialize,
      ),
      ClientLifecyclePhase.initializing,
    );
    expect(
      transitionClientLifecyclePhase(
        ClientLifecyclePhase.ready,
        ClientLifecycleEvent.initializationFailed,
      ),
      isNull,
    );
  });

  test('catalog and gateway observations resolve through generated tables', () {
    expect(
      transitionCatalogConvergencePhase(
        CatalogConvergencePhase.failed,
        CatalogConvergenceEvent.reconcile,
      ),
      CatalogConvergencePhase.reconciling,
    );
    expect(
      transitionLlmGatewayRuntimeState(
        LlmGatewayRuntimeState.unhealthy,
        LlmGatewayRuntimeEvent.reportRunning,
      ),
      LlmGatewayRuntimeState.running,
    );
  });

  test('turn process is monotonic and failed is terminal', () {
    expect(
      transitionConversationTurnProcessStage(
        ConversationTurnProcessStage.submitted,
        ConversationTurnProcessEvent.processing,
      ),
      ConversationTurnProcessStage.processing,
    );
    expect(
      transitionConversationTurnProcessStage(
        ConversationTurnProcessStage.processing,
        ConversationTurnProcessEvent.accepted,
      ),
      isNull,
    );
    expect(
      transitionConversationTurnProcessStage(
        ConversationTurnProcessStage.failed,
        ConversationTurnProcessEvent.completed,
      ),
      isNull,
    );
  });

  test('client update allows only the declared signed-update sequence', () {
    expect(
      transitionClientUpdatePhase(
        ClientUpdatePhase.updateAvailable,
        ClientUpdateEvent.download,
      ),
      ClientUpdatePhase.downloading,
    );
    expect(
      transitionClientUpdatePhase(
        ClientUpdatePhase.idle,
        ClientUpdateEvent.apply,
      ),
      isNull,
    );
  });

  test('autostart apply begins only from a ready projection', () {
    expect(
      transitionSettingsAutostartPhase(
        SettingsAutostartPhase.ready,
        SettingsAutostartEvent.apply,
      ),
      SettingsAutostartPhase.applying,
    );
    expect(
      transitionSettingsAutostartPhase(
        SettingsAutostartPhase.failed,
        SettingsAutostartEvent.apply,
      ),
      isNull,
    );
  });

  test('layout selection commits and recovers only through declared edges', () {
    expect(layoutSelectionStatusInitial, LayoutSelectionStatus.loading);
    expect(
      transitionLayoutSelectionStatus(
        LayoutSelectionStatus.stable,
        LayoutSelectionEvent.beginCommit,
      ),
      LayoutSelectionStatus.committing,
    );
    expect(
      transitionLayoutSelectionStatus(
        LayoutSelectionStatus.committing,
        LayoutSelectionEvent.reject,
      ),
      isNull,
    );
  });
}
