import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller_context.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_install_actions.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_lifecycle_actions.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_runner_trust_actions.dart';
import 'package:licoup/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationStatusUpdate {
  const OptionalCollaborationStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String errorCode;
}

typedef OptionalCollaborationStatusSink =
    void Function(OptionalCollaborationStatusUpdate update);

/// Inert façade over independent lifecycle, runner-trust, installation, and
/// workflow controllers. Construction performs no native or network action.
final class OptionalCollaborationController extends ChangeNotifier
    implements OptionalCollaborationControllerContext {
  OptionalCollaborationController({
    required OptionalCollaborationGateway gateway,
    OptionalCollaborationStatusSink? onStatus,
    Future<void> Function()? onCatalogPurge,
  }) : _gateway = gateway,
       _onStatus = onStatus,
       _onCatalogPurge = onCatalogPurge {
    workflows = OptionalCollaborationWorkflowController(
      gateway: gateway,
      onStatus: ({required chinese, required english, String errorCode = ''}) =>
          reportAction(chinese, english, errorCode: errorCode),
    );
    _lifecycle = OptionalCollaborationLifecycleActions(this);
    _runnerTrust = OptionalCollaborationRunnerTrustActions(this);
    _install = OptionalCollaborationInstallActions(this);
    workflows.addListener(_forwardWorkflowChange);
  }

  final OptionalCollaborationGateway _gateway;
  final OptionalCollaborationStatusSink? _onStatus;
  final Future<void> Function()? _onCatalogPurge;
  late final OptionalCollaborationLifecycleActions _lifecycle;
  late final OptionalCollaborationRunnerTrustActions _runnerTrust;
  late final OptionalCollaborationInstallActions _install;

  @override
  late final OptionalCollaborationWorkflowController workflows;

  OptionalCollaborationRuntimeState? _state;
  OptionalCollaborationInstallPlan? _installPlan;
  OptionalCollaborationWorkflowCatalog? _workflowCatalog;
  bool _busy = false;
  bool _statusLoaded = false;
  String _errorCode = '';

  @override
  OptionalCollaborationGateway get gateway => _gateway;

  @override
  OptionalCollaborationRuntimeState? get state => _state;

  @override
  set state(OptionalCollaborationRuntimeState? value) => _state = value;

  @override
  OptionalCollaborationInstallPlan? get installPlan => _installPlan;

  @override
  set installPlan(OptionalCollaborationInstallPlan? value) =>
      _installPlan = value;

  @override
  OptionalCollaborationWorkflowCatalog? get workflowCatalog => _workflowCatalog;

  @override
  set workflowCatalog(OptionalCollaborationWorkflowCatalog? value) =>
      _workflowCatalog = value;

  bool get busy => _busy || workflows.busy;

  @override
  bool get statusLoaded => _statusLoaded;

  @override
  set statusLoaded(bool value) => _statusLoaded = value;

  bool get catalogLoaded => _workflowCatalog != null;
  String get errorCode =>
      _errorCode.isNotEmpty ? _errorCode : workflows.errorCode;

  Future<bool> loadStatus() => _lifecycle.loadStatus();

  Future<bool> enable({required bool confirmed}) =>
      _lifecycle.enable(confirmed: confirmed);

  Future<bool> importRunnerTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String expectedFingerprintSha256,
    required bool confirmed,
  }) => _runnerTrust.importTrust(
    keyId: keyId,
    publicKeyBase64url: publicKeyBase64url,
    sourceRepositoryUrl: sourceRepositoryUrl,
    expectedFingerprintSha256: expectedFingerprintSha256,
    confirmed: confirmed,
  );

  Future<bool> removeRunnerTrust({required bool confirmed}) =>
      _runnerTrust.removeTrust(confirmed: confirmed);

  Future<bool> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    bool confirmed = false,
  }) => _install.plan(
    githubUrl: githubUrl,
    gitRef: gitRef,
    pluginPath: pluginPath,
    confirmed: confirmed,
  );

  Future<bool> applyInstall({required bool confirmed}) =>
      _install.apply(confirmed: confirmed);

  Future<bool> cancelInstall({required bool confirmed}) =>
      _install.cancel(confirmed: confirmed);

  Future<bool> loadWorkflowCatalog() => _install.loadCatalog();

  Future<bool> disable({required bool confirmed}) =>
      _lifecycle.disable(confirmed: confirmed);

  Future<bool> uninstall({required bool confirmed}) =>
      _lifecycle.uninstall(confirmed: confirmed);

  @override
  bool beginAction() {
    if (_busy || workflows.busy) return false;
    _busy = true;
    _errorCode = '';
    notifyListeners();
    return true;
  }

  @override
  void endAction() {
    _busy = false;
    notifyListeners();
  }

  @override
  bool rejectAction(String errorCode, String chinese, String english) {
    _errorCode = errorCode;
    reportAction(chinese, english, errorCode: errorCode);
    notifyListeners();
    return false;
  }

  @override
  void failAction(String errorCode, String chinese, String english) {
    _errorCode = errorCode;
    reportAction(chinese, english, errorCode: errorCode);
  }

  @override
  void reportAction(String chinese, String english, {String errorCode = ''}) {
    _onStatus?.call(
      OptionalCollaborationStatusUpdate(
        chinese: chinese,
        english: english,
        errorCode: errorCode,
      ),
    );
  }

  @override
  void clearWorkflowCatalog() {
    _workflowCatalog = null;
    workflows.replaceCatalog(null);
  }

  @override
  Future<void> purgeWorkflowCatalog() async {
    clearWorkflowCatalog();
    await _onCatalogPurge?.call();
  }

  void _forwardWorkflowChange() => notifyListeners();

  @override
  void dispose() {
    workflows.removeListener(_forwardWorkflowChange);
    workflows.dispose();
    super.dispose();
  }
}
