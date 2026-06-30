part of 'future_client_controller.dart';

extension FutureClientSecureMeshActions on FutureClientController {
  Future<void> refreshSecureMeshStatus() async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在刷新 Secure Mesh 状态。';
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      secureMeshStatus = await mobileRelayService.secureMeshStatus(
        agentService: agentService,
      );
      statusMessage = 'Secure Mesh 状态已刷新。';
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to refresh secure mesh status: $error');
      secureMeshStatus = {'ok': false, 'error': error.toString()};
      lastError = error.toString();
      statusMessage = 'Secure Mesh 状态刷新失败。';
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> _refreshSecureMeshStatusSilently() async {
    try {
      secureMeshStatus = await mobileRelayService.secureMeshStatus(
        agentService: agentService,
      );
    } catch (error) {
      debugPrint('Failed to load secure mesh status: $error');
      secureMeshStatus = {'ok': false, 'error': error.toString()};
    }
  }

  Future<void> evaluateSecureMeshDeviceTrustPolicy({
    required Map<String, dynamic> identity,
    Map<String, dynamic>? previousIdentity,
    String trustState = 'unverified',
    bool requireVerifiedDevice = true,
    bool allowUnverifiedReadOnly = false,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在评估 Secure Mesh 设备信任策略。';
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      secureMeshDeviceTrustPolicy = await mobileRelayService
          .evaluateSecureMeshDeviceTrust(
            agentService: agentService,
            identity: identity,
            previousIdentity: previousIdentity,
            trustState: trustState,
            requireVerifiedDevice: requireVerifiedDevice,
            allowUnverifiedReadOnly: allowUnverifiedReadOnly,
          );
      statusMessage = 'Secure Mesh 设备信任策略已评估。';
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to evaluate secure mesh device trust: $error');
      secureMeshDeviceTrustPolicy = {'ok': false, 'error': error.toString()};
      lastError = error.toString();
      statusMessage = 'Secure Mesh 设备信任策略评估失败。';
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> evaluateSecureMeshFileRoute({
    required Map<String, dynamic> manifest,
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    statusMessage = '正在评估 Secure Mesh 文件路由。';
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      secureMeshFileRoute = await mobileRelayService
          .evaluateSecureMeshFileRoute(
            agentService: agentService,
            manifest: manifest,
          );
      statusMessage = 'Secure Mesh 文件路由已评估。';
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to evaluate secure mesh file route: $error');
      secureMeshFileRoute = {'ok': false, 'error': error.toString()};
      lastError = error.toString();
      statusMessage = 'Secure Mesh 文件路由评估失败。';
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }
}
