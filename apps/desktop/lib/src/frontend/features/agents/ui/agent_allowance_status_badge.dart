import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/application/features/agents/models/agent_allowance_defaults.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class AgentAllowanceStatusBadge extends StatefulWidget {
  const AgentAllowanceStatusBadge({
    super.key,
    required this.controller,
    required this.target,
  });

  final ClientController controller;
  final TargetCandidate target;

  @override
  State<AgentAllowanceStatusBadge> createState() =>
      _AgentAllowanceStatusBadgeState();
}

class _AgentAllowanceStatusBadgeState extends State<AgentAllowanceStatusBadge> {
  static const _refreshInterval = Duration(minutes: 1);

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _startRefreshCycle();
  }

  @override
  void didUpdateWidget(AgentAllowanceStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.target != widget.target.target ||
        oldWidget.controller != widget.controller) {
      _startRefreshCycle();
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _startRefreshCycle() {
    _refreshTimer?.cancel();
    final targetId = widget.target.target.trim();
    if (targetId.isEmpty) {
      return;
    }
    final controller = widget.controller;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          widget.controller != controller ||
          widget.target.target.trim() != targetId) {
        return;
      }
      _refreshNow(targetId);
    });
    _refreshTimer = Timer.periodic(_refreshInterval, (_) {
      if (!mounted) {
        return;
      }
      _refreshNow(widget.target.target.trim());
    });
  }

  void _refreshNow(String targetId) {
    if (targetId.isEmpty) {
      return;
    }
    unawaited(widget.controller.refreshAgentAllowances(targetId));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final report = widget.controller.agentUsageReport;
    final usage = report?.agent(widget.target.target);
    final cachedAllowances = widget.controller.allowancesForAgent(
      widget.target.target,
    );
    final allowances = cachedAllowances.isNotEmpty
        ? cachedAllowances
        : defaultAllowancesFor(widget.target.target);

    if (allowances.isNotEmpty) {
      return Tooltip(
        message: _allowanceTooltipMessage(allowances, strings),
        child: _AllowanceMeterGroup(
          allowances: allowances,
          strings: strings,
          colors: colors,
        ),
      );
    }

    final totalTokens = report?.totalTokens ?? 0;
    final usageTokens = usage?.totalTokens ?? 0;
    final percentage = totalTokens > 0 && usage != null
        ? ((usageTokens / totalTokens) * 100).clamp(0, 999).round()
        : null;
    final label = percentage == null ? '--%' : '$percentage%';
    return Tooltip(
      message: strings.usagePercentage(widget.target.label),
      child: _AllowanceMeter(
        key: Key('agent-allowance-meter-usage-${widget.target.target}'),
        label: widget.target.label,
        valueText: label,
        progress: percentage == null ? null : percentage / 100,
        showProgress: true,
        status: usage == null ? 'unavailable' : 'available',
        colors: colors,
      ),
    );
  }
}

class _AllowanceMeterGroup extends StatelessWidget {
  const _AllowanceMeterGroup({
    required this.allowances,
    required this.strings,
    required this.colors,
  });

  final List<AgentUsageAllowance> allowances;
  final LicoStrings strings;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final visibleAllowances = _statusBarAllowances(allowances);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < visibleAllowances.length; index++) ...[
          if (index > 0) const SizedBox(width: 10),
          _AllowanceMeter(
            key: Key('agent-allowance-meter-${visibleAllowances[index].kind}'),
            label: allowanceLabel(visibleAllowances[index], strings),
            valueText: _allowanceMeterValue(visibleAllowances[index], strings),
            progress: _allowanceProgress(visibleAllowances[index]),
            showProgress: _isProgressAllowance(visibleAllowances[index]),
            status: visibleAllowances[index].status,
            colors: colors,
          ),
        ],
      ],
    );
  }
}

class _AllowanceMeter extends StatelessWidget {
  const _AllowanceMeter({
    super.key,
    required this.label,
    required this.valueText,
    required this.progress,
    required this.showProgress,
    required this.status,
    required this.colors,
  });

  final String label;
  final String valueText;
  final double? progress;
  final bool showProgress;
  final String status;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final normalizedProgress = progress?.clamp(0.0, 1.0);
    final fillColor = _allowanceProgressColor(
      normalizedProgress,
      status,
      colors,
    );
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _AllowanceMeterLabel(label: label, colors: colors),
          const SizedBox(width: 6),
          if (showProgress) ...[
            SizedBox(
              width: 54,
              child: _AllowanceProgressTrack(
                key: Key('agent-allowance-progress-track-$label'),
                progress: normalizedProgress,
                fillColor: fillColor,
                colors: colors,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            valueText,
            key: Key('agent-allowance-meter-value-$label'),
            maxLines: 1,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: _allowanceValueColor(status, colors),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _AllowanceProgressTrack extends StatelessWidget {
  const _AllowanceProgressTrack({
    super.key,
    required this.progress,
    required this.fillColor,
    required this.colors,
  });

  final double? progress;
  final Color fillColor;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final normalizedProgress = progress?.clamp(0.0, 1.0) ?? 0.0;
    return SizedBox(
      height: 7,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceHigh,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          if (normalizedProgress > 0)
            FractionallySizedBox(
              widthFactor: normalizedProgress,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AllowanceMeterLabel extends StatelessWidget {
  const _AllowanceMeterLabel({required this.label, required this.colors});

  final String label;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      maxLines: 1,
      style: TextStyle(
        color: colors.textMuted,
        fontWeight: FontWeight.w800,
        fontSize: 10,
      ),
    );
  }
}

String _allowanceTooltipMessage(
  List<AgentUsageAllowance> allowances,
  LicoStrings strings,
) {
  final lines = <String>[
    for (final allowance in allowances)
      if (_isWeeklyQuotaAllowance(allowance))
        _weeklyQuotaTooltipLine(allowance, strings),
    for (final allowance in allowances)
      if (_isResetCreditAllowance(allowance))
        _resetCreditTooltipLine(allowance, strings),
  ].where((line) => line.trim().isNotEmpty).toList(growable: false);
  if (lines.isNotEmpty) {
    return lines.join('\n');
  }
  return allowances
      .map(
        (allowance) =>
            '• ${allowanceLabel(allowance, strings)} ${allowanceValue(allowance, strings)}',
      )
      .join('\n');
}

bool _isWeeklyQuotaAllowance(AgentUsageAllowance allowance) {
  if (_isResetCreditAllowance(allowance)) {
    return false;
  }
  final kind = allowance.kind.trim().toLowerCase();
  final period = allowance.period.trim().toLowerCase();
  return period == 'week' || kind.contains('weekly');
}

bool _isResetCreditAllowance(AgentUsageAllowance allowance) {
  final kind = allowance.kind.trim().toLowerCase();
  final period = allowance.period.trim().toLowerCase();
  return period == 'reset-credits' || kind.contains('reset-credit');
}

String _weeklyQuotaTooltipLine(
  AgentUsageAllowance allowance,
  LicoStrings strings,
) {
  final model = _allowanceModelName(allowance);
  final remaining = _allowanceTooltipPercent(allowance, strings);
  final reset = _allowanceResetTime(allowance.message);
  if (strings.isChinese) {
    return strings.quotaRemaining(model, remaining, reset);
  }
  return strings.quotaRemaining(model, remaining, reset);
}

String _resetCreditTooltipLine(
  AgentUsageAllowance allowance,
  LicoStrings strings,
) {
  final value = _balanceAllowanceValue(allowance, strings);
  return '• ${strings.resetCredits} · $value';
}

String _allowanceModelName(AgentUsageAllowance allowance) {
  final provider = allowance.provider.trim();
  final label = allowance.label.trim();
  var model = provider.isNotEmpty ? provider : label;
  if (model.isEmpty) {
    model = label;
  }
  model = model
      .replaceAll(
        RegExp(r'\s+(session|weekly|quota)\s+limit$', caseSensitive: false),
        '',
      )
      .replaceAll(RegExp(r'\s+(会话|周限额|额度)$'), '')
      .trim();
  return model.isEmpty ? label : model;
}

String _allowanceTooltipPercent(
  AgentUsageAllowance allowance,
  LicoStrings strings,
) {
  final progress = _allowanceProgress(allowance);
  if (progress != null) {
    return '${(progress * 100).round()}%';
  }
  final value = allowance.value.trim();
  if (value.endsWith('%')) {
    return value;
  }
  return _allowanceMeterValue(allowance, strings);
}

String _allowanceResetTime(String message) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  final patterns = [
    RegExp(r'resets?\s+in\s+(.+)$', caseSensitive: false),
    RegExp(r'fully\s+refresh(?:es)?\s+in\s+(.+)$', caseSensitive: false),
    RegExp(r'重置(?:时间|于|在)?\s*[:：]?\s*(.+)$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(trimmed);
    if (match == null) {
      continue;
    }
    return _trimResetTime(match.group(1) ?? '');
  }
  return '';
}

String _trimResetTime(String text) {
  var value = text.trim();
  while (value.endsWith('.') || value.endsWith('。')) {
    value = value.substring(0, value.length - 1).trimRight();
  }
  return value;
}

List<AgentUsageAllowance> _statusBarAllowances(
  List<AgentUsageAllowance> allowances,
) {
  if (allowances.length <= 3) {
    return allowances;
  }
  final antigravityPreferredKinds = const [
    'antigravity-gemini-weekly-limit',
    'antigravity-claude-gpt-weekly-limit',
  ];
  final antigravitySelected = <AgentUsageAllowance>[];
  for (final kind in antigravityPreferredKinds) {
    for (final allowance in allowances) {
      if (allowance.kind == kind) {
        antigravitySelected.add(allowance);
        break;
      }
    }
  }
  if (antigravitySelected.isNotEmpty) {
    return antigravitySelected;
  }
  final preferredKinds = const [
    'chatgpt-weekly-limit',
    'chatgpt-limit-reset-credits',
  ];
  final selected = <AgentUsageAllowance>[];
  for (final kind in preferredKinds) {
    for (final allowance in allowances) {
      if (allowance.kind == kind) {
        selected.add(allowance);
        break;
      }
    }
  }
  if (selected.isNotEmpty) {
    return selected;
  }
  return allowances.take(3).toList(growable: false);
}

String _allowanceMeterValue(
  AgentUsageAllowance allowance,
  LicoStrings strings,
) {
  if (!_isProgressAllowance(allowance)) {
    return _balanceAllowanceValue(allowance, strings);
  }
  final progress = _allowanceProgress(allowance);
  if (progress != null) {
    return '${(progress * 100).round()}%';
  }
  final value = allowance.value.trim();
  if (value.endsWith('%')) {
    return value;
  }
  if (allowance.status.trim().toLowerCase() == 'unavailable') {
    return '--%';
  }
  final fallback = allowanceValue(allowance, strings);
  return fallback.trim().isEmpty ? '--%' : fallback;
}

String _balanceAllowanceValue(
  AgentUsageAllowance allowance,
  LicoStrings strings,
) {
  final value = allowance.value.trim();
  if (value.isNotEmpty) {
    final unit = allowance.unit.trim();
    if (unit.isEmpty ||
        unit.toLowerCase() == 'credits' ||
        unit.toLowerCase() == 'available') {
      return value;
    }
    return '$value $unit';
  }
  final normalized = allowance.status.trim().toLowerCase();
  if (normalized == 'not-configured') {
    return strings.notConfigured;
  }
  return '--';
}

double? _allowanceProgress(AgentUsageAllowance allowance) {
  final value = allowance.value.trim();
  final unit = allowance.unit.trim();
  final rawPercent = value.endsWith('%')
      ? value.substring(0, value.length - 1)
      : unit == '%'
      ? value
      : '';
  if (rawPercent.isEmpty) {
    return null;
  }
  final parsed = double.tryParse(rawPercent.replaceAll(',', '').trim());
  if (parsed == null) {
    return null;
  }
  return (parsed / 100).clamp(0.0, 1.0);
}

bool _isProgressAllowance(AgentUsageAllowance allowance) {
  final period = allowance.period.trim().toLowerCase();
  final kind = allowance.kind.trim().toLowerCase();
  if (kind == 'kilo-recharge-credits') {
    return false;
  }
  if (kind == 'kilo-pass-limit') {
    return true;
  }
  if (period == 'balance' ||
      period == 'reset-credits' ||
      kind.contains('reset-credit')) {
    return false;
  }
  return _allowanceProgress(allowance) != null ||
      period == 'day' ||
      period == 'week' ||
      period == 'month' ||
      kind.contains('limit') ||
      kind.contains('quota');
}

Color _allowanceProgressColor(
  double? progress,
  String status,
  LicoThemeColors colors,
) {
  final normalized = status.trim().toLowerCase();
  if (normalized == 'not-configured') {
    return colors.warning;
  }
  if (normalized == 'exhausted' || (progress != null && progress <= 0)) {
    return colors.error;
  }
  if (progress == null) {
    return colors.primary.withAlpha(120);
  }
  if (progress > 0.8) {
    return colors.success;
  }
  if (progress > 0.2) {
    return colors.info;
  }
  if (progress > 0.1) {
    return colors.warning;
  }
  return colors.error;
}

Color _allowanceValueColor(String status, LicoThemeColors colors) {
  return switch (status.trim().toLowerCase()) {
    'exhausted' => colors.error,
    'not-configured' => colors.warning,
    'unavailable' => colors.textMuted,
    _ => colors.text,
  };
}

String allowanceLabel(AgentUsageAllowance allowance, LicoStrings strings) {
  if (!strings.isChinese) {
    return allowance.label;
  }
  return switch (allowance.kind) {
    'claude-weekly-limit' => 'Claude 周限额',
    'chatgpt-session-limit' => 'ChatGPT 会话',
    'chatgpt-weekly-limit' => 'ChatGPT 周限额',
    'chatgpt-limit-reset-credits' => '重置次数',
    'antigravity-gemini-5h-limit' => 'Gemini 5 小时',
    'antigravity-gemini-weekly-limit' => 'Gemini 周限额',
    'antigravity-claude-gpt-5h-limit' => 'Claude/GPT 5 小时',
    'antigravity-claude-gpt-weekly-limit' => 'Claude/GPT 周限额',
    'antigravity-gemini-model-limit' => 'Gemini 模型额度',
    'antigravity-claude-gpt-model-limit' => 'Claude/GPT 模型额度',
    'kilo-pass-limit' => 'Kilo Pass',
    'kilo-recharge-credits' => '充值额度',
    'model-api-balance' => 'API 余额',
    _ => allowance.label,
  };
}

String allowanceValue(AgentUsageAllowance allowance, LicoStrings strings) {
  final value = allowance.value.trim();
  if (value.isNotEmpty) {
    return allowance.unit.trim().isEmpty ? value : '$value ${allowance.unit}';
  }
  final normalized = allowance.status.trim().toLowerCase();
  if (normalized == 'not-configured') {
    return strings.notConfigured;
  }
  return strings.unavailable;
}
