part of 'package:flutter_client/src/application/controller/client_controller.dart';

extension ClientSecureMeshActions on ClientController {
  Future<void> refreshSecureMeshStatus({bool authorize = true}) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在刷新 Secure Mesh 状态。',
      'Refreshing Secure Mesh status.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      final status = await mobileRelayService.secureMeshStatus(
        agentService: agentService,
        authorize: authorize,
      );
      final projection = secureMeshCapabilityService.projectStatus(status);
      secureMeshStatus = status;
      secureMeshCapabilityProjection = projection;
      _setLocalizedStatusMessage(
        'Secure Mesh 状态已刷新。',
        'Secure Mesh status refreshed.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to refresh secure mesh status: $error');
      secureMeshStatus = {'ok': false, 'error': error.toString()};
      secureMeshCapabilityProjection = null;
      lastError = error.toString();
      _setLocalizedStatusMessage(
        'Secure Mesh 状态刷新失败。',
        'Failed to refresh Secure Mesh status.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
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
    _setLocalizedStatusMessage(
      '正在评估 Secure Mesh 设备信任策略。',
      'Evaluating the Secure Mesh device trust policy.',
    );
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
      _setLocalizedStatusMessage(
        'Secure Mesh 设备信任策略已评估。',
        'Secure Mesh device trust policy evaluated.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to evaluate secure mesh device trust: $error');
      secureMeshDeviceTrustPolicy = {'ok': false, 'error': error.toString()};
      lastError = error.toString();
      _setLocalizedStatusMessage(
        'Secure Mesh 设备信任策略评估失败。',
        'Failed to evaluate the Secure Mesh device trust policy.',
      );
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
    _setLocalizedStatusMessage(
      '正在评估 Secure Mesh 文件路由。',
      'Evaluating the Secure Mesh file route.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      secureMeshFileRoute = await mobileRelayService
          .evaluateSecureMeshFileRoute(
            agentService: agentService,
            manifest: manifest,
          );
      _setLocalizedStatusMessage(
        'Secure Mesh 文件路由已评估。',
        'Secure Mesh file route evaluated.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to evaluate secure mesh file route: $error');
      secureMeshFileRoute = {'ok': false, 'error': error.toString()};
      lastError = error.toString();
      _setLocalizedStatusMessage(
        'Secure Mesh 文件路由评估失败。',
        'Failed to evaluate the Secure Mesh file route.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> evaluateSecureMeshFileReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
  }) async {
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      '正在评估安全网格文件接收位置。',
      'Evaluating the Secure Mesh file receive destination.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      secureMeshFileReceiveDestination = await mobileRelayService
          .evaluateSecureMeshFileReceiveDestination(
            agentService: agentService,
            manifest: manifest,
            approvedRoot: approvedRoot,
            conflictPolicy: conflictPolicy,
          );
      _setLocalizedStatusMessage(
        '安全网格文件接收位置已评估。',
        'Secure Mesh file receive destination evaluated.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint(
        'Failed to evaluate secure mesh file receive destination: $error',
      );
      secureMeshFileReceiveDestination = {
        'ok': false,
        'error': error.toString(),
      };
      lastError = error.toString();
      _setLocalizedStatusMessage(
        '安全网格文件接收位置评估失败。',
        'Secure Mesh file receive destination evaluation failed.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  void setSecureMeshFileSyncDraft({
    required String fileName,
    required int totalSize,
    String mimeType = 'application/octet-stream',
    String relativePath = '.',
    String conflictPolicy = 'fail_if_exists',
  }) {
    final normalizedName = p.basename(fileName.trim());
    if (normalizedName.isEmpty || totalSize <= 0) {
      lastError = 'secure_mesh_file_sync_source_invalid';
      _setLocalizedStatusMessage(
        '文件同步源无效。',
        'The file-sync source is invalid.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    final chunkSize = secureMeshFileSyncDefaultChunkSize.clamp(1, totalSize);
    final chunkCount = secureMeshFileSyncChunkCount(totalSize, chunkSize);
    final transferId =
        'file-sync-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    secureMeshFileSyncDraft = SecureMeshFileSyncTransfer(
      id: transferId,
      fileId: transferId,
      fileName: normalizedName,
      mimeType: mimeType.trim().isEmpty ? 'application/octet-stream' : mimeType,
      relativePath: relativePath.trim().isEmpty ? '.' : relativePath.trim(),
      destinationRoot: '',
      conflictPolicy: conflictPolicy.trim().isEmpty
          ? 'fail_if_exists'
          : conflictPolicy.trim(),
      totalSize: totalSize,
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      status: SecureMeshFileSyncStatus.drafting,
    );
    lastError = '';
    _setLocalizedStatusMessage(
      '已选择文件 $normalizedName，请确认目标目录。',
      'Selected $normalizedName. Confirm the destination directory.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
  }

  void setSecureMeshFileSyncDestination(String destinationRoot) {
    final draft = secureMeshFileSyncDraft;
    final normalizedRoot = destinationRoot.trim();
    if (draft == null) {
      lastError = 'secure_mesh_file_sync_draft_missing';
      _setLocalizedStatusMessage('请先选择要同步的文件。', 'Choose a file to sync first.');
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    if (normalizedRoot.isEmpty || !p.isAbsolute(normalizedRoot)) {
      lastError = 'secure_mesh_file_sync_destination_invalid';
      _setLocalizedStatusMessage(
        '目标目录必须是已批准的绝对路径。',
        'The destination must be an approved absolute directory.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    secureMeshFileSyncDraft = draft.copyWith(destinationRoot: normalizedRoot);
    lastError = '';
    _setLocalizedStatusMessage(
      '目标目录已设置，准备评估文件同步。',
      'Destination set. Ready to evaluate the file-sync transfer.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
  }

  Future<void> prepareSecureMeshFileSyncTransfer() async {
    final draft = secureMeshFileSyncDraft;
    if (draft == null) {
      lastError = 'secure_mesh_file_sync_draft_missing';
      _setLocalizedStatusMessage('请先选择要同步的文件。', 'Choose a file to sync first.');
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    if (draft.destinationRoot.trim().isEmpty) {
      lastError = 'secure_mesh_file_sync_destination_missing';
      _setLocalizedStatusMessage(
        '请先确认目标目录。',
        'Confirm the destination directory first.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    secureMeshFileSyncDraft = draft.copyWith(
      status: SecureMeshFileSyncStatus.evaluating,
      errorCode: '',
    );
    _setLocalizedStatusMessage(
      '正在评估 Secure Mesh 文件同步路由与接收确认策略。',
      'Evaluating Secure Mesh file-sync route and receive confirmation policy.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      final manifest = draft.toManifest();
      final route = await mobileRelayService.evaluateSecureMeshFileRoute(
        agentService: agentService,
        manifest: manifest,
      );
      secureMeshFileRoute = route;
      if (route['ok'] != true) {
        throw StateError('secure_mesh_file_sync_route_failed');
      }
      final destination = await mobileRelayService
          .evaluateSecureMeshFileReceiveDestination(
            agentService: agentService,
            manifest: manifest,
            approvedRoot: draft.destinationRoot,
            conflictPolicy: draft.conflictPolicy,
          );
      secureMeshFileReceiveDestination = destination;
      if (destination['ok'] != true ||
          destination['receivePolicy']?['destinationApproved'] != true) {
        throw StateError('secure_mesh_file_sync_destination_denied');
      }
      final confirmation = await mobileRelayService
          .evaluateSecureMeshFileReceiveConfirmation(
            agentService: agentService,
            manifest: manifest,
            approvedRoot: draft.destinationRoot,
            conflictPolicy: draft.conflictPolicy,
            userConfirmed: false,
          );
      secureMeshFileReceiveConfirmation = confirmation;
      if (confirmation['ok'] != true ||
          confirmation['receiveConfirmation']?['required'] != true ||
          confirmation['receiveConfirmation']?['writeAllowed'] == true ||
          confirmation['receiveConfirmation']?['autoPreviewEnabled'] == true ||
          confirmation['receiveConfirmation']?['autoIngestionEnabled'] ==
              true) {
        throw StateError('secure_mesh_file_sync_confirmation_policy_invalid');
      }
      final pending = draft.copyWith(
        status: SecureMeshFileSyncStatus.awaitingConfirmation,
        errorCode: '',
      );
      secureMeshFileSyncDraft = pending;
      secureMeshFileSyncTransfers = _upsertSecureMeshFileSyncTransfer(pending);
      _setLocalizedStatusMessage(
        '文件同步等待本地确认写入：${draft.fileName} → ${draft.destinationRoot}',
        'File-sync awaiting local write confirmation: ${draft.fileName} → ${draft.destinationRoot}',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to prepare secure mesh file sync: $error');
      final failed = draft.copyWith(
        status: SecureMeshFileSyncStatus.failed,
        errorCode: 'secure_mesh_file_sync_prepare_failed',
      );
      secureMeshFileSyncDraft = failed;
      secureMeshFileSyncTransfers = _upsertSecureMeshFileSyncTransfer(failed);
      lastError = 'secure_mesh_file_sync_prepare_failed';
      _setLocalizedStatusMessage(
        'Secure Mesh 文件同步准备失败。',
        'Secure Mesh file-sync preparation failed.',
      );
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  Future<void> confirmSecureMeshFileSyncReceive({
    required bool userConfirmed,
  }) async {
    final draft = secureMeshFileSyncDraft;
    if (draft == null ||
        draft.status != SecureMeshFileSyncStatus.awaitingConfirmation) {
      lastError = 'secure_mesh_file_sync_confirmation_unavailable';
      _setLocalizedStatusMessage(
        '没有等待确认的文件同步。',
        'No file-sync transfer is awaiting confirmation.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    if (isMobileRelayBusy) {
      return;
    }
    isMobileRelayBusy = true;
    lastError = '';
    _setLocalizedStatusMessage(
      userConfirmed ? '正在确认文件同步写入。' : '正在拒绝文件同步写入。',
      userConfirmed
          ? 'Confirming the file-sync write.'
          : 'Rejecting the file-sync write.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
    try {
      final confirmation = await mobileRelayService
          .evaluateSecureMeshFileReceiveConfirmation(
            agentService: agentService,
            manifest: draft.toManifest(),
            approvedRoot: draft.destinationRoot,
            conflictPolicy: draft.conflictPolicy,
            userConfirmed: userConfirmed,
          );
      secureMeshFileReceiveConfirmation = confirmation;
      if (confirmation['ok'] != true) {
        throw StateError('secure_mesh_file_sync_confirmation_failed');
      }
      if (userConfirmed) {
        if (confirmation['receiveConfirmation']?['writeAllowed'] != true ||
            confirmation['receiveConfirmation']?['userConfirmed'] != true ||
            confirmation['receiveConfirmation']?['autoPreviewEnabled'] ==
                true ||
            confirmation['receiveConfirmation']?['autoIngestionEnabled'] ==
                true) {
          throw StateError('secure_mesh_file_sync_confirmation_denied');
        }
        final confirmed = draft.copyWith(
          status: SecureMeshFileSyncStatus.confirmed,
          errorCode: '',
        );
        secureMeshFileSyncDraft = confirmed;
        secureMeshFileSyncTransfers = _upsertSecureMeshFileSyncTransfer(
          confirmed,
        );
        _setLocalizedStatusMessage(
          '已确认文件同步写入（无自动预览/入库）。',
          'File-sync write confirmed (no auto-preview or ingestion).',
        );
      } else {
        final rejected = draft.copyWith(
          status: SecureMeshFileSyncStatus.rejected,
          errorCode: '',
        );
        secureMeshFileSyncDraft = rejected;
        secureMeshFileSyncTransfers = _upsertSecureMeshFileSyncTransfer(
          rejected,
        );
        _setLocalizedStatusMessage('已拒绝文件同步写入。', 'File-sync write rejected.');
      }
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed to confirm secure mesh file sync: $error');
      final failed = draft.copyWith(
        status: SecureMeshFileSyncStatus.failed,
        errorCode: 'secure_mesh_file_sync_confirm_failed',
      );
      secureMeshFileSyncDraft = failed;
      secureMeshFileSyncTransfers = _upsertSecureMeshFileSyncTransfer(failed);
      lastError = 'secure_mesh_file_sync_confirm_failed';
      _setLocalizedStatusMessage('文件同步确认失败。', 'File-sync confirmation failed.');
      statusCaption = 'Secure Mesh';
    } finally {
      isMobileRelayBusy = false;
      _notifyStateChanged();
    }
  }

  List<SecureMeshFileSyncTransfer> _upsertSecureMeshFileSyncTransfer(
    SecureMeshFileSyncTransfer transfer,
  ) {
    final next = <SecureMeshFileSyncTransfer>[
      for (final item in secureMeshFileSyncTransfers)
        if (item.id != transfer.id) item,
      transfer,
    ];
    if (next.length <= 12) {
      return List<SecureMeshFileSyncTransfer>.unmodifiable(next);
    }
    return List<SecureMeshFileSyncTransfer>.unmodifiable(
      next.sublist(next.length - 12),
    );
  }

  void beginSecureMeshSkillSyncDraft({
    required String skillId,
    required String version,
    required String sourceAgentId,
    required String targetAgentId,
    required String packageDigest,
    required String packageFileName,
    required int packageSize,
    String mimeType = 'application/zip',
    bool activate = false,
  }) {
    final normalizedSkill = skillId.trim();
    final normalizedTarget = targetAgentId.trim();
    final normalizedDigest = packageDigest.trim().toLowerCase();
    if (normalizedSkill.isEmpty ||
        normalizedTarget.isEmpty ||
        normalizedDigest.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedDigest)) {
      lastError = 'secure_mesh_skill_sync_draft_invalid';
      _setLocalizedStatusMessage(
        '技能同步草稿无效。',
        'The skill-sync draft is invalid.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    setSecureMeshFileSyncDraft(
      fileName: packageFileName,
      totalSize: packageSize,
      mimeType: mimeType,
      relativePath: 'skills/$normalizedSkill',
    );
    final fileDraft = secureMeshFileSyncDraft;
    if (fileDraft == null) {
      return;
    }
    final transferId =
        'skill-sync-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    secureMeshSkillSyncDraft = SecureMeshSkillSyncTransfer(
      id: transferId,
      skillId: normalizedSkill,
      version: version.trim().isEmpty ? '0.0.0' : version.trim(),
      sourceAgentId: sourceAgentId.trim(),
      targetAgentId: normalizedTarget,
      packageDigest: normalizedDigest,
      activate: activate,
      fileTransfer: fileDraft,
      status: SecureMeshSkillSyncStatus.drafting,
    );
    lastError = '';
    _setLocalizedStatusMessage(
      '已准备技能同步 $normalizedSkill → $normalizedTarget。',
      'Prepared skill-sync $normalizedSkill → $normalizedTarget.',
    );
    statusCaption = 'Secure Mesh';
    _notifyStateChanged();
  }

  Future<void> prepareSecureMeshSkillSyncTransfer() async {
    final skillDraft = secureMeshSkillSyncDraft;
    if (skillDraft == null) {
      lastError = 'secure_mesh_skill_sync_draft_missing';
      _setLocalizedStatusMessage(
        '请先准备技能同步草稿。',
        'Prepare a skill-sync draft first.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    secureMeshSkillSyncDraft = skillDraft.copyWith(
      status: SecureMeshSkillSyncStatus.transferring,
      fileTransfer: secureMeshFileSyncDraft ?? skillDraft.fileTransfer,
    );
    await prepareSecureMeshFileSyncTransfer();
    final fileDraft = secureMeshFileSyncDraft;
    if (fileDraft == null) {
      return;
    }
    if (fileDraft.status == SecureMeshFileSyncStatus.awaitingConfirmation) {
      secureMeshSkillSyncDraft = skillDraft.copyWith(
        status: SecureMeshSkillSyncStatus.awaitingInstall,
        fileTransfer: fileDraft,
        errorCode: '',
      );
      secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
        secureMeshSkillSyncDraft!,
      );
      _setLocalizedStatusMessage(
        '技能加密包已就绪（file-sync 基底），确认写入后将交由 Skill Hub 安装；尚未声明生产证据。',
        'Encrypted skill package ready on the file-sync substrate; after write confirmation Skill Hub install runs. Production evidence is not claimed.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    secureMeshSkillSyncDraft = skillDraft.copyWith(
      status: SecureMeshSkillSyncStatus.failed,
      fileTransfer: fileDraft,
      errorCode: 'secure_mesh_skill_sync_prepare_failed',
    );
    secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
      secureMeshSkillSyncDraft!,
    );
    lastError = 'secure_mesh_skill_sync_prepare_failed';
    _notifyStateChanged();
  }

  Future<void> confirmSecureMeshSkillSyncInstall({
    required bool userConfirmed,
  }) async {
    final skillDraft = secureMeshSkillSyncDraft;
    if (skillDraft == null ||
        skillDraft.status != SecureMeshSkillSyncStatus.awaitingInstall) {
      lastError = 'secure_mesh_skill_sync_confirmation_unavailable';
      _setLocalizedStatusMessage(
        '没有等待安装的技能同步。',
        'No skill-sync transfer is awaiting install.',
      );
      statusCaption = 'Secure Mesh';
      _notifyStateChanged();
      return;
    }
    await confirmSecureMeshFileSyncReceive(userConfirmed: userConfirmed);
    final fileDraft = secureMeshFileSyncDraft;
    if (!userConfirmed) {
      secureMeshSkillSyncDraft = skillDraft.copyWith(
        status: SecureMeshSkillSyncStatus.failed,
        fileTransfer: fileDraft ?? skillDraft.fileTransfer,
        errorCode: 'secure_mesh_skill_sync_rejected',
      );
      secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
        secureMeshSkillSyncDraft!,
      );
      _notifyStateChanged();
      return;
    }
    if (fileDraft?.status != SecureMeshFileSyncStatus.confirmed) {
      secureMeshSkillSyncDraft = skillDraft.copyWith(
        status: SecureMeshSkillSyncStatus.failed,
        fileTransfer: fileDraft ?? skillDraft.fileTransfer,
        errorCode: 'secure_mesh_skill_sync_confirm_failed',
      );
      secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
        secureMeshSkillSyncDraft!,
      );
      lastError = 'secure_mesh_skill_sync_confirm_failed';
      _notifyStateChanged();
      return;
    }
    secureMeshSkillSyncDraft = skillDraft.copyWith(
      status: SecureMeshSkillSyncStatus.installing,
      fileTransfer: fileDraft!,
      errorCode: '',
    );
    _notifyStateChanged();
    try {
      // Install handoff reuses Skill Hub apply against the confirmed package
      // landing path; package code is never executed during transit/preview.
      final sourcePath = p.join(
        fileDraft.destinationRoot,
        fileDraft.relativePath,
        fileDraft.fileName,
      );
      skillInstallResult = await agentService.applySkillInstall(
        agent: skillDraft.targetAgentId,
        sourcePath: sourcePath,
        name: skillDraft.skillId,
        pin: skillDraft.activate,
      );
      final installed = skillInstallResult?['ok'] == true;
      secureMeshSkillSyncDraft = skillDraft.copyWith(
        status: installed
            ? SecureMeshSkillSyncStatus.installed
            : SecureMeshSkillSyncStatus.failed,
        fileTransfer: fileDraft,
        errorCode: installed ? '' : 'secure_mesh_skill_sync_install_failed',
      );
      secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
        secureMeshSkillSyncDraft!,
      );
      if (!installed) {
        lastError = 'secure_mesh_skill_sync_install_failed';
      }
      _setLocalizedStatusMessage(
        installed ? '技能同步安装完成：${skillDraft.skillId}' : '技能同步安装失败。',
        installed
            ? 'Skill-sync install completed: ${skillDraft.skillId}'
            : 'Skill-sync install failed.',
      );
      statusCaption = 'Secure Mesh';
    } catch (error) {
      debugPrint('Failed skill-sync install handoff: $error');
      secureMeshSkillSyncDraft = skillDraft.copyWith(
        status: SecureMeshSkillSyncStatus.failed,
        fileTransfer: fileDraft,
        errorCode: 'secure_mesh_skill_sync_install_failed',
      );
      secureMeshSkillSyncTransfers = _upsertSecureMeshSkillSyncTransfer(
        secureMeshSkillSyncDraft!,
      );
      lastError = 'secure_mesh_skill_sync_install_failed';
      _setLocalizedStatusMessage('技能同步安装失败。', 'Skill-sync install failed.');
      statusCaption = 'Secure Mesh';
    } finally {
      _notifyStateChanged();
    }
  }

  List<SecureMeshSkillSyncTransfer> _upsertSecureMeshSkillSyncTransfer(
    SecureMeshSkillSyncTransfer transfer,
  ) {
    final next = <SecureMeshSkillSyncTransfer>[
      for (final item in secureMeshSkillSyncTransfers)
        if (item.id != transfer.id) item,
      transfer,
    ];
    if (next.length <= 12) {
      return List<SecureMeshSkillSyncTransfer>.unmodifiable(next);
    }
    return List<SecureMeshSkillSyncTransfer>.unmodifiable(
      next.sublist(next.length - 12),
    );
  }
}
