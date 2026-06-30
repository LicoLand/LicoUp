import 'package:flutter/material.dart';

import '../services/target_candidate.dart';
import 'theme.dart';

const _agentIconAssets = <String, String>{
  'openclaw': 'assets/agent-icons/openclaw.png',
  'claude-code': 'assets/agent-icons/claude-code.png',
  'codex': 'assets/agent-icons/codex.png',
  'code': 'assets/agent-icons/vscode.png',
  'vscode': 'assets/agent-icons/vscode.png',
  'antigravity': 'assets/agent-icons/antigravity.png',
  'opencode': 'assets/agent-icons/opencode.png',
  'copilot': 'assets/agent-icons/copilot.png',
  'kilo-code': 'assets/agent-icons/kilo-code.png',
  'cursor': 'assets/agent-icons/cursor.png',
  'hermes': 'assets/agent-icons/hermes.png',
};

class AgentBrandIcon extends StatelessWidget {
  const AgentBrandIcon({
    super.key,
    required this.target,
    this.size = 30,
    this.iconSize = 20,
    this.selected = false,
    this.detected = true,
  });

  final TargetCandidate target;
  final double size;
  final double iconSize;
  final bool selected;
  final bool detected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final asset =
        _agentIconAssets[target.target] ?? _agentIconAssets[target.id];
    final background = selected
        ? colors.primaryFixed
        : detected
        ? Color.lerp(colors.surfaceLow, colors.primaryFixed, 0.38)!
        : colors.surfaceLow;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? colors.primary : colors.line,
          width: selected ? 1 : 0.6,
        ),
      ),
      child: Center(
        child: asset == null
            ? Icon(
                target.manual
                    ? Icons.edit_location_alt_outlined
                    : Icons.extension_outlined,
                size: iconSize,
                color: detected ? colors.primary : colors.textMuted,
              )
            : Image.asset(
                asset,
                width: iconSize,
                height: iconSize,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
      ),
    );
  }
}
