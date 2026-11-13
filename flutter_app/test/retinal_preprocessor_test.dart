import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/services/ml/pipeline/pipeline_exceptions.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/retinal_preprocess_config.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/retinal_preprocessor.dart';

/// Synthetic 256px fundus: a textured disc on a black border.
img.Image fundusFrame({int size = 256}) {
  final image = img.Image(width: size, height: size);
  final center = (size - 1) / 2.0;
  final radius = size * 0.42;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - center;
      final dy = y - center;
      if (dx * dx + dy * dy > radius * radius) continue;
      final checker = ((x ~/ 4) + (y ~/ 4)) % 2 == 0;
      final v = checker ? 110 : 150;
      image.setPixelRgb(x, y, v, (v ~/ 2) + 40, 70);
    }
  }
  return image;
}

img.Image solidFrame(int r, int g, int b, {int size = 64}) {
  final image = img.Image(width: size, height: size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

RetinalPreprocessConfig tinyConfig({
  RetinalTensorNormalization normalization =
      RetinalTensorNormalization.imagenet,
}) {
  return RetinalPreprocessConfig(
    outputSize: 4,
    blurSigma: 0,
    applyBenGraham: false,
    workingMaxSide: 64,
    normalization: normalization,
  );
}

void main() {
  group('tensor contract', () {
    test('ordinal tensor is NHWC float32 with 512x512x3 elements', () {
      final image = fundusFrame();
      final tensor = RetinalPreprocessor.toModelTensor(image);
      expect(tensor.length, 512 * 512 * 3);
      expect(
        tensor.length,
        RetinalPreprocessConfig.ordinal512ImageNet.tensorElementCount,
      );
      expect(
        RetinalPreprocessConfig.ordinal512ImageNet.tensorByteLength,
        tensor.length * 4,
      );
      for (var i = 0; i < 3000; i++) {
        expect(tensor[i].isFinite, isTrue);
      }
    });

    test('toModelTensor is deterministic across calls', () {
      final image = fundusFrame(size: 192);
      final a = RetinalPreprocessor.toModelTensor(image);
      final b = RetinalPreprocessor.toModelTensor(image);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i += 997) {
        expect(a[i], b[i]);
      }
    });

    test('prepareForModel(validate: false) matches toModelTensor', () {
      final image = fundusFrame(size: 192);
      final direct = RetinalPreprocessor.toModelTensor(image);
      final prepared = RetinalPreprocessor.prepareForModel(
        image,
        validate: false,
      );
      expect(prepared.tensor.length, direct.length);
      for (var i = 0; i < direct.length; i += 499) {
        expect(prepared.tensor[i], closeTo(direct[i], 1e-6));
      }
    });

    test('ImageNet normalisation uses (p/255 - mean)/std per channel', () {
      // Solid (200,100,50): every source pixel maps to the same output cell,
      // so the expected values are exact.
      final prepared = RetinalPreprocessor.prepareForModel(
        solidFrame(200, 100, 50),
        config: tinyConfig(),
        validate: false,
      );
      final t = prepared.tensor;
      expect(t.length, 4 * 4 * 3);
      final expectedR = (200 / 255.0 - 0.485) / 0.229;
      final expectedG = (100 / 255.0 - 0.456) / 0.224;
      final expectedB = (50 / 255.0 - 0.406) / 0.225;
      // Mask corners are black by design; only the centre 2x2 cells of a 4x4
      // output are fully inside the disc.
      for (final i in const [5, 6, 9, 10]) {
        expect(t[i * 3], closeTo(expectedR, 1e-5));
        expect(t[i * 3 + 1], closeTo(expectedG, 1e-5));
        expect(t[i * 3 + 2], closeTo(expectedB, 1e-5));
      }
    });

    test('unit normalisation keeps values in [0,1]', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        solidFrame(200, 100, 50),
        config: tinyConfig(normalization: RetinalTensorNormalization.unit),
        validate: false,
      );
      // Output pixel (1,1) lies inside the circular mask.
      const i = 5 * 3;
      expect(prepared.tensor[i], closeTo(200 / 255.0, 1e-5));
      expect(prepared.tensor[i + 1], closeTo(100 / 255.0, 1e-5));
      expect(prepared.tensor[i + 2], closeTo(50 / 255.0, 1e-5));
    });

    test('rawRgb255 normalisation keeps 8-bit values', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        solidFrame(200, 100, 50),
        config: tinyConfig(normalization: RetinalTensorNormalization.rawRgb255),
        validate: false,
      );
      const i = 5 * 3;
      expect(prepared.tensor[i], closeTo(200, 1e-4));
      expect(prepared.tensor[i + 1], closeTo(100, 1e-4));
      expect(prepared.tensor[i + 2], closeTo(50, 1e-4));
    });

    test('fiveClass224Raw resizes the whole frame to 224x224 raw RGB', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        fundusFrame(size: 256),
        config: RetinalPreprocessConfig.fiveClass224Raw,
        validate: false,
      );
      expect(prepared.tensor.length, 224 * 224 * 3);
      for (var i = 0; i < 500; i++) {
        expect(prepared.tensor[i], inInclusiveRange(0, 255));
      }
    });

    test('toRawRgbNhwc uses the legacy bicubic contract', () {
      final tensor = RetinalPreprocessor.toRawRgbNhwc(
        solidFrame(10, 20, 30),
        size: 8,
      );
      expect(tensor.length, 8 * 8 * 3);
      expect(tensor[0], closeTo(10, 1));
      expect(tensor[1], closeTo(20, 1));
      expect(tensor[2], closeTo(30, 1));
    });
  });

  group('crop + guard', () {
    test('fully black image reports noRetinalRegion without throwing', () {
      final metrics = RetinalPreprocessor.inspect(
        img.Image(width: 64, height: 64),
      );
      expect(metrics.isUsable, isFalse);
      expect(metrics.failureReason, PreprocessingFailureReason.noRetinalRegion);
    });

    test('tiny bright spot reports retinaTooSmall', () {
      final image = img.Image(width: 64, height: 64);
      for (var y = 28; y < 36; y++) {
        for (var x = 28; x < 36; x++) {
          image.setPixelRgb(x, y, 200, 200, 200);
        }
      }
      final metrics = RetinalPreprocessor.inspect(image);
      expect(metrics.failureReason, PreprocessingFailureReason.retinaTooSmall);
    });

    test('solid frame reports lowContrast', () {
      final metrics = RetinalPreprocessor.inspect(solidFrame(120, 120, 120));
      expect(metrics.failureReason, PreprocessingFailureReason.lowContrast);
    });

    test('very dark textured frame reports lowExposure', () {
      final image = img.Image(width: 64, height: 64);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          final v = (x + y) % 2 == 0 ? 2 : 8;
          image.setPixelRgb(x, y, v, v, v);
        }
      }
      final metrics = RetinalPreprocessor.inspect(image);
      expect(metrics.failureReason, PreprocessingFailureReason.lowExposure);
    });

    test('blown-out frame reports overExposure', () {
      final metrics = RetinalPreprocessor.inspect(solidFrame(250, 250, 250));
      expect(metrics.failureReason, PreprocessingFailureReason.overExposure);
    });

    test('valid synthetic fundus passes the structural guard', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        fundusFrame(),
        config: RetinalPreprocessConfig.ordinal512ImageNet,
      );
      expect(prepared.metrics.failureReason, isNull);
      expect(prepared.metrics.retinalAreaRatio, greaterThan(0.04));
      expect(prepared.metrics.meanLuma, greaterThan(12));
      expect(prepared.metrics.sharpness, greaterThan(6));
      expect(prepared.metrics.cropSide, greaterThan(100));
    });

    test('validate: false still returns a tensor for a solid frame', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        solidFrame(120, 120, 120),
        validate: false,
      );
      expect(prepared.tensor.length, 512 * 512 * 3);
    });

    test('toModelTensor throws ArgumentError on degenerate frames', () {
      expect(
        () => RetinalPreprocessor.toModelTensor(img.Image(width: 4, height: 4)),
        throwsArgumentError,
      );
      expect(
        () =>
            RetinalPreprocessor.toModelTensor(img.Image(width: 64, height: 64)),
        throwsArgumentError,
      );
    });

    test('prepareForModel throws typed PreprocessingException', () {
      expect(
        () => RetinalPreprocessor.prepareForModel(
          img.Image(width: 64, height: 64),
        ),
        throwsA(
          isA<PreprocessingException>().having(
            (e) => e.reason,
            'reason',
            PreprocessingFailureReason.noRetinalRegion,
          ),
        ),
      );
    });
  });

  group('preview + packed RGB', () {
    test('preview is a decodeable 512x512 PNG', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        fundusFrame(size: 192),
        validate: false,
        includePreview: true,
      );
      expect(prepared.previewBytes, isNotEmpty);
      expect(prepared.previewWidth, 512);
      expect(prepared.previewHeight, 512);
      final decoded = img.decodePng(prepared.previewBytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, 512);
      expect(decoded.height, 512);
    });

    test('preview is omitted when not requested', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        fundusFrame(size: 128),
        validate: false,
      );
      expect(prepared.previewBytes, isEmpty);
      expect(prepared.previewWidth, 0);
      expect(prepared.previewHeight, 0);
    });

    test('rgbPackedToImage round-trips channel order and offset', () {
      final packed = Uint8List.fromList([255, 0, 0, 0, 255, 0]);
      final image = RetinalPreprocessor.rgbPackedToImage(packed, 2, 1);
      expect(image.width, 2);
      expect(image.height, 1);
      final first = image.getPixel(0, 0);
      final second = image.getPixel(1, 0);
      expect([first.r, first.g, first.b], [255, 0, 0]);
      expect([second.r, second.g, second.b], [0, 255, 0]);
    });

    test('rgbPackedToImage rejects truncated buffers', () {
      expect(
        () => RetinalPreprocessor.rgbPackedToImage(Uint8List(5), 2, 1),
        throwsA(isA<PreprocessingException>()),
      );
    });
  });

  group('area-weighted resize', () {
    test('downscale preserves a constant field exactly', () {
      final prepared = RetinalPreprocessor.prepareForModel(
        solidFrame(10, 20, 30, size: 128),
        config: RetinalPreprocessConfig(
          outputSize: 16,
          blurSigma: 0,
          applyBenGraham: false,
          normalization: RetinalTensorNormalization.rawRgb255,
        ),
        validate: false,
      );
      for (var y = 6; y < 10; y++) {
        for (var x = 6; x < 10; x++) {
          final i = (y * 16 + x) * 3;
          expect(prepared.tensor[i], closeTo(10, 1e-4));
          expect(prepared.tensor[i + 1], closeTo(20, 1e-4));
          expect(prepared.tensor[i + 2], closeTo(30, 1e-4));
        }
      }
    });

    test('upscale output stays inside the source dynamic range', () {
      final image = img.Image(width: 32, height: 32);
      for (var y = 0; y < 32; y++) {
        for (var x = 0; x < 32; x++) {
          image.setPixelRgb(x, y, x * 8, y * 8, 128);
        }
      }
      final prepared = RetinalPreprocessor.prepareForModel(
        image,
        config: RetinalPreprocessConfig(
          outputSize: 64,
          blurSigma: 0,
          applyBenGraham: false,
          normalization: RetinalTensorNormalization.rawRgb255,
        ),
        validate: false,
      );
      for (var i = 0; i < prepared.tensor.length; i++) {
        expect(prepared.tensor[i], inInclusiveRange(0, 255));
      }
    });
  });

  group('geometry', () {
    test('circular crop disc is inscribed in the bright bounding box', () {
      final image = img.Image(width: 100, height: 80);
      for (var y = 20; y < 60; y++) {
        for (var x = 10; x < 90; x++) {
          image.setPixelRgb(x, y, 180, 180, 180);
        }
      }
      final square = RetinalPreprocessor.cropToRetinalSquare(image);
      expect(square, isNotNull);
      // bbox 80x40 -> radius 20 -> 40x40 crop.
      expect(square!.width, 40);
      expect(square.height, 40);
    });

    test('crop returns null for a fully dark frame', () {
      expect(
        RetinalPreprocessor.cropToRetinalSquare(
          img.Image(width: 64, height: 64),
        ),
        isNull,
      );
    });

    test('sharpness is higher for texture than for a flat field', () {
      final flat = RetinalPreprocessor.inspect(solidFrame(120, 120, 120));
      final textured = RetinalPreprocessor.inspect(fundusFrame(size: 192));
      expect(textured.sharpness, greaterThan(flat.sharpness));
      expect(math.max(textured.sharpness, 0), greaterThan(6));
    });
  });
}
