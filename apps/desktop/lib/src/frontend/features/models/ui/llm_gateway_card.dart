import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/endpoint_configuration.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/models/models_intent.dart';
import 'package:licoup/src/presentation/models/models_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class LlmGatewayCard extends StatefulWidget {
  const LlmGatewayCard({
    super.key,
    required this.projection,
    required this.phase,
    required this.intents,
    this.notice,
    this.belowDivider,
  });

  final GatewayProjection projection;
  final PresentationPhase phase;
  final PresentationNotice? notice;
  final IntentSink<ModelsIntent> intents;
  final Widget? belowDivider;

  @override
  State<LlmGatewayCard> createState() => _LlmGatewayCardState();
}

final class _LlmGatewayCardState extends State<LlmGatewayCard> {
  late final TextEditingController _endpoint;

  @override
  void initState() {
    super.initState();
    _endpoint = TextEditingController(text: widget.projection.endpoint);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.projection.initialized) {
        widget.intents.send(const RefreshGateway());
      }
    }, debugLabel: 'LlmGatewayCard.initialRefresh');
  }

  @override
  void didUpdateWidget(covariant LlmGatewayCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projection.endpoint != widget.projection.endpoint &&
        _endpoint.text != widget.projection.endpoint) {
      _endpoint.text = widget.projection.endpoint;
    }
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  bool get _busy =>
      widget.phase == PresentationPhase.applying ||
      widget.phase == PresentationPhase.loading;

  bool get _canStart =>
      !_busy &&
      switch (widget.projection.stateLabel) {
        'stopped' || 'unknown' || 'unhealthy' => true,
        _ => false,
      };

  bool get _canStop =>
      !_busy && widget.projection.running && widget.projection.managed;

  String _serviceText(bool chinese) => switch (widget.projection.stateLabel) {
    'running' => chinese ? '运行中' : 'Running',
    'stopped' => chinese ? '未运行' : 'Stopped',
    'unhealthy' => chinese ? '异常' : 'Unhealthy',
    'detecting' => chinese ? '检测中…' : 'Detecting…',
    _ => chinese ? '状态未知' : 'Unknown',
  };

  String _modelText(LicoStrings strings) {
    final gateway = widget.projection;
    if (!gateway.credentialsAuthorized) {
      return strings.llmGatewayNotReadyWaitingForAuthorization;
    }
    if (gateway.modelReady) return strings.isChinese ? '已就绪' : 'Ready';
    if (gateway.running) return strings.llmGatewayKeysLoadedStartToApply;
    return strings.llmGatewayKeysLoadedWaitingForService;
  }

  String get _processText {
    final pid = widget.projection.pid;
    if (pid == null) return '-';
    final process = widget.projection.processLabel;
    return process.isEmpty ? '$pid' : '$pid  ·  $process';
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final gateway = widget.projection;
    final chinese = strings.isChinese;
    final colors = context.licoColors;
    final message = _gatewayMessage(widget.notice?.reasonCode, chinese);
    final controls = Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
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
              controller: _endpoint,
              enabled: !_busy,
              hintText: 'http://127.0.0.1:15722',
              saveTooltip: chinese ? '保存 Gateway URL' : 'Save Gateway URL',
              onSave: () =>
                  widget.intents.send(SaveGatewayEndpoint(_endpoint.text)),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  message,
                  style: TextStyle(
                    color:
                        widget.notice?.severity ==
                            PresentationNoticeSeverity.error
                        ? colors.error
                        : colors.textMuted,
                  ),
                ),
              ),
            const SizedBox(height: 14),
            EndpointStatusRow(
              key: const ValueKey('gateway-service-status'),
              label: chinese ? '服务' : 'Service',
              value: _serviceText(chinese),
              valueColor: gateway.running ? colors.success : null,
            ),
            EndpointStatusRow(
              key: const ValueKey('gateway-model-status'),
              label: chinese ? '模型' : 'Models',
              value: _modelText(strings),
              valueColor: gateway.modelReady
                  ? colors.success
                  : colors.textMuted,
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
                  onPressed: _canStart
                      ? () => widget.intents.send(const SetGatewayEnabled(true))
                      : null,
                  icon: _busy
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(
                    _busy
                        ? strings.llmGatewayStarting
                        : strings.llmGatewayStart,
                  ),
                ),
                FilledButton.tonal(
                  key: const ValueKey('gateway-service-stop'),
                  style: FilledButton.styleFrom(foregroundColor: colors.error),
                  onPressed: _canStop
                      ? () =>
                            widget.intents.send(const SetGatewayEnabled(false))
                      : null,
                  child: Text(strings.llmGatewayStop),
                ),
              ],
            ),
            if (gateway.recoveryNoticeLabel.isNotEmpty) ...[
              const SizedBox(height: 10),
              _GatewayRecoveryNotification(
                noticeLabel: gateway.recoveryNoticeLabel,
                attempt: gateway.recoveryAttempt,
                maxAttempts: gateway.maxRecoveryAttempts,
                busy: _busy,
                intents: widget.intents,
              ),
            ],
          ],
        ),
      ),
    );
    final belowDivider = widget.belowDivider;
    if (belowDivider == null) return controls;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [controls, const SizedBox(height: 16), belowDivider],
    );
  }
}

String? _gatewayMessage(String? code, bool chinese) => switch (code) {
  'invalid_local_gateway_endpoint' =>
    chinese ? '请输入有效的本地 Gateway URL。' : 'Enter a valid local Gateway URL.',
  'gateway_endpoint_saved' =>
    chinese ? 'Gateway URL 已保存。' : 'Gateway URL saved.',
  'gateway_endpoint_save_failed' =>
    chinese ? 'Gateway URL 未能保存。' : 'Gateway URL was not saved.',
  'gateway_status_failed' =>
    chinese ? 'Gateway 状态检测失败。' : 'Gateway status check failed.',
  'gateway_started' => chinese ? 'Gateway 已启动。' : 'Gateway started.',
  'gateway_start_failed' =>
    chinese ? 'Gateway 启动失败。' : 'Gateway failed to start.',
  'gateway_stopped' => chinese ? 'Gateway 已停止。' : 'Gateway stopped.',
  'gateway_stop_failed' =>
    chinese ? 'Gateway 停止失败。' : 'Gateway failed to stop.',
  _ => null,
};

final class _GatewayRecoveryNotification extends StatelessWidget {
  const _GatewayRecoveryNotification({
    required this.noticeLabel,
    required this.attempt,
    required this.maxAttempts,
    required this.busy,
    required this.intents,
  });

  final String noticeLabel;
  final int attempt;
  final int maxAttempts;
  final bool busy;
  final IntentSink<ModelsIntent> intents;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final recovering = noticeLabel == 'recovering';
    final message = recovering
        ? (chinese
              ? 'LLM Gateway 正在自动恢复（$attempt/$maxAttempts）…'
              : 'Recovering LLM Gateway ($attempt/$maxAttempts)…')
        : (chinese
              ? 'LLM Gateway 自动恢复失败，诊断已记录。'
              : 'LLM Gateway recovery failed. Diagnostics recorded.');
    return Semantics(
      liveRegion: true,
      label: message,
      child: Row(
        key: const Key('llm-gateway-notification-item'),
        children: [
          if (recovering)
            SizedBox.square(
              key: const Key('llm-gateway-recovery-spinner'),
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.accent,
              ),
            )
          else
            Icon(Icons.warning_amber_rounded, size: 20, color: colors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (!recovering) ...[
            const SizedBox(width: 8),
            TextButton(
              key: const Key('llm-gateway-restart-action'),
              onPressed: busy
                  ? null
                  : () => intents.send(const RecoverModelGateway()),
              child: Text(chinese ? '重试' : 'Retry'),
            ),
          ],
        ],
      ),
    );
  }
}
