import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

mixin ClientTargetFacade on AgentWorkspaceCoordinator {
  TargetController get targetController;

  @override
  List<TargetCandidate> get scannedTargets => targetController.targets;

  @override
  set scannedTargets(List<TargetCandidate> value) {
    targetController.replaceTargets(value);
  }

  List<String> get agentTabOrder => targetController.tabOrder;

  set agentTabOrder(List<String> value) {
    targetController.replaceTabOrder(value);
  }

  Map<String, dynamic>? get targetInspection => targetController.inspection;
  Map<String, dynamic>? get snapshotRestoreResult =>
      targetController.snapshotRestoreResult;
  @override
  bool get initialized => lifecycleProjection.initialized;

  bool get isScanningTargets => targetController.isScanning;
  bool get isAddingTarget => targetController.isAdding;

  Future<void> scanTargets({
    bool showProgress = true,
    bool? surfaceErrors,
    bool forceRescanKnown = false,
  }) => targetController.scan(
    showProgress: showProgress,
    surfaceErrors: surfaceErrors,
    forceRescanKnown: forceRescanKnown,
  );

  @override
  Future<bool> agentWorkspaceEnsureConversationRuntimeBinding(String agentId) =>
      targetController.ensureConversationRuntimeBinding(agentId);

  Future<void> addManualTarget({
    required String target,
    String configPath = '',
    String binaryPath = '',
    String historyRoot = '',
    String location = 'local',
    Map<String, dynamic> runtimeConnection = const <String, dynamic>{},
  }) => targetController.addManualTarget(
    target: target,
    configPath: configPath,
    binaryPath: binaryPath,
    historyRoot: historyRoot,
    location: location,
    runtimeConnection: runtimeConnection,
  );

  Future<void> inspectTarget(String target) =>
      targetController.inspectTarget(target);

  Future<void> restoreSnapshot(String snapshotId) =>
      targetController.restoreSnapshot(snapshotId);

  Future<void> reorderConversationAgentTabs(
    List<TargetCandidate> visibleTargets,
    int oldIndex,
    int newIndex,
  ) => targetController.reorderConversationAgentTabs(
    visibleTargets,
    oldIndex,
    newIndex,
  );
}
