import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../widgets/fx/particle_field.dart';
import '../../widgets/scanner/scanner.dart';
import '../figma_dashboard_screen.dart';

/// Cinematic boot & optical-calibration splash.
///
/// Deliberately slow (~8s) so the launch feels like a device powering on
/// rather than an app flashing past. Phases:
///   1. Logo fades/scales in over a drifting particle field.
///   2. Wordmark + tagline reveal with a letter-spacing settle.
///   3. Optical calibration runs on the Flame scanner with staged telemetry.
///   4. Progress fills; the mark emits a particle burst into the dashboard.
///
/// A [SKIP] affordance and tap-to-skip remain for impatient operators, and
/// `MediaQuery.disableAnimationsOf` collapses everything to a static frame.
class FuturisticSplashScreen extends StatefulWidget {
  const FuturisticSplashScreen({super.key});

  @override
  State<FuturisticSplashScreen> createState() => _FuturisticSplashScreenState();
}

/// One line of the boot telemetry log. [at] is the fractional progress (0..1)
/// at which the line becomes the active status; the line stays visible after.
class _BootLine {
  const _BootLine(this.at, this.text);
  final double at;
  final String text;
}

class _FuturisticSplashScreenState extends State<FuturisticSplashScreen>
    with TickerProviderStateMixin {
  // Master progress drives both the visual reveal and the telemetry reveal.
  late final AnimationController _boot;
  late final AnimationController _burst;
  // Slow breathing clock for the brand mark — the same surface animates,
  // so the mark never reads as a static image pasted on an animation.
  late final AnimationController _pulse;

  bool _navigated = false;
  bool _burstStarted = false;

  // Total cinematic length. Held here so timings stay easy to tune.
  static const _bootDuration = Duration(milliseconds: 8200);
  static const _burstDuration = Duration(milliseconds: 900);

  static const _lines = <_BootLine>[
    _BootLine(0.00, 'BOOT: INITIALIZING OPTIC MATRIX'),
    _BootLine(0.14, 'ENCRYPTED SQLCIPHER VAULT: MOUNTED'),
    _BootLine(0.30, 'CALIBRATING MACULA & OPTIC DISC SENSORS'),
    _BootLine(0.48, 'RETINAL NERVE-FIBRE MAP: ALIGNED'),
    _BootLine(0.64, 'TFLITE INFERENCE ENGINE: ONLINE (fp32)'),
    _BootLine(0.80, 'OFFLINE-UP-LINK WINDOW: ARMED'),
    _BootLine(0.92, 'DIAGNOSTIC SYSTEM READY \u2022 ALL GATES GREEN'),
  ];

  bool _bootStarted = false;

  @override
  void initState() {
    super.initState();
    _boot = AnimationController(vsync: this, duration: _bootDuration)
      ..addListener(_onBootTick)
      ..addStatusListener(_onBootStatus);
    _burst = AnimationController(vsync: this, duration: _burstDuration);
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // MediaQuery must be read here, not in initState.
    if (_bootStarted) return;
    _bootStarted = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      // Reduced-motion: jump straight to the end state, then proceed.
      _boot.value = 1.0;
      _navigated = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _proceed());
      return;
    }
    _boot.forward();
    // The brand mark breathes on its own slow clock so the mark and the
    // scanner read as one animated surface.
    _pulse.repeat();
  }

  void _onBootTick() {
    // Fire the outgoing burst once, near the very end of the boot.
    if (!_burstStarted && _boot.value > 0.96) {
      _burstStarted = true;
      _burst.forward();
      // Give the burst a beat to read before swapping routes.
      Timer(const Duration(milliseconds: 520), _proceed);
    }
    if (mounted) setState(() {});
  }

  void _onBootStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && !_burstStarted) {
      _burstStarted = true;
      _burst.forward();
      Timer(const Duration(milliseconds: 520), _proceed);
    }
  }

  void _proceed() {
    if (_navigated || !mounted) return;
    _navigated = true;
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 700),
        pageBuilder: (context, anim, secondary) => const FigmaDashboardScreen(),
        transitionsBuilder: (context, anim, secondary, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _boot.dispose();
    _burst.dispose();
    _pulse.dispose();
    super.dispose();
  }

  // ---- Phase helpers -------------------------------------------------------

  double get _p => _boot.value;

  /// Eased 0..1 ramp for a sub-animation that should occupy [start]..[end]
  /// of the master timeline.
  double _phase(double start, double end, {Curve curve = Curves.easeOutCubic}) {
    final t = ((_p - start) / (end - start)).clamp(0.0, 1.0);
    return curve.transform(t);
  }

  ScannerAnimationState get _scannerState {
    if (_p < 0.18) return ScannerAnimationState.idle;
    if (_p < 0.42) return ScannerAnimationState.qualityCheck;
    if (_p < 0.72) return ScannerAnimationState.scanning;
    if (_p < 0.92) return ScannerAnimationState.analyzing;
    return ScannerAnimationState.resultReady;
  }

  int get _activeLine {
    for (var i = _lines.length - 1; i >= 0; i--) {
      if (_p >= _lines[i].at) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final logoIn = _phase(0.01, 0.12);
    final wordIn = _phase(0.02, 0.14);
    final logoScale = 0.72 + 0.28 * logoIn;

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _proceed,
        child: SafeArea(
          child: ParticleField(
            particleCount: 46,
            seed: 11,
            speed: reduced ? 0 : 0.7,
            opacity: 0.5 + 0.3 * _phase(0.0, 0.25),
            burst: _burst.value,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _header(),
                  const Spacer(),

                  // ---- Centerpiece: logo over the scanner calibration ----
                  _scannerStage(logoScale, logoIn, reduced),

                  const SizedBox(height: 22),
                  _wordmark(wordIn),
                  const Spacer(),

                  // ---- Live terminal boot log ----
                  _terminal(reduced),
                  const SizedBox(height: 14),
                  _skipHint(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final blink = (DateTime.now().millisecondsSinceEpoch ~/ 500).isEven;
    return Opacity(
      opacity: _phase(0.0, 0.12, curve: Curves.easeOut),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Shrink-to-fit: the monospace build string plus its letter-spacing
          // is wider than a 360 dp phone, and a fade still LAYOUT-overflows.
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: blink
                          ? ScannerHUDTheme.neonCyan
                          : ScannerHUDTheme.neonCyan.withValues(alpha: 0.3),
                      boxShadow: [
                        BoxShadow(
                          color: ScannerHUDTheme.neonCyan.withValues(
                            alpha: 0.6,
                          ),
                          blurRadius: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'DRISHTI // OS v1.2',
                    maxLines: 1,
                    softWrap: false,
                    style: ScannerHUDTheme.hudMonoStyle.copyWith(
                      fontSize: 11,
                      color: ScannerHUDTheme.neonCyan,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: _proceed,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 32),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'SKIP BOOT ▶',
              maxLines: 1,
              softWrap: false,
              style: ScannerHUDTheme.hudMonoStyle.copyWith(
                fontSize: 10,
                color: Colors.white54,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scannerStage(double logoScale, double logoIn, bool reduced) {
    return SizedBox(
      height: 268,
      width: 268,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Flame scanner calibration runs beneath the logo.
          //
          // Chrome-less mode: the console's status/telemetry bands are
          // omitted here — inside a 268 px stage they would leave a 72 px
          // canvas and put the telemetry text behind the brand mark. The
          // splash communicates progress through its own boot log instead.
          Opacity(
            opacity: _phase(0.16, 0.40) * 0.55,
            child: ConstrainedBox(
              constraints: const BoxConstraints.expand(),
              child: ScannerView(
                state: _scannerState,
                progress: _p,
                aspectRatio: 1.0,
                reduceMotion: reduced,
                showConsoleChrome: false,
              ),
            ),
          ),
          // The DRISHTI brand mark blooms over the calibration, breathing
          // with the same clock as the scanner so it reads as ONE composed
          // surface instead of a static image pasted on an animation.
          Opacity(
            opacity: logoIn,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final breath = reduced
                    ? 1.0
                    : 1.0 + 0.028 * math.sin(_pulse.value * 2 * math.pi);
                return Transform.scale(
                  scale: logoScale * breath,
                  child: Container(
                    width: 158,
                    height: 158,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: RadialGradient(
                        colors: [
                          ScannerHUDTheme.neonCyan.withValues(
                            alpha: reduced
                                ? 0.10
                                : 0.13 +
                                      0.07 *
                                          math.sin(_pulse.value * 2 * math.pi),
                          ),
                          Colors.transparent,
                        ],
                      ),
                    ),
                    // Mark-only asset (no navy tile): the artwork sits
                    // directly on the scanner canvas, so the eye reads as
                    // part of the same surface instead of a pasted image.
                    child: Image.asset(
                      'assets/branding/drishti_mark.png',
                      width: 152,
                      height: 152,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.high,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _wordmark(double wordIn) {
    return Opacity(
      opacity: wordIn,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/branding/drishti_logo_horizontal_no_tagline.png',
            height: 28,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(height: 10),
          Opacity(
            opacity: _phase(0.22, 0.42),
            child: Text(
              'EXPLAINABLE RETINAL SCREENING  ·  GOOD / BORDERLINE / REJECT',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.9),
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _terminal(bool reduced) {
    final progress = _p;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _p >= 1.0 ? 'SYS_STATUS: READY' : 'SYS_STATUS: CALIBRATING',
                style: ScannerHUDTheme.hudMonoStyle.copyWith(
                  fontSize: 9,
                  color: Colors.white38,
                ),
              ),
              Text(
                '${(progress * 100).toInt().toString().padLeft(2, '0')}%',
                style: ScannerHUDTheme.hudMonoStyle.copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: ScannerHUDTheme.neonCyan,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white10,
              valueColor: AlwaysStoppedAnimation<Color>(
                _p > 0.92 ? ScannerHUDTheme.success : ScannerHUDTheme.neonCyan,
              ),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 12),
          // Telemetry lines appear one by one; the latest is highlighted.
          for (var i = 0; i <= _activeLine; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Opacity(
                opacity: i == _activeLine ? 1.0 : 0.45,
                // FittedBox (not TextOverflow) — a fade still LAYOUT-overflows
                // a narrow phone; scaleDown keeps the whole boot line inside
                // a 360 dp screen.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    i == _activeLine && _p < 1.0
                        ? '${_lines[i].text} ▌'
                        : '${_lines[i].text}  ✓',
                    style: ScannerHUDTheme.hudMonoStyle.copyWith(
                      fontSize: 10,
                      color: i == _activeLine
                          ? (_p > 0.92
                                ? ScannerHUDTheme.success
                                : ScannerHUDTheme.neonCyan)
                          : Colors.white54,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _skipHint() {
    return Opacity(
      opacity: _phase(0.05, 0.2) * 0.9,
      child: Text(
        'TAP ANYWHERE TO SKIP',
        style: ScannerHUDTheme.hudMonoStyle.copyWith(
          fontSize: 9,
          color: Colors.white24,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}
