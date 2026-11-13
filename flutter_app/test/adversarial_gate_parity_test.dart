import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/services/ml/pipeline_schema.dart';
import 'package:netra_ai_mobile/services/ml/quality_gate.dart';

/// Red-team parity: every adversarial fixture the SERVER gate rejects must
/// also be rejected by the ON-DEVICE Dart gate (P2 parity contract).
void main() {
  final dir = Directory('../test_samples/03_adversarial_non_fundus');
  final gate = const QualityGateDart();

  test('on-device gate rejects all adversarial fixtures', () {
    expect(dir.existsSync(), isTrue);
    final files =
        dir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.toLowerCase().endsWith('.jpg') ||
                  f.path.toLowerCase().endsWith('.png') ||
                  f.path.toLowerCase().endsWith('.jpeg'),
            )
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final failures = <String>[];
    for (final f in files) {
      final canonical = decodeCanonicalRgb(f.readAsBytesSync());
      final res = gate.assess(
        canonical.bytes,
        canonical.width,
        canonical.height,
      );
      final rejected =
          res.errorCode == PipelineErrorCode.imgNotFundus ||
          res.errorCode == PipelineErrorCode.imgUntgradable;
      if (!rejected) {
        failures.add(
          '${f.uri.pathSegments.last}: PASSED as ${res.grade.name} '
          '(blur=${res.metrics.sharpnessScore.toStringAsFixed(1)}, '
          'bright=${res.metrics.meanBrightness.toStringAsFixed(1)}, '
          'contrast=${res.metrics.contrastScore.toStringAsFixed(1)}, '
          'fov=${res.metrics.fovRatio.toStringAsFixed(2)}, '
          'mlq=${res.metrics.mlQualityScore.toStringAsFixed(2)})',
        );
      }
    }
    for (final f in failures) {
      // ignore: avoid_print
      print('LEAKED: $f');
    }
    expect(
      failures,
      isEmpty,
      reason:
          '${failures.length}/${files.length} adversarial fixtures '
          'leaked through the on-device gate',
    );
  });
}
