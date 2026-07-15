import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class ProxyBridgeStatusPill extends StatelessWidget {
  const ProxyBridgeStatusPill({
    super.key,
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: colors.primary),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: colors.text,
            ),
          ),
        ],
      ),
    );
  }
}

Map<String, dynamic> proxyBridgeMap(Object? value) {
  return value is Map<String, dynamic>
      ? value
      : value is Map
      ? Map<String, dynamic>.from(value)
      : const {};
}

Map<String, dynamic> tunAssistFromProxyBridgeStatus(
  Map<String, dynamic> status,
) {
  final document = proxyBridgeMap(status['document']);
  final fromDocument = proxyBridgeMap(document['tunAssist']);
  if (fromDocument.isNotEmpty) {
    return fromDocument;
  }
  return proxyBridgeMap(status['tunAssist']);
}

String proxyBridgeWrapperRoot(
  Map<String, dynamic> status,
  Map<String, dynamic> plan,
) {
  final source = plan.isNotEmpty ? plan : status;
  final wrappers = proxyBridgeMap(source['wrappers']);
  if (wrappers['root'] != null) {
    return wrappers['root'].toString();
  }
  final document = proxyBridgeMap(status['document']);
  return proxyBridgeMap(document['wrappers'])['root']?.toString() ?? '';
}

String proxyBridgeTargetLabel(String target) {
  return switch (target) {
    'codex' => 'ChatGPT Codex - CLI',
    'claude-code' => 'Claude Code - CLI',
    'antigravity' => 'Antigravity - CLI',
    'opencode' => 'OpenCode - CLI',
    'openclaw' => 'OpenClaw - CLI',
    'cursor' => 'Cursor - IDE',
    'code' => 'Visual Studio Code - IDE',
    'copilot' => 'GitHub Copilot - CLI',
    'kilo-code' => 'Kilo Code - CLI',
    'kimi-code' => 'Kimi Code - CLI',
    'hermes' => 'Hermes Agent - CLI',
    _ => target,
  };
}
