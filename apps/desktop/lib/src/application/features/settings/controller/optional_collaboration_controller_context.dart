import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_gateway.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

abstract interface class OptionalCollaborationControllerContext {
  OptionalCollaborationGateway get gateway;
  OptionalCollaborationWorkflowController get workflows;

  OptionalCollaborationRuntimeState? get state;
  set state(OptionalCollaborationRuntimeState? value);

  OptionalCollaborationInstallPlan? get installPlan;
  set installPlan(OptionalCollaborationInstallPlan? value);

  OptionalCollaborationWorkflowCatalog? get workflowCatalog;
  set workflowCatalog(OptionalCollaborationWorkflowCatalog? value);

  bool get statusLoaded;
  set statusLoaded(bool value);

  bool beginAction();
  void endAction();
  bool rejectAction(String errorCode, String chinese, String english);
  void failAction(String errorCode, String chinese, String english);
  void reportAction(String chinese, String english, {String errorCode = ''});
  void clearWorkflowCatalog();
  Future<void> purgeWorkflowCatalog();
}
