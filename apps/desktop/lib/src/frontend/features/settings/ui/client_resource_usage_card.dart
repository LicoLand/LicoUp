import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';

class ClientResourceUsageCard extends StatefulWidget {
  const ClientResourceUsageCard({
    super.key,
    required this.binding,
    this.totalMemoryBytes,
  });

  final SettingsBinding binding;

  /// Injectable machine capacity for tests; defaults to a live platform read.
  final int? totalMemoryBytes;

  @override
  State<ClientResourceUsageCard> createState() =>
      _ClientResourceUsageCardState();
}

class _ClientResourceUsageCardState extends State<ClientResourceUsageCard> {
  @override
  void initState() {
    super.initState();
    widget.binding.intents.send(const StartSettingsResourceUsage());
  }

  @override
  void didUpdateWidget(ClientResourceUsageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      oldWidget.binding.intents.send(const StopSettingsResourceUsage());
      widget.binding.intents.send(const StartSettingsResourceUsage());
    }
  }

  @override
  void dispose() {
    widget.binding.intents.send(const StopSettingsResourceUsage());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<
      SettingsResourceUsageProjection,
      SettingsResourceUsageProjection
    >(
      source: widget.binding.resourceUsage,
      select: _resourceIdentity,
      builder: _buildSnapshot,
    );
  }

  Widget _buildSnapshot(
    BuildContext context,
    SettingsResourceUsageProjection snapshot,
  ) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    if (!snapshot.supported) {
      return ListTile(
        leading: Icon(
          Icons.monitor_heart_outlined,
          color: colors.textSecondary,
        ),
        title: Text(strings.resourceUsage),
        subtitle: Text(strings.resourceUsageUnsupported),
      );
    }
    final totalMemoryBytes =
        widget.totalMemoryBytes ?? snapshot.totalMemoryBytes;
    final segments = _buildSegments(
      strings: strings,
      colors: colors,
      clientRssBytes: snapshot.clientRssBytes,
      agentRssBytes: snapshot.agentRssBytes,
    );
    final trackedBytes = segments.fold<int>(
      0,
      (sum, segment) => sum + segment.bytes,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LicoContentSpacing.item,
        LicoContentSpacing.compact,
        LicoContentSpacing.item,
        LicoContentSpacing.item,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.monitor_heart_outlined,
                size: 18,
                color: colors.textSecondary,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Text(
                  strings.resourceUsage,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: colors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: LicoContentSpacing.item),
          if (totalMemoryBytes == null || totalMemoryBytes <= 0)
            Text(
              snapshot.clientRssBytes <= 0
                  ? strings.memoryUsage
                  : '${strings.appTitle}  '
                        '${formatMemoryCapacity(snapshot.clientRssBytes)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            )
          else
            _MemoryRingBlock(
              segments: segments,
              totalMemoryBytes: totalMemoryBytes,
              trackedBytes: trackedBytes,
              colors: colors,
              strings: strings,
            ),
        ],
      ),
    );
  }

  List<MemoryUsageRingSegment> _buildSegments({
    required LicoStrings strings,
    required LicoThemeColors colors,
    required int clientRssBytes,
    required Map<String, int> agentRssBytes,
  }) {
    final palette = memoryUsageSegmentPalette(colors);
    final segments = <MemoryUsageRingSegment>[
      MemoryUsageRingSegment(
        id: 'licoup',
        label: strings.appTitle,
        bytes: clientRssBytes < 0 ? 0 : clientRssBytes,
        color: palette.first,
      ),
    ];
    final targets = agentRssBytes.keys.toList()..sort();
    for (var index = 0; index < targets.length; index += 1) {
      final target = targets[index];
      final rssBytes = agentRssBytes[target]!;
      segments.add(
        MemoryUsageRingSegment(
          id: target,
          label: _agentDisplayLabel(target),
          bytes: rssBytes < 0 ? 0 : rssBytes,
          color: palette[(index + 1) % palette.length],
        ),
      );
    }
    return segments;
  }
}

SettingsResourceUsageProjection _resourceIdentity(
  SettingsResourceUsageProjection value,
) => value;

class _MemoryRingBlock extends StatelessWidget {
  const _MemoryRingBlock({
    required this.segments,
    required this.totalMemoryBytes,
    required this.trackedBytes,
    required this.colors,
    required this.strings,
  });

  final List<MemoryUsageRingSegment> segments;
  final int totalMemoryBytes;
  final int trackedBytes;
  final LicoThemeColors colors;
  final LicoStrings strings;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 148,
          height: 148,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(148),
                painter: MemoryUsageRingPainter(
                  segments: segments,
                  totalBytes: totalMemoryBytes,
                  colors: colors,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      formatMemoryCapacity(trackedBytes),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: colors.text,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      strings.memoryOfTotal(
                        formatMemoryCapacity(totalMemoryBytes),
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10.5, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: LicoContentSpacing.item),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final segment in segments) ...[
                _SegmentLegendRow(segment: segment, colors: colors),
                const SizedBox(height: LicoContentSpacing.compact),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SegmentLegendRow extends StatelessWidget {
  const _SegmentLegendRow({required this.segment, required this.colors});

  final MemoryUsageRingSegment segment;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: segment.color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: LicoContentSpacing.compact),
        Expanded(
          child: Text(
            segment.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.text,
            ),
          ),
        ),
        const SizedBox(width: LicoContentSpacing.compact),
        Text(
          formatRssBytes(segment.bytes),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: colors.text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: LicoContentSpacing.inline),
        Text(
          segment.bytes >= 1024 * 1024 * 1024 ? 'GB' : 'MB',
          style: TextStyle(fontSize: 10, color: colors.textMuted),
        ),
      ],
    );
  }
}

String _agentDisplayLabel(String target) {
  return switch (target) {
    'claude-code' => 'Claude Code',
    'kimi-code' => 'Kimi Code',
    'kilo-code' => 'Kilo Code',
    _ => target,
  };
}
