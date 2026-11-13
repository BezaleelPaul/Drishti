import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/models/retinal_markers.dart';

void main() {
  group('RetinalMarkers.fromJson', () {
    test('parses an available payload with dimensions and candidates', () {
      final markers = RetinalMarkers.fromJson({
        'review_id': 'REV-8F3A21C0B4D7',
        'available': true,
        'reason': null,
        'source': 'classical_cv_segmentation',
        'width': 2240,
        'height': 1680,
        'optic_disc': {'x': 412, 'y': 862, 'r': 168},
        'fovea': {'x': 1385, 'y': 805},
        'ma_candidates': [
          {'x': 1204, 'y': 933, 'r': 5},
          {'x': 1180, 'y': 901, 'r': 4},
        ],
      });

      expect(markers.reviewId, 'REV-8F3A21C0B4D7');
      expect(markers.available, isTrue);
      expect(markers.reason, isNull);
      expect(markers.source, 'classical_cv_segmentation');
      expect(markers.width, 2240);
      expect(markers.height, 1680);
      expect(markers.opticDisc, isNotNull);
      expect(markers.opticDisc!.x, 412);
      expect(markers.opticDisc!.y, 862);
      expect(markers.opticDisc!.r, 168);
      expect(markers.fovea, isNotNull);
      expect(markers.fovea!.x, 1385);
      expect(markers.fovea!.y, 805);
      expect(markers.maCandidates, hasLength(2));
      expect(markers.maCandidates[0].x, 1204);
      expect(markers.maCandidates[0].y, 933);
      expect(markers.maCandidates[0].r, 5);
      expect(markers.maCandidates[1].r, 4);
    });

    test('parses an unavailable payload without marker coordinates', () {
      final markers = RetinalMarkers.fromJson({
        'review_id': 'REV-8F3A21C0B4D7',
        'available': false,
        'reason': 'Original fundus image could not be retrieved',
        'source': 'classical_cv_segmentation',
        'width': 0,
        'height': 0,
        'optic_disc': null,
        'fovea': null,
        'ma_candidates': [],
      });

      expect(markers.reviewId, 'REV-8F3A21C0B4D7');
      expect(markers.available, isFalse);
      expect(markers.reason, 'Original fundus image could not be retrieved');
      expect(markers.width, 0);
      expect(markers.height, 0);
      expect(markers.opticDisc, isNull);
      expect(markers.fovea, isNull);
      expect(markers.maCandidates, isEmpty);
    });

    test('keeps empty candidates distinguishable from unavailable', () {
      final emptyButAvailable = RetinalMarkers.fromJson({
        'review_id': 'REV-EMPTY',
        'available': true,
        'reason': 'No microaneurysm candidates found',
        'source': 'classical_cv_segmentation',
        'width': 2240,
        'height': 1680,
        'optic_disc': {'x': 412, 'y': 862, 'r': 168},
        'fovea': {'x': 1385, 'y': 805},
        'ma_candidates': [],
      });
      final unavailable = RetinalMarkers.fromJson({
        'review_id': 'REV-EMPTY',
        'available': false,
        'reason': 'Segmentation failed',
        'source': 'classical_cv_segmentation',
        'width': 0,
        'height': 0,
        'optic_disc': null,
        'fovea': null,
        'ma_candidates': [],
      });

      expect(emptyButAvailable.available, isTrue);
      expect(emptyButAvailable.maCandidates, isEmpty);
      expect(emptyButAvailable.opticDisc, isNotNull);
      expect(unavailable.available, isFalse);
      expect(unavailable.maCandidates, isEmpty);
      expect(unavailable.opticDisc, isNull);
      expect(emptyButAvailable.available, isNot(unavailable.available));
    });

    test('treats a missing ma_candidates key as an explicitly empty list', () {
      final markers = RetinalMarkers.fromJson({
        'review_id': 'REV-NOKEY',
        'available': true,
        'source': 'classical_cv_segmentation',
        'width': 100,
        'height': 100,
      });

      expect(markers.maCandidates, isNotNull);
      expect(markers.maCandidates, isEmpty);
    });

    test('rejects a source other than classical CV segmentation', () {
      expect(
        () => RetinalMarkers.fromJson({
          'review_id': 'REV-DISHONEST',
          'available': true,
          'source': 'model_attention',
          'width': 100,
          'height': 100,
          'ma_candidates': [],
        }),
        throwsFormatException,
      );
    });

    test('constructs with the pinned classical CV source', () {
      final markers = RetinalMarkers(
        reviewId: 'REV-DIRECT',
        available: false,
        reason: 'no image',
      );

      expect(markers.source, 'classical_cv_segmentation');
      expect(markers.width, 0);
      expect(markers.height, 0);
      expect(markers.maCandidates, isEmpty);
    });
  });
}
