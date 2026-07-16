import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

String formatAgentUsageTimeLabel(DateTime time) {
  return '${time.month}-${time.day}';
}

String formatAgentUsageTooltipNumber(num value) {
  if (value <= 0) {
    return '0';
  }
  return formatAgentUsageNumber(value);
}

String formatAgentUsageNumber(num value) {
  if (value <= 0) {
    return '-';
  }
  if (value >= 1000000000000) {
    return '${_trimTrailingZero((value / 1000000000000).toStringAsFixed(1))}T';
  }
  if (value >= 1000000000) {
    return '${_trimTrailingZero((value / 1000000000).toStringAsFixed(1))}G';
  }
  if (value >= 1000000) {
    return '${_trimTrailingZero((value / 1000000).toStringAsFixed(1))}M';
  }
  if (value >= 1000) {
    return '${_trimTrailingZero((value / 1000).toStringAsFixed(1))}K';
  }
  final normalized = value is int || value == value.roundToDouble()
      ? value.round().toString()
      : value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');
  return _withThousandsSeparators(normalized);
}

String formatCompactAgentUsageNumber(num value) {
  return formatAgentUsageNumber(value);
}

String _trimTrailingZero(String value) {
  if (value.endsWith('.0')) {
    return value.substring(0, value.length - 2);
  }
  return value;
}

String _withThousandsSeparators(String value) {
  final parts = value.split('.');
  final text = parts.first;
  final buffer = StringBuffer();
  for (var index = 0; index < text.length; index += 1) {
    if (index > 0 && (text.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(text[index]);
  }
  if (parts.length > 1 && parts[1].isNotEmpty) {
    buffer.write('.');
    buffer.write(parts[1]);
  }
  return buffer.toString();
}

String formatAgentUsagePercent(num value, num total) {
  if (value <= 0 || total <= 0) {
    return '--%';
  }
  return '${((value / total) * 100).clamp(0, 999).round()}%';
}

/// Bar fill width as this row's share of the section total (not max among rows).
double agentUsageShareFraction(num value, num total) {
  if (value <= 0 || total <= 0) {
    return 0;
  }
  return (value / total).clamp(0.0, 1.0).toDouble();
}

String agentUsageWarningLabel(String value, LicoStrings strings) {
  return switch (value.trim().toLowerCase()) {
    'codex_local_token_event_scan_failed' =>
      strings.isChinese
          ? 'ChatGPT Token 历史扫描失败'
          : 'ChatGPT token history scan failed',
    'native_history_scan_failed' =>
      strings.isChinese ? '原生历史扫描失败' : 'Native history scan failed',
    'target_scan_failed' =>
      strings.isChinese ? '智能体检测失败' : 'Agent detection failed',
    _ => strings.isChinese ? '用量统计存在未识别警告' : 'Unrecognized usage warning',
  };
}
