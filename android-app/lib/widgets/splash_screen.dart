import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../main.dart';
import '../screens/home_screen.dart';

/// Splash screen cinetique : des particules convergent des bords de l'ecran
/// vers les pixels du logo (echantillonnes depuis assets/continium.png), le
/// titre CONTINIUM se deplie, la forme reste fige 2 s, puis tout s'estompe
/// vers l'accueil. Miroir Flutter du loader du site (docs/loader.js).
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  static const _convergeEnd = Duration(milliseconds: 1300);
  static const _holdEnd = Duration(milliseconds: 3300);
  static const _total = Duration(milliseconds: 4200);

  late final AnimationController _controller;
  List<Offset> _targets = const [];
  double _imageW = 1;
  double _imageH = 1;
  List<ui.Image> _sprites = const [];
  bool _reducedMotion = false;
  bool _goHomeFired = false;

  @override
  void initState() {
    super.initState();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _controller = AnimationController(vsync: this, duration: _total);
    if (_reducedMotion) {
      _controller.duration = const Duration(milliseconds: 900);
      _controller.forward().then((_) => _goHome());
    } else {
      _loadLogo();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final s in _sprites) {
      s.dispose();
    }
    super.dispose();
  }

  /// Echantillonne les pixels lumineux du logo comme cibles des particules,
  /// et pre-rend des sprites de lueur accent a plusieurs intensites.
  Future<void> _loadLogo() async {
    try {
      final data = await rootBundle.load('assets/continium.png');
      final codec = await ui.instantiateImageCodec(
        data.buffer.asUint8List(),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final bytes = byteData!.buffer.asUint8List();
      final w = image.width;
      final h = image.height;

      final pts = <Offset>[];
      const step = 2;
      for (var y = 0; y < h; y += step) {
        for (var x = 0; x < w; x += step) {
          final i = (y * w + x) * 4;
          final a = bytes[i + 3] / 255.0;
          if (a < 0.15) continue;
          final lum =
              (0.2126 * bytes[i] +
                  0.7152 * bytes[i + 1] +
                  0.0722 * bytes[i + 2]) /
              255.0;
          if (a * lum > 0.28) pts.add(Offset(x.toDouble(), y.toDouble()));
        }
      }
      image.dispose();
      if (!mounted) return;

      if (pts.isNotEmpty) {
        const maxPts = 420;
        if (pts.length > maxPts) {
          final out = <Offset>[];
          for (var i = 0; i < maxPts; i++) {
            out.add(pts[(i * pts.length) ~/ maxPts]);
          }
          pts.clear();
          pts.addAll(out);
        }
        setState(() {
          _targets = List.unmodifiable(pts);
          _imageW = w.toDouble();
          _imageH = h.toDouble();
        });
      }
    } catch (_) {
      // Le logo seul suffit en secours.
    }
    if (!mounted) return;
    final sprites = await _makeGlowSprites();
    if (!mounted) return;
    setState(() => _sprites = sprites);
    _controller.forward().then((_) => _goHome());
  }

  Future<List<ui.Image>> _makeGlowSprites() async {
    const strengths = [0.20, 0.45, 0.75, 1.0];
    final out = <ui.Image>[];
    for (final s in strengths) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const size = 64.0;
      const rect = Rect.fromLTWH(0, 0, size, size);
      const accent = AppColors.accent;
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          rect.center,
          size / 2,
          [
            accent.withValues(alpha: 1.0 * s),
            accent.withValues(alpha: 0.45 * s),
            accent.withValues(alpha: 0.0),
          ],
          const [0.0, 0.45, 1.0],
        );
      canvas.drawRect(rect, paint);
      out.add(await recorder.endRecording().toImage(size.round(), size.round()));
    }
    return out;
  }

  void _goHome() {
    if (_goHomeFired || !mounted) return;
    _goHomeFired = true;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => const HomeScreen(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
      ),
    );
  }

  Rect _logoBox(Size size) {
    final w = size.width;
    final h = size.height;
    final box = math.min(math.min(w * 0.42, h * 0.24), 230.0);
    return Rect.fromCenter(
      center: Offset(w / 2, h * 0.36),
      width: box,
      height: box * (_imageH / _imageW),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final box = _logoBox(size);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          final fadeStart = _holdEnd.inMilliseconds / _total.inMilliseconds;
          final fade =
              1.0 - ((t - fadeStart) / (1.0 - fadeStart)).clamp(0.0, 1.0);

          return Opacity(
            opacity: fade,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _SplashPainter(
                      targets: _targets,
                      imageW: _imageW,
                      imageH: _imageH,
                      t: t,
                      sprites: _sprites,
                      convergeEnd:
                          _convergeEnd.inMilliseconds /
                          _total.inMilliseconds,
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: box.width,
                        height: box.height,
                        child: _targets.isEmpty
                            ? Image.asset(
                                'assets/continium.png',
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) =>
                                    const Icon(
                                      Icons.hub_outlined,
                                      color: AppColors.accent,
                                      size: 72,
                                    ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 26),
                      _SplashTitle(t: t),
                    ],
                  ),
                ),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 28,
                  child: Opacity(
                    opacity: 0.55,
                    child: Text(
                      'par Malo Lemoine · 2026',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Titre CONTINIUM qui se deplie (opacite + interlignage) pendant la
/// convergence, comme sur le site.
class _SplashTitle extends StatelessWidget {
  final double t;
  const _SplashTitle({required this.t});

  @override
  Widget build(BuildContext context) {
    final title = ((t - 0.15) / 0.35).clamp(0.0, 1.0);
    final subtitle = ((t - 0.45) / 0.3).clamp(0.0, 1.0);
    final spacing = 4.0 + (1.0 - title) * 10.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: title,
          child: Text(
            'CONTINIUM',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: spacing,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Opacity(
          opacity: subtitle,
          child: const Text(
            'Continuite PC <-> telephone',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
              letterSpacing: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}

/// Particules convergentes (easeOutCubic, decalage par particule), puis
/// respiration autour des cibles pendant la phase figee. Le sprite est
/// choisi parmi 4 intensites de lueur pour moduler l'alpha sans changer de
/// paint (perf).
class _SplashPainter extends CustomPainter {
  final List<Offset> targets;
  final double imageW;
  final double imageH;
  final double t;
  final List<ui.Image> sprites;
  final double convergeEnd;

  _SplashPainter({
    required this.targets,
    required this.imageW,
    required this.imageH,
    required this.t,
    required this.sprites,
    required this.convergeEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (targets.isEmpty || sprites.isEmpty) return;
    final rng = math.Random(42);
    final w = size.width;
    final h = size.height;

    final boxW = math.min(math.min(w * 0.42, h * 0.24), 230.0);
    final boxH = boxW * (imageH / imageW);
    final boxCenter = Offset(w / 2, h * 0.36);
    final boxTopLeft = boxCenter - Offset(boxW / 2, boxH / 2);

    final paint = Paint();
    final corePaint = Paint();
    final n = targets.length;
    final now = t * 4.2;
    for (var i = 0; i < n; i++) {
      final target = targets[rng.nextInt(targets.length)];
      final targetPos = Offset(
        boxTopLeft.dx + (target.dx / imageW) * boxW,
        boxTopLeft.dy + (target.dy / imageH) * boxH,
      );

      final delay = rng.nextDouble() * 0.45;
      final p = ((t - delay) / convergeEnd).clamp(0.0, 1.0);
      final ease = 1.0 - math.pow(1.0 - p, 3.0).toDouble();

      Offset pos;
      double alpha;
      if (ease < 1.0) {
        final edge = _edgePoint(rng, w, h);
        pos = Offset.lerp(edge, targetPos, ease)!;
        alpha = ease;
      } else {
        final amp = 0.6 + rng.nextDouble() * 1.6;
        final phase = rng.nextDouble() * math.pi * 2;
        final breathe = math.sin(now * 1.4 * math.pi * 2 + phase) * amp;
        pos = targetPos.translate(breathe, breathe * 0.6);
        alpha = 0.95;
      }

      if (alpha < 0.03) continue;
      final spriteIdx = (alpha * (sprites.length - 1)).round().clamp(
        0,
        sprites.length - 1,
      );
      final sprite = sprites[spriteIdx];
      final r = 2.2 + rng.nextDouble() * 3.0;
      final dst = Rect.fromCenter(
        center: pos,
        width: r * 2.4,
        height: r * 2.4,
      );
      canvas.drawImageRect(
        sprite,
        Rect.fromLTWH(0, 0, sprite.width.toDouble(), sprite.height.toDouble()),
        dst,
        paint,
      );
      corePaint.color = AppColors.accent.withValues(alpha: alpha);
      canvas.drawCircle(pos, r * 0.55, corePaint);
    }
  }

  static Offset _edgePoint(math.Random rng, double w, double h) {
    final side = rng.nextInt(4);
    switch (side) {
      case 0:
        return Offset(rng.nextDouble() * w, 0);
      case 1:
        return Offset(rng.nextDouble() * w, h);
      case 2:
        return Offset(0, rng.nextDouble() * h);
      default:
        return Offset(w, rng.nextDouble() * h);
    }
  }

  @override
  bool shouldRepaint(covariant _SplashPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.targets.length != targets.length ||
      oldDelegate.sprites != sprites;
}
