import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/models/controller/llm_gateway_lifecycle_controller.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/llm_vault_authorization.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_formatters.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_timeline_data.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_wave_overview.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

enum _GatewayServiceState { detecting, running, stopped, unhealthy, unknown }

/// Local LLM Gateway endpoint, lifecycle, readiness, and local usage summary.
/// Credential authorization and process startup share one explicit card action.
///
/// When [belowDivider] is set, that widget is placed after the gateway controls
/// divider and before the local usage summary — keeping sibling cards unnested.
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
  List<_GatewayUsageDay> _usageDays = const [];
  int _usageWindowDays = 30;
  Timer? _usageRefresh;

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
        await _loadUsage();
      }),
    );
    _usageRefresh = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_loadUsage()),
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
    _usageRefresh?.cancel();
    _usageRefresh = null;
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

  Future<void> _loadUsage() async {
    try {
      final payload = await widget.agentService.runCli(const [
        'llm-gateway',
        'service',
        'usage',
      ]);
      final days = (payload['days'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_GatewayUsageDay.fromJson)
          .where((day) => day.date != null)
          .toList(growable: false);
      if (mounted) setState(() => _usageDays = days);
    } catch (_) {
      // Gateway counters are secondary presentation data. Lifecycle controls
      // remain available when an old sidecar has no usage projection yet.
    }
  }

  Future<void> _authorizeAndStart() async {
    if (_busy || widget.authorization.busy) return;
    final strings = LicoStrings.of(context);
    final needsAuthorization = !widget.authorization.authorized;
    final needsCredentialReload =
        _serviceState == _GatewayServiceState.running && !_modelReady;
    setState(() {
      _busy = true;
      _messageIsError = false;
      _message = needsAuthorization
          ? strings.llmGatewayRequestingAuthorization
          : null;
    });
    try {
      if (needsAuthorization) {
        final authorized = await widget.authorization.authorize(
          widget.agentService,
        );
        if (!mounted) return;
        final failure = widget.authorization.failure;
        if (authorized ||
            failure == LlmVaultAuthorizationFailure.noCredentials) {
          await widget.authorization.refreshInventory(widget.agentService);
        }
        if (!authorized) {
          setState(() {
            _messageIsError = true;
            _message = failure == LlmVaultAuthorizationFailure.noCredentials
                ? strings.llmGatewayNoCredentialsAvailable
                : strings.llmGatewayAuthorizationFailed;
          });
          return;
        }
        await widget.lifecycleController?.pollNow();
      }
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
      await _loadUsage();
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
      await _loadUsage();
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

  bool get _canAuthorizeAndStart =>
      !_busy &&
      switch (_serviceState) {
        _GatewayServiceState.stopped || _GatewayServiceState.unknown => true,
        _GatewayServiceState.unhealthy => _serviceManaged,
        // Allow re-authorize when a managed process is up but has no usable
        // key lease (common after an external CLI restart without handoff).
        _GatewayServiceState.running =>
          _serviceManaged && (!_credentialsApplied || !_modelReady),
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

  String _primaryActionLabel(LicoStrings strings) {
    if (_busy || widget.authorization.busy) {
      return widget.authorization.authorized
          ? strings.llmGatewayStarting
          : strings.llmGatewayAuthorizing;
    }
    return widget.authorization.authorized
        ? strings.llmGatewayStart
        : strings.llmGatewayAuthorizeAndStart;
  }

  String get _processText {
    final pid = _servicePid;
    if (pid == null) return '-';
    return _processName.isEmpty ? '$pid' : '$pid  ·  $_processName';
  }

  List<_GatewayUsageDay> get _visibleUsageDays {
    final today = DateTime.now().toUtc();
    final start = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: _usageWindowDays - 1));
    return [
      for (final day in _usageDays)
        if (day.date != null && !day.date!.isBefore(start)) day,
    ];
  }

  int _agentRequests(String agent) => _visibleUsageDays.fold<int>(
    0,
    (total, day) => total + (day.agents[agent] ?? 0),
  );

  AgentUsageTimelineData _gatewayModelTimeline() {
    final today = DateTime.now().toUtc();
    final first = DateTime.utc(
      today.year,
      today.month,
      today.day,
    ).subtract(Duration(days: _usageWindowDays - 1));
    final byDate = {
      for (final day in _visibleUsageDays) _dateKey(day.date!): day.models,
    };
    final snapshots = <AgentUsageSnapshot>[];
    final totals = <String, double>{};
    for (var offset = 0; offset < _usageWindowDays; offset += 1) {
      final date = first.add(Duration(days: offset));
      final values = <String, double>{
        for (final entry in (byDate[_dateKey(date)] ?? const {}).entries)
          entry.key: entry.value.toDouble(),
      };
      for (final entry in values.entries) {
        totals.update(
          entry.key,
          (value) => value + entry.value,
          ifAbsent: () => entry.value,
        );
      }
      snapshots.add(AgentUsageSnapshot(time: date.toLocal(), values: values));
    }
    final labels = totals.keys.toList()
      ..sort((left, right) {
        final count = (totals[right] ?? 0).compareTo(totals[left] ?? 0);
        return count != 0 ? count : left.compareTo(right);
      });
    return AgentUsageTimelineData(
      snapshots: snapshots,
      series: [for (final label in labels) AgentUsageSeries(label: label)],
      seriesTotals: Map.unmodifiable(totals),
      shareSeriesLabels: List.unmodifiable(labels),
      groupTotal: totals.values.fold<double>(0, (sum, value) => sum + value),
      hasDailyBreakdown: _usageDays.isNotEmpty,
    );
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
            Text(
              'LLM Gateway',
              style: Theme.of(context).textTheme.titleMedium,
            ),
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
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FilledButton.icon(
              key: const ValueKey('gateway-authorize-and-start'),
              onPressed: _canAuthorizeAndStart
                  ? () => unawaited(_authorizeAndStart())
                  : null,
              icon: _busy || widget.authorization.busy
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      widget.authorization.authorized
                          ? Icons.play_arrow_rounded
                          : Icons.fingerprint,
                      size: 18,
                    ),
              label: Text(_primaryActionLabel(strings)),
            ),
            const SizedBox(width: 10),
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

  Widget _buildUsage(BuildContext context) {
    final chinese = LicoStrings.of(context).isChinese;
    final colors = context.licoColors;
    final modelTimeline = _gatewayModelTimeline();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = [
              _GatewayAgentUsageCard(
                target: 'codex',
                label: 'Codex',
                requests: _agentRequests('codex'),
                chinese: chinese,
              ),
              _GatewayAgentUsageCard(
                target: 'claude-code',
                label: 'Claude Code',
                requests: _agentRequests('claude-code'),
                chinese: chinese,
              ),
            ];
            if (constraints.maxWidth < 620) {
              return Column(
                children: [
                  for (final card in cards)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: card,
                    ),
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 12),
                Expanded(child: cards[1]),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        if (modelTimeline.isEmpty)
          Container(
            key: const ValueKey('gateway-model-usage-empty'),
            height: 180,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.line.withAlpha(90)),
            ),
            child: Text(
              chinese ? '暂无 Gateway API 请求' : 'No Gateway API requests yet',
              style: TextStyle(color: colors.textMuted),
            ),
          )
        else
          AgentUsageWaveOverview(
            grouping: AgentUsageChartGrouping.model,
            timeline: modelTimeline,
            onGroupingChanged: (_) {},
            windowDays: _usageWindowDays,
            windowBusy: false,
            onWindowChanged: (days) => setState(() => _usageWindowDays = days),
            showGroupingControl: false,
            title: chinese ? 'API 请求次数' : 'API requests',
            tooltipSemanticLabel: (date) => chinese
                ? '${_dateKey(date)} Gateway API 请求次数'
                : '${_dateKey(date)} Gateway API requests',
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final belowDivider = widget.belowDivider;
    if (belowDivider == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildControls(context),
              const Divider(height: 32),
              _buildUsage(context),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: _buildControls(context),
          ),
        ),
        const SizedBox(height: 16),
        belowDivider,
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: _buildUsage(context),
          ),
        ),
      ],
    );
  }
}

final class _GatewayAgentUsageCard extends StatelessWidget {
  const _GatewayAgentUsageCard({
    required this.target,
    required this.label,
    required this.requests,
    required this.chinese,
  });

  final String target;
  final String label;
  final int requests;
  final bool chinese;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      key: ValueKey('gateway-agent-$target'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(110)),
      ),
      child: Row(
        children: [
          AgentBrandIcon(
            target: TargetCandidate(
              target: target,
              label: label,
              kind: 'cli',
              status: 'detected',
              configured: true,
              confidence: 1,
              adapterStatus: 'native',
            ),
            size: 34,
            iconSize: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Icon(
            Icons.model_training_outlined,
            color: colors.textSecondary,
            size: 20,
          ),
          const SizedBox(width: 7),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatAgentUsageNumber(requests),
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(
                chinese ? 'API 请求' : 'API requests',
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

final class _GatewayUsageDay {
  const _GatewayUsageDay({
    required this.date,
    required this.agents,
    required this.models,
  });

  final DateTime? date;
  final Map<String, int> agents;
  final Map<String, int> models;

  factory _GatewayUsageDay.fromJson(Map<String, dynamic> json) {
    Map<String, int> counts(Object? source) {
      if (source is! Map) return const {};
      return {
        for (final entry in source.entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
      };
    }

    final rawDate = DateTime.tryParse((json['date'] ?? '').toString());
    final date = rawDate == null
        ? null
        : DateTime.utc(rawDate.year, rawDate.month, rawDate.day);
    return _GatewayUsageDay(
      date: date,
      agents: Map.unmodifiable(counts(json['agents'])),
      models: Map.unmodifiable(counts(json['models'])),
    );
  }
}

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
