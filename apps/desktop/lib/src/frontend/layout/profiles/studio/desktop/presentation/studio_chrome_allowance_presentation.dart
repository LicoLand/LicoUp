import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';

enum LayoutChromeStatusTone {
  neutral,
  primaryMuted,
  info,
  success,
  warning,
  error,
}

@immutable
final class LayoutChromeAllowancePresentation {
  LayoutChromeAllowancePresentation({
    required this.tooltip,
    required Iterable<LayoutChromeAllowanceMeterPresentation> meters,
  }) : meters = UnmodifiableListView(
         List<LayoutChromeAllowanceMeterPresentation>.of(meters),
       );

  final String tooltip;
  final List<LayoutChromeAllowanceMeterPresentation> meters;
}

@immutable
final class LayoutChromeAllowanceMeterPresentation {
  const LayoutChromeAllowanceMeterPresentation({
    required this.semanticId,
    required this.label,
    required this.valueText,
    required this.progress,
    required this.showProgress,
    required this.status,
    required this.progressTone,
    required this.valueTone,
  });

  final String semanticId;
  final String label;
  final String valueText;
  final double? progress;
  final bool showProgress;
  final String status;
  final LayoutChromeStatusTone progressTone;
  final LayoutChromeStatusTone valueTone;
}

/// Converts the controller-free semantic snapshot into localized, style-free
/// meter values. Individual profiles still own every visual decision.
LayoutChromeAllowancePresentation? presentLayoutChromeAllowance(
  LayoutChromeAllowanceSnapshot? allowance,
  LicoStrings strings,
) {
  if (allowance == null) {
    return null;
  }
  if (allowance.meters.isEmpty) {
    final percentage = allowance.usagePercentage;
    final status = percentage == null ? 'unavailable' : 'available';
    return LayoutChromeAllowancePresentation(
      tooltip: strings.usagePercentage(allowance.targetLabel),
      meters: [
        LayoutChromeAllowanceMeterPresentation(
          semanticId: 'usage-${allowance.targetId}',
          label: allowance.targetLabel,
          valueText: percentage == null ? '--%' : '$percentage%',
          progress: percentage == null ? null : percentage / 100,
          showProgress: true,
          status: status,
          progressTone: _progressTone(
            percentage == null ? null : percentage / 100,
            status,
          ),
          valueTone: _valueTone(status),
        ),
      ],
    );
  }

  final visible = _statusBarAllowances(allowance.meters);
  return LayoutChromeAllowancePresentation(
    tooltip: _allowanceTooltipMessage(allowance.meters, strings),
    meters: [
      for (final meter in visible)
        LayoutChromeAllowanceMeterPresentation(
          semanticId: meter.kind,
          label: _allowanceLabel(meter, strings),
          valueText: _allowanceMeterValue(meter, strings),
          progress: _allowanceProgress(meter),
          showProgress: _isProgressAllowance(meter),
          status: meter.status,
          progressTone: _progressTone(_allowanceProgress(meter), meter.status),
          valueTone: _valueTone(meter.status),
        ),
    ],
  );
}

String _allowanceTooltipMessage(
  List<LayoutChromeAllowanceMeterSnapshot> allowances,
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
            '• ${_allowanceLabel(allowance, strings)} ${_allowanceValue(allowance, strings)}',
      )
      .join('\n');
}

bool _isWeeklyQuotaAllowance(LayoutChromeAllowanceMeterSnapshot allowance) {
  if (_isResetCreditAllowance(allowance)) {
    return false;
  }
  final kind = allowance.kind.trim().toLowerCase();
  final period = allowance.period.trim().toLowerCase();
  return period == 'week' || kind.contains('weekly');
}

bool _isResetCreditAllowance(LayoutChromeAllowanceMeterSnapshot allowance) {
  final kind = allowance.kind.trim().toLowerCase();
  final period = allowance.period.trim().toLowerCase();
  return period == 'reset-credits' || kind.contains('reset-credit');
}

String _weeklyQuotaTooltipLine(
  LayoutChromeAllowanceMeterSnapshot allowance,
  LicoStrings strings,
) => strings.quotaRemaining(
  _allowanceModelName(allowance),
  _allowanceTooltipPercent(allowance, strings),
  _allowanceResetTime(allowance.message),
);

String _resetCreditTooltipLine(
  LayoutChromeAllowanceMeterSnapshot allowance,
  LicoStrings strings,
) =>
    '• ${strings.resetCredits} · ${_balanceAllowanceValue(allowance, strings)}';

String _allowanceModelName(LayoutChromeAllowanceMeterSnapshot allowance) {
  final provider = allowance.provider.trim();
  final label = allowance.label.trim();
  var model = provider.isNotEmpty ? provider : label;
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
  LayoutChromeAllowanceMeterSnapshot allowance,
  LicoStrings strings,
) {
  final progress = _allowanceProgress(allowance);
  if (progress != null) {
    return '${(progress * 100).round()}%';
  }
  final value = allowance.value.trim();
  return value.endsWith('%') ? value : _allowanceMeterValue(allowance, strings);
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
    if (match != null) {
      return _trimResetTime(match.group(1) ?? '');
    }
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

List<LayoutChromeAllowanceMeterSnapshot> _statusBarAllowances(
  List<LayoutChromeAllowanceMeterSnapshot> allowances,
) {
  if (allowances.length <= 3) {
    return allowances;
  }
  for (final preferredKinds in const [
    ['antigravity-gemini-weekly-limit', 'antigravity-claude-gpt-weekly-limit'],
    ['chatgpt-weekly-limit', 'chatgpt-limit-reset-credits'],
  ]) {
    final selected = <LayoutChromeAllowanceMeterSnapshot>[];
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
  }
  return allowances.take(3).toList(growable: false);
}

String _allowanceMeterValue(
  LayoutChromeAllowanceMeterSnapshot allowance,
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
  final fallback = _allowanceValue(allowance, strings);
  return fallback.trim().isEmpty ? '--%' : fallback;
}

String _balanceAllowanceValue(
  LayoutChromeAllowanceMeterSnapshot allowance,
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
  return allowance.status.trim().toLowerCase() == 'not-configured'
      ? strings.notConfigured
      : '--';
}

String _allowanceLabel(
  LayoutChromeAllowanceMeterSnapshot allowance,
  LicoStrings strings,
) {
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

String _allowanceValue(
  LayoutChromeAllowanceMeterSnapshot allowance,
  LicoStrings strings,
) {
  final value = allowance.value.trim();
  if (value.isNotEmpty) {
    return allowance.unit.trim().isEmpty ? value : '$value ${allowance.unit}';
  }
  return allowance.status.trim().toLowerCase() == 'not-configured'
      ? strings.notConfigured
      : strings.unavailable;
}

double? _allowanceProgress(LayoutChromeAllowanceMeterSnapshot allowance) {
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
  return parsed == null ? null : (parsed / 100).clamp(0.0, 1.0);
}

bool _isProgressAllowance(LayoutChromeAllowanceMeterSnapshot allowance) {
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

LayoutChromeStatusTone _progressTone(double? progress, String status) {
  final normalized = status.trim().toLowerCase();
  if (normalized == 'not-configured') {
    return LayoutChromeStatusTone.warning;
  }
  if (normalized == 'exhausted' || (progress != null && progress <= 0)) {
    return LayoutChromeStatusTone.error;
  }
  if (progress == null) {
    return LayoutChromeStatusTone.primaryMuted;
  }
  if (progress > 0.8) {
    return LayoutChromeStatusTone.success;
  }
  if (progress > 0.2) {
    return LayoutChromeStatusTone.info;
  }
  if (progress > 0.1) {
    return LayoutChromeStatusTone.warning;
  }
  return LayoutChromeStatusTone.error;
}

LayoutChromeStatusTone _valueTone(String status) =>
    switch (status.trim().toLowerCase()) {
      'exhausted' => LayoutChromeStatusTone.error,
      'not-configured' => LayoutChromeStatusTone.warning,
      'unavailable' => LayoutChromeStatusTone.neutral,
      _ => LayoutChromeStatusTone.neutral,
    };
