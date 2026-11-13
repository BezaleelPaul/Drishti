import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'pipeline_schema.dart';
import 'quality_thresholds.dart';

class QualityGateDart {
  const QualityGateDart();

  QualityAssessmentResult assess(
    Uint8List rgbBytes,
    int width,
    int height, {
    bool strictMode = false,
  }) {
    if (width < kFundusMinSize || height < kFundusMinSize) {
      return const QualityAssessmentResult(
        grade: QualityGrade.BAD,
        isReliable: false,
        reasons: [QualityReason.nonFundusOrCorrupt],
        details: 'Image dimensions too small',
        errorCode: PipelineErrorCode.imgNotFundus,
      );
    }

    final decision = _domainGate(rgbBytes, width, height);
    if (decision.verdict == _Verdict.notFundus) {
      return QualityAssessmentResult(
        grade: QualityGrade.BAD,
        isReliable: false,
        reasons: const [QualityReason.nonFundusOrCorrupt],
        details: decision.reason,
        errorCode: PipelineErrorCode.imgNotFundus,
      );
    }

    final metrics = _calculateMetrics(rgbBytes, width, height);

    final reasons = <QualityReason>[];
    var isBad = false;
    if (metrics.sharpnessScore < _blurBad(strictMode)) {
      reasons.add(QualityReason.severeBlur);
      isBad = true;
    }
    if (metrics.meanBrightness < _minBrightnessBad(strictMode)) {
      reasons.add(QualityReason.inadequateIllumination);
      isBad = true;
    } else if (metrics.meanBrightness > _maxBrightnessBad(strictMode)) {
      reasons.add(QualityReason.overexposure);
      isBad = true;
    }
    if (metrics.contrastScore < _minContrastBad(strictMode)) {
      reasons.add(QualityReason.lowContrast);
      isBad = true;
    }
    if (metrics.fovRatio < _minFovBad(strictMode)) {
      reasons.add(QualityReason.insufficientFieldOfView);
      isBad = true;
    }
    if (metrics.mlQualityScore < _minMlBad(strictMode)) {
      reasons.add(QualityReason.lowMlQuality);
      isBad = true;
    }
    if (isBad) {
      return QualityAssessmentResult(
        grade: QualityGrade.BAD,
        isReliable: false,
        reasons: reasons,
        metrics: metrics,
        details: 'Fails reliability gate',
        errorCode: PipelineErrorCode.imgUntgradable,
      );
    }

    var isBorderline = false;
    if (metrics.sharpnessScore < _blurGood(strictMode)) isBorderline = true;
    if (metrics.meanBrightness < _minBrightnessGood(strictMode) ||
        metrics.meanBrightness > _maxBrightnessGood(strictMode)) {
      isBorderline = true;
    }
    if (metrics.contrastScore < _minContrastGood(strictMode)) {
      isBorderline = true;
    }
    if (metrics.fovRatio < _minFovGood(strictMode)) isBorderline = true;
    if (metrics.mlQualityScore < _minMlGood(strictMode)) isBorderline = true;

    if (isBorderline) {
      return QualityAssessmentResult(
        grade: QualityGrade.BORDERLINE,
        isReliable: false,
        reasons: const [QualityReason.borderlineMarginal],
        metrics: metrics,
        details: 'Borderline image',
        errorCode: PipelineErrorCode.imgUntgradable,
      );
    }

    return QualityAssessmentResult(
      grade: QualityGrade.GOOD,
      isReliable: true,
      reasons: const [QualityReason.adequate],
      metrics: metrics,
      details: 'Image certified as reliable for DR classification',
    );
  }

  double _blurGood(bool s) => s ? kStrictBlurGood : kBlurGoodThreshold;
  double _blurBad(bool s) => s ? kStrictBlurBad : kBlurBadThreshold;
  double _minBrightnessGood(bool s) =>
      s ? kStrictMinBrightnessGood : kMinBrightnessGood;
  double _minBrightnessBad(bool s) =>
      s ? kStrictMinBrightnessBad : kMinBrightnessBad;
  double _maxBrightnessGood(bool s) =>
      s ? kStrictMaxBrightnessGood : kMaxBrightnessGood;
  double _maxBrightnessBad(bool s) =>
      s ? kStrictMaxBrightnessBad : kMaxBrightnessBad;
  double _minContrastGood(bool s) =>
      s ? kStrictMinContrastGood : kMinContrastGood;
  double _minContrastBad(bool s) => s ? kStrictMinContrastBad : kMinContrastBad;
  double _minFovGood(bool s) => s ? kStrictMinFovGood : kMinFovRatioGood;
  double _minFovBad(bool s) => s ? kStrictMinFovBad : kMinFovRatioBad;
  double _minMlGood(bool s) => s ? kStrictMinMlGood : kMinMlQualityGood;
  double _minMlBad(bool s) => s ? kStrictMinMlBad : kMinMlQualityBad;

  _DomainDecision _domainGate(Uint8List rgb, int w, int h) {
    if (_channelStdDevs(rgb).every((v) => v < kFundusMinVariance)) {
      return const _DomainDecision(
        _Verdict.notFundus,
        'Image has almost zero variance (blank or solid color)',
      );
    }

    final s = _fundusSignals(rgb, w, h);

    if (s.brightness < kDeferBelowBrightness ||
        s.brightness > kDeferAboveBrightness) {
      return const _DomainDecision(
        _Verdict.undetermined,
        'Illumination outside domain-gate range; deferring',
      );
    }

    if (s.redBlueRatio < kMinRedToBlueRatio) {
      return _DomainDecision(
        _Verdict.notFundus,
        'Color profile does not match retinal fundus '
        '(Red/Blue ratio=${s.redBlueRatio.toStringAsFixed(2)})',
      );
    }

    final bandOk =
        s.orangeBandFrac >= kMinOrangeBandFrac ||
        s.orangeBandFracBright >= kMinOrangeBandFracBright ||
        s.orangeBandFracLit >= kMinOrangeBandFracLit ||
        (s.orangeBandFracLit >= kMinOrangeBandFracLitWeak &&
            s.ringDarkFrac >= kMinRingDarkFracStruct &&
            s.cornerMean <= kMaxCornerMean);

    if (!bandOk) {
      return const _DomainDecision(
        _Verdict.notFundus,
        'Saturated retinal-orange band absent',
      );
    }
    if (s.ringDarkFrac < kMinRingDarkFrac) {
      return const _DomainDecision(
        _Verdict.notFundus,
        'Circular retinal field with dark border not detected',
      );
    }
    return const _DomainDecision(_Verdict.fundus, '');
  }

  _FundusSignals _fundusSignals(Uint8List rgb, int w, int h) {
    final n = w * h;
    final ringW = math.max(4, (kRingWidthFrac * math.min(w, h)).toInt());
    final cornerH = math.max(4, (0.18 * h).toInt());
    final cornerW = math.max(4, (0.18 * w).toInt());
    final bx0 = (0.3 * w).toInt();
    final bx1 = (0.7 * w).toInt();
    final by0 = (0.3 * h).toInt();
    final by1 = (0.7 * h).toInt();

    var bandCount = 0;
    var bandBrightCount = 0;
    var bandLitCount = 0;
    var ringDarkCount = 0;
    var ringCount = 0;
    var cornerSum = 0.0;
    var cornerCount = 0;
    var centerSum = 0.0;
    var centerCount = 0;
    var illuminatedCount = 0;
    var rSum = 0.0;
    var gSum = 0.0;
    var bSum = 0.0;

    for (var y = 0; y < h; y++) {
      final topCornerBand = y < cornerH;
      final bottomCornerBand = y >= h - cornerH;
      for (var x = 0; x < w; x++) {
        final i = (y * w + x) * 3;
        final r = rgb[i].toDouble();
        final g = rgb[i + 1].toDouble();
        final b = rgb[i + 2].toDouble();

        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));
        final denom = maxC - minC + 1e-6;
        final sat = maxC > 0 ? (maxC - minC) / (maxC + 1e-6) : 0.0;

        double hue;
        if (maxC == r) {
          hue = (60.0 * ((g - b) / denom)) % 360.0;
        } else if (maxC == g) {
          hue = 60.0 * ((b - r) / denom) + 120.0;
        } else {
          hue = 60.0 * ((r - g) / denom) + 240.0;
        }

        final luma = (r + g + b) / 3.0;
        final inHueWindow = kOrangeHueMin <= kOrangeHueMax
            ? hue >= kOrangeHueMin && hue <= kOrangeHueMax
            : hue >= kOrangeHueMin || hue <= kOrangeHueMax;
        final hardInBand = inHueWindow && sat >= kOrangeMinSat;
        final softInBand = inHueWindow && sat >= 0.20;

        if (hardInBand) bandCount++;
        if (luma > 30.0) {
          illuminatedCount++;
          if (hardInBand) bandBrightCount++;
          if (softInBand) bandLitCount++;
        }

        rSum += r;
        gSum += g;
        bSum += b;

        final inRing =
            y < ringW || y >= h - ringW || x < ringW || x >= w - ringW;
        if (inRing) {
          ringCount++;
          if (luma < kRingDarkLuma) ringDarkCount++;
        }

        final inCorner =
            (topCornerBand || bottomCornerBand) &&
            (x < cornerW || x >= w - cornerW);
        if (inCorner) {
          cornerCount++;
          cornerSum += luma;
        }

        if (y >= by0 && y < by1 && x >= bx0 && x < bx1) {
          centerCount++;
          centerSum += luma;
        }
      }
    }

    final centerMean = centerCount > 0 ? centerSum / centerCount : 0.0;
    final cornerMean = cornerCount > 0 ? cornerSum / cornerCount : 0.0;
    final meanR = rSum / n;
    final meanB = bSum / n + 1e-5;
    return _FundusSignals(
      orangeBandFrac: bandCount / n,
      orangeBandFracBright: illuminatedCount > 0
          ? bandBrightCount / illuminatedCount
          : 0.0,
      orangeBandFracLit: illuminatedCount > 0
          ? bandLitCount / illuminatedCount
          : 0.0,
      ringDarkFrac: ringCount > 0 ? ringDarkCount / ringCount : 0.0,
      cornerMean: cornerMean,
      centerMean: centerMean,
      redBlueRatio: meanR / meanB,
      brightness: (rSum + gSum + bSum) / (3.0 * n),
    );
  }

  QualityMetrics _calculateMetrics(Uint8List rgb, int w, int h) {
    final gray = _toGray(rgb, w, h);
    final maskFov = _extractRetinalMask(gray, w, h);
    final mask = maskFov.mask;
    final fovRatio = maskFov.fovRatio;
    final lap = _laplacian(gray, w, h);

    double meanBrightness;
    double contrastScore;
    double sharpnessScore;

    if (fovRatio > 0.05) {
      var sum = 0.0;
      var sumSq = 0.0;
      var lapSum = 0.0;
      var lapSqSum = 0.0;
      var count = 0;
      for (var i = 0; i < gray.length; i++) {
        if (mask[i] == 0) continue;
        final v = gray[i];
        sum += v;
        sumSq += v * v;
        final lv = lap[i];
        lapSum += lv;
        lapSqSum += lv * lv;
        count++;
      }
      if (count > 0) {
        meanBrightness = sum / count;
        contrastScore = math.sqrt(
          math.max(0.0, sumSq / count - meanBrightness * meanBrightness),
        );
        final lapMean = lapSum / count;
        sharpnessScore = math.max(0.0, lapSqSum / count - lapMean * lapMean);
      } else {
        meanBrightness = _meanAll(gray);
        contrastScore = _stdAll(gray);
        sharpnessScore = _varAll(lap);
      }
    } else {
      meanBrightness = _meanAll(gray);
      contrastScore = _stdAll(gray);
      sharpnessScore = _varAll(lap);
    }

    final sBlur = _sigmoid(kBlurSlope * (sharpnessScore - kBlurGoodThreshold));
    final sIllum = math.exp(
      -((meanBrightness - kIllumOptimum) * (meanBrightness - kIllumOptimum)) /
          (2.0 * kIllumSigma * kIllumSigma),
    );
    final sContrast =
        1.0 /
        (1.0 + math.exp(-kContrastSlope * (contrastScore - kContrastCenter)));
    final sFov = (fovRatio / kFovNormalization).clamp(0.0, 1.0);
    final mlScore =
        (kFusionBlurWeight * sBlur +
                kFusionIllumWeight * sIllum +
                kFusionContrastWeight * sContrast +
                kFusionFovWeight * sFov)
            .clamp(0.0, 1.0);

    return QualityMetrics(
      sharpnessScore: sharpnessScore,
      meanBrightness: meanBrightness,
      contrastScore: contrastScore,
      fovRatio: fovRatio,
      mlQualityScore: mlScore,
    );
  }

  Float64List _toGray(Uint8List rgb, int w, int h) {
    final g = Float64List(w * h);
    for (var i = 0, j = 0; i < rgb.length; i += 3, j++) {
      g[j] = 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
    }
    return g;
  }

  /// Per-channel STANDARD DEVIATION (fundus_gate compares std < 2.0, not
  /// variance — an earlier port compared variance here, which is more
  /// lenient and let near-blank images through the blank-frame check).
  List<double> _channelStdDevs(Uint8List rgb) {
    final n = rgb.length ~/ 3;
    final sums = List<double>.filled(3, 0);
    final sqs = List<double>.filled(3, 0);
    for (var i = 0; i < rgb.length; i += 3) {
      for (var c = 0; c < 3; c++) {
        final v = rgb[i + c].toDouble();
        sums[c] += v;
        sqs[c] += v * v;
      }
    }
    final out = List<double>.filled(3, 0);
    for (var c = 0; c < 3; c++) {
      final m = sums[c] / n;
      out[c] = math.sqrt(math.max(0.0, sqs[c] / n - m * m));
    }
    return out;
  }

  double _meanAll(Float64List a) {
    var s = 0.0;
    for (final v in a) {
      s += v;
    }
    return s / a.length;
  }

  double _stdAll(Float64List a) {
    final m = _meanAll(a);
    var sq = 0.0;
    for (final v in a) {
      sq += v * v;
    }
    return math.sqrt(math.max(0.0, sq / a.length - m * m));
  }

  double _varAll(Float64List a) {
    final m = _meanAll(a);
    var sq = 0.0;
    for (final v in a) {
      sq += v * v;
    }
    return math.max(0.0, sq / a.length - m * m);
  }

  double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

  /// Otsu threshold + largest 8-connected bright component; approximates the
  /// cv2 threshold+close+findContours path in
  /// checker._extract_dynamic_retinal_mask. Falls back to the shared
  /// gray > 15 retinal mask (src/image_io.retinal_mask) when the component
  /// is degenerate (checker.py:411-416).
  ({Uint8List mask, double fovRatio}) _extractRetinalMask(
    Float64List gray,
    int w,
    int h,
  ) {
    final u8 = Uint8List(gray.length);
    final hist = List<int>.filled(256, 0);
    for (var i = 0; i < gray.length; i++) {
      final v = gray[i].round().clamp(0, 255);
      u8[i] = v;
      hist[v]++;
    }

    var total = 0;
    var sumAll = 0;
    for (var t = 0; t < 256; t++) {
      total += hist[t];
      sumAll += t * hist[t];
    }
    var sumB = 0;
    var wB = 0;
    var bestBetween = 0.0;
    var threshold = 0;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      final wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      final mB = sumB / wB;
      final mF = (sumAll - sumB) / wF;
      final between = wB * wF * (mB - mF) * (mB - mF);
      if (between > bestBetween) {
        bestBetween = between;
        threshold = t;
      }
    }

    final binary = Uint8List(gray.length);
    for (var i = 0; i < binary.length; i++) {
      binary[i] = u8[i] > threshold ? 255 : 0;
    }
    final closed = _close(binary, w, h);
    final comp = _largestComponent(closed, w, h);
    if (comp.fovRatio > 0.10) {
      return comp;
    }

    final mask = Uint8List(gray.length);
    var count = 0;
    for (var i = 0; i < gray.length; i++) {
      if (gray[i] > kRetinalBgThreshold) {
        mask[i] = 1;
        count++;
      }
    }
    return (mask: mask, fovRatio: count / gray.length);
  }

  /// Separable box morphological close, approximating cv2 MORPH_ELLIPSE(11,11).
  Uint8List _close(Uint8List binary, int w, int h) {
    final dil = _maxFilter(binary, w, h);
    final ero = _minFilter(dil, w, h);
    return ero;
  }

  Uint8List _maxFilter(Uint8List src, int w, int h) {
    final tmp = Uint8List(src.length);
    final out = Uint8List(src.length);
    const r = 5;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 0;
        for (var d = -r; d <= r; d++) {
          final xx = (x + d).clamp(0, w - 1);
          final v = src[y * w + xx];
          if (v > m) m = v;
        }
        tmp[y * w + x] = m;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 0;
        for (var d = -r; d <= r; d++) {
          final yy = (y + d).clamp(0, h - 1);
          final v = tmp[yy * w + x];
          if (v > m) m = v;
        }
        out[y * w + x] = m;
      }
    }
    return out;
  }

  Uint8List _minFilter(Uint8List src, int w, int h) {
    final tmp = Uint8List(src.length);
    final out = Uint8List(src.length);
    const r = 5;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 255;
        for (var d = -r; d <= r; d++) {
          final xx = (x + d).clamp(0, w - 1);
          final v = src[y * w + xx];
          if (v < m) m = v;
        }
        tmp[y * w + x] = m;
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var m = 255;
        for (var d = -r; d <= r; d++) {
          final yy = (y + d).clamp(0, h - 1);
          final v = tmp[yy * w + x];
          if (v < m) m = v;
        }
        out[y * w + x] = m;
      }
    }
    return out;
  }

  ({Uint8List mask, double fovRatio}) _largestComponent(
    Uint8List binary,
    int w,
    int h,
  ) {
    final labels = Int32List(w * h);
    final stack = <int>[];
    var nextLabel = 0;
    var bestLabel = 0;
    var bestSize = 0;

    for (var s = 0; s < binary.length; s++) {
      if (binary[s] == 0 || labels[s] != 0) continue;
      nextLabel++;
      var size = 0;
      stack.add(s);
      labels[s] = nextLabel;
      while (stack.isNotEmpty) {
        final i = stack.removeLast();
        size++;
        final x = i % w;
        final y = i ~/ w;
        for (var dy = -1; dy <= 1; dy++) {
          final ny = y + dy;
          if (ny < 0 || ny >= h) continue;
          for (var dx = -1; dx <= 1; dx++) {
            final nx = x + dx;
            if (nx < 0 || nx >= w) continue;
            final j = ny * w + nx;
            if (binary[j] != 0 && labels[j] == 0) {
              labels[j] = nextLabel;
              stack.add(j);
            }
          }
        }
      }
      if (size > bestSize) {
        bestSize = size;
        bestLabel = nextLabel;
      }
    }

    final mask = Uint8List(w * h);
    if (bestSize > 0) {
      for (var i = 0; i < labels.length; i++) {
        if (labels[i] == bestLabel) mask[i] = 1;
      }
    }
    return (mask: mask, fovRatio: bestSize / (w * h));
  }

  /// cv2.Laplacian(gray, CV_64F), default kernel with BORDER_REFLECT_101.
  Float64List _laplacian(Float64List gray, int w, int h) {
    final out = Float64List(gray.length);
    for (var y = 0; y < h; y++) {
      final up = y > 0 ? y - 1 : y + 1;
      final down = y < h - 1
          ? y + 1
          : y - 2 < 0
          ? y - 1
          : y - 1;
      for (var x = 0; x < w; x++) {
        final left = x > 0 ? x - 1 : x + 1;
        final right = x < w - 1 ? x + 1 : x - 1;
        final i = y * w + x;
        out[i] =
            gray[up * w + x] +
            gray[down * w + x] +
            gray[y * w + left] +
            gray[y * w + right] -
            4.0 * gray[i];
      }
    }
    return out;
  }
}

class _FundusSignals {
  const _FundusSignals({
    required this.orangeBandFrac,
    required this.orangeBandFracBright,
    required this.orangeBandFracLit,
    required this.ringDarkFrac,
    required this.cornerMean,
    required this.centerMean,
    required this.redBlueRatio,
    required this.brightness,
  });

  final double orangeBandFrac;
  final double orangeBandFracBright;
  final double orangeBandFracLit;
  final double ringDarkFrac;
  final double cornerMean;
  final double centerMean;
  final double redBlueRatio;
  final double brightness;
}

class _DomainDecision {
  const _DomainDecision(this.verdict, this.reason);
  final _Verdict verdict;
  final String reason;
}

enum _Verdict { fundus, notFundus, undetermined }

class CanonicalImage {
  const CanonicalImage({
    required this.bytes,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Canonical RGB decode funnel (src/image_io.to_rgb_uint8 contract): rejects
/// oversized frames BEFORE decode, RGBA drops alpha, values clip to [0,255].
/// Throws FormatException on decode failure — callers map that to
/// IMG_INVALID (fail closed), never continue with stale pixels.
CanonicalImage decodeCanonicalRgb(Uint8List encoded, {int maxDim = 4096}) {
  if (encoded.isEmpty) {
    throw const FormatException('Empty image array.');
  }
  final decoded = img.decodeImage(encoded);
  if (decoded == null) {
    throw const FormatException('Could not decode image');
  }
  return canonicalRgbFromDecoded(decoded, maxDim: maxDim);
}

/// Extracts canonical RGB bytes from an already-decoded image without a
/// second JPEG decode pass (router Node 1 shares one decode across stages).
///
/// Frames larger than [analysisMaxDim] on the longest side are downscaled
/// BEFORE the metric passes: the pure-Dart gate is O(pixels) and a 12 MP
/// capture would spend seconds on the phone. Documented deviation from the
/// Python gate (which runs full-res) — verdict parity is enforced by the
/// adversarial + phone-image test suites, not by byte equality.
CanonicalImage canonicalRgbFromDecoded(
  img.Image decoded, {
  int maxDim = 4096,
  int analysisMaxDim = 2048,
}) {
  var w = decoded.width;
  var h = decoded.height;
  if (w <= 0 || h <= 0 || h > maxDim || w > maxDim) {
    throw FormatException('Invalid image dimensions: ${w}x$h');
  }
  var source = decoded;
  final longest = w > h ? w : h;
  if (longest > analysisMaxDim) {
    final scale = analysisMaxDim / longest;
    source = img.copyResize(
      decoded,
      width: (w * scale).round().clamp(1, analysisMaxDim),
      height: (h * scale).round().clamp(1, analysisMaxDim),
      interpolation: img.Interpolation.cubic,
    );
    w = source.width;
    h = source.height;
  }
  final out = Uint8List(w * h * 3);
  var j = 0;
  for (final p in source) {
    out[j++] = p.r.toInt().clamp(0, 255);
    out[j++] = p.g.toInt().clamp(0, 255);
    out[j++] = p.b.toInt().clamp(0, 255);
  }
  return CanonicalImage(bytes: out, width: w, height: h);
}
