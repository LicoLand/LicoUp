import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Product-level Assistant mark. The source asset is Lucide Sparkles (ISC),
/// kept as a vector so the same mark remains crisp in composer and bubbles.
final class AssistantSparklesIcon extends StatelessWidget {
  const AssistantSparklesIcon({super.key, required this.color, this.size = 20});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/agent-icons/assistant-sparkles.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
