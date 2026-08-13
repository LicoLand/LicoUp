import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/frontend/features/settings/ui/resource_usage_shared.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ClientResourceUsageCard extends StatefulWidget {
  const ClientResourceUsageCard({super.key, this.controller});

  /// Injectable for tests; when null the card owns a live probe-backed
  /// controller for the current platform.
  final ClientResourceUsageController? controller;

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
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final latest = controller.samples.isEmpty
            ? null
            : controller.samples.last;
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
              const SizedBox(height: LicoContentSpacing.compact),
              Text(
                strings.resourceSamplingHint,
                style: TextStyle(fontSize: 11.5, color: colors.textMuted),
              ),
              const SizedBox(height: LicoContentSpacing.item),
              _MetricBlock(
                label: strings.memoryUsage,
                value: latest == null ? '--' : formatRssBytes(latest.rssBytes),
                unit: latest == null ? '' : 'MB',
                values: [
                  for (final sample in controller.samples)
                    sample.rssBytes.toDouble(),
                ],
                color: colors.accent,
                colors: colors,
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              _MetricBlock(
                label: strings.diskReadRate,
                value: latest == null
                    ? '--'
                    : formatRateKbPerSec(_rateKbPerSec(latest, read: true)),
                unit: latest == null ? '' : 'KB/s',
                values: [
                  for (final sample in controller.samples)
                    _rateKbPerSec(sample, read: true),
                ],
                color: colors.accent,
                colors: colors,
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              _MetricBlock(
                label: strings.diskWriteRate,
                value: latest == null
                    ? '--'
                    : formatRateKbPerSec(_rateKbPerSec(latest, read: false)),
                unit: latest == null ? '' : 'KB/s',
                values: [
                  for (final sample in controller.samples)
                    _rateKbPerSec(sample, read: false),
                ],
                color: colors.success,
                colors: colors,
              ),
              const SizedBox(height: LicoContentSpacing.compact),
              Text(
                strings.sessionTransferTotal(
                  formatBytes(controller.sessionReadBytes),
                  formatBytes(controller.sessionWriteBytes),
                ),
                style: TextStyle(fontSize: 11.5, color: colors.textMuted),
              ),
            ],
          ),
        );
      },
    );
  }

  double _rateKbPerSec(ClientResourceUsageSample sample, {required bool read}) {
    final intervalMs = sample.interval.inMilliseconds;
    if (intervalMs <= 0) {
      return 0;
    }
    final deltaBytes = read ? sample.deltaReadBytes : sample.deltaWriteBytes;
    return deltaBytes * 1000 / intervalMs / 1024;
  }
}

class _MetricBlock extends StatelessWidget {
  const _MetricBlock({
    required this.label,
    required this.value,
    required this.unit,
    required this.values,
    required this.color,
    required this.colors,
  });

  final String label;
  final String value;
  final String unit;
  final List<double> values;
  final Color color;
  final LicoThemeColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 118,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: colors.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: LicoContentSpacing.inline / 2),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: colors.text,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: LicoContentSpacing.inline),
                    Text(
                      unit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: LicoContentSpacing.item),
        Expanded(
          child: SizedBox(
            height: 56,
            child: CustomPaint(
              painter: ResourceUsageSparklinePainter(
                values: values,
                color: color,
                colors: colors,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
