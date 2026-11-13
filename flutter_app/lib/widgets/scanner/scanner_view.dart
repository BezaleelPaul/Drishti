import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_layout_grid/flutter_layout_grid.dart';

import '../glass/glass_console.dart';
import 'scanner_game.dart';
import 'scanner_state.dart';
import 'scanner_theme.dart';

/// Reusable Flame-driven Retinal Scanner Component.
///
/// Encapsulates the FlameGame lifecycle, decodes fundus imagery into GPU textures,
/// presents a clinical HUD overlay, and synchronizes with application state.
///
/// LAYOUT CONTRACT (rigid, no free-floating overlays)
/// =================================================
/// The console is a 3-track CSS-style grid, so no HUD element can ever
/// overlap the canvas or another HUD element, at any aspect ratio:
///
///   | status    | 56 px  | fixed — status pill + cancel affordance      |
///   | canvas    | 1fr    | the Flame game window (the only flexible track) |
///   | telemetry | 140 px | fixed — FOV / progress / provenance readouts   |
///
/// The HUD is NO LONGER painted over the canvas with `Positioned` children:
/// the canvas owns its own track, and the two console bands are glass
/// surfaces above/below it. This is what removes the previous overlap class
/// (HUD rows competing with the canvas for the same pixels) and guarantees
/// a fixed-height home for every text row.
class ScannerView extends StatefulWidget {
  final Uint8List? imageBytes;
  final ScannerAnimationState state;
  final double progress;
  final bool reduceMotion;
  final String? customStatusText;
  final VoidCallback? onCancel;
  final Widget? overlay;
  final double aspectRatio;
  final bool isInteractive;

  /// When false, only the canvas track is rendered (no status band, no
  /// telemetry band).
  ///
  /// Used by the splash screen, where the console chrome would sit UNDER the
  /// brand mark: a 56 px status band plus a 140 px telemetry band inside a
  /// 268 px stage leaves a 72 px canvas, and the telemetry text ends up
  /// behind the glowing logo (unreadable) while the logo circle and the
  /// calibration rings read as two competing circles. In chrome-less mode the
  /// scanner is a pure animation surface and the progress is communicated by
  /// the screen's own boot log.
  final bool showConsoleChrome;

  const ScannerView({
    super.key,
    this.imageBytes,
    this.state = ScannerAnimationState.idle,
    this.progress = 0.0,
    this.reduceMotion = false,
    this.customStatusText,
    this.onCancel,
    this.overlay,
    this.aspectRatio = 1.0,
    this.isInteractive = false,
    this.showConsoleChrome = true,
  });

  @override
  State<ScannerView> createState() => _ScannerViewState();
}

class _ScannerViewState extends State<ScannerView> with WidgetsBindingObserver {
  late final ScannerGame _game;
  ui.Image? _decodedImage;
  bool _isDecoding = false;
  Uint8List? _lastImageBytes;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _game = ScannerGame()
      ..animationState = widget.state
      ..progress = widget.progress
      ..reduceMotion = widget.reduceMotion;

    if (widget.imageBytes != null) {
      _decodeImage(widget.imageBytes!);
    }
  }

  @override
  void didUpdateWidget(ScannerView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.state != widget.state) {
      _game.animationState = widget.state;
    }
    if (oldWidget.progress != widget.progress) {
      _game.progress = widget.progress;
    }
    if (oldWidget.reduceMotion != widget.reduceMotion) {
      _game.reduceMotion = widget.reduceMotion;
    }

    if (widget.imageBytes != _lastImageBytes && widget.imageBytes != null) {
      _decodeImage(widget.imageBytes!);
    }
  }

  Future<void> _decodeImage(Uint8List bytes) async {
    if (_isDecoding) return;
    _isDecoding = true;
    _lastImageBytes = bytes;

    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      _decodedImage?.dispose();
      _decodedImage = frame.image;
      _game.fundusImage = _decodedImage;
    } catch (_) {
      // Keep aperture backdrop fallback if decode fails
    } finally {
      _isDecoding = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _game.resumeEngine();
    } else {
      _game.pauseEngine();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _game.pauseEngine();
    _decodedImage?.dispose();
    super.dispose();
  }

  /// Track 1 — fixed 56 px status band.
  Widget _statusBand(String statusText, Color stateColor) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: GlassConsolePanel(
        borderRadius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        // Reduced-motion / low-end devices drop the backdrop blur (a
        // BackdropFilter is a saveLayer) but keep the glass tint + border.
        blurEnabled: !widget.reduceMotion,
        accentColor: stateColor,
        accentOpacity: 0.42,
        // Opaque enough that no canvas pixel shows through the status text.
        baseOpacity: 0.78,
        child: Row(
          children: [
            GlassConsolePulse(color: stateColor),
            const SizedBox(width: 8),
            Expanded(
              child: GlassConsoleLabel(
                statusText.toUpperCase(),
                color: stateColor,
                fontSize: 10,
                maxLines: 1,
              ),
            ),
            if (widget.onCancel != null)
              GestureDetector(
                onTap: widget.onCancel,
                child: GlassConsoleLabel(
                  'CANCEL',
                  color: const Color(0xFFCBD5E1),
                  fontSize: 9,
                  letterSpacing: 0.5,
                  maxLines: 1,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Track 2 — the only flexible track: the Flame canvas window.
  ///
  /// RENDERING BOUNDARY: the game canvas is hard-clipped to its own track
  /// (`ClipRect`, hard edge). Flame draws particles/rings in canvas space and
  /// anything that escapes the track would otherwise paint over the console
  /// bands above and below it. The clip is structural — it holds at any
  /// screen size, aspect ratio or animation phase.
  Widget _canvasBand() {
    final stack = Stack(
      fit: StackFit.expand,
      children: [
        GameWidget<ScannerGame>(game: _game),
        if (widget.overlay != null) widget.overlay!,
        const _HUDCornerMarkers(),
      ],
    );
    final canvas = ClipRect(
      clipBehavior: Clip.hardEdge,
      child: ColoredBox(
        // Opaque canvas bed: the console bands never composite against
        // moving pixels, so their text stays crisp.
        color: ScannerHUDTheme.background,
        child: stack,
      ),
    );
    if (widget.isInteractive) {
      return ClipRect(
        clipBehavior: Clip.hardEdge,
        child: InteractiveViewer(
          minScale: 1.0,
          maxScale: 3.5,
          clipBehavior: Clip.hardEdge,
          child: canvas,
        ),
      );
    }
    return canvas;
  }

  /// Track 3 — fixed 140 px telemetry band.
  ///
  /// One information row + one provenance row. The progress percentage is a
  /// self-contained chip in the panel's top-right corner so it never competes
  /// with the scanner target or the telemetry text.
  Widget _telemetryBand(Color stateColor) {
    final progressLabel = widget.progress > 0
        ? '${(widget.progress * 100).toInt()}%'
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: GlassConsolePanel(
        borderRadius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        blurEnabled: !widget.reduceMotion,
        accentColor: stateColor,
        accentOpacity: 0.34,
        // Opaque enough that the canvas never shows through the text.
        baseOpacity: 0.78,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: GlassConsoleLabel(
                    'FOV: 45° | MACULA CENTERED',
                    color: const Color(0xFFCBD5E1),
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                    maxLines: 1,
                  ),
                ),
                if (progressLabel != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: stateColor.withValues(alpha: 0.55),
                        width: 1,
                      ),
                      color: stateColor.withValues(alpha: 0.10),
                    ),
                    child: GlassConsoleLabel(
                      progressLabel,
                      color: stateColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                      maxLines: 1,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            GlassConsoleLabel(
              'ORIGINAL CAPTURE • NO SYNTHETIC OVERLAY',
              color: const Color(0xFF64748B),
              fontSize: 8,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              maxLines: 1,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final statusText = widget.customStatusText ?? widget.state.displayName;
    final stateColor = widget.state.primaryColor;

    return Semantics(
      label: 'Animated retinal scanner in ${widget.state.name} mode',
      liveRegion: true,
      child: Container(
        decoration: BoxDecoration(
          color: ScannerHUDTheme.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: stateColor.withValues(alpha: 0.4),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: stateColor.withValues(alpha: 0.12),
              blurRadius: 18,
              spreadRadius: 2,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: widget.aspectRatio,
          // The console is a self-contained surface: the grid can never
          // paint outside its own box, so a track can never bleed over the
          // content below the scanner (the note text, the action button).
          child: ClipRect(
            clipBehavior: Clip.hardEdge,
            child: widget.showConsoleChrome
                ? LayoutGrid(
                    areas: 'status\ncanvas\ntelemetry',
                    columnSizes: [1.fr],
                    rowSizes: [56.px, 1.fr, 140.px],
                    children: [
                      _statusBand(statusText, stateColor).inGridArea('status'),
                      _canvasBand().inGridArea('canvas'),
                      _telemetryBand(stateColor).inGridArea('telemetry'),
                    ],
                  )
                // Chrome-less mode: one pure animation surface, no bands.
                : _canvasBand(),
          ),
        ),
      ),
    );
  }
}

/// HUD technical corner markers (drawn inside the canvas track only).
class _HUDCornerMarkers extends StatelessWidget {
  const _HUDCornerMarkers();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Stack(
          children: const [
            Align(
              alignment: Alignment.topLeft,
              child: _CornerBracket(turns: 0),
            ),
            Align(
              alignment: Alignment.topRight,
              child: _CornerBracket(turns: 1),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: _CornerBracket(turns: 2),
            ),
            Align(
              alignment: Alignment.bottomLeft,
              child: _CornerBracket(turns: 3),
            ),
          ],
        ),
      ),
    );
  }
}

class _CornerBracket extends StatelessWidget {
  final int turns;

  const _CornerBracket({required this.turns});

  @override
  Widget build(BuildContext context) {
    return RotatedBox(
      quarterTurns: turns,
      child: CustomPaint(size: const Size(12, 12), painter: _CornerPainter()),
    );
  }
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x667DF9FF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(0, 0)
      ..lineTo(size.width, 0);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
