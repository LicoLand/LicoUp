import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ClientResourceUsageCard extends StatefulWidget {
  const ClientResourceUsageCard({
    super.key,
    this.controller,
    this.agentController,
    this.totalMemoryBytes,
  });

  /// Injectable for tests; when null the card owns a live probe-backed
  /// controller for the current platform.
  final ClientResourceUsageController? controller;

  /// Optional shared agent sampler so the ring can include running agents.
  final AgentResourceUsageController? agentController;

  /// Injectable machine capacity for tests; defaults to a live platform read.
  final int? totalMemoryBytes;

  @override
  State<ClientResourceUsageCard> createState() =>
      _ClientResourceUsageCardState();
}

class _ClientResourceUsageCardState extends State<ClientResourceUsageCard> {
  ClientResourceUsageController? _ownedController;

  ClientResourceUsageController get _controller =>
      widget.controller ??
      (_ownedController ??= createClientResourceUsageController());

  @override
  void initState() {
    super.initState();
    _controller.start();
    widget.agentController?.start();
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final controller = _controller;
    if (!controller.supported) {
      return ListTile(
        leading: Icon(
          Icons.monitor_heart_outlined,
          color: colors.textSecondary,
        ),
        title: Text(strings.resourceUsage),
        subtitle: Text(strings.resourceUsageUnsupported),
      );
    }
    final agentController = widget.agentController;
    final listenables = <Listenable>[controller];
    if (agentController != null) {
      listenables.add(agentController);
    }
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        final latest = controller.samples.isEmpty
            ? null
            : controller.samples.last;
        final totalMemoryBytes =
            widget.totalMemoryBytes ?? controller.totalMemoryBytes;
        final segments = _buildSegments(
          strings: strings,
          colors: colors,
          clientRssBytes: latest?.rssBytes ?? 0,
          agentController: agentController,
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
                  latest == null
                      ? strings.memoryUsage
                      : '${strings.appTitle}  ${formatMemoryCapacity(latest.rssBytes)}',
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
      },
    );
  }

  List<MemoryUsageRingSegment> _buildSegments({
    required LicoStrings strings,
    required LicoThemeColors colors,
    required int clientRssBytes,
    required AgentResourceUsageController? agentController,
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
    if (agentController == null) {
      return segments;
    }
    final latestByAgent = agentController.latestByAgent;
    final targets = latestByAgent.keys.toList()..sort();
    for (var index = 0; index < targets.length; index += 1) {
      final target = targets[index];
      final sample = latestByAgent[target]!;
      segments.add(
        MemoryUsageRingSegment(
          id: target,
          label: _agentDisplayLabel(target),
          bytes: sample.rssBytes < 0 ? 0 : sample.rssBytes,
          color: palette[(index + 1) % palette.length],
        ),
      );
    }
    return segments;
  }
}

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
