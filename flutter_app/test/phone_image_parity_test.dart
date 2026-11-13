import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/quality_gate.dart';

/// Reproduces the user's field report: random phone images must be
/// rejected by the on-device gate (server rejects all of them).
void main() {
  final dir = Directory('../test_samples/phone_random');
  final gate = const QualityGateDart();

  test('on-device gate rejects random phone images (server parity)', () {
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.toLowerCase().endsWith('.jpg') ||
                  f.path.toLowerCase().endsWith('.png'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    expect(files, isNotEmpty);
    for (final f in files) {
      var rejected = false;
      String grade = 'BAD';
      String code = 'none';
      double blur = -1, bright = -1, contrast = -1, fov = -1, mlq = -1;
      try {
        final canonical = decodeCanonicalRgb(f.readAsBytesSync());
        final res = gate.assess(
          canonical.bytes,
          canonical.width,
          canonical.height,
        );
        grade = res.grade.name;
        code = res.errorCode?.code ?? 'none';
        rejected =
            code == 'IMG_NOT_FUNDUS' ||
            code == 'IMG_UNGRADABLE' ||
            code == 'IMG_INVALID';
        blur = res.metrics.sharpnessScore;
        bright = res.metrics.meanBrightness;
        contrast = res.metrics.contrastScore;
        fov = res.metrics.fovRatio;
        mlq = res.metrics.mlQualityScore;
      } on FormatException {
        // Python parity: undecodable input => IMG_INVALID (fail closed).
        rejected = true;
        code = 'IMG_INVALID';
      }
      // ignore: avoid_print
      print(
        'DART ${f.uri.pathSegments.last}: ${rejected ? "REJECT" : "LEAK"} '
        'grade=$grade code=$code '
        'blur=${blur.toStringAsFixed(1)} '
        'bright=${bright.toStringAsFixed(1)} '
        'contrast=${contrast.toStringAsFixed(1)} '
        'fov=${fov.toStringAsFixed(2)} '
        'mlq=${mlq.toStringAsFixed(2)}',
      );
      expect(
        rejected,
        isTrue,
        reason: '${f.path} leaked through the on-device gate',
      );
    }
  });
}
