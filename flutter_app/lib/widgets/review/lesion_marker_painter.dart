import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/retinal_markers.dart';
import '../scanner/scanner_theme.dart';

/// Paints retinal markers over the displayed fundus image.
///
/// Visual grammar: optic disc -> circle outline, fovea -> crosshair, each
/// microaneurysm candidate -> small ring with a soft "found here" pulse and
/// (when callouts are on) a leader arrow + honest text label. Markers come
/// only from the supplied [RetinalMarkers] (source pixel space) and are
/// mapped into [imageRect], the actual displayed-image rect; any marker
/// whose mapped centre falls outside that rect is skipped, so nothing is
/// ever drawn beyond the image bounds.
///
/// Callout copy states what the marker IS — a lesion candidate located by
/// classical CV segmentation — never a diagnosis (provenance rule).
class LesionMarkerPainter extends CustomPainter {
  const LesionMarkerPainter({
    required this.markers,
    required this.imageRect,
    required this.scale,
    this.strokeScale = 1.0,
    this.pulse = 0.0,
    this.showCallouts = false,
    this.selectedLesionId,
    this.highlightCriterionId,
  });

  static const double _baseStrokeWidth = 2.0;
  static const double _candidateStrokeWidth = 1.6;
  static const double _minCandidateDisplayRadius = 3.0;
  static const double _foveaArmLength = 8.0;

  /// Pulse animation phase (0..1): drives the expanding "found area" ring
  /// so a static screenshot is identical to the legacy rendering.
  final double pulse;

  /// Whether callout arrows + labels are drawn (on by the live viewer).
  final bool showCallouts;

  /// Evidence-linked extension: the currently selected lesion id. When set,
  /// that marker is emphasized and all other candidates are dimmed.
  final String? selectedLesionId;

  /// When set (a criterion id from the versioned policy), markers whose
  /// criterion links include it are emphasized — criterion→marker highlight.
  final String? highlightCriterionId;

  /// At most this many lesion callouts are labelled; dense candidate sets
  /// would otherwise soup the image with arrows.
  static const int _maxCallouts = 4;

  final RetinalMarkers markers;

  /// Destination rect of the displayed image, in the painter's coordinate
  /// space; the viewer is responsible for handing the real fitted rect.
  final Rect imageRect;

  /// Displayed size / source size; scales marker geometry.
  final double scale;

  final double strokeScale;

  static Offset mapToDisplay(Offset source, Rect imageRect, double scale) {
    return Offset(
      imageRect.left + source.dx * scale,
      imageRect.top + source.dy * scale,
    );
  }

  static List<MarkerToDraw> drawableMarkers(
    RetinalMarkers markers,
    Rect imageRect,
    double scale, {
    String? selectedLesionId,
    String? highlightCriterionId,
  }) {
    if (!markers.available) return const [];
    if (scale.isNaN || scale.isInfinite || scale <= 0) return const [];

    final out = <MarkerToDraw>[];

    final disc = markers.opticDisc;
    if (disc != null) {
      final position = mapToDisplay(
        Offset(disc.x.toDouble(), disc.y.toDouble()),
        imageRect,
        scale,
      );
      if (_isRenderable(position, imageRect)) {
        out.add(
          MarkerToDraw(
            kind: MarkerKind.opticDisc,
            position: position,
            radius: disc.r * scale,
          ),
        );
      }
    }

    final fovea = markers.fovea;
    if (fovea != null) {
      final position = mapToDisplay(
        Offset(fovea.x.toDouble(), fovea.y.toDouble()),
        imageRect,
        scale,
      );
      if (_isRenderable(position, imageRect)) {
        out.add(
          MarkerToDraw(
            kind: MarkerKind.fovea,
            position: position,
            radius: _foveaArmLength,
          ),
        );
      }
    }

    // Evidence-linked rendering: when the payload carries typed evidence
    // items, they are the render source (stable ids + types + criterion
    // links). Legacy payloads fall back to the maCandidates coordinate list.
    final evidence = markers.lesionEvidence
        .where(
          (e) =>
              e.statusKnown &&
              e.typeKnown &&
              e.detectionStatus == LesionEvidenceItem.statusDetected &&
              e.geometryValid,
        )
        .toList(growable: false);
    if (evidence.isNotEmpty) {
      for (final item in evidence) {
        final position = mapToDisplay(
          Offset(item.x.toDouble(), item.y.toDouble()),
          imageRect,
          scale,
        );
        if (_isRenderable(position, imageRect)) {
          out.add(
            MarkerToDraw(
              kind: item.lesionType == LesionEvidenceItem.typeExudateCandidate
                  ? MarkerKind.exudateCandidate
                  : MarkerKind.candidate,
              position: position,
              radius: math.max(item.radius * scale, _minCandidateDisplayRadius),
              lesionId: item.lesionId,
              lesionType: item.lesionType,
              selected:
                  selectedLesionId != null && selectedLesionId == item.lesionId,
              dimmed:
                  selectedLesionId != null && selectedLesionId != item.lesionId,
              criterionHighlighted:
                  highlightCriterionId != null &&
                  item.criterionLinks.contains(highlightCriterionId),
            ),
          );
        }
      }
      return out;
    }

    // v1 payloads NEVER fall back to the legacy coordinate list: the evidence
    // items are the same detections (legacy list is a compat mirror), so
    // falling back would double-draw. All-invalid v1 evidence renders nothing.
    if (!markers.hasEvidenceExtension) {
      for (final candidate in markers.maCandidates) {
        final position = mapToDisplay(
          Offset(candidate.x.toDouble(), candidate.y.toDouble()),
          imageRect,
          scale,
        );
        if (_isRenderable(position, imageRect)) {
          out.add(
            MarkerToDraw(
              kind: MarkerKind.candidate,
              position: position,
              radius: math.max(candidate.r * scale, _minCandidateDisplayRadius),
            ),
          );
        }
      }
    }

    return out;
  }

  static bool _isRenderable(Offset position, Rect imageRect) {
    if (!position.dx.isFinite || !position.dy.isFinite) return false;
    return position.dx >= imageRect.left &&
        position.dx <= imageRect.right &&
        position.dy >= imageRect.top &&
        position.dy <= imageRect.bottom;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(imageRect);
    for (final marker in drawableMarkers(
      markers,
      imageRect,
      scale,
      selectedLesionId: selectedLesionId,
      highlightCriterionId: highlightCriterionId,
    )) {
      switch (marker.kind) {
        case MarkerKind.opticDisc:
          canvas.drawCircle(
            marker.position,
            marker.radius,
            _strokePaint(ScannerHUDTheme.neonCyan, _baseStrokeWidth),
          );
        case MarkerKind.fovea:
          final arm = marker.radius;
          final paint = _strokePaint(Colors.white, _baseStrokeWidth)
            ..strokeCap = StrokeCap.round;
          canvas.drawLine(
            Offset(marker.position.dx - arm, marker.position.dy),
            Offset(marker.position.dx + arm, marker.position.dy),
            paint,
          );
          canvas.drawLine(
            Offset(marker.position.dx, marker.position.dy - arm),
            Offset(marker.position.dx, marker.position.dy + arm),
            paint,
          );
        case MarkerKind.candidate:
          // "AI found something here" affordance: soft halo fill + crisp
          // ring, then an expanding pulse ring locked to [pulse].
          final halo = Paint()
            ..color = _soften(
              ScannerHUDTheme.warning,
              marker.dimmed ? 0.06 : 0.12,
            );
          canvas.drawCircle(marker.position, marker.radius + 2.0, halo);
          canvas.drawCircle(
            marker.position,
            marker.radius,
            _strokePaint(
              marker.dimmed
                  ? _soften(ScannerHUDTheme.warning, 0.30)
                  : ScannerHUDTheme.warning,
              marker.selected ? _baseStrokeWidth : _candidateStrokeWidth,
            ),
          );
          if (marker.criterionHighlighted) {
            canvas.drawCircle(
              marker.position,
              marker.radius + 5.0,
              _strokePaint(ScannerHUDTheme.neonCyan, 2.2),
            );
          }
          if (pulse > 0.0 && pulse < 1.0 && !marker.dimmed) {
            final alpha = (1.0 - pulse) * 0.55;
            canvas.drawCircle(
              marker.position,
              marker.radius + 4.0 + 12.0 * pulse,
              _strokePaint(ScannerHUDTheme.warning, 1.4)
                ..color = _soften(ScannerHUDTheme.warning, alpha),
            );
          }
        case MarkerKind.exudateCandidate:
          // Exudate candidates: yellow ring (bright-lesion colour), same
          // honest affordance semantics as MA candidates.
          canvas.drawCircle(
            marker.position,
            marker.radius,
            _strokePaint(
              const Color(0xFFFACC15),
              marker.selected ? _baseStrokeWidth : _candidateStrokeWidth,
            ),
          );
          if (marker.criterionHighlighted) {
            canvas.drawCircle(
              marker.position,
              marker.radius + 5.0,
              _strokePaint(ScannerHUDTheme.neonCyan, 2.2),
            );
          }
          if (marker.dimmed) {
            canvas.drawCircle(
              marker.position,
              marker.radius,
              Paint()..color = _soften(const Color(0xFF0F172A), 0.25),
            );
          }
      }
    }

    if (showCallouts) _paintCallouts(canvas);
    canvas.restore();
  }

  /// Leader arrows + honest text labels for the first [_maxCallouts]
  /// rendered candidates, plus one-line anatomical captions. Pills are
  /// placed collision-aware: every placed pill is tracked, each new callout
  /// tries slots (preferred side near → far, other side, vertical stacks)
  /// until it finds one that fits inside [imageRect] without overlapping.
  void _paintCallouts(Canvas canvas) {
    final placed = <Rect>[];

    // Anatomical captions claim space first so candidate pills route
    // around them instead of overprinting them.
    final allMarkers = drawableMarkers(
      markers,
      imageRect,
      scale,
      selectedLesionId: selectedLesionId,
      highlightCriterionId: highlightCriterionId,
    );
    for (final marker in allMarkers) {
      if (marker.kind == MarkerKind.opticDisc) {
        placed.add(
          _drawLabel(
            canvas,
            marker.position.translate(8, marker.radius + 10),
            'Optic disc',
          ),
        );
      } else if (marker.kind == MarkerKind.fovea) {
        placed.add(
          _drawLabel(canvas, marker.position.translate(8, 14), 'Fovea'),
        );
      }
    }

    final candidates =
        allMarkers
            .where(
              (m) =>
                  m.kind == MarkerKind.candidate ||
                  m.kind == MarkerKind.exudateCandidate,
            )
            .toList()
          ..sort((a, b) => a.position.dy.compareTo(b.position.dy));

    var index = 0;
    for (final marker in candidates) {
      if (index >= _maxCallouts) break;
      final ok = _drawCallout(
        canvas: canvas,
        target: marker.position,
        radius: marker.radius,
        text: marker.lesionType == LesionEvidenceItem.typeExudateCandidate
            ? 'Suspected exudate #${index + 1} (classical CV)'
            : 'Suspected microaneurysm #${index + 1} (classical CV)',
        placed: placed,
      );
      // Numbering only advances when the label actually landed, so the
      // visible callouts stay sequential (1, 2, 3…) even when some are
      // skipped for space.
      if (ok) index++;
    }
  }

  /// Arrow + label for one candidate. Tries placement slots in order —
  /// the side with more free space first, near gap then far gap, mirrored
  /// side, then vertical stack offsets — and draws the first placement
  /// that fits inside [imageRect] without colliding with [placed].
  /// Returns false when no slot fits.
  bool _drawCallout({
    required Canvas canvas,
    required Offset target,
    required double radius,
    required String text,
    required List<Rect> placed,
  }) {
    final textSize = _measure(text);
    final pillSize = textSize + const Offset(12, 8);
    if (pillSize.width > imageRect.width - 4) return false;

    final preferRight = target.dx >= imageRect.center.dx;
    for (final side in preferRight ? [1, -1] : [-1, 1]) {
      for (final dySign in [-1.0, 1.0]) {
        for (final gap in const [26.0, 46.0]) {
          final anchor = target + Offset(side * gap, dySign * gap * 0.4);
          final pill = Rect.fromLTWH(
            side < 0 ? anchor.dx - pillSize.width : anchor.dx,
            anchor.dy - pillSize.height / 2,
            pillSize.width,
            pillSize.height,
          );
          final fitted = _clampInside(pill);
          if (fitted == null) continue;
          // Stack nudges: same slot shifted up/down so dense candidate
          // clusters fan out instead of stacking into one blob.
          for (final dy in [
            0.0,
            -(pillSize.height + 6),
            pillSize.height + 6,
            -2 * (pillSize.height + 6),
            2 * (pillSize.height + 6),
          ]) {
            final candidate = _clampInside(fitted.shift(Offset(0, dy)));
            if (candidate == null) continue;
            if (_collides(candidate, placed)) continue;
            if (_paintPlacedCallout(canvas, candidate, target, radius, text)) {
              placed.add(candidate);
              return true;
            }
          }
        }
      }
    }
    return false;
  }

  /// Draws the leader + arrowhead + label pill for an already-placed pill
  /// rect. Returns false when the leader cannot reach the target ring.
  bool _paintPlacedCallout(
    Canvas canvas,
    Rect pillRect,
    Offset target,
    double radius,
    String text,
  ) {
    // Leader from the pill edge nearest the target toward the ring,
    // stopping at radius + 4 so the arrowhead does not cover the ring.
    final pillAttach = Offset(
      pillRect.left < target.dx ? pillRect.right : pillRect.left,
      pillRect.center.dy,
    );
    final span = target - pillAttach;
    final spanLength = span.distance;
    if (spanLength < radius + 6) return false;
    final stop = pillAttach + span * ((spanLength - radius - 4) / spanLength);
    final leader = _strokePaint(_soften(ScannerHUDTheme.warning, 0.9), 1.3)
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(pillAttach, stop, leader);

    // Arrowhead at [stop], oriented along the leader.
    final angle = math.atan2(span.dy, span.dx);
    const headLength = 7.0;
    final head = Path()
      ..moveTo(stop.dx, stop.dy)
      ..lineTo(
        stop.dx - headLength * math.cos(angle - 0.45),
        stop.dy - headLength * math.sin(angle - 0.45),
      )
      ..lineTo(
        stop.dx - headLength * math.cos(angle + 0.45),
        stop.dy - headLength * math.sin(angle + 0.45),
      )
      ..close();
    canvas.drawPath(
      head,
      Paint()..color = _soften(ScannerHUDTheme.warning, 0.95),
    );

    _drawLabelAt(canvas, pillRect, text);
    return true;
  }

  /// Clamps [pill] fully inside [imageRect]; null when it cannot fit.
  Rect? _clampInside(Rect pill) {
    if (pill.width > imageRect.width - 4 ||
        pill.height > imageRect.height - 4) {
      return null;
    }
    return Rect.fromLTWH(
      pill.left.clamp(imageRect.left + 2, imageRect.right - pill.width - 2),
      pill.top.clamp(imageRect.top + 2, imageRect.bottom - pill.height - 2),
      pill.width,
      pill.height,
    );
  }

  static bool _collides(Rect rect, List<Rect> placed) {
    final inflated = rect.inflate(4);
    for (final other in placed) {
      if (inflated.overlaps(other)) return true;
    }
    return false;
  }

  /// Anatomical caption pill; returns the drawn rect so callers can reserve
  /// the space against later callouts.
  Rect _drawLabel(Canvas canvas, Offset anchor, String text) {
    final size = _measure(text);
    final pill = Rect.fromLTWH(
      anchor.dx.clamp(
        imageRect.left + 2,
        (imageRect.right - size.width - 12).clamp(2.0, double.infinity),
      ),
      anchor.dy.clamp(
        imageRect.top + 2,
        (imageRect.bottom - size.height - 10).clamp(2.0, double.infinity),
      ),
      size.width + 12,
      size.height + 8,
    );
    _drawLabelAt(canvas, pill, text);
    return pill;
  }

  void _drawLabelAt(Canvas canvas, Rect pill, String text) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, const Radius.circular(4)),
      Paint()..color = _soften(const Color(0xFF0F172A), 0.82),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pill, const Radius.circular(4)),
      _strokePaint(_soften(ScannerHUDTheme.warning, 0.55), 1.0),
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: imageRect.width - 16);
    painter.paint(
      canvas,
      Offset(pill.left + 6, pill.center.dy - painter.height / 2),
    );
  }

  Size _measure(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: _labelStyle),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: imageRect.width - 16);
    return Size(painter.width, painter.height);
  }

  static const _labelStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w600,
    color: Color(0xFFFDE68C),
  );

  static Color _soften(Color base, double alpha) =>
      base.withValues(alpha: alpha.clamp(0.0, 1.0));

  Paint _strokePaint(Color color, double width) {
    return Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * strokeScale;
  }

  @override
  bool shouldRepaint(covariant LesionMarkerPainter oldDelegate) =>
      oldDelegate.markers != markers ||
      oldDelegate.imageRect != imageRect ||
      oldDelegate.scale != scale ||
      oldDelegate.strokeScale != strokeScale ||
      oldDelegate.pulse != pulse ||
      oldDelegate.showCallouts != showCallouts ||
      oldDelegate.selectedLesionId != selectedLesionId ||
      oldDelegate.highlightCriterionId != highlightCriterionId;
}

enum MarkerKind { opticDisc, fovea, candidate, exudateCandidate }

class MarkerToDraw {
  const MarkerToDraw({
    required this.kind,
    required this.position,
    required this.radius,
    this.lesionId,
    this.lesionType,
    this.selected = false,
    this.dimmed = false,
    this.criterionHighlighted = false,
  });

  final MarkerKind kind;
  final Offset position;
  final double radius;

  /// Stable evidence id (evidence-linked payloads only).
  final String? lesionId;
  final String? lesionType;

  /// Selection emphasis (evidence-linked interaction).
  final bool selected;

  /// Dimmed when another marker is selected.
  final bool dimmed;

  /// Emphasized when its criterion is highlighted.
  final bool criterionHighlighted;
}
