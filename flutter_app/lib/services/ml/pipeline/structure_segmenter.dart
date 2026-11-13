import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../../models/retinal_markers.dart';

/// On-device lite port of the server's classical-CV retinal structure
/// segmenter (`src/segmentation/structure_segmenter.py`).
///
/// Computes the SAME advisory marker payload the tele-ophthalmologist viewer
/// consumes — optic disc, fovea estimate, and microaneurysm candidates — so
/// landmark arrows are available offline for every capture. Honesty rules
/// carried over unchanged:
/// * the payload source is pinned to `classical_cv_segmentation` (never
///   model attention / Grad-CAM);
/// * `available=false` (could not compute) is distinct from
///   `available=true` with zero candidates (healthy, nothing found);
/// * failures degrade to an unavailable payload with a reason, never a
///   fabricated landmark.
///
/// Documented deviations from the Python reference (advisory only, never
/// gates a grade): no OpenCV — box-blur top-hat replaces the disk-kernel
/// black-hat, and no CLAHE/vessel-exclusion pass; a compactness filter drops
/// elongated vessel-fragment candidates instead. Coordinates are in the
/// ORIGINAL image pixel space (the marker contract).
RetinalMarkers computeRetinalMarkers(Uint8List imageBytes) {
  RetinalMarkers unavailable(String reason) =>
      RetinalMarkers(reviewId: 'on-device', available: false, reason: reason);

  final img.Image? decoded;
  try {
    decoded = img.decodeImage(imageBytes);
  } catch (_) {
    return unavailable('Image could not be decoded for landmark analysis.');
  }
  final raw = decoded;
  if (raw == null || raw.width < 3 || raw.height < 3) {
    return unavailable('Image could not be decoded for landmark analysis.');
  }

  // Work at a bounded resolution; coordinates are scaled back at the end.
  const workMax = 384.0;
  final workScale = workMax / (raw.width > raw.height ? raw.width : raw.height);
  final work = workScale < 1.0
      ? img.copyResize(
          raw,
          width: (raw.width * workScale).round().clamp(3, 1 << 14),
          height: (raw.height * workScale).round().clamp(3, 1 << 14),
        )
      : raw;
  final w = work.width;
  final h = work.height;
  final n = w * h;

  final green = Float32List(n);
  final intensity = Float32List(n);
  final retinal = Uint8List(n);
  var retinalCount = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = work.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final i = y * w + x;
      green[i] = g;
      intensity[i] = r * 0.6 + g * 0.4;
      final luma = 0.299 * r + 0.587 * g + 0.114 * b;
      if (luma > 10.0) {
        retinal[i] = 255;
        retinalCount++;
      }
    }
  }
  if (retinalCount * 100 < n) {
    return unavailable('No retinal region detected in this frame.');
  }

  final minDim = w < h ? w : h;

  // ---- Optic disc: brightest centroid of (0.6R + 0.4G), large blur, masked.
  final odRadiusPx = (minDim * 0.08).round().clamp(2, 1 << 12);
  final odBlurRadius = (minDim ~/ 8).clamp(2, 45);
  final blurredIntensity = _boxBlur(intensity, w, h, odBlurRadius);
  var odX = 0;
  var odY = 0;
  var best = -1.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (retinal[i] == 0) continue;
      if (blurredIntensity[i] > best) {
        best = blurredIntensity[i];
        odX = x;
        odY = y;
      }
    }
  }

  // ---- Fovea: geometric estimate temporal to the OD (Python reference rule).
  final centreX = w / 2.0;
  final centreY = h / 2.0;
  final odSide = odX < centreX ? 1 : -1;
  final margin = (minDim ~/ 20).clamp(2, 1 << 12);
  double clip(double v, double lo, double hi) =>
      v < lo ? lo : (v > hi ? hi : v);
  final foveaX = clip(
    odX + odSide * odRadiusPx * 3.2,
    margin.toDouble(),
    (w - margin).toDouble(),
  );
  final foveaY = clip(
    odY + (centreY - odY) * 0.3,
    margin.toDouble(),
    (h - margin).toDouble(),
  );

  // ---- Microaneurysm candidates: top-hat dark spots on the green channel.
  final bgRadius = ((minDim * 15.0 / 512.0) ~/ 2).clamp(2, 24);
  final background = _boxBlur(green, w, h, bgRadius);
  final spotMask = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (retinal[i] != 0 && background[i] - green[i] > 15.0) {
      spotMask[i] = 255;
    }
  }

  final scaleRef = (minDim / 512.0).clamp(0.5, 2.0).toDouble();
  final minArea = (3 * scaleRef * scaleRef).round().clamp(2, 1 << 12);
  final maxArea = (65 * scaleRef * scaleRef).round();
  final candidates = _compactRoundSpots(
    spotMask,
    w,
    h,
    minArea,
    maxArea,
  ).take(35).toList();

  // ---- Scale coordinates back to original pixel space.
  final fxScale = raw.width / w;
  final fyScale = raw.height / h;
  return RetinalMarkers(
    reviewId: 'on-device',
    available: true,
    width: raw.width,
    height: raw.height,
    opticDisc: MarkerCircle(
      x: (odX * fxScale).round(),
      y: (odY * fyScale).round(),
      r: (odRadiusPx * ((fxScale + fyScale) / 2)).round(),
    ),
    fovea: MarkerPoint(
      x: (foveaX * fxScale).round(),
      y: (foveaY * fyScale).round(),
    ),
    maCandidates: candidates
        .map(
          (c) => MarkerCircle(
            x: (c.$1 * fxScale).round(),
            y: (c.$2 * fyScale).round(),
            r: (c.$3 * ((fxScale + fyScale) / 2)).round(),
          ),
        )
        .toList(growable: false),
  );
}

/// Separable box blur with a running sum — O(n) per pass. Returns a new
/// [Float32List]; edges clamp to the border (matches OpenCV BORDER_REPLICATE
/// closely enough for advisory landmarking).
Float32List _boxBlur(Float32List src, int w, int h, int radius) {
  final tmp = Float32List(src.length);
  final horizontal = Float32List(src.length);
  final denom = (radius * 2 + 1).toDouble();

  for (var y = 0; y < h; y++) {
    final row = y * w;
    var sum = 0.0;
    for (var x = -radius; x <= radius; x++) {
      sum += src[row + x.clamp(0, w - 1)];
    }
    for (var x = 0; x < w; x++) {
      horizontal[row + x] = sum / denom;
      final out = x - radius;
      final inn = (x + radius + 1).clamp(0, w - 1);
      if (out < 0) {
        sum += src[row + inn] - src[row];
      } else {
        sum += src[row + inn] - src[row + out];
      }
    }
  }
  for (var x = 0; x < w; x++) {
    var sum = 0.0;
    for (var y = -radius; y <= radius; y++) {
      sum += horizontal[y.clamp(0, h - 1) * w + x];
    }
    for (var y = 0; y < h; y++) {
      tmp[y * w + x] = sum / denom;
      final out = y - radius;
      final inn = (y + radius + 1).clamp(0, h - 1);
      if (out < 0) {
        sum += horizontal[inn * w + x] - horizontal[x];
      } else {
        sum += horizontal[inn * w + x] - horizontal[out * w + x];
      }
    }
  }
  return tmp;
}

/// 4-connected components on a binary mask, keeping compact round-ish spots
/// within [minArea, maxArea]. Returns (x, y, r) tuples with r >= 3.
Iterable<(int, int, int)> _compactRoundSpots(
  Uint8List mask,
  int w,
  int h,
  int minArea,
  int maxArea,
) sync* {
  final visited = Uint8List(mask.length);
  final stack = <int>[];
  for (var start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || visited[start] != 0) continue;
    stack
      ..clear()
      ..add(start);
    visited[start] = 1;
    var area = 0;
    var sumX = 0;
    var sumY = 0;
    var minX = w;
    var maxX = -1;
    var minY = h;
    var maxY = -1;
    while (stack.isNotEmpty) {
      final i = stack.removeLast();
      final x = i % w;
      final y = i ~/ w;
      area++;
      sumX += x;
      sumY += y;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      if (x > 0 && mask[i - 1] != 0 && visited[i - 1] == 0) {
        visited[i - 1] = 1;
        stack.add(i - 1);
      }
      if (x + 1 < w && mask[i + 1] != 0 && visited[i + 1] == 0) {
        visited[i + 1] = 1;
        stack.add(i + 1);
      }
      if (y > 0 && mask[i - w] != 0 && visited[i - w] == 0) {
        visited[i - w] = 1;
        stack.add(i - w);
      }
      if (y + 1 < h && mask[i + w] != 0 && visited[i + w] == 0) {
        visited[i + w] = 1;
        stack.add(i + w);
      }
    }
    if (area < minArea || area > maxArea) continue;
    final bw = maxX - minX + 1;
    final bh = maxY - minY + 1;
    final bboxArea = bw * bh;
    // Compactness gate: drops elongated vessel fragments and edge slivers.
    if (bboxArea == 0 || area / bboxArea < 0.30) continue;
    if (bw > 3.5 * bh || bh > 3.5 * bw) continue;
    yield (
      (sumX / area).round(),
      (sumY / area).round(),
      ((bw > bh ? bw : bh) / 2).round().clamp(3, 1 << 12),
    );
  }
}
