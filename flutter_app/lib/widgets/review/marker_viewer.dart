import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/retinal_markers.dart';
import '../scanner/scanner_theme.dart';
import 'lesion_marker_painter.dart';

/// Clinician-side zoom + wipe viewer for one review case.
///
/// Markers and image load independently through injected fetchers (the
/// review screen wires these to ApiService); a marker failure degrades to
/// an honest unavailable state over the real image — never a decorative
/// overlay (Req 5.3).
///
/// Analysis affordances for the doctor:
///   * every lesion candidate pulses with a leader arrow + honest label
///     ("Suspected microaneurysm #n (classical CV)") pointing at the exact
///     region that drove the result,
///   * the Compare button animates the before/after wipe over the same
///     image, so "what did the AI add" reads at a glance,
///   * pinch-zoom (up to 3.5x) plus a double-tap zoom toggle for analysing
///     a single lesion up close.
typedef MarkerFetcher = Future<RetinalMarkers> Function(String reviewId);
typedef ReviewImageFetcher = Future<Uint8List> Function(String reviewId);

class ClinicianMarkerViewer extends StatefulWidget {
  const ClinicianMarkerViewer({
    super.key,
    required this.reviewId,
    this.fetchMarkers,
    this.fetchImage,
  });

  final String reviewId;
  final MarkerFetcher? fetchMarkers;
  final ReviewImageFetcher? fetchImage;

  /// Req 3.3: pinch-zoom must reach at least 3.5x the fitted size.
  static const double maxZoom = 3.5;

  /// Double-tap toggle zoom level (bounded by [maxZoom]).
  static const double tapZoom = 2.4;

  /// The BoxFit.contain letterbox rect for a [srcW]x[srcH] source inside
  /// [viewport]. This is the real displayed-image rect in the zoom child's
  /// coordinate space and is handed to the painter as imageRect, so markers
  /// land on their anatomy (task 3.1's obligation to the viewer).
  static Rect fittedImageRect(Size viewport, double srcW, double srcH) {
    if (srcW <= 0 || srcH <= 0 || viewport.isEmpty) return Rect.zero;
    final scale = math.min(viewport.width / srcW, viewport.height / srcH);
    final width = srcW * scale;
    final height = srcH * scale;
    return Rect.fromLTWH(
      (viewport.width - width) / 2,
      (viewport.height - height) / 2,
      width,
      height,
    );
  }

  @override
  State<ClinicianMarkerViewer> createState() => _ClinicianMarkerViewerState();
}

enum _MarkerLoad { loading, available, unavailable }

enum _ImageLoad { loading, loaded, failed }

class _ClinicianMarkerViewerState extends State<ClinicianMarkerViewer>
    with TickerProviderStateMixin {
  _MarkerLoad _markerLoad = _MarkerLoad.loading;
  RetinalMarkers? _markers;
  String? _markerDetail;
  _ImageLoad _imageLoad = _ImageLoad.loading;
  Uint8List? _imageBytes;
  String? _imageDetail;

  /// Wipe default: fully marked view — the doctor sees markers without
  /// interaction; dragging left reveals the plain view (Req 4.1).
  double _wipeFraction = 1.0;

  /// Drives the expanding pulse rings around lesion candidates.
  AnimationController? _pulse;

  /// Drives the animated before/after compare sweep while playing.
  late final AnimationController _compare;

  /// Double-tap zoom: animated transform about the tapped image point.
  late final TransformationController _viewTransform;
  late final AnimationController _zoomAnim;
  Matrix4? _zoomFrom;
  Matrix4? _zoomTo;

  bool _comparePlaying = false;

  @override
  void initState() {
    super.initState();
    _compare = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _compare.addListener(() {
      if (!mounted) return;
      setState(() => _wipeFraction = _compare.value);
    });
    _viewTransform = TransformationController();
    _zoomAnim =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 240),
        )..addListener(() {
          final from = _zoomFrom;
          final to = _zoomTo;
          if (from == null || to == null) return;
          _viewTransform.value = Matrix4Tween(
            begin: from,
            end: to,
          ).transform(_zoomAnim.value);
        });
    _loadMarkers();
    _loadImage();
  }

  @override
  void dispose() {
    _pulse?.dispose();
    _compare.dispose();
    _zoomAnim.dispose();
    _viewTransform.dispose();
    super.dispose();
  }

  Future<void> _loadMarkers() async {
    final fetcher = widget.fetchMarkers;
    if (fetcher == null) {
      _setMarkersUnavailable('No marker source configured.');
      return;
    }
    try {
      final markers = await fetcher(widget.reviewId);
      if (!mounted) return;
      setState(() {
        _markers = markers;
        _markerLoad = markers.available
            ? _MarkerLoad.available
            : _MarkerLoad.unavailable;
        _markerDetail = markers.available
            ? null
            : (markers.reason ??
                  'Markers could not be computed for this case.');
        if (markers.available) {
          // Only the marked layer animates; miss rate stays zero before
          // any markers exist.
          _pulse ??= AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1800),
          )..repeat();
        }
      });
    } catch (error) {
      _setMarkersUnavailable('Marker load failed: $error');
    }
  }

  void _setMarkersUnavailable(String detail) {
    if (!mounted) return;
    setState(() {
      _markerLoad = _MarkerLoad.unavailable;
      _markerDetail = detail;
    });
  }

  Future<void> _loadImage() async {
    final fetcher = widget.fetchImage;
    if (fetcher == null) {
      _setImageFailed('No image source configured.');
      return;
    }
    try {
      final bytes = await fetcher(widget.reviewId);
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageLoad = _ImageLoad.loaded;
      });
    } catch (error) {
      _setImageFailed('$error');
    }
  }

  void _setImageFailed(String detail) {
    if (!mounted) return;
    setState(() {
      _imageLoad = _ImageLoad.failed;
      _imageDetail = detail;
    });
  }

  // ---- Compare (animated before/after wipe) --------------------------------

  void _toggleCompare() {
    if (_comparePlaying) {
      _compare.stop();
      setState(() => _comparePlaying = false);
      return;
    }
    if (_compare.isCompleted) _compare.value = 0.0;
    setState(() {
      _comparePlaying = true;
    });
    _compare.repeat(reverse: true);
  }

  void _onManualWipe(double value) {
    if (_comparePlaying) {
      _compare.stop();
      setState(() => _comparePlaying = false);
    }
    setState(() => _wipeFraction = value);
  }

  // ---- Double-tap zoom ------------------------------------------------------

  void _onDoubleTapDown(TapDownDetails details) {
    final current = _viewTransform.value;
    final scaleNow = current.getMaxScaleOnAxis();
    final Matrix4 target;
    if (scaleNow > 1.05) {
      target = Matrix4.identity();
    } else {
      final tap = details.localPosition;
      target = current.clone()
        ..translateByDouble(tap.dx, tap.dy, 0.0, 1.0)
        ..scaleByDouble(
          ClinicianMarkerViewer.tapZoom,
          ClinicianMarkerViewer.tapZoom,
          1.0,
          1.0,
        )
        ..translateByDouble(-tap.dx, -tap.dy, 0.0, 1.0);
    }
    _zoomFrom = current.clone();
    _zoomTo = target;
    _zoomAnim.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    if (_imageLoad == _ImageLoad.failed) {
      return _ImageErrorState(detail: _imageDetail);
    }
    return Column(
      children: [
        Expanded(child: _zoomableLayers()),
        if (_imageLoad == _ImageLoad.loaded) _statusFooter(),
      ],
    );
  }

  /// ONE InteractiveViewer carries BOTH layers, so zoom/pan stay identical
  /// by construction under the wipe (Req 4.2). The painter sits inside the
  /// transform, so strokeScale stays 1.0 (task 3.1 review note). The
  /// double-tap detector wraps the zoom CHILD (same coordinate space as the
  /// transform), so the tap point anchors the zoom exactly where the doctor
  /// tapped.
  Widget _zoomableLayers() {
    return InteractiveViewer(
      transformationController: _viewTransform,
      panEnabled: true,
      minScale: 1.0,
      maxScale: ClinicianMarkerViewer.maxZoom,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: () {},
        child: _imageLoad == _ImageLoad.loading
            ? const Center(
                child: CircularProgressIndicator(
                  color: ScannerHUDTheme.neonCyan,
                ),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final viewport = constraints.biggest;
                  final markers = _markers;
                  final markedReady =
                      _markerLoad == _MarkerLoad.available &&
                      markers != null &&
                      markers.width > 0 &&
                      markers.height > 0;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(
                        child: Image.memory(_imageBytes!, fit: BoxFit.contain),
                      ),
                      if (markedReady) _markedLayer(viewport, markers),
                    ],
                  );
                },
              ),
      ),
    );
  }

  /// Marked layer: same image bytes + marker painter, clipped to
  /// [_wipeFraction] of the viewport width (Req 4.1). The pulse only
  /// repaints the overlay CustomPaint — the base image never rebuilds.
  Widget _markedLayer(Size viewport, RetinalMarkers markers) {
    final imageRect = ClinicianMarkerViewer.fittedImageRect(
      viewport,
      markers.width.toDouble(),
      markers.height.toDouble(),
    );
    return ClipRect(
      clipper: WipeFractionClipper(_wipeFraction),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(_imageBytes!, fit: BoxFit.contain),
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pulse ?? const AlwaysStoppedAnimation(0.0),
              builder: (context, _) {
                return CustomPaint(
                  painter: LesionMarkerPainter(
                    markers: markers,
                    imageRect: imageRect,
                    scale: imageRect.width / markers.width,
                    pulse: _pulse?.value ?? 0.0,
                    showCallouts: true,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusFooter() {
    switch (_markerLoad) {
      case _MarkerLoad.loading:
        return const Padding(
          padding: EdgeInsets.all(12),
          child: Text('Loading markers…'),
        );
      case _MarkerLoad.unavailable:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Markers unavailable'),
              if (_markerDetail != null)
                Text(
                  _markerDetail!,
                  style: const TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        );
      case _MarkerLoad.available:
        final markers = _markers!;
        final candidateCount = markers.maCandidates.length;
        return Container(
          color: ScannerHUDTheme.darkSurface,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Tooltip(
                    message: _comparePlaying
                        ? 'Stop before/after compare'
                        : 'Play before/after compare',
                    child: IconButton(
                      onPressed: _toggleCompare,
                      icon: Icon(
                        _comparePlaying
                            ? Icons.stop_circle_outlined
                            : Icons.motion_photos_on,
                        color: ScannerHUDTheme.neonCyan,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _wipeFraction,
                      onChanged: _onManualWipe,
                      activeColor: ScannerHUDTheme.neonCyan,
                      inactiveColor: const Color(0xFF334155),
                    ),
                  ),
                ],
              ),
              Text(
                candidateCount == 0
                    ? 'No lesion candidates found — anatomical landmarks only.'
                    : '$candidateCount lesion candidate${candidateCount == 1 ? '' : 's'} · '
                          '${RetinalMarkers.classicalCvSource} · play to compare, '
                          'drag the slider to wipe, double-tap the image to zoom.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
            ],
          ),
        );
    }
  }
}

/// Clips the marked layer to the left [fraction] of the width: the
/// drag-to-reveal wipe (Req 4.1). Public so tests can read the live wipe
/// fraction through `getClip`.
class WipeFractionClipper extends CustomClipper<Rect> {
  const WipeFractionClipper(this.fraction);

  final double fraction;

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(
      0,
      0,
      size.width * fraction.clamp(0.0, 1.0),
      size.height,
    );
  }

  @override
  bool shouldReclip(WipeFractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
}

class _ImageErrorState extends StatelessWidget {
  const _ImageErrorState({this.detail});

  final String? detail;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Fundus image could not be loaded.'),
            if (detail != null)
              Text(
                detail!,
                style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}
