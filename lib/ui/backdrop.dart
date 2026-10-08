import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The window background: a dark canvas with slow, drifting colour clouds
/// that turn from blue to green while connected.
///
/// The motion stops when [animate] is off or the platform asks for reduced
/// motion, and by itself whenever the window is hidden (no frames are
/// scheduled then), so it costs nothing in the tray.
class AnimatedBackdrop extends StatefulWidget {
  const AnimatedBackdrop({
    super.key,
    required this.child,
    required this.connected,
    this.animate = true,
  });

  final Widget child;
  final bool connected;
  final bool animate;

  @override
  State<AnimatedBackdrop> createState() => _AnimatedBackdropState();
}

class _AnimatedBackdropState extends State<AnimatedBackdrop>
    with SingleTickerProviderStateMixin {
  late final _drift =
      AnimationController(vsync: this, duration: const Duration(seconds: 48));

  bool get _moving =>
      widget.animate && !MediaQuery.disableAnimationsOf(context);

  void _sync() {
    if (_moving) {
      if (!_drift.isAnimating) _drift.repeat();
    } else {
      _drift.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AnimatedBackdrop old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = StatusColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: TweenAnimationBuilder<double>(
            // Cross-fades the palette when the connection state flips.
            tween: Tween(end: widget.connected ? 1.0 : 0.0),
            duration: Duration(milliseconds: _moving ? 1100 : 0),
            curve: Curves.easeInOut,
            builder: (context, mix, _) => CustomPaint(
              painter: _BackdropPainter(
                drift: _drift,
                mix: mix,
                base: status.backdrop,
                strength: dark ? 0.34 : 0.26,
                vignette: dark,
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Cloud {
  const _Cloud(this.x, this.y, this.radius, this.ax, this.ay, this.fx, this.fy,
      this.phase, this.idle, this.active);

  /// Resting centre and radius, as fractions of the canvas.
  final double x, y, radius;

  /// How far it wanders, and how fast (cycles per loop) on each axis.
  final double ax, ay, fx, fy, phase;
  final Color idle, active;
}

const _clouds = [
  _Cloud(0.18, 0.20, 0.62, 0.10, 0.08, 1, 2, 0.0, brandBlue, Color(0xFF10B981)),
  _Cloud(0.86, 0.26, 0.55, 0.09, 0.12, 2, 1, 1.7, brandViolet, Color(0xFF14B8A6)),
  _Cloud(0.70, 0.92, 0.66, 0.12, 0.07, 1, 3, 3.1, brandCyan, Color(0xFF22D3EE)),
  _Cloud(0.10, 0.88, 0.48, 0.07, 0.10, 3, 2, 4.4, Color(0xFF4F46E5), brandBlue),
];

class _BackdropPainter extends CustomPainter {
  _BackdropPainter({
    required this.drift,
    required this.mix,
    required this.base,
    required this.strength,
    required this.vignette,
  }) : super(repaint: drift);

  final Animation<double> drift;
  final double mix;
  final Color base;
  final double strength;
  final bool vignette;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = base);

    final t = drift.value * 2 * math.pi;
    final unit = math.max(size.width, size.height);
    for (final c in _clouds) {
      final centre = Offset(
        (c.x + c.ax * math.sin(t * c.fx + c.phase)) * size.width,
        (c.y + c.ay * math.cos(t * c.fy + c.phase)) * size.height,
      );
      final radius = c.radius * unit;
      final colour = Color.lerp(c.idle, c.active, mix)!;
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colour.withValues(alpha: strength),
              colour.withValues(alpha: strength * 0.35),
              colour.withValues(alpha: 0),
            ],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }

    if (vignette) {
      // Darkens the edges so content in the middle reads clearly.
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            radius: 0.95,
            colors: [Colors.transparent, base.withValues(alpha: 0.72)],
            stops: const [0.35, 1],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) =>
      old.mix != mix || old.base != base || old.strength != strength;
}
