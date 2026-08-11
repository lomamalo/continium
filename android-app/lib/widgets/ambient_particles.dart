import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart';

/// Particules ambiantes discretes : petits points accent qui montent
/// lentement en vacillant (twinkle), en arriere-plan de l'app. Leur nombre
/// s'adapte a la surface de l'ecran et le flux s'arrete en mode
/// reduced-motion.
class AmbientParticles extends StatefulWidget {
  const AmbientParticles({super.key});

  @override
  State<AmbientParticles> createState() => _AmbientParticlesState();
}

class _AmbientParticlesState extends State<AmbientParticles>
    with SingleTickerProviderStateMixin {
  static const _cycle = Duration(seconds: 30);

  late final AnimationController _controller;
  List<_Drifter> _particles = const [];
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycle)..repeat();
    if (!MediaQuery.disableAnimationsOf(context)) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _ensureParticles(Size size) {
    if (size == _lastSize && _particles.isNotEmpty) return;
    _lastSize = size;
    final n = (size.width * size.height / 9000).clamp(12, 40).round();
    final rng = math.Random(7);
    _particles = List.generate(
      n,
      (_) => _Drifter(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        radius: 0.8 + rng.nextDouble() * 1.6,
        speed: 0.004 + rng.nextDouble() * 0.010,
        sway: 0.006 + rng.nextDouble() * 0.012,
        phase: rng.nextDouble() * math.pi * 2,
        baseAlpha: 0.10 + rng.nextDouble() * 0.22,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            _ensureParticles(size);
            return CustomPaint(
              painter: _AmbientPainter(
                particles: _particles,
                time: _controller.value * 30.0,
                size: size,
              ),
            );
          },
        );
      },
    );
  }
}

class _Drifter {
  final double x;
  final double y;
  final double radius;
  final double speed;
  final double sway;
  final double phase;
  final double baseAlpha;

  const _Drifter({
    required this.x,
    required this.y,
    required this.radius,
    required this.speed,
    required this.sway,
    required this.phase,
    required this.baseAlpha,
  });
}

class _AmbientPainter extends CustomPainter {
  final List<_Drifter> particles;
  final double time;
  final Size size;

  _AmbientPainter({
    required this.particles,
    required this.time,
    required this.size,
  });

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint();
    for (final p in particles) {
      final y = (p.y - time * p.speed) % 1.0;
      final x =
          (p.x + math.sin(time * 0.5 + p.phase) * p.sway + 1.0) % 1.0;
      final twinkle =
          0.55 + 0.45 * math.sin(time * 1.2 + p.phase * 3.0);
      paint.color = AppColors.accent.withValues(
        alpha: p.baseAlpha * twinkle,
      );
      canvas.drawCircle(
        Offset(x * s.width, y * s.height),
        p.radius,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter oldDelegate) =>
      oldDelegate.time != time || oldDelegate.size != size;
}
