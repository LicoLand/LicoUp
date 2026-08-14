import 'package:flutter/material.dart';

class LicoUpLogo extends StatelessWidget {
  const LicoUpLogo({super.key, this.size = 24, this.opacity = 1});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/brand/lico-app-icon.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
      opacity: AlwaysStoppedAnimation(opacity),
    );
  }
}
