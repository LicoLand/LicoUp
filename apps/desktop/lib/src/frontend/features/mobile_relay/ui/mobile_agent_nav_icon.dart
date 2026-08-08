import 'package:flutter/material.dart';

class MobileAgentNavIcon extends StatelessWidget {
  const MobileAgentNavIcon({super.key, required this.color, this.size = 28});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MobileAgentNavIconPainter(color)),
    );
  }
}

class _MobileAgentNavIconPainter extends CustomPainter {
  const _MobileAgentNavIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 1024;
    canvas
      ..save()
      ..scale(scale);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 64
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(92, 286, 840, 582),
        const Radius.circular(68),
      ),
      stroke,
    );
    canvas.drawCircle(const Offset(323.925, 576.512), 68.266, fill);
    canvas.drawCircle(const Offset(699.904, 576.512), 68.266, fill);
    canvas.drawLine(
      const Offset(283.306, 159.061),
      const Offset(740.693, 159.061),
      stroke,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MobileAgentNavIconPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
