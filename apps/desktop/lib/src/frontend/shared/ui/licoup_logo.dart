import 'package:flutter/material.dart';

class LicoUpLogo extends StatelessWidget {
  const LicoUpLogo({super.key, this.size = 24, this.opacity = 1});

  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: _LicoUpLogoPainter()),
      ),
    );
  }
}

class _LicoUpLogoPainter extends CustomPainter {
  const _LicoUpLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(size.width * 0.22)),
      Paint()..color = const Color(0xFF0A0A0A),
    );

    final gold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.033
      ..shader = const LinearGradient(
        colors: [Color(0xFFC8962E), Color(0xFFE8B840), Color(0xFFA07820)],
      ).createShader(rect);
    final cyan = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.023
      ..color = const Color(0x7A5ECFFF);

    canvas.drawPath(
      _polygonPath(size, const [
        Offset(32, 7),
        Offset(54, 19),
        Offset(54, 45),
        Offset(32, 57),
        Offset(10, 45),
        Offset(10, 19),
      ]),
      gold..color = const Color(0x90C8962E),
    );
    canvas.drawLine(_scale(size, 32, 13), _scale(size, 32, 51), cyan);
    canvas.drawLine(_scale(size, 15, 22), _scale(size, 49, 42), cyan);
    canvas.drawLine(_scale(size, 15, 42), _scale(size, 49, 22), cyan);

    final innerFill = Paint()
      ..style = PaintingStyle.fill
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x12FFFFFF), Color(0x00FFFFFF)],
      ).createShader(rect);
    final inner = _polygonPath(size, const [
      Offset(32, 20),
      Offset(43, 26),
      Offset(43, 38),
      Offset(32, 44),
      Offset(21, 38),
      Offset(21, 26),
    ]);
    canvas.drawPath(inner, innerFill);
    canvas.drawPath(inner, gold..strokeWidth = size.width * 0.046);

    final nodeGold = Paint()..color = const Color(0xBBC8962E);
    final nodeCyan = Paint()..color = const Color(0xAA5ECFFF);
    for (final point in const [
      Offset(43, 26),
      Offset(32, 44),
      Offset(21, 26),
    ]) {
      canvas.drawCircle(
        _scale(size, point.dx, point.dy),
        size.width * 0.025,
        nodeGold,
      );
    }
    for (final point in const [
      Offset(32, 20),
      Offset(43, 38),
      Offset(21, 38),
    ]) {
      canvas.drawCircle(
        _scale(size, point.dx, point.dy),
        size.width * 0.025,
        nodeCyan,
      );
    }
    canvas.drawCircle(
      _scale(size, 32, 32),
      size.width * 0.048,
      Paint()..shader = gold.shader,
    );
    canvas.drawCircle(
      _scale(size, 32, 32),
      size.width * 0.023,
      Paint()..color = const Color(0xCCFFFFFF),
    );
  }

  @override
  bool shouldRepaint(covariant _LicoUpLogoPainter oldDelegate) => false;

  static Path _polygonPath(Size size, List<Offset> points) {
    final path = Path()
      ..moveTo(
        _scale(size, points.first.dx, points.first.dy).dx,
        _scale(size, points.first.dx, points.first.dy).dy,
      );
    for (final point in points.skip(1)) {
      final scaled = _scale(size, point.dx, point.dy);
      path.lineTo(scaled.dx, scaled.dy);
    }
    return path..close();
  }

  static Offset _scale(Size size, double x, double y) {
    return Offset(size.width * x / 64, size.height * y / 64);
  }
}
