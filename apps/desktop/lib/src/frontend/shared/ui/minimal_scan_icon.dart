import 'package:flutter/material.dart';

class MinimalScanIcon extends StatelessWidget {
  const MinimalScanIcon({
    super.key,
    this.size = 21,
    this.color,
    this.strokeWidth = 1.8,
  });

  final double size;
  final Color? color;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MinimalScanIconPainter(
          color: color ?? iconTheme.color ?? Colors.black,
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _MinimalScanIconPainter extends CustomPainter {
  const _MinimalScanIconPainter({
    required this.color,
    required this.strokeWidth,
  });

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final inset = strokeWidth / 2 + size.shortestSide * 0.08;
    final left = inset;
    final top = inset;
    final right = size.width - inset;
    final bottom = size.height - inset;
    final corner = size.shortestSide * 0.28;

    final path = Path()
      ..moveTo(left, top + corner)
      ..lineTo(left, top)
      ..lineTo(left + corner, top)
      ..moveTo(right - corner, top)
      ..lineTo(right, top)
      ..lineTo(right, top + corner)
      ..moveTo(right, bottom - corner)
      ..lineTo(right, bottom)
      ..lineTo(right - corner, bottom)
      ..moveTo(left + corner, bottom)
      ..lineTo(left, bottom)
      ..lineTo(left, bottom - corner);
    canvas.drawPath(path, paint);

    final scanY = size.height * 0.53;
    canvas.drawLine(
      Offset(left + corner * 0.55, scanY),
      Offset(right - corner * 0.55, scanY),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _MinimalScanIconPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
