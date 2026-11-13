import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/retinal_markers.dart';
import '../../l10n/evidence_strings.dart';
import 'lesion_marker_painter.dart';

/// Full-screen, phone-first fundus inspector.
///
/// Gestures:
/// * pinch to zoom (1x–6x)
/// * drag to pan while zoomed
/// * double-tap to jump to 2.5x, double-tap again to reset
/// * +/- buttons and an explicit reset for one-handed use
/// * tap a lesion candidate to open its evidence sheet (schema_version 1.0
///   payloads only; legacy payloads keep the legacy read-only behaviour)
///
/// When [markers] is supplied (available payload), landmark arrows from
/// classical CV segmentation are drawn over the image and zoom/pan with it.
/// The image is never stretched or replaced; only the real capture is shown.
class ZoomableFundusScreen extends StatefulWidget {
  const ZoomableFundusScreen({
    super.key,
    required this.imageBytes,
    this.title = 'Fundus inspection',
    this.caption,
    this.markers,
  });

  final Uint8List imageBytes;
  final String title;
  final String? caption;
  final RetinalMarkers? markers;

  static const double maxZoom = 6.0;
  static const double doubleTapZoom = 2.5;

  @override
  State<ZoomableFundusScreen> createState() => _ZoomableFundusScreenState();
}

class _ZoomableFundusScreenState extends State<ZoomableFundusScreen>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomAnim;
  Matrix4? _zoomFrom;
  Matrix4? _zoomTo;
  Size _viewport = Size.zero;
  bool _markersVisible = true;

  // Evidence-linked interaction state (schema_version 1.0 payloads only).
  // Fitted image rect/scale cached by the inner LayoutBuilder so tap
  // hit-testing can map display coordinates back to source pixels even
  // while the InteractiveViewer transform is applied on top.
  Rect _imageRect = Rect.zero;
  double _imageScale = 1.0;
  String? _selectedLesionId;
  String? _highlightCriterionId;

  bool get _markersReady {
    final m = widget.markers;
    return m != null && m.available && m.width > 0 && m.height > 0;
  }

  @override
  void initState() {
    super.initState();
    _zoomAnim =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 220),
        )..addListener(() {
          final from = _zoomFrom;
          final to = _zoomTo;
          if (from == null || to == null) return;
          _transform.value = Matrix4Tween(
            begin: from,
            end: to,
          ).transform(_zoomAnim.value);
        });
  }

  @override
  void dispose() {
    _zoomAnim.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _animateTo(Matrix4 target) {
    _zoomFrom = _transform.value.clone();
    _zoomTo = target;
    unawaited(_zoomAnim.forward(from: 0.0));
  }

  Matrix4 _scaleAboutCentre(double target) {
    final centre = _viewport.center(Offset.zero);
    return Matrix4.identity()
      ..translateByDouble(centre.dx, centre.dy, 0.0, 1.0)
      ..scaleByDouble(target, target, 1.0, 1.0)
      ..translateByDouble(-centre.dx, -centre.dy, 0.0, 1.0);
  }

  void _setScale(double target) {
    final clamped = target.clamp(1.0, ZoomableFundusScreen.maxZoom).toDouble();
    if ((clamped - _transform.value.getMaxScaleOnAxis()).abs() < 0.01) return;
    _animateTo(
      clamped <= 1.0 ? Matrix4.identity() : _scaleAboutCentre(clamped),
    );
  }

  void _zoomBy(double factor) {
    _setScale(_transform.value.getMaxScaleOnAxis() * factor);
  }

  void _reset() {
    _animateTo(Matrix4.identity());
  }

  void _onDoubleTapDown(TapDownDetails details) {
    unawaited(HapticFeedback.selectionClick());
    final current = _transform.value;
    if (current.getMaxScaleOnAxis() > 1.05) {
      _animateTo(Matrix4.identity());
      return;
    }
    final tap = details.localPosition;
    _animateTo(
      current.clone()
        ..translateByDouble(tap.dx, tap.dy, 0.0, 1.0)
        ..scaleByDouble(
          ZoomableFundusScreen.doubleTapZoom,
          ZoomableFundusScreen.doubleTapZoom,
          1.0,
          1.0,
        )
        ..translateByDouble(-tap.dx, -tap.dy, 0.0, 1.0),
    );
  }

  /// Maps a tap (local widget position) to SOURCE-image pixel coordinates,
  /// accounting for the fitted-image letterbox. Because the GestureDetector
  /// is the child of the InteractiveViewer, details.localPosition is already
  /// in the child's local coordinate space (the transformation is already inverted
  /// by the framework). Returns null when markers/evidence are unavailable or the
  /// tap falls outside the displayed image.
  (double, double)? _tapToSource(Offset localPosition) {
    final m = widget.markers;
    if (m == null ||
        !m.available ||
        _imageRect == Rect.zero ||
        _imageScale <= 0) {
      return null;
    }
    if (!_imageRect.contains(localPosition)) return null;
    return (
      (localPosition.dx - _imageRect.left) / _imageScale,
      (localPosition.dy - _imageRect.top) / _imageScale,
    );
  }

  /// Nearest evidence item within a generous slop of the source tap point.
  String? _hitTestLesion(double sx, double sy) {
    final m = widget.markers!;
    String? bestId;
    double bestDist = double.infinity;
    for (final item in m.lesionEvidence) {
      if (item.detectionStatus != LesionEvidenceItem.statusDetected ||
          !item.geometryValid) {
        continue;
      }
      final dist = math.sqrt(
        math.pow(sx - item.x, 2) + math.pow(sy - item.y, 2),
      );
      final slop = math.max(item.radius + 10.0, 16.0);
      if (dist <= slop && dist < bestDist) {
        bestDist = dist;
        bestId = item.lesionId;
      }
    }
    return bestId;
  }

  void _onTapUp(TapUpDetails details) {
    final source = _tapToSource(details.localPosition);
    if (source == null) {
      if (_selectedLesionId != null) setState(() => _selectedLesionId = null);
      return;
    }
    final id = _hitTestLesion(source.$1, source.$2);
    setState(() {
      _selectedLesionId = (id == _selectedLesionId) ? null : id;
    });
    if (_selectedLesionId != null) unawaited(HapticFeedback.selectionClick());
  }

  Widget _canvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewport = constraints.biggest;
        return InteractiveViewer(
          key: const ValueKey('fundus-zoom-canvas'),
          transformationController: _transform,
          minScale: 1.0,
          maxScale: ZoomableFundusScreen.maxZoom,
          panEnabled: true,
          scaleEnabled: true,
          clipBehavior: Clip.hardEdge,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onDoubleTapDown: _onDoubleTapDown,
            onDoubleTap: () {},
            onTapUp: _markersReady && widget.markers!.hasEvidenceExtension
                ? _onTapUp
                : null,
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    widget.imageBytes,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => const Center(
                      child: Text(
                        'Image could not be displayed.',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
                  if (_markersVisible && _markersReady)
                    LayoutBuilder(
                      builder: (context, inner) {
                        final m = widget.markers!;
                        final iw = m.width.toDouble();
                        final ih = m.height.toDouble();
                        final scale = math.min(
                          inner.maxWidth / iw,
                          inner.maxHeight / ih,
                        );
                        final rect = Rect.fromCenter(
                          center: Offset(
                            inner.maxWidth / 2,
                            inner.maxHeight / 2,
                          ),
                          width: iw * scale,
                          height: ih * scale,
                        );
                        _imageRect = rect;
                        _imageScale = scale;
                        return IgnorePointer(
                          child: CustomPaint(
                            painter: LesionMarkerPainter(
                              markers: m,
                              imageRect: rect,
                              scale: scale,
                              showCallouts: true,
                              selectedLesionId: _selectedLesionId,
                              highlightCriterionId: _highlightCriterionId,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  LesionEvidenceItem? _selectedEvidence() {
    final id = _selectedLesionId;
    if (id == null) return null;
    for (final item in widget.markers!.lesionEvidence) {
      if (item.lesionId == id) return item;
    }
    return null;
  }

  Widget _evidenceDetailBar() {
    final item = _selectedEvidence();
    if (item == null) return const SizedBox.shrink();
    final typeLabel = switch (item.lesionType) {
      LesionEvidenceItem.typeMaCandidate => EvidenceStrings.t('candidate_ma'),
      LesionEvidenceItem.typeExudateCandidate => EvidenceStrings.t(
        'candidate_exudate',
      ),
      _ => EvidenceStrings.t('candidate_unknown'),
    };
    final m = widget.markers!;
    return Container(
      key: const ValueKey('fundus-evidence-detail'),
      color: const Color(0xFF0B1220),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$typeLabel  ·  ${item.lesionId}',
            style: const TextStyle(
              color: Color(0xFFFDE68C),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            EvidenceStrings.t('status_detected'),
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          if (item.evidenceNotes.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${EvidenceStrings.t('evidence_notes_label')}: ${item.evidenceNotes.first}',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
          if (m.criteriaEvaluation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final criterion in m.criteriaEvaluation)
                  if (criterion.supportingEvidenceIds.contains(item.lesionId))
                    ActionChip(
                      key: ValueKey(
                        'fundus-criterion-${criterion.criterionId}',
                      ),
                      avatar: Icon(
                        criterion.status == CriterionEvaluation.satisfied
                            ? Icons.check_circle
                            : Icons.help_outline,
                        size: 16,
                        color: criterion.status == CriterionEvaluation.satisfied
                            ? const Color(0xFF34D399)
                            : Colors.white54,
                      ),
                      label: Text(
                        EvidenceStrings.t(criterion.criterionId),
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                      onPressed: () => setState(() {
                        _highlightCriterionId =
                            (_highlightCriterionId == criterion.criterionId)
                            ? null
                            : criterion.criterionId;
                      }),
                    ),
              ],
            ),
          ],
          if (_highlightCriterionId != null) ...[
            const SizedBox(height: 4),
            Text(
              '${EvidenceStrings.t('criterion_show_markers')}: $_highlightCriterionId',
              style: const TextStyle(color: Color(0xFF67E8F9), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      color: const Color(0xFF0B1220),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                key: const ValueKey('fundus-zoom-out'),
                tooltip: 'Zoom out',
                onPressed: () => _zoomBy(1 / 1.4),
                icon: const Icon(Icons.remove_circle_outline),
                color: Colors.white70,
              ),
              ValueListenableBuilder<Matrix4>(
                valueListenable: _transform,
                builder: (context, matrix, _) {
                  final scale = matrix.getMaxScaleOnAxis().clamp(1.0, 6.0);
                  return SizedBox(
                    width: 54,
                    child: Text(
                      '${scale.toStringAsFixed(1)}×',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF67E8F9),
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  );
                },
              ),
              IconButton(
                key: const ValueKey('fundus-zoom-in'),
                tooltip: 'Zoom in',
                onPressed: () => _zoomBy(1.4),
                icon: const Icon(Icons.add_circle_outline),
                color: Colors.white70,
              ),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('fundus-zoom-reset'),
                onPressed: _reset,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Reset'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF67E8F9),
                ),
              ),
            ],
          ),
          Text(
            widget.caption ??
                'Pinch to zoom · drag to pan · double-tap to zoom or reset',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1220),
        foregroundColor: const Color(0xFF67E8F9),
        elevation: 0,
        title: Text(
          widget.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          if (_markersReady)
            IconButton(
              key: const ValueKey('fundus-markers-toggle'),
              tooltip: _markersVisible
                  ? 'Hide landmark markers'
                  : 'Show landmark markers',
              onPressed: () =>
                  setState(() => _markersVisible = !_markersVisible),
              icon: Icon(
                _markersVisible ? Icons.my_location : Icons.location_off,
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Semantics(
                label:
                    'Zoomable fundus image. Pinch, drag, or double-tap to '
                    'inspect.',
                child: _canvas(),
              ),
            ),
            _evidenceDetailBar(),
            _bottomBar(),
          ],
        ),
      ),
    );
  }
}
