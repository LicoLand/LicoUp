import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_file_transfer_controller.dart';
import 'package:flutter_client/src/application/features/mobile_relay/policy/secure_mesh_policy.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';

/// Owns skill package transfer and the explicit Skill Hub install handoff.
final class SecureMeshSkillTransferController extends ChangeNotifier {
  SecureMeshSkillTransferController({
    required SecureMeshSkillInstallGateway skillInstaller,
    required SecureMeshFileTransferController fileController,
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusReporter report,
    required void Function(Map<String, dynamic>? result) onInstallResult,
    required DateTime Function() now,
  }) : _skillInstaller = skillInstaller,
       _fileController = fileController,
       _operationGate = operationGate,
       _report = report,
       _onInstallResult = onInstallResult,
       _now = now;

  final SecureMeshSkillInstallGateway _skillInstaller;
  final SecureMeshFileTransferController _fileController;
  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusReporter _report;
  final void Function(Map<String, dynamic>? result) _onInstallResult;
  final DateTime Function() _now;

  List<SecureMeshSkillSyncTransfer> _transfers = const [];
  SecureMeshSkillSyncTransfer? _draft;

  List<SecureMeshSkillSyncTransfer> get transfers => _transfers;
  SecureMeshSkillSyncTransfer? get draft => _draft;

  void replaceTransfers(List<SecureMeshSkillSyncTransfer> value) {
    _transfers = List<SecureMeshSkillSyncTransfer>.unmodifiable(value);
    notifyListeners();
  }

  void replaceDraft(SecureMeshSkillSyncTransfer? value) {
    _draft = value;
    notifyListeners();
  }

  void beginDraft({
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
    final skill = skillId.trim();
    final target = targetAgentId.trim();
    final digest = packageDigest.trim().toLowerCase();
    if (skill.isEmpty ||
        target.isEmpty ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
      _report(
        '技能同步草稿无效。',
        'The skill-sync draft is invalid.',
        errorCode: 'secure_mesh_skill_sync_draft_invalid',
      );
      notifyListeners();
      return;
    }
    _fileController.setDraft(
      fileName: packageFileName,
      totalSize: packageSize,
      mimeType: mimeType,
      relativePath: 'skills/$skill',
    );
    final file = _fileController.draft;
    if (file == null) return;
    _draft = SecureMeshSkillSyncTransfer(
      id: 'skill-sync-${_now().toUtc().microsecondsSinceEpoch}',
      skillId: skill,
      version: version.trim().isEmpty ? '0.0.0' : version.trim(),
      sourceAgentId: sourceAgentId.trim(),
      targetAgentId: target,
      packageDigest: digest,
      activate: activate,
      fileTransfer: file,
      status: SecureMeshSkillSyncStatus.drafting,
    );
    _report(
      '已准备技能同步 $skill → $target。',
      'Prepared skill-sync $skill → $target.',
    );
    notifyListeners();
  }

  Future<void> prepareTransfer() async {
    final current = _draft;
    if (current == null) {
      _report(
        '请先准备技能同步草稿。',
        'Prepare a skill-sync draft first.',
        errorCode: 'secure_mesh_skill_sync_draft_missing',
      );
      notifyListeners();
      return;
    }
    _draft = current.copyWith(
      status: SecureMeshSkillSyncStatus.transferring,
      fileTransfer: _fileController.draft ?? current.fileTransfer,
    );
    notifyListeners();
    await _fileController.prepareTransfer();
    final file = _fileController.draft;
    if (file?.status == SecureMeshFileSyncStatus.awaitingConfirmation) {
      _draft = current.copyWith(
        status: SecureMeshSkillSyncStatus.awaitingInstall,
        fileTransfer: file!,
        errorCode: '',
      );
      _transfers = SecureMeshPolicy.upsertSkillTransfer(_transfers, _draft!);
      _report(
        '技能加密包已就绪，确认写入后将交由 Skill Hub 安装。',
        'Encrypted skill package ready; Skill Hub install follows write confirmation.',
      );
    } else if (file != null) {
      _draft = current.copyWith(
        status: SecureMeshSkillSyncStatus.failed,
        fileTransfer: file,
        errorCode: 'secure_mesh_skill_sync_prepare_failed',
      );
      _transfers = SecureMeshPolicy.upsertSkillTransfer(_transfers, _draft!);
      _report(
        '技能同步准备失败。',
        'Skill-sync preparation failed.',
        errorCode: 'secure_mesh_skill_sync_prepare_failed',
      );
    }
    notifyListeners();
  }

  Future<void> confirmInstall({required bool userConfirmed}) async {
    final current = _draft;
    if (current == null ||
        current.status != SecureMeshSkillSyncStatus.awaitingInstall) {
      _report(
        '没有等待安装的技能同步。',
        'No skill-sync transfer is awaiting install.',
        errorCode: 'secure_mesh_skill_sync_confirmation_unavailable',
      );
      notifyListeners();
      return;
    }
    await _fileController.confirmReceive(userConfirmed: userConfirmed);
    final file = _fileController.draft;
    if (!userConfirmed) {
      _failDraft(
        current,
        file ?? current.fileTransfer,
        'secure_mesh_skill_sync_rejected',
      );
      notifyListeners();
      return;
    }
    if (file?.status != SecureMeshFileSyncStatus.confirmed) {
      _failDraft(
        current,
        file ?? current.fileTransfer,
        'secure_mesh_skill_sync_confirm_failed',
      );
      _report(
        '技能同步确认失败。',
        'Skill-sync confirmation failed.',
        errorCode: 'secure_mesh_skill_sync_confirm_failed',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _draft = current.copyWith(
      status: SecureMeshSkillSyncStatus.installing,
      fileTransfer: file!,
      errorCode: '',
    );
    notifyListeners();
    try {
      final result = await _skillInstaller.applyInstall(
        agent: current.targetAgentId,
        sourcePath: p.join(
          file.destinationRoot,
          file.relativePath,
          file.fileName,
        ),
        name: current.skillId,
        pin: current.activate,
      );
      _onInstallResult(SecureMeshPolicy.installActionProjection(result));
      final installed = result['ok'] == true;
      _draft = current.copyWith(
        status: installed
            ? SecureMeshSkillSyncStatus.installed
            : SecureMeshSkillSyncStatus.failed,
        fileTransfer: file,
        errorCode: installed ? '' : 'secure_mesh_skill_sync_install_failed',
      );
      _transfers = SecureMeshPolicy.upsertSkillTransfer(_transfers, _draft!);
      _report(
        installed ? '技能同步安装完成：${current.skillId}' : '技能同步安装失败。',
        installed
            ? 'Skill-sync install completed: ${current.skillId}'
            : 'Skill-sync install failed.',
        errorCode: installed ? '' : 'secure_mesh_skill_sync_install_failed',
      );
    } catch (_) {
      _failDraft(current, file, 'secure_mesh_skill_sync_install_failed');
      _onInstallResult(const {
        'ok': false,
        'errorCode': 'secure_mesh_skill_sync_install_failed',
      });
      _report(
        '技能同步安装失败。',
        'Skill-sync install failed.',
        errorCode: 'secure_mesh_skill_sync_install_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  void _failDraft(
    SecureMeshSkillSyncTransfer current,
    SecureMeshFileSyncTransfer file,
    String errorCode,
  ) {
    final failed = current.copyWith(
      status: SecureMeshSkillSyncStatus.failed,
      fileTransfer: file,
      errorCode: errorCode,
    );
    _draft = failed;
    _transfers = SecureMeshPolicy.upsertSkillTransfer(_transfers, failed);
  }
}
