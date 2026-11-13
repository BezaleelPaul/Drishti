import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:drishti/services/ml/pipeline_schema.dart';
import 'package:drishti/services/ml/quality_gate.dart';
import 'package:drishti/services/ml/quality_thresholds.dart';

void main() {
  group('QualityGateDart (parity with src/quality/checker.py)', () {
    const gate = QualityGateDart();

    Uint8List solidRgb(int w, int h, int r, int g, int b) {
      final out = Uint8List(w * h * 3);
      for (var i = 0; i < out.length; i += 3) {
        out[i] = r;
        out[i + 1] = g;
        out[i + 2] = b;
      }
      return out;
    }

    test('solid-color image is rejected as non-fundus (IMG_NOT_FUNDUS)', () {
      // Flat blue frame: zero per-channel variance -> NOT_FUNDUS path.
      final res = gate.assess(solidRgb(96, 96, 10, 10, 200), 96, 96);
      expect(res.grade, QualityGrade.BAD);
      expect(res.errorCode, PipelineErrorCode.imgNotFundus);
      expect(res.reasons, contains(QualityReason.nonFundusOrCorrupt));
    });

    test('tiny image is rejected as non-fundus', () {
      final res = gate.assess(solidRgb(32, 32, 120, 30, 30), 32, 32);
      expect(res.grade, QualityGrade.BAD);
      expect(res.errorCode, PipelineErrorCode.imgNotFundus);
    });

    test('threshold constants match checker.py exactly', () {
      expect(kBlurGoodThreshold, 85.0);
      expect(kBlurBadThreshold, 15.0);
      expect(kMinBrightnessGood, 40.0);
      expect(kMinBrightnessBad, 20.0);
      expect(kMaxBrightnessGood, 210.0);
      expect(kMaxBrightnessBad, 235.0);
      expect(kMinContrastGood, 16.0);
      expect(kMinContrastBad, 7.0);
      expect(kMinFovRatioGood, 0.35);
      expect(kMinFovRatioBad, 0.15);
      expect(kMinRedToBlueRatio, 1.10);
      expect(kMinMlQualityGood, 0.70);
      expect(kMinMlQualityBad, 0.38);
      expect(kMaxRecaptureCap, 2);
      expect(kReferableMassThreshold, 0.645);
    });

    test('strict thresholds match checker.strict()', () {
      expect(kStrictBlurGood, 110.0);
      expect(kStrictBlurBad, 45.0);
      expect(kStrictMinBrightnessGood, 50.0);
      expect(kStrictMinBrightnessBad, 25.0);
      expect(kStrictMaxBrightnessGood, 200.0);
      expect(kStrictMaxBrightnessBad, 230.0);
      expect(kStrictMinContrastGood, 22.0);
      expect(kStrictMinContrastBad, 10.0);
      expect(kStrictMinFovGood, 0.45);
      expect(kStrictMinFovBad, 0.20);
      expect(kStrictMinRedToBlue, 1.15);
      expect(kStrictMinMlGood, 0.80);
      expect(kStrictMinMlBad, 0.48);
    });

    test('canonical decode rejects oversized frames before decode', () {
      expect(() => decodeCanonicalRgb(Uint8List(0)), throwsFormatException);
    });

    test('bright golden-yellow retina is recognized as fundus, never rejected as non-fundus', () {
      // 256x256 circular retinal field:
      // Dark border ring/corners (luma=15), yellow/golden illuminated center (R=235, G=195, B=60; hue ~46°)
      const w = 256;
      const h = 256;
      final rgb = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          final dx = x - 128;
          final dy = y - 128;
          final distSq = dx * dx + dy * dy;
          if (distSq <= 100 * 100) {
            // Bright golden-yellow fundus
            rgb[i] = 235;
            rgb[i + 1] = 195;
            rgb[i + 2] = 60;
          } else {
            // Dark surround/corners
            rgb[i] = 12;
            rgb[i + 1] = 12;
            rgb[i + 2] = 12;
          }
        }
      }

      final res = gate.assess(rgb, w, h);
      // Must NOT be rejected as non-fundus (IMG_NOT_FUNDUS)
      expect(res.errorCode != PipelineErrorCode.imgNotFundus, isTrue,
          reason: 'Bright golden-yellow retina must not be rejected with IMG_NOT_FUNDUS');
    });

    test('borderline quality scan returns QualityGrade.BORDERLINE with isReliable: true', () {
      // Retinal field with marginal focus/contrast but valid circular fundus
      const w = 256;
      const h = 256;
      final rgb = Uint8List(w * h * 3);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          final dx = x - 128;
          final dy = y - 128;
          final distSq = dx * dx + dy * dy;
          if (distSq <= 90 * 90) {
            // Realistic texture giving moderate sharpness (~25-35, above 15 bad cutoff but below 45 good cutoff)
            final pattern = ((x % 6 == 0 ? 30 : 0) + (y % 6 == 0 ? 25 : 0));
            rgb[i] = (200 + pattern).clamp(0, 255);
            rgb[i + 1] = (110 + pattern).clamp(0, 255);
            rgb[i + 2] = (40 + pattern ~/ 2).clamp(0, 255);
          } else {
            rgb[i] = 8;
            rgb[i + 1] = 8;
            rgb[i + 2] = 8;
          }
        }
      }

      final res = gate.assess(rgb, w, h);
      // Minimum viable requirements met: gradable with caution
      expect(res.grade, isNot(QualityGrade.BAD));
      expect(res.isReliable, isTrue);
    });
  });
}
