import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';

abstract interface class OptionalCollaborationWorkflowActionContext {
  OptionalCollaborationGateway get gateway;
  OptionalCollaborationWorkflowCatalog? get catalog;

  OptionalCollaborationWorkflowPlan? get localDeploymentPlan;
  set localDeploymentPlan(OptionalCollaborationWorkflowPlan? value);

  OptionalCollaborationWorkflowPlan? get mcpInstallPlan;
  set mcpInstallPlan(OptionalCollaborationWorkflowPlan? value);

  OptionalCollaborationWorkflowApplyResult? get lastApplyResult;
  set lastApplyResult(OptionalCollaborationWorkflowApplyResult? value);

  List<OptionalLocalServerState> get localServers;
  set localServers(List<OptionalLocalServerState> value);

  bool beginAction();
  void endAction();
  bool rejectAction(String errorCode, String chinese, String english);
  void failAction(String errorCode, String chinese, String english);
  void reportAction(String chinese, String english, {String errorCode = ''});
  OptionalLocalServerState? localServerById(String deploymentId);
  void replaceLocalServer(OptionalLocalServerState server);
}
