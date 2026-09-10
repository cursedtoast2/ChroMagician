import 'package:flutter/material.dart';

class AmbientGlow extends StatelessWidget {
  const AmbientGlow({super.key, required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: 800,
      height: 800,
      decoration: BoxDecoration(
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.23), color.withValues(alpha: 0)],
        ),
      ),
    ),
  );
}

class CartridgePainter extends CustomPainter {
  CartridgePainter({required this.connected});
  final bool connected;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 116, size.height / 125);
    final body = RRect.fromRectAndRadius(
      const Rect.fromLTWH(9, 4, 98, 115),
      const Radius.circular(9),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xffb8b1c6), Color(0xff797286)],
        ).createShader(body.outerRect),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(18, 30, 80, 62),
        const Radius.circular(4),
      ),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: connected
              ? [
                  const Color(0xffc5ed9b),
                  const Color(0xff829b64),
                  const Color(0xff574770),
                ]
              : [const Color(0xff4c5150), const Color(0xff353a39)],
        ).createShader(const Rect.fromLTWH(18, 30, 80, 62)),
    );
    final chip = Paint()..color = const Color(0x44111612);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(44, 45, 29, 29),
        const Radius.circular(3),
      ),
      chip,
    );
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(Rect.fromLTWH(38, 49 + i * 6.0, 6, 2), chip);
      canvas.drawRect(Rect.fromLTWH(73, 49 + i * 6.0, 6, 2), chip);
    }
    for (var i = 0; i < 3; i++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(25, 14 + i * 4.0, 66, 1.5),
          const Radius.circular(1),
        ),
        Paint()..color = const Color(0xff625e6d),
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(38, 103, 40, 4),
        const Radius.circular(2),
      ),
      Paint()..color = const Color(0xff635c70),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(CartridgePainter oldDelegate) =>
      connected != oldDelegate.connected;
}
