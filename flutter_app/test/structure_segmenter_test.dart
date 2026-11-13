import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/models/retinal_markers.dart';
import 'package:netra_ai_mobile/services/ml/pipeline/structure_segmenter.dart';

/// Synthetic fundus: dark-red circular retina on black background, a bright
/// yellowish optic-disc blob left of centre, and three small dark dots
/// (microaneurysm stand-ins) right of centre.
img.Image _fundus({required int size}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  final centre = size ~/ 2;
  final retinaR = (size * 0.45).round();
  // Retina: dark red disc.
  img.fillCircle(
    image,
    x: centre,
    y: centre,
    radius: retinaR,
    color: img.ColorRgb8(120, 30, 30),
  );
  // Optic disc: bright yellowish blob at 35% width.
  final odX = (size * 0.35).round();
  final odY = centre;
  img.fillCircle(
    image,
    x: odX,
    y: odY,
    radius: (size * 0.08).round(),
    color: img.ColorRgb8(220, 190, 120),
  );
  // Dark lesion dots at 65% width — sized like real microaneurysms (a few
  // pixels at 512, inside the detector's 3..65·scale² area window).
  for (final dy in [-size ~/ 8, 0, size ~/ 8]) {
    img.fillCircle(
      image,
      x: (size * 0.65).round(),
      y: centre + dy,
      radius: size >= 512 ? 3 : 2,
      color: img.ColorRgb8(30, 10, 10),
    );
  }
  return image;
}

Uint8List _encode(img.Image image) => Uint8List.fromList(img.encodePng(image));

void main() {
  test('finds optic disc, fovea estimate and lesion candidates in-bounds', () {
    final markers = computeRetinalMarkers(_encode(_fundus(size: 512)));

    expect(markers.available, isTrue, reason: markers.reason);
    expect(markers.width, 512);
    expect(markers.height, 512);
    expect(markers.source, RetinalMarkers.classicalCvSource);

    final od = markers.opticDisc!;
    expect(od.x, inInclusiveRange(0, 512));
    expect(od.y, inInclusiveRange(0, 512));
    // Disc blob sits at x=0.35*512=179, y=256.
    expect(od.x, closeTo(179, 40));
    expect(od.y, closeTo(256, 40));
    expect(od.r, greaterThan(10));

    // Fovea estimate is temporal to the OD (OD on the left half -> fovea
    // shifts right) and pulled toward the vertical centre.
    final fovea = markers.fovea!;
    expect(fovea.x, greaterThan(od.x));
    expect(fovea.y, inInclusiveRange(0, 512));

    // The three dark dots should appear as candidates near x≈333.
    expect(markers.maCandidates, isNotEmpty);
    for (final c in markers.maCandidates) {
      expect(c.x, inInclusiveRange(0, 512));
      expect(c.y, inInclusiveRange(0, 512));
      expect(c.r, greaterThanOrEqualTo(3));
    }
    final nearDots = markers.maCandidates
        .where((c) => (c.x - 333).abs() < 80 && (c.y - 256).abs() < 90)
        .length;
    expect(nearDots, greaterThanOrEqualTo(1));
  });

  test(
    'reports available with zero candidates on a uniform retina (healthy)',
    () {
      final image = img.Image(width: 128, height: 128);
      img.fill(image, color: img.ColorRgb8(120, 40, 40));
      final markers = computeRetinalMarkers(_encode(image));

      expect(markers.available, isTrue);
      expect(markers.maCandidates, isEmpty);
    },
  );

  test('degrades to unavailable (no retinal region) on a black frame', () {
    final image = img.Image(width: 64, height: 64);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));
    final markers = computeRetinalMarkers(_encode(image));

    expect(markers.available, isFalse);
    expect(markers.reason, isNotNull);
    expect(markers.opticDisc, isNull);
    expect(markers.maCandidates, isEmpty);
  });

  test('degrades to unavailable on undecodable bytes', () {
    final markers = computeRetinalMarkers(Uint8List.fromList([1, 2, 3, 4]));

    expect(markers.available, isFalse);
    expect(markers.reason, isNotNull);
  });

  test('markers carry coordinates in the original pixel space', () {
    // Source 2048px frame -> working 384px; coordinates must come back in
    // original space (disc centre ≈ 0.35 * 2048 = 717).
    final markers = computeRetinalMarkers(_encode(_fundus(size: 2048)));

    expect(markers.available, isTrue);
    expect(markers.width, 2048);
    expect(markers.height, 2048);
    final od = markers.opticDisc!;
    expect(od.x, closeTo(0.35 * 2048, 0.11 * 2048));
    expect(od.y, closeTo(0.5 * 2048, 0.11 * 2048));
  });
}
