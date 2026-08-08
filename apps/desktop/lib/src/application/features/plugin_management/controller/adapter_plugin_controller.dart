import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/application/features/plugin_management/models/adapter_plugin_catalog.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';

final class AdapterPluginStatusUpdate {
  const AdapterPluginStatusUpdate({
    required this.chinese,
    required this.english,
    this.errorCode = '',
  });

  final String chinese;
  final String english;
  final String errorCode;
}

typedef AdapterPluginStatusSink =
    void Function(AdapterPluginStatusUpdate update);

/// Serializes catalog refreshes and lifecycle mutations through one command
/// lane so the UI never renders a result older than a preceding mutation.
final class AdapterPluginController extends ChangeNotifier {
  AdapterPluginController({
    required AgentCommandRunner runner,
    required AdapterPluginStatusSink onStatus,
  }) : _runner = runner,
       _onStatus = onStatus;

  final AgentCommandRunner _runner;
  final AdapterPluginStatusSink _onStatus;
  Future<void> _tail = Future<void>.value();
  int _pendingOperations = 0;
  AdapterPluginCatalog? _catalog;
  String _lastErrorCode = '';

  AdapterPluginCatalog? get catalog => _catalog;
  List<AdapterPluginDescriptor> get adapters =>
      _catalog?.adapters ?? const <AdapterPluginDescriptor>[];
  bool get busy => _pendingOperations > 0;
  String get lastErrorCode => _lastErrorCode;

  Future<void> refresh() => _enqueue(() async {
    if (await _loadCatalog()) {
      _report('插件目录已刷新。', 'Plugin catalog refreshed.');
    }
  });

  Future<void> install(String agentId) =>
      _mutate(agentId, AdapterPluginLifecycleAction.install);

  Future<void> uninstall(String agentId) =>
      _mutate(agentId, AdapterPluginLifecycleAction.uninstall);

  Future<void> _mutate(
    String agentId,
    AdapterPluginLifecycleAction action,
  ) => _enqueue(() async {
    final adapter = _catalog?.adapter(agentId);
    if (adapter == null) {
      _report(
        '找不到指定的适配器。',
        'The requested adapter is not in the catalog.',
        errorCode: 'adapter_plugin_missing',
      );
      return;
    }
    if (!adapter.supports(action)) {
      _report(
        '该适配器未声明此操作。',
        'The catalog does not declare this adapter action.',
        errorCode: 'adapter_plugin_action_not_declared',
      );
      return;
    }
    final actionName = action.name;
    try {
      final output = await _runner.runCli(['adapter', agentId, actionName]);
      if (output['ok'] != true) {
        _reportActionFailure(action, _wireErrorCode(output));
        return;
      }
      if (!await _loadCatalog(reportFailure: false)) {
        _report(
          '操作成功，但无法刷新插件目录。',
          'The action succeeded, but the plugin catalog could not be refreshed.',
          errorCode: 'adapter_plugin_catalog_refresh_failed',
        );
        return;
      }
      _report(
        action == AdapterPluginLifecycleAction.install ? '适配器已安装。' : '适配器已卸载。',
        action == AdapterPluginLifecycleAction.install
            ? 'Adapter installed.'
            : 'Adapter uninstalled.',
      );
    } catch (_) {
      _reportActionFailure(action, null);
    }
  });

  Future<bool> _loadCatalog({bool reportFailure = true}) async {
    try {
      final output = await _runner.runCli(const ['adapter', 'catalog']);
      _catalog = AdapterPluginCatalog.fromJson(output);
      _lastErrorCode = '';
      notifyListeners();
      return true;
    } on FormatException catch (error) {
      if (reportFailure) {
        _report(
          '插件目录格式无效。',
          'The plugin catalog response is invalid.',
          errorCode: error.message,
        );
      }
      return false;
    } catch (_) {
      if (reportFailure) {
        _report(
          '插件目录刷新失败。',
          'Plugin catalog refresh failed.',
          errorCode: 'adapter_plugin_catalog_refresh_failed',
        );
      }
      return false;
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _pendingOperations += 1;
    notifyListeners();
    final next = _tail.then((_) => operation()).whenComplete(() {
      _pendingOperations -= 1;
      notifyListeners();
    });
    _tail = next.catchError((_) {});
    return next;
  }

  void _reportActionFailure(
    AdapterPluginLifecycleAction action,
    String? wireCode,
  ) {
    final install = action == AdapterPluginLifecycleAction.install;
    _report(
      install ? '适配器安装失败。' : '适配器卸载失败。',
      install ? 'Adapter installation failed.' : 'Adapter uninstall failed.',
      errorCode:
          wireCode ??
          (install
              ? 'adapter_plugin_install_failed'
              : 'adapter_plugin_uninstall_failed'),
    );
  }

  String? _wireErrorCode(Map<String, dynamic> output) {
    final error = output['error'];
    if (error is Map && error['code'] is String) {
      return error['code'] as String;
    }
    return output['errorCode'] is String ? output['errorCode'] as String : null;
  }

  void _report(String chinese, String english, {String errorCode = ''}) {
    _lastErrorCode = errorCode;
    _onStatus(
      AdapterPluginStatusUpdate(
        chinese: chinese,
        english: english,
        errorCode: errorCode,
      ),
    );
    notifyListeners();
  }
}
