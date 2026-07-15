import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ProviderBrandIcon extends StatelessWidget {
  const ProviderBrandIcon({
    super.key,
    required this.providerId,
    required this.color,
    this.size = 30,
  });

  final String providerId;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final icon = _brandIconFor(providerId, brightness);
    if (icon == null) {
      return Icon(Icons.smart_toy_outlined, color: color, size: size);
    }
    return SvgPicture.asset(
      icon.asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticsLabel: icon.label,
    );
  }
}

class _ProviderBrandIconAsset {
  const _ProviderBrandIconAsset({required this.asset, required this.label});

  final String asset;
  final String label;
}

_ProviderBrandIconAsset? _brandIconFor(
  String providerId,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  return switch (providerId) {
    'chatgpt' || 'openai' => _ProviderBrandIconAsset(
      asset: dark
          ? 'assets/provider-icons/openai-dark.svg'
          : 'assets/provider-icons/openai-light.svg',
      label: 'OpenAI',
    ),
    'gemini' => const _ProviderBrandIconAsset(
      asset: 'assets/provider-icons/gemini.svg',
      label: 'Gemini',
    ),
    'kimi' => _ProviderBrandIconAsset(
      asset: dark
          ? 'assets/provider-icons/kimi-dark.svg'
          : 'assets/provider-icons/kimi-light.svg',
      label: 'Kimi',
    ),
    'deepseek' => const _ProviderBrandIconAsset(
      asset: 'assets/provider-icons/deepseek.svg',
      label: 'DeepSeek',
    ),
    _ => null,
  };
}
