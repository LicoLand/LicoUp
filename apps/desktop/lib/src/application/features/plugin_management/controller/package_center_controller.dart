import 'dart:async';

import 'package:licoup/src/application/features/plugin_management/models/package_center_catalog.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class PackageCenterStatusUpdate {
  const PackageCenterStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String errorCode;
}

typedef PackageCenterStatusSink =
    void Function(PackageCenterStatusUpdate update);

/// Reads and mutates the native package store.
///
/// Every fact this controller publishes comes from a native route
/// (`package catalog`, `package enable`, `package disable`,
/// `package install-plan` → `package install-confirm` → `package install-apply`,
/// `package uninstall-*`). The controller holds no package fact of its own: it
/// serializes native reads and mutations through one lane so the package center
/// never renders a result older than a preceding mutation, and it refuses to
/// publish a report the store could not have produced.
final class PackageCenterController extends ApplicationStateOwner {
  PackageCenterController({
    required AgentCommandRunner runner,
    required PackageCenterStatusSink onStatus,
  }) : _runner = runner,
       _onStatus = onStatus;

  final AgentCommandRunner _runner;
  final PackageCenterStatusSink _onStatus;
  Future<void> _tail = Future<void>.value();
  Future<void>? _refreshFuture;
  int _pendingOperations = 0;
  PackageCenterCatalog _catalog = PackageCenterCatalog.empty;
  String _lastErrorCode = '';
  String _dataRoot = '';

  PackageCenterCatalog get catalog => _catalog;
  List<PackageCatalogItem> get packages => _catalog.packages;
  bool get loaded => _loaded;
  bool get busy => _pendingOperations > 0;
  String get lastErrorCode => _lastErrorCode;
  String get dataRoot => _dataRoot;
  bool _loaded = false;

  /// The resolved data home the native routes operate on.
  ///
  /// Set once by the bootstrap step that resolved the client storage root; an
  /// empty root means no native package route can be addressed yet.
  void useDataRoot(String dataRoot) {
    final normalized = dataRoot.trim();
    if (normalized == _dataRoot) return;
    _dataRoot = normalized;
    publishChange();
  }

  /// The four facts the native store reported for one package, or `null` when
  /// the store does not hold that package.
  PackageFactsProjection? factsFor(String packageId) =>
      _catalog.package(packageId)?.facts;

  /// The four facts for one detected Agent's package, or the explicit
  /// not-installed state when the store holds no package for it.
  PackageFactsProjection factsForAgent(String agentId) {
    final item = _catalog.packageForAgent(agentId);
    return item?.facts ?? PackageFactsProjection.absent;
  }

  Future<void> refresh() {
    final active = _refreshFuture;
    if (active != null) return active;
    late final Future<void> next;
    next =
        _enqueue(() async {
          if (await _loadCatalog()) {
            _report('软件包目录已刷新。', 'Package catalog refreshed.');
          }
        }).whenComplete(() {
          if (identical(_refreshFuture, next)) _refreshFuture = null;
        });
    _refreshFuture = next;
    return next;
  }

  /// Plan, confirm and apply one install from a local archive.
  ///
  /// The plan the store derives is confirmed in the same lane, so the bytes the
  /// user reviewed are the bytes applied. Returns whether the package ended up
  /// installed.
  Future<bool> installFromArchive(String archive) => _enqueue(() async {
    final path = archive.trim();
    if (path.isEmpty) {
      _report(
        '没有可安装的软件包文件。',
        'No package archive is available to install.',
        errorCode: 'package_archive_missing',
      );
      return false;
    }
    try {
      final planned = PackageInstallPlan.fromJson(
        await _runner.runCli([
          'package',
          'install-plan',
          _dataRoot,
          '--archive',
          path,
        ]),
      );
      final confirmed = await _runner.runCli([
        'package',
        'install-confirm',
        _dataRoot,
        '--archive',
        path,
        '--plan',
        planned.planDigest,
      ]);
      if (confirmed['isError'] == true) {
        _reportRefusal(
          _wireReasonCode(confirmed) ?? 'package_install_confirmation_stale',
        );
        return false;
      }
      final applied = await _runner.runCli([
        'package',
        'install-apply',
        _dataRoot,
        '--archive',
        path,
        '--confirmation',
        planned.confirmation,
      ]);
      if (applied['isError'] == true) {
        _reportRefusal(_wireReasonCode(applied) ?? 'package_install_failed');
        return false;
      }
      if (!await _loadCatalog(reportFailure: false)) {
        _report(
          '软件包已安装，但目录无法刷新。',
          'The package was installed, but the catalog could not be refreshed.',
          errorCode: 'package_catalog_refresh_failed',
        );
        return true;
      }
      _report('${planned.packageId} 已安装。', '${planned.packageId} installed.');
      return true;
    } on FormatException catch (error) {
      _reportRefusal(error.message);
      return false;
    } catch (_) {
      _reportRefusal('package_install_plan_failed');
      return false;
    }
  });

  /// Switch one installed version on or off. The bytes stay in place.
  Future<bool> setEnabled({
    required String packageId,
    required String version,
    required bool enabled,
  }) => _enqueue(() async {
    try {
      final output = await _runner.runCli([
        'package',
        enabled ? 'enable' : 'disable',
        _dataRoot,
        packageId,
        version,
      ]);
      if (output['isError'] == true) {
        _reportRefusal(
          _wireReasonCode(output) ??
              (enabled ? 'package_enable_failed' : 'package_disable_failed'),
        );
        return false;
      }
      if (!await _loadCatalog(reportFailure: false)) {
        _report(
          enabled ? '已启用，但目录无法刷新。' : '已停用，但目录无法刷新。',
          enabled
              ? 'Enabled, but the catalog could not be refreshed.'
              : 'Disabled, but the catalog could not be refreshed.',
          errorCode: 'package_catalog_refresh_failed',
        );
        return true;
      }
      _report(
        enabled ? '$packageId 已启用。' : '$packageId 已停用。',
        enabled ? '$packageId enabled.' : '$packageId disabled.',
      );
      return true;
    } catch (_) {
      _reportRefusal(
        enabled ? 'package_enable_failed' : 'package_disable_failed',
      );
      return false;
    }
  });

  /// Remove one installed version through the store's own drain transaction.
  Future<bool> uninstall({
    required String packageId,
    required String version,
  }) => _enqueue(() async {
    try {
      final preview = await _runner.runCli([
        'package',
        'uninstall-preview',
        _dataRoot,
        packageId,
        version,
      ]);
      if (preview['isError'] == true) {
        _reportRefusal(
          _wireReasonCode(preview) ?? 'package_uninstall_preview_failed',
        );
        return false;
      }
      final drain = await _runner.runCli([
        'package',
        'uninstall-drain',
        _dataRoot,
        packageId,
        version,
      ]);
      if (drain['isError'] == true) {
        _reportRefusal(
          _wireReasonCode(drain) ?? 'package_uninstall_drain_failed',
        );
        return false;
      }
      final collect = await _runner.runCli([
        'package',
        'uninstall-collect',
        _dataRoot,
        packageId,
        version,
      ]);
      if (collect['isError'] == true) {
        _reportRefusal(
          _wireReasonCode(collect) ?? 'package_uninstall_collect_failed',
        );
        return false;
      }
      if (!await _loadCatalog(reportFailure: false)) {
        _report(
          '软件包已卸载，但目录无法刷新。',
          'The package was uninstalled, but the catalog could not be refreshed.',
          errorCode: 'package_catalog_refresh_failed',
        );
        return true;
      }
      _report('$packageId 已卸载。', '$packageId uninstalled.');
      return true;
    } catch (_) {
      _reportRefusal('package_uninstall_failed');
      return false;
    }
  });

  /// Read the store's own catalog, recovering an interrupted install first.
  Future<bool> _loadCatalog({bool reportFailure = true}) async {
    if (_dataRoot.isEmpty) {
      if (reportFailure) {
        _report(
          '尚未确定数据目录。',
          'The data home is not resolved yet.',
          errorCode: 'package_data_root_unresolved',
        );
      }
      return false;
    }
    try {
      final output = await _runner.runCli(['package', 'catalog', _dataRoot]);
      _catalog = PackageCenterCatalog.fromJson(output);
      _loaded = true;
      _lastErrorCode = '';
      publishChange();
      return true;
    } on FormatException catch (error) {
      if (reportFailure) {
        _report(
          '软件包目录格式无效。',
          'The package catalog response is invalid.',
          errorCode: error.message,
        );
      }
      return false;
    } catch (_) {
      if (reportFailure) {
        _report(
          '软件包目录刷新失败。',
          'Package catalog refresh failed.',
          errorCode: 'package_catalog_refresh_failed',
        );
      }
      return false;
    }
  }

  /// Runs one operation after the preceding one settles.
  ///
  /// The lane never completes with an error: a route that fails is reported
  /// through the status sink and returned as its own failure value, so a refused
  /// install can never abort the remaining installs or the caller's step.
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    _pendingOperations += 1;
    publishChange();
    final next = _tail.then((_) => operation()).whenComplete(() {
      _pendingOperations -= 1;
      publishChange();
    });
    _tail = next.then((_) {}, onError: (_) {});
    return next;
  }

  void _reportRefusal(String reasonCode) {
    _report('软件包操作失败。', 'The package operation failed.', errorCode: reasonCode);
  }

  String? _wireReasonCode(Map<String, dynamic> output) {
    if (output['reasonCode'] is String) return output['reasonCode'] as String;
    final error = output['error'];
    if (error is Map && error['code'] is String) {
      return error['code'] as String;
    }
    return output['errorCode'] is String ? output['errorCode'] as String : null;
  }

  void _report(String chinese, String english, {String errorCode = ''}) {
    _lastErrorCode = errorCode;
    _onStatus(
      PackageCenterStatusUpdate(
        chinese: chinese,
        english: english,
        errorCode: errorCode,
      ),
    );
    publishChange();
  }
}
