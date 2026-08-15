import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentUsagePanelHeader extends StatelessWidget {
  const AgentUsagePanelHeader({
    super.key,
    required this.title,
    this.onExit,
    this.trailing = const <Widget>[],
  });

  final String title;
  final VoidCallback? onExit;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Row(
      children: [
        if (onExit != null)
          Tooltip(
            message: strings.exit,
            waitDuration: LicoMotion.tooltipWait,
            child: InkWell(
              key: const Key('agent-usage-exit-button'),
              onTap: onExit,
              customBorder: const CircleBorder(),
              child: Padding(
                padding: const EdgeInsets.only(
                  right: LicoContentSpacing.compact,
                ),
                child: Icon(
                  Icons.chevron_left_rounded,
                  size: 20,
                  color: colors.text,
                ),
              ),
            ),
          ),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
        ),
        ...trailing,
      ],
    );
  }
}

class AgentUsageEmptyState extends StatelessWidget {
  const AgentUsageEmptyState({super.key, this.onExit});

  final VoidCallback? onExit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final empty = Text(
      strings.noUsageReportYet,
      style: TextStyle(color: colors.textMuted, fontWeight: FontWeight.w700),
    );
    if (onExit == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: empty,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AgentUsagePanelHeader(title: strings.tokenUsage, onExit: onExit),
        const SizedBox(height: LicoContentSpacing.compact),
        empty,
      ],
    );
  }
}

class AgentUsageBarSection extends StatelessWidget {
  const AgentUsageBarSection({
    super.key,
    this.title,
    required this.rows,
    required this.emptyLabel,
    this.valueHeader,
  });

  final String? title;
  final List<AgentUsageBarData> rows;
  final String emptyLabel;
  final String? valueHeader;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null) ...[
          Text(
            title!,
            style: TextStyle(
              color: colors.text,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
        ],
        if (rows.isNotEmpty && valueHeader != null) ...[
          _UsageBarHeader(valueHeader: valueHeader!),
          const SizedBox(height: 6),
        ],
        if (rows.isEmpty)
          Text(
            emptyLabel,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          )
        else
          for (final row in rows) ...[
            _UsageBarRow(data: row),
            if (row != rows.last) const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _UsageBarHeader extends StatelessWidget {
  const _UsageBarHeader({required this.valueHeader});

  final String valueHeader;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: context.licoColors.textMuted,
      fontSize: 10,
      fontWeight: FontWeight.w700,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 640) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(valueHeader, style: style),
              const SizedBox(width: 64),
            ],
          );
        }
        return Row(
          children: [
            const SizedBox(width: 150),
            const SizedBox(width: 10),
            const Expanded(child: SizedBox.shrink()),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: Text(
                valueHeader,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: style,
              ),
            ),
            const SizedBox(width: 10),
            const SizedBox(width: 64),
          ],
        );
      },
    );
  }
}

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({required this.data});

  final AgentUsageBarData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final fraction = data.fraction.clamp(0.0, 1.0).toDouble();
    final label = Text(
      data.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: colors.textMuted, fontSize: 12),
    );
    final value = _UsageBarValue(
      value: data.value,
      color: colors.text,
      width: 96,
      weight: FontWeight.w800,
    );
    final trailing = _UsageBarValue(
      value: data.trailing,
      color: colors.textMuted,
      width: 64,
      weight: FontWeight.w400,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final progress = KeyedSubtree(
          key: ValueKey('usage-progress-${data.label}'),
          child: _UsageProgressBar(
            fraction: fraction,
            accent: data.accent ?? colors.primary,
          ),
        );
        if (constraints.maxWidth < 640) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: label),
                  const SizedBox(width: 8),
                  value,
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
              const SizedBox(height: 5),
              FractionallySizedBox(
                widthFactor: 0.72,
                alignment: Alignment.centerLeft,
                child: progress,
              ),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 150, child: label),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: SizedBox(width: double.infinity, child: progress),
                ),
              ),
            ),
            const SizedBox(width: 10),
            value,
            const SizedBox(width: 10),
            trailing,
          ],
        );
      },
    );
  }
}

class _UsageProgressBar extends StatelessWidget {
  const _UsageProgressBar({required this.fraction, required this.accent});

  final double fraction;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillWidth = constraints.maxWidth * fraction;
        return Stack(
          children: [
            Container(
              key: const ValueKey('usage-progress-track'),
              height: 10,
              decoration: BoxDecoration(
                color: colors.surfaceLow,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Container(
              key: const ValueKey('usage-progress-fill'),
              width: fillWidth,
              height: 10,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _UsageBarValue extends StatelessWidget {
  const _UsageBarValue({
    required this.value,
    required this.color,
    required this.width,
    required this.weight,
  });

  final String value;
  final Color color;
  final double width;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.right,
        style: TextStyle(color: color, fontSize: 12, fontWeight: weight),
      ),
    );
  }
}

class AgentUsageBarData {
  const AgentUsageBarData({
    required this.label,
    required this.value,
    required this.trailing,
    required this.fraction,
    this.accent,
  });

  final String label;
  final String value;
  final String trailing;
  final double fraction;
  final Color? accent;
}
