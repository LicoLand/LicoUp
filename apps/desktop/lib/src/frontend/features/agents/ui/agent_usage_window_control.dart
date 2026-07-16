import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

class AgentUsageWindowControl extends StatefulWidget {
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
  State<AgentUsageWindowControl> createState() =>
      _AgentUsageWindowControlState();
}

final class _AgentUsageWindowControlState
    extends State<AgentUsageWindowControl> {
  late int _draftDays;

  @override
  void initState() {
    super.initState();
    _draftDays = widget.days.clamp(1, 365).toInt();
  }

  @override
  void didUpdateWidget(covariant AgentUsageWindowControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.days != widget.days) {
      _draftDays = widget.days.clamp(1, 365).toInt();
    }
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Semantics(
      label: strings.tokenUsageWindow,
      value: strings.lastDays(_draftDays),
      child: Row(
        children: [
          SizedBox(
            width: 112,
            child: Text(
              strings.lastDays(_draftDays),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          Expanded(
            child: Slider(
              key: const Key('agent-usage-history-days'),
              value: _draftDays.toDouble(),
              min: 1,
              max: 365,
              divisions: 364,
              label: strings.lastDays(_draftDays),
              onChanged: widget.busy
                  ? null
                  : (value) => setState(() => _draftDays = value.round()),
              onChangeEnd: widget.busy
                  ? null
                  : (value) => widget.onChanged(value.round()),
            ),
          ),
        ],
      ),
    );
  }
}
