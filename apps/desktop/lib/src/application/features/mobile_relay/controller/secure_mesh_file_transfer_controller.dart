import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/features/mobile_relay/controller/secure_mesh_controller_support.dart';
import 'package:flutter_client/src/application/features/mobile_relay/policy/secure_mesh_policy.dart';
import 'package:flutter_client/src/contracts/mobile_relay_control.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';

/// Owns the local file-sync draft, receive policy, and confirmation state.
final class SecureMeshFileTransferController extends ChangeNotifier {
  SecureMeshFileTransferController({
    required SecureMeshGateway gateway,
    required MobileRelayOperationGate operationGate,
    required SecureMeshStatusReporter report,
    required DateTime Function() now,
  }) : _gateway = gateway,
       _operationGate = operationGate,
       _report = report,
       _now = now;

  final SecureMeshGateway _gateway;
  final MobileRelayOperationGate _operationGate;
  final SecureMeshStatusReporter _report;
  final DateTime Function() _now;

  Map<String, dynamic>? _route;
  Map<String, dynamic>? _destination;
  Map<String, dynamic>? _confirmation;
  List<SecureMeshFileSyncTransfer> _transfers = const [];
  SecureMeshFileSyncTransfer? _draft;

  Map<String, dynamic>? get route => _route;
  Map<String, dynamic>? get destination => _destination;
  Map<String, dynamic>? get confirmation => _confirmation;
  List<SecureMeshFileSyncTransfer> get transfers => _transfers;
  SecureMeshFileSyncTransfer? get draft => _draft;

  void replaceRoute(Map<String, dynamic>? value) {
    _route = value == null ? null : SecureMeshPolicy.fileRouteProjection(value);
    notifyListeners();
  }

  void replaceDestination(Map<String, dynamic>? value) {
    _destination = value == null
        ? null
        : SecureMeshPolicy.fileDestinationProjection(value);
    notifyListeners();
  }

  void replaceConfirmation(Map<String, dynamic>? value) {
    _confirmation = value == null
        ? null
        : SecureMeshPolicy.fileConfirmationProjection(value);
    notifyListeners();
  }

  void replaceTransfers(List<SecureMeshFileSyncTransfer> value) {
    _transfers = List<SecureMeshFileSyncTransfer>.unmodifiable(value);
    notifyListeners();
  }

  void replaceDraft(SecureMeshFileSyncTransfer? value) {
    _draft = value;
    notifyListeners();
  }

  Future<void> evaluateRoute(Map<String, dynamic> manifest) async {
    if (!_operationGate.tryAcquire()) return;
    _report('正在评估 Secure Mesh 文件路由。', 'Evaluating the Secure Mesh file route.');
    notifyListeners();
    try {
      _route = SecureMeshPolicy.fileRouteProjection(
        await _gateway.evaluateFileRoute(manifest),
      );
      _report('Secure Mesh 文件路由已评估。', 'Secure Mesh file route evaluated.');
    } catch (_) {
      _route = const {
        'ok': false,
        'errorCode': 'secure_mesh_file_route_failed',
      };
      _report(
        'Secure Mesh 文件路由评估失败。',
        'Failed to evaluate the Secure Mesh file route.',
        errorCode: 'secure_mesh_file_route_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> evaluateReceiveDestination({
    required Map<String, dynamic> manifest,
    required String approvedRoot,
    String conflictPolicy = 'fail_if_exists',
  }) async {
    if (!_operationGate.tryAcquire()) return;
    _report(
      '正在评估安全网格文件接收位置。',
      'Evaluating the Secure Mesh file receive destination.',
    );
    notifyListeners();
    try {
      _destination = SecureMeshPolicy.fileDestinationProjection(
        await _gateway.evaluateFileReceiveDestination(
          manifest: manifest,
          approvedRoot: approvedRoot,
          conflictPolicy: conflictPolicy,
        ),
      );
      _report(
        '安全网格文件接收位置已评估。',
        'Secure Mesh file receive destination evaluated.',
      );
    } catch (_) {
      _destination = const {
        'ok': false,
        'errorCode': 'secure_mesh_file_destination_failed',
      };
      _report(
        '安全网格文件接收位置评估失败。',
        'Secure Mesh file receive destination evaluation failed.',
        errorCode: 'secure_mesh_file_destination_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  void setDraft({
    required String fileName,
    required int totalSize,
    String mimeType = 'application/octet-stream',
    String relativePath = '.',
    String conflictPolicy = 'fail_if_exists',
  }) {
    final normalizedName = p.basename(fileName.trim());
    if (normalizedName.isEmpty || totalSize <= 0) {
      _report(
        '文件同步源无效。',
        'The file-sync source is invalid.',
        errorCode: 'secure_mesh_file_sync_source_invalid',
      );
      notifyListeners();
      return;
    }
    final chunkSize = secureMeshFileSyncDefaultChunkSize.clamp(1, totalSize);
    final transferId = 'file-sync-${_now().toUtc().microsecondsSinceEpoch}';
    _draft = SecureMeshFileSyncTransfer(
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
      chunkCount: secureMeshFileSyncChunkCount(totalSize, chunkSize),
      status: SecureMeshFileSyncStatus.drafting,
    );
    _report(
      '已选择文件 $normalizedName，请确认目标目录。',
      'Selected $normalizedName. Confirm the destination directory.',
    );
    notifyListeners();
  }

  void setDestination(String destinationRoot) {
    final current = _draft;
    final normalized = destinationRoot.trim();
    if (current == null) {
      _report(
        '请先选择要同步的文件。',
        'Choose a file to sync first.',
        errorCode: 'secure_mesh_file_sync_draft_missing',
      );
    } else if (normalized.isEmpty || !p.isAbsolute(normalized)) {
      _report(
        '目标目录必须是已批准的绝对路径。',
        'The destination must be an approved absolute directory.',
        errorCode: 'secure_mesh_file_sync_destination_invalid',
      );
    } else {
      _draft = current.copyWith(destinationRoot: normalized);
      _report(
        '目标目录已设置，准备评估文件同步。',
        'Destination set. Ready to evaluate the file-sync transfer.',
      );
    }
    notifyListeners();
  }

  Future<void> prepareTransfer() async {
    final current = _draft;
    if (current == null) {
      _report(
        '请先选择要同步的文件。',
        'Choose a file to sync first.',
        errorCode: 'secure_mesh_file_sync_draft_missing',
      );
      notifyListeners();
      return;
    }
    if (current.destinationRoot.trim().isEmpty) {
      _report(
        '请先确认目标目录。',
        'Confirm the destination directory first.',
        errorCode: 'secure_mesh_file_sync_destination_missing',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _draft = current.copyWith(
      status: SecureMeshFileSyncStatus.evaluating,
      errorCode: '',
    );
    _report(
      '正在评估 Secure Mesh 文件同步路由与接收确认策略。',
      'Evaluating Secure Mesh file-sync route and receive confirmation policy.',
    );
    notifyListeners();
    try {
      final manifest = current.toManifest();
      final rawRoute = await _gateway.evaluateFileRoute(manifest);
      _route = SecureMeshPolicy.fileRouteProjection(rawRoute);
      if (rawRoute['ok'] != true) throw const SecureMeshPolicyFailure();

      final rawDestination = await _gateway.evaluateFileReceiveDestination(
        manifest: manifest,
        approvedRoot: current.destinationRoot,
        conflictPolicy: current.conflictPolicy,
      );
      _destination = SecureMeshPolicy.fileDestinationProjection(rawDestination);
      if (rawDestination['ok'] != true ||
          secureMeshNested(
                rawDestination,
                'receivePolicy',
                'destinationApproved',
              ) !=
              true) {
        throw const SecureMeshPolicyFailure();
      }

      final rawConfirmation = await _gateway.evaluateFileReceiveConfirmation(
        manifest: manifest,
        approvedRoot: current.destinationRoot,
        conflictPolicy: current.conflictPolicy,
        userConfirmed: false,
      );
      _confirmation = SecureMeshPolicy.fileConfirmationProjection(
        rawConfirmation,
      );
      if (rawConfirmation['ok'] != true ||
          secureMeshNested(
                rawConfirmation,
                'receiveConfirmation',
                'required',
              ) !=
              true ||
          secureMeshNested(
                rawConfirmation,
                'receiveConfirmation',
                'writeAllowed',
              ) ==
              true ||
          secureMeshNested(
                rawConfirmation,
                'receiveConfirmation',
                'autoPreviewEnabled',
              ) ==
              true ||
          secureMeshNested(
                rawConfirmation,
                'receiveConfirmation',
                'autoIngestionEnabled',
              ) ==
              true) {
        throw const SecureMeshPolicyFailure();
      }
      final pending = current.copyWith(
        status: SecureMeshFileSyncStatus.awaitingConfirmation,
        errorCode: '',
      );
      _draft = pending;
      _transfers = SecureMeshPolicy.upsertFileTransfer(_transfers, pending);
      _report(
        '文件同步等待本地确认写入：${current.fileName}',
        'File-sync awaiting local write confirmation: ${current.fileName}',
      );
    } catch (_) {
      _failDraft(current, 'secure_mesh_file_sync_prepare_failed');
      _report(
        'Secure Mesh 文件同步准备失败。',
        'Secure Mesh file-sync preparation failed.',
        errorCode: 'secure_mesh_file_sync_prepare_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  Future<void> confirmReceive({required bool userConfirmed}) async {
    final current = _draft;
    if (current == null ||
        current.status != SecureMeshFileSyncStatus.awaitingConfirmation) {
      _report(
        '没有等待确认的文件同步。',
        'No file-sync transfer is awaiting confirmation.',
        errorCode: 'secure_mesh_file_sync_confirmation_unavailable',
      );
      notifyListeners();
      return;
    }
    if (!_operationGate.tryAcquire()) return;
    _report(
      userConfirmed ? '正在确认文件同步写入。' : '正在拒绝文件同步写入。',
      userConfirmed
          ? 'Confirming the file-sync write.'
          : 'Rejecting the file-sync write.',
    );
    notifyListeners();
    try {
      final raw = await _gateway.evaluateFileReceiveConfirmation(
        manifest: current.toManifest(),
        approvedRoot: current.destinationRoot,
        conflictPolicy: current.conflictPolicy,
        userConfirmed: userConfirmed,
      );
      _confirmation = SecureMeshPolicy.fileConfirmationProjection(raw);
      if (raw['ok'] != true) throw const SecureMeshPolicyFailure();
      if (userConfirmed &&
          (secureMeshNested(raw, 'receiveConfirmation', 'writeAllowed') !=
                  true ||
              secureMeshNested(raw, 'receiveConfirmation', 'userConfirmed') !=
                  true ||
              secureMeshNested(
                    raw,
                    'receiveConfirmation',
                    'autoPreviewEnabled',
                  ) ==
                  true ||
              secureMeshNested(
                    raw,
                    'receiveConfirmation',
                    'autoIngestionEnabled',
                  ) ==
                  true)) {
        throw const SecureMeshPolicyFailure();
      }
      final completed = current.copyWith(
        status: userConfirmed
            ? SecureMeshFileSyncStatus.confirmed
            : SecureMeshFileSyncStatus.rejected,
        errorCode: '',
      );
      _draft = completed;
      _transfers = SecureMeshPolicy.upsertFileTransfer(_transfers, completed);
      _report(
        userConfirmed ? '已确认文件同步写入（无自动预览/入库）。' : '已拒绝文件同步写入。',
        userConfirmed
            ? 'File-sync write confirmed (no auto-preview or ingestion).'
            : 'File-sync write rejected.',
      );
    } catch (_) {
      _failDraft(current, 'secure_mesh_file_sync_confirm_failed');
      _report(
        '文件同步确认失败。',
        'File-sync confirmation failed.',
        errorCode: 'secure_mesh_file_sync_confirm_failed',
      );
    } finally {
      _operationGate.release();
      notifyListeners();
    }
  }

  void _failDraft(SecureMeshFileSyncTransfer current, String errorCode) {
    final failed = current.copyWith(
      status: SecureMeshFileSyncStatus.failed,
      errorCode: errorCode,
    );
    _draft = failed;
    _transfers = SecureMeshPolicy.upsertFileTransfer(_transfers, failed);
  }
}
