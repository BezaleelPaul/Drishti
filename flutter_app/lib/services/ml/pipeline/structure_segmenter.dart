import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../../models/retinal_markers.dart';

/// Request payload for isolate execution of landmark detection.
class RetinalMarkerRequest {
  const RetinalMarkerRequest(this.imageBytes, {this.predictedGrade});
  final Uint8List imageBytes;
  final int? predictedGrade;
}

/// Dispatches [computeRetinalMarkers] from an isolate-friendly request wrapper.
RetinalMarkers computeRetinalMarkersFromRequest(RetinalMarkerRequest req) {
  return computeRetinalMarkers(req.imageBytes, predictedGrade: req.predictedGrade);
}

/// On-device lite port of the retinal structure segmenter.
///
/// Computes the advisory marker payload:
/// 1. Optic disc: localized via brightness × vertical vessel edge convergence,
///    with FOV perimeter eroded by ~5% to eliminate crescent flash glare.
/// 2. Fovea: localized via 2D Integral Image Difference-of-Boxes inside the
///    temporal anatomical ROI (~2.4 disc diameters / 4.8 * odRadius).
///    Returns nullable MarkerPoint? (null when outside FOV or obscured by hemorrhage).
/// 3. Microaneurysms: green-channel dark spots filtered by Hessian anisotropy
///    to suppress tubular blood vessels, with candidate extraction gated off
///    when predictedGrade == 0 (No DR).
RetinalMarkers computeRetinalMarkers(
  Uint8List imageBytes, {
  int? predictedGrade,
}) {
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

  // Work on a canonical bounded grid (~256x256) for non-blocking sub-10ms isolate execution.
  const workMax = 256.0;
  final workScale = workMax / math.max(raw.width, raw.height);
  final work = workScale < 1.0
      ? img.copyResize(
          raw,
          width: (raw.width * workScale).round().clamp(16, 256),
          height: (raw.height * workScale).round().clamp(16, 256),
          interpolation: img.Interpolation.linear,
        )
      : raw;
  final w = work.width;
  final h = work.height;
  final n = w * h;

  final red = Float32List(n);
  final green = Float32List(n);
  final blue = Float32List(n);
  final fovMask = Uint8List(n);
  var fovCount = 0;

  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = work.getPixel(x, y);
      final r = p.r.toDouble();
      final g = p.g.toDouble();
      final b = p.b.toDouble();
      final i = y * w + x;
      red[i] = r;
      green[i] = g;
      blue[i] = b;

      // Retinal FOV area mask (Red > 20 dominant / tissue signature)
      final isRetinal = r > 20.0 && ((r > b * 1.05) || (g > b * 1.05) || (r + g + b > 50.0));
      if (isRetinal) {
        fovMask[i] = 1;
        fovCount++;
      }
    }
  }

  // Hard capture gate: at least 15% retinal FOV in frame
  if (fovCount * 100 < 15 * n) {
    return unavailable('No retinal region detected in this frame.');
  }

  final minDim = math.min(w, h);

  // Erode circular FOV border by ~5% of FOV width to eliminate crescent flash glare
  final fovDiameter = math.sqrt(fovCount * 4.0 / math.pi);
  final erosionRadius = (fovDiameter * 0.05).round().clamp(2, 14);
  final erodedFovMask = _minFilterMask(fovMask, w, h, erosionRadius);

  // ---- 1. Optic Disc: Brightness × Vertical Vessel Edge Density ----
  final odRadius = (minDim * 0.08).round().clamp(3, 22);

  // Vertical vessel edge gradient: |G(x, y+1) - G(x, y-1)|
  final vGrad = Float32List(n);
  for (var y = 1; y < h - 1; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      if (erodedFovMask[row + x] == 0) continue;
      vGrad[row + x] = (green[(y + 1) * w + x] - green[(y - 1) * w + x]).abs();
    }
  }

  final rSmooth = _boxBlur(red, w, h, math.max(2, odRadius ~/ 2));
  final vSmooth = _boxBlur(vGrad, w, h, odRadius);

  var maxR = 0.0;
  var maxV = 0.0;
  for (var i = 0; i < n; i++) {
    if (erodedFovMask[i] == 0) continue;
    if (rSmooth[i] > maxR) maxR = rSmooth[i];
    if (vSmooth[i] > maxV) maxV = vSmooth[i];
  }

  // Equatorial band (0.20*h to 0.80*h, 0.10*w to 0.90*w)
  final yTop = (h * 0.20).round();
  final yBottom = (h * 0.80).round();
  final xLeft = (w * 0.10).round();
  final xRight = (w * 0.90).round();

  var odX = (w * 0.35).round();
  var odY = (h * 0.50).round();
  var bestOdScore = -1.0;

  for (var y = yTop; y <= yBottom; y++) {
    final row = y * w;
    for (var x = xLeft; x <= xRight; x++) {
      final i = row + x;
      if (erodedFovMask[i] == 0) continue;
      final rNorm = maxR > 0 ? rSmooth[i] / maxR : 0.0;
      final vNorm = maxV > 0 ? vSmooth[i] / maxV : 0.0;
      final score = rNorm * (0.6 + 0.4 * vNorm);
      if (score > bestOdScore) {
        bestOdScore = score;
        odX = x;
        odY = y;
      }
    }
  }

  // ---- 2. Safe, Nullable Fovea Localization: Integral Image Difference-of-Boxes ----
  final centreX = w / 2.0;
  final centreY = h / 2.0;
  final odSide = odX < centreX ? 1 : -1;
  final expFoveaX = odX + odSide * (odRadius * 4.8);
  final expFoveaY = odY + (centreY - odY) * 0.25;

  // Build 2D Integral Image (Summed-Area Table) of the Green channel
  final stride = w + 1;
  final sat = Int32List((w + 1) * (h + 1));
  for (var y = 0; y < h; y++) {
    var rowSum = 0;
    final srcRow = y * w;
    final satRowPrev = y * stride;
    final satRowCurr = (y + 1) * stride;
    for (var x = 0; x < w; x++) {
      rowSum += green[srcRow + x].round();
      sat[satRowCurr + (x + 1)] = sat[satRowPrev + (x + 1)] + rowSum;
    }
  }

  int rectSum(int x1, int y1, int x2, int y2) {
    return sat[(y2 + 1) * stride + (x2 + 1)] -
        sat[y1 * stride + (x2 + 1)] -
        sat[(y2 + 1) * stride + x1] +
        sat[y1 * stride + x1];
  }

  final rIn = math.max(2, (odRadius * 0.35).round());
  final rOut = math.max(rIn + 2, (odRadius * 1.0).round());
  final areaIn = (2 * rIn + 1) * (2 * rIn + 1);
  final areaTotal = (2 * rOut + 1) * (2 * rOut + 1);
  final areaRing = areaTotal - areaIn;

  double? foveaX;
  double? foveaY;

  // If the expected anatomical fovea position lies outside the frame, cleanly return null
  final isOffFrame = expFoveaX < 0 || expFoveaX >= w || expFoveaY < 0 || expFoveaY >= h;
  if (!isOffFrame) {
    final roiR = (odRadius * 1.5).round();
    final clRoiX1 = (expFoveaX - roiR).round().clamp(0, w - 1);
    final clRoiX2 = (expFoveaX + roiR).round().clamp(0, w - 1);
    final clRoiY1 = (expFoveaY - roiR).round().clamp(0, h - 1);
    final clRoiY2 = (expFoveaY + roiR).round().clamp(0, h - 1);

    double? bestFoveaX;
    double? bestFoveaY;
    var bestContrast = -double.infinity;

    for (var ry = clRoiY1; ry <= clRoiY2; ry++) {
      if (ry - rOut < 0 || ry + rOut >= h) continue;
      final rowOffset = ry * w;
      for (var rx = clRoiX1; rx <= clRoiX2; rx++) {
        if (rx - rOut < 0 || rx + rOut >= w) continue;
        if (fovMask[rowOffset + rx] == 0) continue;

        // Ensure outer surround ring stays entirely inside circular retinal FOV
        if (fovMask[(ry - rOut) * w + (rx - rOut)] == 0 ||
            fovMask[(ry - rOut) * w + (rx + rOut)] == 0 ||
            fovMask[(ry + rOut) * w + (rx - rOut)] == 0 ||
            fovMask[(ry + rOut) * w + (rx + rOut)] == 0) {
          continue;
        }

        final sumIn = rectSum(rx - rIn, ry - rIn, rx + rIn, ry + rIn);
        final sumTotal = rectSum(rx - rOut, ry - rOut, rx + rOut, ry + rOut);
        final sumRing = sumTotal - sumIn;
        final meanIn = sumIn / areaIn;
        final meanRing = sumRing / areaRing;
        final contrast = meanRing - meanIn;

        if (contrast > bestContrast) {
          bestContrast = contrast;
          bestFoveaX = rx.toDouble();
          bestFoveaY = ry.toDouble();
        }
      }
    }

    // Fovea is an avascular depression darker than surround (contrast >= 0.5).
    // If obscured by Grade 4 macular hemorrhage or flat, return null cleanly.
    if (bestFoveaX != null && bestContrast >= 0.5) {
      foveaX = bestFoveaX;
      foveaY = bestFoveaY;
    }
  }

  // ---- 3. Vessel/Border-Masked Microaneurysm Detection & Grade Gating ----
  List<(int, int, int)> candidates = const [];
  if (predictedGrade != 0) {
    final bgRadius = ((minDim * 15.0 / 256.0) ~/ 2).clamp(2, 16);
    final background = _boxBlur(green, w, h, bgRadius);
    final spotMask = Uint8List(n);
    final odDiscRadiusSq = (odRadius * 1.4) * (odRadius * 1.4);

    for (var y = 2; y < h - 2; y++) {
      for (var x = 2; x < w - 2; x++) {
        final i = y * w + x;
        if (erodedFovMask[i] == 0) continue;
        final dx = x - odX;
        final dy = y - odY;
        if (dx * dx + dy * dy < odDiscRadiusSq) continue;
        final diff = background[i] - green[i];
        if (diff <= 12.0) continue;

        // Tubular vessel suppression via Hessian directional curvature:
        // Linear blood vessels exhibit high curvature across the vessel and low along it.
        final dxx = (green[i + 1] + green[i - 1] - 2 * green[i]).abs();
        final dyy = (green[i + w] + green[i - w] - 2 * green[i]).abs();
        final sumD = dxx + dyy;
        if (sumD > 4.0) {
          final anisotropy = (dxx - dyy).abs() / sumD;
          if (anisotropy > 0.55) {
            // High anisotropy -> tubular blood vessel -> suppress!
            continue;
          }
        }
        spotMask[i] = 255;
      }
    }

    final scaleRef = (minDim / 256.0).clamp(0.5, 2.0);
    final minArea = (2 * scaleRef * scaleRef).round().clamp(2, 50);
    final maxArea = (45 * scaleRef * scaleRef).round().clamp(10, 200);
    candidates = _compactRoundSpots(spotMask, w, h, minArea, maxArea).take(35).toList();
  }

  // ---- 4. Scale Coordinates Back to Original Pixel Space ----
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
      r: (odRadius * ((fxScale + fyScale) / 2)).round(),
    ),
    fovea: foveaX != null && foveaY != null
        ? MarkerPoint(
            x: (foveaX * fxScale).round(),
            y: (foveaY * fyScale).round(),
          )
        : null,
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

/// Separable min-filter to erode binary mask by [radius].
Uint8List _minFilterMask(Uint8List src, int w, int h, int radius) {
  final tmp = Uint8List(src.length);
  final out = Uint8List(src.length);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var minVal = 1;
      for (var d = -radius; d <= radius; d++) {
        final xx = (x + d).clamp(0, w - 1);
        if (src[row + xx] == 0) {
          minVal = 0;
          break;
        }
      }
      tmp[row + x] = minVal;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var minVal = 1;
      for (var d = -radius; d <= radius; d++) {
        final yy = (y + d).clamp(0, h - 1);
        if (tmp[yy * w + x] == 0) {
          minVal = 0;
          break;
        }
      }
      out[y * w + x] = minVal;
    }
  }
  return out;
}

/// Separable box blur with running sum — O(n).
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

/// 4-connected components on a binary mask, keeping compact round-ish spots.
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
    // Compactness filter
    if (bboxArea == 0 || area / bboxArea < 0.30) continue;
    if (bw > 2.8 * bh || bh > 2.8 * bw) continue;
    yield (
      (sumX / area).round(),
      (sumY / area).round(),
      ((bw > bh ? bw : bh) / 2).round().clamp(3, 1 << 12),
    );
  }
}
