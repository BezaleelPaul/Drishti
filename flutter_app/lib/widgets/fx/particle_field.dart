import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Ambient particle field used behind the neon nav rail and as the splash
/// burst origin.
///
/// Deliberately package-free: a `CustomPainter` with a fixed particle budget
/// is cheaper and easier to keep on-palette than any animation asset. Particles
/// are generated once from a seed so a rebuild never reshuffles the field
/// (no flicker on `setState`).
class ParticleField extends StatefulWidget {
  const ParticleField({
    super.key,
    this.particleCount = 34,
    this.seed = 7,
    this.baseColor = const Color(0xFF7DF9FF),
    this.dimColor = const Color(0xFF00B4D8),
    this.opacity = 0.55,
    this.speed = 1.0,
    this.burst = 0.0,
    this.child,
  });

  /// Number of drifting particles. Keep small — this repaints every frame.
  final int particleCount;

  /// Deterministic seed so the field is stable across rebuilds.
  final int seed;

  final Color baseColor;
  final Color dimColor;

  /// Overall alpha multiplier for the whole field (0 = hidden).
  final double opacity;

  /// Drift speed multiplier. 0 freezes the field (useful in tests).
  final double speed;

  /// 0..1 radial burst factor. When > 0 particles fly outward from the
  /// center and fade — used for the splash logo "explode into the UI" beat.
  final double burst;

  final Widget? child;

  @override
  State<ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<ParticleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // Long duration; we only read `value` as a continuously advancing clock.
      duration: const Duration(days: 1),
    );
    if (widget.speed > 0) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(ParticleField old) {
    super.didUpdateWidget(old);
    if (widget.speed > 0 && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.speed <= 0 && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return IgnorePointer(
      child: CustomPaint(
        painter: _ParticlePainter(
          controller: _controller,
          particles: _Particle.generate(
            count: widget.particleCount,
            seed: widget.seed,
          ),
          baseColor: widget.baseColor,
          dimColor: widget.dimColor,
          opacity: widget.opacity,
          speed: widget.speed,
          burst: widget.burst,
          frozen: reduced || widget.speed <= 0,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Immutable description of one particle's motion, derived from a seed.
class _Particle {
  const _Particle({
    required this.angle,
    required this.radius,
    required this.size,
    required this.twinklePhase,
    required this.driftPhase,
    required this.isBright,
  });

  final double angle;
  final double radius;
  final double size;
  final double twinklePhase;
  final double driftPhase;
  final bool isBright;

  static List<_Particle> generate({required int count, required int seed}) {
    final rng = math.Random(seed);
    return List<_Particle>.generate(count, (i) {
      return _Particle(
        angle: rng.nextDouble() * math.pi * 2,
        radius: 0.18 + rng.nextDouble() * 0.82,
        size: 0.8 + rng.nextDouble() * 2.2,
        twinklePhase: rng.nextDouble() * math.pi * 2,
        driftPhase: rng.nextDouble() * math.pi * 2,
        isBright: rng.nextDouble() > 0.72,
      );
    });
  }
}

class _ParticlePainter extends CustomPainter {
  _ParticlePainter({
    required this.controller,
    required this.particles,
    required this.baseColor,
    required this.dimColor,
    required this.opacity,
    required this.speed,
    required this.burst,
    required this.frozen,
  }) : super(repaint: controller);

  final AnimationController controller;
  final List<_Particle> particles;
  final Color baseColor;
  final Color dimColor;
  final double opacity;
  final double speed;
  final double burst;
  final bool frozen;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final t = frozen ? 0.0 : controller.value * 2 * math.pi * speed;
    final center = Offset(size.width / 2, size.height / 2);
    final shortest = math.min(size.width, size.height);

    for (final p in particles) {
      // Slow orbital drift + a small radial wobble so particles never move
      // in lockstep.
      final drift = p.angle + t * 0.06;
      final wobble = math.sin(t * 0.5 + p.driftPhase) * 0.03;

      // Burst pushes particles outward from center and scales their travel.
      final burstPush = burst * 0.55;
      final r = (p.radius + wobble + burstPush).clamp(0.0, 1.6) * shortest / 2;

      final pos = center + Offset(math.cos(drift) * r, math.sin(drift) * r);

      // Twinkle: sine-driven alpha so particles breathe instead of strobing.
      final twinkle = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(t + p.twinklePhase));

      // During a burst particles fade out as they fly away.
      final burstFade = 1.0 - burst.clamp(0.0, 1.0);
      final alpha = (opacity * twinkle * burstFade).clamp(0.0, 1.0);
      if (alpha <= 0.01) continue;

      final color = Color.lerp(dimColor, baseColor, p.isBright ? 1.0 : 0.35)!;

      // Soft halo under each particle for the glow look.
      if (p.isBright) {
        final halo = Paint()
          ..color = color.withValues(alpha: alpha * 0.18)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
        canvas.drawCircle(pos, p.size * 3.2, halo);
      }

      final dot = Paint()..color = color.withValues(alpha: alpha);
      canvas.drawCircle(pos, p.size, dot);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter old) {
    return old.opacity != opacity ||
        old.baseColor != baseColor ||
        old.dimColor != dimColor ||
        old.burst != burst ||
        old.speed != speed ||
        old.particles.length != particles.length;
  }
}
