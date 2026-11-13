import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'pipeline_exceptions.dart';
import 'retinal_preprocess_config.dart';

/// Pure-Dart Ben Graham retinal preprocessing shared by every on-device path.
///
/// PIPELINE (parity with `src/classification/classifier.py:188-218`):
/// 1. decode (caller) -> packed RGB, row-major `(y * w + x) * 3 + c`.
/// 2. dark-border bounding box: pixels whose luma
///    `0.299R + 0.587G + 0.114B` exceeds [RetinalPreprocessConfig
///    .borderLumaThreshold] (7 by default).
/// 3. circular mask crop to the inscribed square of that bounding box.
/// 4. Ben Graham: `dst = 4*src - 4*GaussianBlur(sigma) + 128`, clamped.
/// 5. area-weighted (OpenCV `INTER_AREA`) resize to the model edge, then
///    float32 normalisation into NHWC layout.
///
/// MEMORY LAYOUT: the returned tensor is one image, NHWC, float32:
/// `tensor[((y * size + x) * 3) + c]`, 4 bytes per element. RGB order matches
/// the model's channel order (ImageNet means are in R,G,B order).
///
/// CONCURRENCY: every method is synchronous and allocates only per-call
/// buffers, so it is safe to run inside a dedicated isolate (which is exactly
/// what [RetinalAnalysisIsolateBridge] does). The synchronous legacy runner
/// also calls into this class so both paths can never drift.
class RetinalPreprocessor {
  const RetinalPreprocessor._();

  /// Fast structural inspection used by tests, diagnostics and the strict
  /// pipeline guard. Never throws for a decodable frame; inspect
  /// [RetinalFundusMetrics.failureReason] instead.
  static RetinalFundusMetrics inspect(
    img.Image source, {
    RetinalPreprocessConfig config = RetinalPreprocessConfig.ordinal512ImageNet,
  }) {
    return _analyzeCore(source, config).metrics;
  }

  /// Full preprocessing for a model tensor.
  ///
  /// [validate] enables the structural guard (exposure/contrast/focus/area).
  /// The legacy golden-parity entry point ([toModelTensor]) deliberately runs
  /// with validation disabled.
  ///
  /// [includePreview] additionally encodes the enhanced crop as a PNG for the
  /// clinician review screen. Encoding is done in this isolate; callers that
  /// only need the tensor should leave it false.
  ///
  /// Throws [PreprocessingException] on undecodable, degenerate, or
  /// structurally invalid frames. Never returns a tensor for such a frame.
  static PreprocessedRetina prepareForModel(
    img.Image source, {
    RetinalPreprocessConfig config = RetinalPreprocessConfig.ordinal512ImageNet,
    bool validate = true,
    bool includePreview = false,
  }) {
    final stopwatch = Stopwatch()..start();
    final core = _analyzeCore(source, config);

    final failure = core.metrics.failureReason;
    if (validate && failure != null) {
      throw PreprocessingException(
        failure,
        _failureMessage(failure, core.metrics, source),
      );
    }

    if (!config.cropToRetina) {
      final tensor = _rawTensor(source, config);
      final preview = includePreview
          ? _encodePreview(source, config.previewMaxSide)
          : Uint8List(0);
      return PreprocessedRetina(
        tensor: tensor,
        previewBytes: preview,
        previewWidth: preview.isEmpty ? 0 : config.previewMaxSide,
        previewHeight: preview.isEmpty ? 0 : config.previewMaxSide,
        metrics: core.metrics,
        preprocessingMicros: stopwatch.elapsedMicroseconds,
      );
    }

    final square = core.square;
    if (square == null) {
      // _analyzeCore reports noRetinalRegion/retinaTooSmall in metrics; the
      // only way to reach this branch is a caller that disabled validation.
      throw PreprocessingException(
        core.metrics.failureReason ??
            PreprocessingFailureReason.noRetinalRegion,
        _failureMessage(
          core.metrics.failureReason ??
              PreprocessingFailureReason.noRetinalRegion,
          core.metrics,
          source,
        ),
      );
    }

    final enhanced = config.applyBenGraham
        ? _benGrahamAtWorkingSize(
            square,
            sigma: config.blurSigma,
            maxWorkingSide: config.workingMaxSide,
          )
        : square;
    final tensor = _toNormalizedNhwc(enhanced, config);
    final preview = includePreview
        ? _encodePreview(enhanced, config.previewMaxSide)
        : Uint8List(0);

    return PreprocessedRetina(
      tensor: tensor,
      previewBytes: preview,
      previewWidth: preview.isEmpty ? 0 : config.previewMaxSide,
      previewHeight: preview.isEmpty ? 0 : config.previewMaxSide,
      metrics: core.metrics,
      preprocessingMicros: stopwatch.elapsedMicroseconds,
    );
  }

  /// Golden-parity tensor builder used by the legacy synchronous runner.
  ///
  /// Important: this intentionally skips exposure/focus validation. The
  /// calibrated quality gate runs *before* model prediction in the
  /// orchestrator; duplicating (possibly stricter) thresholds here would
  /// silently break the golden fixtures.
  ///
  /// Throws [ArgumentError] for fully dark frames or degenerate crops, matching
  /// the historical runner contract.
  static Float32List toModelTensor(
    img.Image source, {
    RetinalPreprocessConfig config = RetinalPreprocessConfig.ordinal512ImageNet,
  }) {
    if (!config.cropToRetina) return _rawTensor(source, config);

    final packed = toRgb255(source);
    final scan = _scan(packed, source.width, source.height);
    if (!scan.hasRegion) {
      throw ArgumentError(
        'Retinal crop degenerate (${source.width}x${source.height}): '
        'no pixel above luma ${config.borderLumaThreshold}.',
      );
    }
    final radius = math.min(scan.cropWidth, scan.cropHeight) ~/ 2;
    if (radius < config.minCropRadius) {
      throw ArgumentError(
        'Retinal crop degenerate (${source.width}x${source.height}): '
        'disc radius $radius < ${config.minCropRadius}.',
      );
    }

    final square = _cropFromPacked(
      packed,
      source.width,
      source.height,
      scan,
      radius,
    );
    final enhanced = config.applyBenGraham
        ? _benGrahamAtWorkingSize(
            square,
            sigma: config.blurSigma,
            maxWorkingSide: config.workingMaxSide,
          )
        : square;
    return _toNormalizedNhwc(enhanced, config);
  }

  /// Dark-border crop then circular mask crop, at native resolution.
  ///
  /// Returns null when the frame has no retinal region or the disc is smaller
  /// than [minRadius]. Retained as a public primitive for tests.
  static img.Image? cropToRetinalSquare(
    img.Image source, {
    double borderLumaThreshold = 7.0,
    int minRadius = 16,
  }) {
    final packed = toRgb255(source);
    final scan = _scan(
      packed,
      source.width,
      source.height,
      lumaThreshold: borderLumaThreshold,
    );
    if (!scan.hasRegion) return null;
    final radius = math.min(scan.cropWidth, scan.cropHeight) ~/ 2;
    if (radius < minRadius) return null;
    return _cropFromPacked(packed, source.width, source.height, scan, radius);
  }

  /// Wraps a worker-provided packed RGB buffer without decoding a JPEG.
  ///
  /// The returned image aliases [rgb] (no copy); the caller must keep the
  /// buffer alive for the duration of preprocessing, which it does.
  static img.Image rgbPackedToImage(Uint8List rgb, int width, int height) {
    if (width <= 0 || height <= 0) {
      throw PreprocessingException(
        PreprocessingFailureReason.invalidDimensions,
        'Invalid RGB dimensions ${width}x$height.',
      );
    }
    final required = width * height * 3;
    if (rgb.length < required) {
      throw PreprocessingException(
        PreprocessingFailureReason.invalidDimensions,
        'Packed RGB buffer is ${rgb.length} bytes; '
        '${width}x$height needs $required.',
      );
    }
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      bytesOffset: rgb.offsetInBytes,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );
  }

  /// Raw RGB `[0,255]` float32 NHWC tensor for graphs that normalise
  /// internally (legacy 224px Keras artifact). Uses bicubic resize, matching
  /// the server's PIL parity path.
  static Float32List toRawRgbNhwc(img.Image source, {int size = 224}) {
    if (size <= 0) {
      throw PreprocessingException(
        PreprocessingFailureReason.invalidDimensions,
        'Invalid output size $size.',
      );
    }
    final resized = img.copyResize(
      source,
      width: size,
      height: size,
      interpolation: img.Interpolation.cubic,
    );
    final rgb = toRgb255(resized);
    final out = Float32List(size * size * 3);
    for (var i = 0; i < out.length; i++) {
      out[i] = rgb[i].toDouble();
    }
    return out;
  }

  /// Extracts packed RGB bytes through the package pixel iterator.
  ///
  /// The iterator is channel-order safe for any decoded format (RGBA, BGR,
  /// palette), unlike raw `Image.data` indexing.
  static Uint8List toRgb255(img.Image image) {
    final out = Uint8List(image.width * image.height * 3);
    var j = 0;
    for (final pixel in image) {
      out[j++] = pixel.r.toInt().clamp(0, 255);
      out[j++] = pixel.g.toInt().clamp(0, 255);
      out[j++] = pixel.b.toInt().clamp(0, 255);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Core analysis
  // ---------------------------------------------------------------------------

  static _Core _analyzeCore(img.Image source, RetinalPreprocessConfig config) {
    if (source.width <= 0 || source.height <= 0) {
      throw PreprocessingException(
        PreprocessingFailureReason.invalidDimensions,
        'Invalid image dimensions ${source.width}x${source.height}.',
      );
    }

    final packed = toRgb255(source);
    final scan = _scan(
      packed,
      source.width,
      source.height,
      lumaThreshold: config.borderLumaThreshold,
    );

    if (!scan.hasRegion) {
      return _Core(
        metrics: RetinalFundusMetrics(
          retinalAreaRatio: 0,
          meanLuma: 0,
          stdLuma: 0,
          sharpness: 0,
          cropSide: 0,
          failureReason: PreprocessingFailureReason.noRetinalRegion,
        ),
      );
    }

    final radius = math.min(scan.cropWidth, scan.cropHeight) ~/ 2;
    if (radius < config.minCropRadius) {
      return _Core(
        metrics: RetinalFundusMetrics(
          retinalAreaRatio: scan.retinalAreaRatio,
          meanLuma: scan.meanLuma,
          stdLuma: scan.stdLuma,
          sharpness: 0,
          cropSide: radius * 2,
          failureReason: PreprocessingFailureReason.retinaTooSmall,
        ),
      );
    }

    final square = _cropFromPacked(
      packed,
      source.width,
      source.height,
      scan,
      radius,
    );
    final sharpness = _laplacianVariance(square);

    final metrics = RetinalFundusMetrics(
      retinalAreaRatio: scan.retinalAreaRatio,
      meanLuma: scan.meanLuma,
      stdLuma: scan.stdLuma,
      sharpness: sharpness,
      cropSide: square.width,
      failureReason: _classify(scan, sharpness, config),
    );
    return _Core(metrics: metrics, square: square);
  }

  static PreprocessingFailureReason? _classify(
    _ScanData scan,
    double sharpness,
    RetinalPreprocessConfig config,
  ) {
    if (scan.retinalAreaRatio < config.minRetinalAreaRatio) {
      return PreprocessingFailureReason.notFundus;
    }
    if (scan.meanLuma < config.minMeanLuma) {
      return PreprocessingFailureReason.lowExposure;
    }
    if (scan.meanLuma > config.maxMeanLuma) {
      return PreprocessingFailureReason.overExposure;
    }
    if (scan.stdLuma < config.minLumaStdDev) {
      return PreprocessingFailureReason.lowContrast;
    }
    if (sharpness < config.minSharpness) {
      return PreprocessingFailureReason.outOfFocus;
    }
    return null;
  }

  static String _failureMessage(
    PreprocessingFailureReason reason,
    RetinalFundusMetrics metrics,
    img.Image source,
  ) {
    final size = '${source.width}x${source.height}';
    return switch (reason) {
      PreprocessingFailureReason.decodeFailed =>
        'Encoded image could not be decoded.',
      PreprocessingFailureReason.emptyImage => 'Image buffer is empty.',
      PreprocessingFailureReason.invalidDimensions =>
        'Invalid image dimensions ($size).',
      PreprocessingFailureReason.noRetinalRegion =>
        'No retinal region detected in $size frame (all pixels are black).',
      PreprocessingFailureReason.notFundus =>
        'Retinal area ${(metrics.retinalAreaRatio * 100).toStringAsFixed(1)}% '
            'is too small for a fundus capture.',
      PreprocessingFailureReason.lowExposure =>
        'Retinal mean luma ${metrics.meanLuma.toStringAsFixed(1)} is below the '
            'exposure floor.',
      PreprocessingFailureReason.overExposure =>
        'Retinal mean luma ${metrics.meanLuma.toStringAsFixed(1)} is above the '
            'exposure ceiling.',
      PreprocessingFailureReason.lowContrast =>
        'Retinal luma spread ${metrics.stdLuma.toStringAsFixed(1)} is too flat '
            'to contain structure.',
      PreprocessingFailureReason.outOfFocus =>
        'Focus score ${metrics.sharpness.toStringAsFixed(1)} indicates a '
            'defocused capture.',
      PreprocessingFailureReason.retinaTooSmall =>
        'Detected retinal disc side ${metrics.cropSide}px is below the model '
            'minimum.',
    };
  }

  /// Scans packed RGB once for the dark-border bounding box plus masked luma
  /// statistics. O(pixels), single pass, no allocations per pixel.
  static _ScanData _scan(
    Uint8List rgb,
    int width,
    int height, {
    double lumaThreshold = 7.0,
  }) {
    var minX = width, maxX = -1, minY = height, maxY = -1;
    var count = 0;
    var sum = 0.0;
    var sumSq = 0.0;

    for (var y = 0; y < height; y++) {
      final row = y * width * 3;
      for (var x = 0; x < width; x++) {
        final i = row + x * 3;
        final luma = 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
        if (luma > lumaThreshold) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
          count++;
          sum += luma;
          sumSq += luma * luma;
        }
      }
    }

    if (maxX < 0) {
      return _ScanData.empty(width, height);
    }
    final mean = sum / count;
    final variance = math.max(0.0, sumSq / count - mean * mean);
    return _ScanData(
      minX: minX,
      maxX: maxX,
      minY: minY,
      maxY: maxY,
      width: width,
      height: height,
      retinalPixelCount: count,
      meanLuma: mean,
      stdLuma: math.sqrt(variance),
    );
  }

  static img.Image _cropFromPacked(
    Uint8List src,
    int width,
    int height,
    _ScanData scan,
    int radius,
  ) {
    final cx = scan.cropWidth ~/ 2;
    final cy = scan.cropHeight ~/ 2;
    final outSide = radius * 2;
    final out = img.Image(width: outSide, height: outSide);
    final outData = Uint8List(outSide * outSide * 3);
    final r2 = radius * radius;

    for (var y = 0; y < outSide; y++) {
      final sy = cy - radius + y + scan.minY;
      for (var x = 0; x < outSide; x++) {
        final sx = cx - radius + x + scan.minX;
        final dx = x - radius;
        final dy = y - radius;
        final di = (y * outSide + x) * 3;
        if (dx * dx + dy * dy <= r2) {
          final si = (sy * width + sx) * 3;
          outData[di] = src[si];
          outData[di + 1] = src[si + 1];
          outData[di + 2] = src[si + 2];
        }
      }
    }
    _writeRgb(out, outData);
    return out;
  }

  // ---------------------------------------------------------------------------
  // Ben Graham
  // ---------------------------------------------------------------------------

  /// Ben Graham enhancement at working resolution.
  ///
  /// The reference blurs at native resolution. For frames larger than
  /// [maxWorkingSide] we area-resize first and scale sigma by
  /// `workingSide / nativeSide`, keeping the blur radius equivalent in
  /// normalised retinal coordinates. Measured on the clinical corpus: max
  /// score drift 0.059, 10/10 grade agreement.
  static img.Image _benGrahamAtWorkingSize(
    img.Image square, {
    required double sigma,
    required int maxWorkingSide,
  }) {
    final side = square.width;
    img.Image work = square;
    var effectiveSigma = sigma;
    if (side > maxWorkingSide) {
      work = img.copyResize(
        square,
        width: maxWorkingSide,
        height: maxWorkingSide,
        interpolation: img.Interpolation.average,
      );
      effectiveSigma = sigma * (work.width / side);
    }

    final src = toRgb255(work);
    final blur = toRgb255(_gaussianBlurExact(work, effectiveSigma));
    final pixels = work.width * work.height;
    final outRgb = Uint8List(pixels * 3);
    for (var i = 0; i < pixels; i++) {
      final j = i * 3;
      for (var c = 0; c < 3; c++) {
        final value = 4 * src[j + c] - 4 * blur[j + c] + 128;
        outRgb[j + c] = value.round().clamp(0, 255);
      }
    }
    final out = img.Image(width: work.width, height: work.height);
    _writeRgb(out, outRgb);
    return out;
  }

  /// Exact separable Gaussian over packed RGB with BORDER_REFLECT_101 edges.
  ///
  /// Horizontal pass into float accumulators, vertical pass into uint8.
  /// `ksize = 2 * round(3 * sigma) + 1`, matching OpenCV's `ksize = 0` rule.
  static img.Image _gaussianBlurExact(img.Image src, double sigma) {
    if (sigma <= 0) {
      throw ArgumentError.value(sigma, 'sigma', 'Must be > 0');
    }
    final width = src.width;
    final height = src.height;
    final srcRgb = toRgb255(src);

    final half = math.max(1, (sigma * 3).round());
    final ksize = 2 * half + 1;
    final kernel = List<double>.filled(ksize, 0);
    var kernelSum = 0.0;
    for (var i = -half; i <= half; i++) {
      final value = math.exp(-(i * i) / (2 * sigma * sigma));
      kernel[i + half] = value;
      kernelSum += value;
    }
    for (var i = 0; i < ksize; i++) {
      kernel[i] /= kernelSum;
    }

    final temp = List<double>.filled(width * height * 3, 0);
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < height; y++) {
        final row = y * width * 3;
        for (var x = 0; x < width; x++) {
          var acc = 0.0;
          for (var k = -half; k <= half; k++) {
            acc +=
                kernel[k + half] *
                srcRgb[row + _reflect101(width, x + k) * 3 + c];
          }
          temp[row + x * 3 + c] = acc;
        }
      }
    }

    final outRgb = Uint8List(width * height * 3);
    for (var c = 0; c < 3; c++) {
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          var acc = 0.0;
          for (var k = -half; k <= half; k++) {
            acc +=
                kernel[k + half] *
                temp[_reflect101(height, y + k) * width * 3 + x * 3 + c];
          }
          outRgb[(y * width + x) * 3 + c] = acc.round().clamp(0, 255);
        }
      }
    }

    final out = img.Image(width: width, height: height);
    _writeRgb(out, outRgb);
    return out;
  }

  /// BORDER_REFLECT_101: mirror about the edge pixel (-1 -> 1, w -> w-2).
  static int _reflect101(int length, int i) {
    if (i < 0) return -i;
    if (i >= length) return 2 * length - i - 2;
    return i;
  }

  // ---------------------------------------------------------------------------
  // Tensorisation
  // ---------------------------------------------------------------------------

  /// Area-weighted (OpenCV INTER_AREA) resize straight to normalised NHWC.
  ///
  /// Each source pixel is weighted by its fractional overlap with the
  /// destination cell; the package's `Interpolation.average` uses hard integer
  /// box boundaries that diverge from cv2 by up to ~0.6 normalised units at
  /// downscale edges. No intermediate uint8 image is allocated.
  static Float32List _toNormalizedNhwc(
    img.Image enhanced,
    RetinalPreprocessConfig config,
  ) {
    final size = config.outputSize;
    final srcWidth = enhanced.width;
    final srcHeight = enhanced.height;
    final src = toRgb255(enhanced);
    final out = Float32List(config.tensorElementCount);

    final mean = config.mean;
    final std = config.std;
    final normalization = config.normalization;
    final isRaw = normalization == RetinalTensorNormalization.rawRgb255;
    final isImageNet = normalization == RetinalTensorNormalization.imagenet;

    final xScale = srcWidth / size;
    final yScale = srcHeight / size;

    for (var oy = 0; oy < size; oy++) {
      final fy0 = oy * yScale;
      final fy1 = (oy + 1) * yScale;
      var iy0 = fy0.floor();
      var iy1 = fy1.ceil();
      if (iy1 == iy0) iy1++;
      iy0 = iy0.clamp(0, srcHeight - 1);
      iy1 = iy1.clamp(iy0 + 1, srcHeight);

      for (var ox = 0; ox < size; ox++) {
        final fx0 = ox * xScale;
        final fx1 = (ox + 1) * xScale;
        var ix0 = fx0.floor();
        var ix1 = fx1.ceil();
        if (ix1 == ix0) ix1++;
        ix0 = ix0.clamp(0, srcWidth - 1);
        ix1 = ix1.clamp(ix0 + 1, srcWidth);

        var accR = 0.0, accG = 0.0, accB = 0.0, weightSum = 0.0;
        for (var sy = iy0; sy < iy1; sy++) {
          final yOverlap =
              (sy + 1 < fy1 ? sy + 1 : fy1) - (sy > fy0 ? sy : fy0);
          if (yOverlap <= 0) continue;
          final rowBase = sy * srcWidth * 3;
          for (var sx = ix0; sx < ix1; sx++) {
            final xOverlap =
                (sx + 1 < fx1 ? sx + 1 : fx1) - (sx > fx0 ? sx : fx0);
            if (xOverlap <= 0) continue;
            final weight = xOverlap * yOverlap;
            final si = rowBase + sx * 3;
            accR += weight * src[si];
            accG += weight * src[si + 1];
            accB += weight * src[si + 2];
            weightSum += weight;
          }
        }

        final inv = 1.0 / weightSum;
        final oi = (oy * size + ox) * 3;
        final r = accR * inv;
        final g = accG * inv;
        final b = accB * inv;
        if (isRaw) {
          out[oi] = r;
          out[oi + 1] = g;
          out[oi + 2] = b;
        } else if (isImageNet) {
          out[oi] = (r / 255.0 - mean[0]) / std[0];
          out[oi + 1] = (g / 255.0 - mean[1]) / std[1];
          out[oi + 2] = (b / 255.0 - mean[2]) / std[2];
        } else {
          out[oi] = r / 255.0;
          out[oi + 1] = g / 255.0;
          out[oi + 2] = b / 255.0;
        }
      }
    }
    return out;
  }

  static Float32List _rawTensor(
    img.Image source,
    RetinalPreprocessConfig config,
  ) {
    return toRawRgbNhwc(source, size: config.outputSize);
  }

  /// Laplacian variance of the retinal square, a conservative focus signal.
  ///
  /// The square is area-resized to at most 384px first so the metric cost is
  /// bounded regardless of capture resolution. Values are in luma units
  /// squared; a featureless frame is near zero, a sharp fundus is in the
  /// tens-to-hundreds.
  ///
  /// The statistic is restricted to the inner 90% of the circular mask: the
  /// mask leaves pure-black corners, and the resulting hard disc edge would
  /// otherwise dominate the variance and make a completely flat frame look
  /// sharp.
  static double _laplacianVariance(img.Image square) {
    const maxSide = 384;
    img.Image work = square;
    if (square.width > maxSide || square.height > maxSide) {
      work = img.copyResize(
        square,
        width: maxSide,
        height: maxSide,
        interpolation: img.Interpolation.average,
      );
    }
    final width = work.width;
    final height = work.height;
    if (width < 5 || height < 5) return 0;

    final rgb = toRgb255(work);
    final gray = Float64List(width * height);
    for (var i = 0; i < gray.length; i++) {
      final j = i * 3;
      gray[i] = 0.299 * rgb[j] + 0.587 * rgb[j + 1] + 0.114 * rgb[j + 2];
    }

    final centerX = (width - 1) / 2.0;
    final centerY = (height - 1) / 2.0;
    final innerRadius = math.min(width, height) * 0.45;
    final innerRadiusSq = innerRadius * innerRadius;

    var sum = 0.0;
    var sumSq = 0.0;
    var count = 0;
    for (var y = 1; y < height - 1; y++) {
      final dy = y - centerY;
      final row = y * width;
      for (var x = 1; x < width - 1; x++) {
        final dx = x - centerX;
        if (dx * dx + dy * dy > innerRadiusSq) continue;
        final i = row + x;
        final laplacian =
            4 * gray[i] -
            gray[i - width] -
            gray[i + width] -
            gray[i - 1] -
            gray[i + 1];
        sum += laplacian;
        sumSq += laplacian * laplacian;
        count++;
      }
    }
    if (count == 0) return 0;
    final mean = sum / count;
    return math.max(0.0, sumSq / count - mean * mean);
  }

  static Uint8List _encodePreview(img.Image enhanced, int maxSide) {
    final resized = (enhanced.width == maxSide && enhanced.height == maxSide)
        ? enhanced
        : img.copyResize(
            enhanced,
            width: maxSide,
            height: maxSide,
            interpolation: img.Interpolation.average,
          );
    return img.encodePng(resized, level: 6);
  }

  static void _writeRgb(img.Image image, Uint8List rgb) {
    var j = 0;
    for (final pixel in image) {
      pixel.r = rgb[j++];
      pixel.g = rgb[j++];
      pixel.b = rgb[j++];
    }
  }
}

/// Structural metrics measured before enhancement.
class RetinalFundusMetrics {
  const RetinalFundusMetrics({
    required this.retinalAreaRatio,
    required this.meanLuma,
    required this.stdLuma,
    required this.sharpness,
    required this.cropSide,
    this.failureReason,
  });

  /// Retinal pixels (`luma > 7`) divided by the full frame area.
  final double retinalAreaRatio;

  /// Mean luma over retinal pixels, in `[0, 255]`.
  final double meanLuma;

  /// Luma standard deviation over retinal pixels.
  final double stdLuma;

  /// Laplacian variance of the retinal square (higher = sharper).
  final double sharpness;

  /// Side length of the circular-mask crop in source pixels (0 if no region).
  final int cropSide;

  /// Null when the frame passes the structural guard.
  final PreprocessingFailureReason? failureReason;

  bool get isUsable => failureReason == null;
}

/// Tensor + preview + metrics produced by [RetinalPreprocessor.prepareForModel].
class PreprocessedRetina {
  const PreprocessedRetina({
    required this.tensor,
    required this.previewBytes,
    required this.previewWidth,
    required this.previewHeight,
    required this.metrics,
    required this.preprocessingMicros,
  });

  /// NHWC float32 tensor, ready for `interpreter.getInputTensor(0)
  /// .asFloat32View()..setAll(...)`.
  final Float32List tensor;

  /// PNG of the enhanced crop, or an empty buffer when not requested.
  final Uint8List previewBytes;
  final int previewWidth;
  final int previewHeight;

  final RetinalFundusMetrics metrics;

  /// Time spent in decode-adjacent preprocessing (excludes JPEG decode when
  /// the caller decoded first; the worker measures the full phase separately).
  final int preprocessingMicros;
}

class _ScanData {
  const _ScanData({
    required this.minX,
    required this.maxX,
    required this.minY,
    required this.maxY,
    required this.width,
    required this.height,
    required this.retinalPixelCount,
    required this.meanLuma,
    required this.stdLuma,
  });

  factory _ScanData.empty(int width, int height) => _ScanData(
    minX: 0,
    maxX: -1,
    minY: 0,
    maxY: -1,
    width: width,
    height: height,
    retinalPixelCount: 0,
    meanLuma: 0,
    stdLuma: 0,
  );

  final int minX;
  final int maxX;
  final int minY;
  final int maxY;
  final int width;
  final int height;
  final int retinalPixelCount;
  final double meanLuma;
  final double stdLuma;

  bool get hasRegion => maxX >= 0;

  int get cropWidth => maxX - minX + 1;
  int get cropHeight => maxY - minY + 1;

  double get retinalAreaRatio =>
      width == 0 || height == 0 ? 0 : retinalPixelCount / (width * height);
}

class _Core {
  const _Core({required this.metrics, this.square});

  final RetinalFundusMetrics metrics;
  final img.Image? square;
}
