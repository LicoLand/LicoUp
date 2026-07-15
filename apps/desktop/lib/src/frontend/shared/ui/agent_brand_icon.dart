import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:flutter_client/src/contracts/agent_orchestration_policy.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

const _agentIconAssets = <String, String>{
  'openclaw': 'assets/agent-icons/openclaw.svg',
  'claude-code': 'assets/agent-icons/claude-code.svg',
  // ChatGPT blossom mark (no app-icon background).
  'codex': 'assets/agent-icons/codex-light.svg',
  'code': 'assets/agent-icons/vscode.png',
  'vscode': 'assets/agent-icons/vscode.png',
  // Official Antigravity mark extracted from the local app icon (no squircle).
  'antigravity': 'assets/agent-icons/antigravity.png',
  'opencode': 'assets/agent-icons/opencode.svg',
  'copilot': 'assets/agent-icons/copilot.svg',
  'kilo-code': 'assets/agent-icons/kilo-code.svg',
  'cursor': 'assets/agent-icons/cursor.svg',
  'hermes': 'assets/agent-icons/hermes.svg',
  // Theme-aware lettermarks (no app-icon background).
  'kimi': 'assets/agent-icons/kimi-light.svg',
  'kimi-code': 'assets/agent-icons/kimi-light.svg',
  'pi': 'assets/agent-icons/pi.svg',
};

const _agentIconDarkAssets = <String, String>{
  'codex': 'assets/agent-icons/codex-dark.svg',
  'kimi': 'assets/agent-icons/kimi-dark.svg',
  'kimi-code': 'assets/agent-icons/kimi-dark.svg',
};

/// Mono marks that ship as `currentColor` and need a theme-aware brand fill.
const _agentIconTintKeys = <String>{'cursor', 'hermes', 'opencode'};

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
    final brightness = Theme.of(context).brightness;
    final key = _agentIconAssets.containsKey(target.target)
        ? target.target
        : (_agentIconAssets.containsKey(target.id) ? target.id : null);
    final asset = key == null
        ? null
        : (brightness == Brightness.dark
              ? (_agentIconDarkAssets[key] ?? _agentIconAssets[key])
              : _agentIconAssets[key]);
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: isAgentOrchestrationTargetId(target.target)
            ? Icon(
                Icons.account_tree_outlined,
                size: iconSize,
                color: selected ? colors.primary : colors.text,
              )
            : asset == null
            ? Icon(
                target.manual
                    ? Icons.edit_location_alt_outlined
                    : Icons.extension_outlined,
                size: iconSize,
                color: selected
                    ? colors.primary
                    : detected
                    ? colors.text
                    : colors.textMuted,
              )
            : asset.endsWith('.svg')
            ? SvgPicture.asset(
                asset,
                width: iconSize,
                height: iconSize,
                fit: BoxFit.contain,
                colorFilter: key != null && _agentIconTintKeys.contains(key)
                    ? ColorFilter.mode(
                        brightness == Brightness.dark
                            ? Colors.white
                            : const Color(0xFF111111),
                        BlendMode.srcIn,
                      )
                    : null,
                semanticsLabel: target.label,
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
