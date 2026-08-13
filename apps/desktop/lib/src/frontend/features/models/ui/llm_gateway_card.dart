import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

enum _GatewayServiceState { detecting, running, stopped, unhealthy, unknown }

/// Local LLM Gateway endpoint, lifecycle, and readiness.
/// Credential authorization and process startup share one explicit card action.
///
/// When [belowDivider] is set, that widget is placed after the gateway controls
/// card — keeping sibling cards unnested.
final class LlmGatewayCard extends StatefulWidget {
  const LlmGatewayCard({
    super.key,
    required this.agentService,
    required this.authorization,
    required this.readSettings,
    required this.writeSettings,
    this.lifecycleController,
    this.belowDivider,
  });

  final AgentCommandRunner agentService;
  final LlmVaultAuthorization authorization;
  final Future<Map<String, Object?>> Function() readSettings;
  final Future<void> Function(Map<String, Object?> content) writeSettings;
  final LlmGatewayLifecycleController? lifecycleController;
  final Widget? belowDivider;

  @override
  State<LlmGatewayCard> createState() => _LlmGatewayCardState();
}

final class _LlmGatewayCardState extends State<LlmGatewayCard> {
  late final TextEditingController _urlController;
  bool _loading = true;
  bool _saving = false;
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  _GatewayServiceState _serviceState = _GatewayServiceState.detecting;
  int? _servicePid;
  String _processName = '';
  bool _serviceManaged = false;
  bool _credentialsApplied = false;
  bool _modelReady = false;
  int _servicePort = defaultLlmGatewayPort;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: _url(defaultLlmGatewayPort));
    widget.authorization.addListener(_projectionChanged);
    widget.lifecycleController?.addListener(_lifecycleChanged);
    final cachedReport = widget.lifecycleController?.lastReport;
    if (cachedReport != null) {
      _applyServiceStatus(cachedReport, fallbackPort: _servicePort);
    }
    unawaited(
      _load().then((_) async {
        // The application-wide lifecycle controller already monitors the
        // process. Only isolated/test cards without it perform their own probe.
        if (widget.lifecycleController == null) {
          await _detectService();
        }
      }),
    );
  }

  @override
  void didUpdateWidget(covariant LlmGatewayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authorization != widget.authorization) {
      oldWidget.authorization.removeListener(_projectionChanged);
      widget.authorization.addListener(_projectionChanged);
    }
    if (oldWidget.lifecycleController != widget.lifecycleController) {
      oldWidget.lifecycleController?.removeListener(_lifecycleChanged);
      widget.lifecycleController?.addListener(_lifecycleChanged);
    }
  }

  @override
  void dispose() {
    widget.authorization.removeListener(_projectionChanged);
    widget.lifecycleController?.removeListener(_lifecycleChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _projectionChanged() {
    if (mounted) setState(() {});
  }

  void _lifecycleChanged() {
    final report = widget.lifecycleController?.lastReport;
    if (!mounted || report == null) return;
    setState(() => _applyServiceStatus(report, fallbackPort: _servicePort));
  }

  String _url(int port) => 'http://127.0.0.1:$port';

  Future<void> _load() async {
    try {
      final content = await widget.readSettings();
      final stored = content[llmGatewayPortSettingsKey];
      final port = stored is int
          ? stored
          : stored is String
          ? int.tryParse(stored)
          : null;
      if (!mounted) return;
      setState(() {
        if (port != null && _validPort(port)) {
          _servicePort = port;
          _urlController.text = _url(port);
        }
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _validPort(int value) => value > 0 && value <= 65535;

  int? _portFromUrl() {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null ||
        uri.scheme != 'http' ||
        !const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        !_validPort(uri.port)) {
      return null;
    }
    return uri.port;
  }

  Future<void> _save() async {
    final port = _portFromUrl();
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    if (port == null) {
      setState(() {
        _messageIsError = true;
        _message = chinese
            ? '请输入有效的本地 Gateway URL。'
            : 'Enter a valid local Gateway URL.';
      });
      return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final content = await widget.readSettings();
      content[llmGatewayPortSettingsKey] = port;
      await widget.writeSettings(content);
      if (!mounted) return;
      setState(() {
        _servicePort = port;
        _urlController.text = _url(port);
        _messageIsError = false;
        _message = chinese ? 'Gateway URL 已保存。' : 'Gateway URL saved.';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _messageIsError = true;
          _message = chinese
              ? 'Gateway URL 未能保存。'
              : 'Gateway URL was not saved.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _applyServiceStatus(
    Map<String, dynamic> payload, {
    required int fallbackPort,
  }) {
    _serviceState = switch ('${payload['state']}') {
      'running' => _GatewayServiceState.running,
      'stopped' => _GatewayServiceState.stopped,
      'unhealthy' => _GatewayServiceState.unhealthy,
      _ => _GatewayServiceState.unknown,
    };
    _serviceManaged = payload['managed'] == true;
    _servicePid = payload['pid'] is int ? payload['pid'] as int : null;
    _processName = (payload['processName'] ?? '').toString();
    _credentialsApplied = payload['credentialsApplied'] == true;
    _modelReady = payload['modelReady'] == true;
    final port = payload['port'];
    _servicePort = port is int && _validPort(port) ? port : fallbackPort;
  }

  Future<void> _detectService() async {
    if (_busy || !mounted) return;
    setState(() => _busy = true);
    try {
      final port = _portFromUrl() ?? _servicePort;
      final payload = await widget.agentService.runCli([
        'llm-gateway',
        'service',
        'status',
        '--port',
        '$port',
      ]);
      if (mounted) {
        setState(() => _applyServiceStatus(payload, fallbackPort: port));
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _serviceState = _GatewayServiceState.unknown;
          _servicePid = null;
          _processName = '';
          _messageIsError = true;
          _message = Localizations.localeOf(context).languageCode == 'zh'
              ? 'Gateway 状态检测失败。'
              : 'Gateway status check failed.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startService() async {
    if (_busy) return;
    final strings = LicoStrings.of(context);
    final needsCredentialReload =
        _serviceState == _GatewayServiceState.running && !_modelReady;
    setState(() {
      _busy = true;
      _messageIsError = false;
      _message = null;
    });
    try {
      if (!mounted) return;
      // A CLI/orphan restart can leave the sidecar running without a key
      // handoff. Stop first so start can re-apply credentials.
      if (needsCredentialReload ||
          (_serviceState == _GatewayServiceState.running &&
              !_credentialsApplied)) {
        final lifecycle = widget.lifecycleController;
        if (lifecycle == null) {
          await widget.agentService.runCli([
            'llm-gateway',
            'service',
            'stop',
            '--port',
            '$_servicePort',
          ]);
        } else {
          await lifecycle.stop();
        }
        if (!mounted) return;
      }
      setState(() => _message = null);
      late Map<String, dynamic> payload;
      final lifecycle = widget.lifecycleController;
      if (lifecycle == null) {
        payload = await widget.agentService.runCli([
          'llm-gateway',
          'service',
          'start',
          '--port',
          '$_servicePort',
        ]);
      } else {
        await lifecycle.start();
        payload = lifecycle.lastReport ?? const {};
      }
      if (!mounted) return;
      setState(() {
        _applyServiceStatus(payload, fallbackPort: _servicePort);
        _messageIsError = _serviceState != _GatewayServiceState.running;
        _message = _serviceState == _GatewayServiceState.running
            ? strings.llmGatewayStarted
            : strings.llmGatewayStartFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _messageIsError = true;
        _message = strings.llmGatewayStartFailed;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stopService() async {
    if (_busy) return;
    final strings = LicoStrings.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final lifecycle = widget.lifecycleController;
      late Map<String, dynamic> payload;
      if (lifecycle == null) {
        payload = await widget.agentService.runCli([
          'llm-gateway',
          'service',
          'stop',
          '--port',
          '$_servicePort',
        ]);
      } else {
        await lifecycle.stop();
        payload = lifecycle.lastReport ?? const {};
      }
      if (!mounted) return;
      setState(() {
        _applyServiceStatus(payload, fallbackPort: _servicePort);
        _messageIsError = false;
        _message = strings.llmGatewayStopped;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _messageIsError = true;
          _message = strings.llmGatewayStopFailed;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canStart =>
      !_busy &&
      switch (_serviceState) {
        _GatewayServiceState.stopped ||
        _GatewayServiceState.unknown ||
        _GatewayServiceState.unhealthy => true,
        _ => false,
      };

  bool get _canStop =>
      !_busy &&
      _serviceState == _GatewayServiceState.running &&
      _serviceManaged;

  String _serviceText(bool chinese) => switch (_serviceState) {
    _GatewayServiceState.running => chinese ? '运行中' : 'Running',
    _GatewayServiceState.stopped => chinese ? '未运行' : 'Stopped',
    _GatewayServiceState.unhealthy => chinese ? '异常' : 'Unhealthy',
    _GatewayServiceState.detecting => chinese ? '检测中…' : 'Detecting…',
    _GatewayServiceState.unknown => chinese ? '状态未知' : 'Unknown',
  };

  String _modelText(LicoStrings strings) {
    if (!widget.authorization.authorized) {
      return strings.llmGatewayNotReadyWaitingForAuthorization;
    }
    if (_modelReady) {
      return strings.isChinese ? '已就绪' : 'Ready';
    }
    if (_serviceState == _GatewayServiceState.running) {
      return strings.llmGatewayKeysLoadedStartToApply;
    }
    return strings.llmGatewayKeysLoadedWaitingForService;
  }

  String get _processText {
    final pid = _servicePid;
    if (pid == null) return '-';
    return _processName.isEmpty ? '$pid' : '$pid  ·  $_processName';
  }

  Widget _buildControls(BuildContext context) {
    final strings = LicoStrings.of(context);
    final chinese = strings.isChinese;
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.lan_outlined),
            const SizedBox(width: 10),
            Text('LLM Gateway', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: 16),
        EndpointUrlField(
          key: const ValueKey('gateway-url'),
          controller: _urlController,
          enabled: !_loading && !_saving,
          hintText: _url(defaultLlmGatewayPort),
          saveTooltip: chinese ? '保存 Gateway URL' : 'Save Gateway URL',
          onSave: () => unawaited(_save()),
        ),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              _message!,
              style: TextStyle(
                color: _messageIsError ? colors.error : colors.textMuted,
              ),
            ),
          ),
        const SizedBox(height: 14),
        EndpointStatusRow(
          key: const ValueKey('gateway-service-status'),
          label: chinese ? '服务' : 'Service',
          value: _serviceText(chinese),
          valueColor: _serviceState == _GatewayServiceState.running
              ? colors.success
              : null,
        ),
        EndpointStatusRow(
          key: const ValueKey('gateway-model-status'),
          label: chinese ? '模型' : 'Models',
          value: _modelText(strings),
          valueColor: _modelReady ? colors.success : colors.textMuted,
        ),
        EndpointStatusRow(
          key: const ValueKey('gateway-process-status'),
          label: chinese ? '进程 ID' : 'Process ID',
          value: _processText,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const ValueKey('gateway-service-start'),
              onPressed: _canStart ? () => unawaited(_startService()) : null,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow_rounded, size: 18),
              label: Text(
                _busy ? strings.llmGatewayStarting : strings.llmGatewayStart,
              ),
            ),
            FilledButton.tonal(
              key: const ValueKey('gateway-service-stop'),
              style: FilledButton.styleFrom(foregroundColor: colors.error),
              onPressed: _canStop ? () => unawaited(_stopService()) : null,
              child: Text(strings.llmGatewayStop),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final belowDivider = widget.belowDivider;
    final controls = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: _buildControls(context),
      ),
    );
    if (belowDivider == null) {
      return controls;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [controls, const SizedBox(height: 16), belowDivider],
    );
  }
}
