import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_segmented_control.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

const List<int> _presetDays = <int>[7, 30, 90];

/// Usage-window picker: one connected segmented control of preset ranges.
/// One tap applies; nothing else to learn or operate.
class AgentUsageWindowControl extends StatelessWidget {
  const AgentUsageWindowControl({
    super.key,
    required this.days,
    required this.busy,
    required this.onChanged,
  });

  final int days;
  final bool busy;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Semantics(
      label: strings.tokenUsageWindow,
      value: strings.lastDays(days),
      child: AgentUsageSegmentedTrack(
        children: [
          for (final preset in _presetDays)
            AgentUsageSegment(
              key: Key('agent-usage-window-chip-$preset'),
              label: strings.daysShort(preset),
              selected: days == preset,
              onTap: busy ? null : () => onChanged(preset),
            ),
        ],
      ),
    );
  }
}
