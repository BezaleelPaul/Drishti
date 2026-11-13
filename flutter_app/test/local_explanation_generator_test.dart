import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:drishti/services/ml/pipeline/local_explanation_generator.dart';

Uint8List _syntheticFundus({required int size}) {
  final image = img.Image(width: size, height: size);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  final centre = size ~/ 2;
  // Circular retina
  img.fillCircle(
    image,
    x: centre,
    y: centre,
    radius: (size * 0.45).round(),
    color: img.ColorRgb8(120, 30, 30),
  );
  // Optic disc
  img.fillCircle(
    image,
    x: (size * 0.35).round(),
    y: centre,
    radius: (size * 0.08).round(),
    color: img.ColorRgb8(220, 190, 120),
  );
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('LocalExplanationGenerator (100% on-device explainability)', () {
    test('generates valid PNG overlay and clinical rationale for Grade 0', () {
      final bytes = _syntheticFundus(size: 256);
      final req = LocalExplanationRequest(
        imageBytes: bytes,
        predictedGrade: 0,
        confidence: 0.94,
        probabilities: [0.94, 0.04, 0.01, 0.005, 0.005],
      );

      final res = generateLocalExplanationWorker(req);
      expect(res.overlayBytes, isNotEmpty);
      final decodedOverlay = img.decodePng(res.overlayBytes);
      expect(decodedOverlay, isNotNull);
      expect(decodedOverlay!.width, inInclusiveRange(16, 384));
      expect(decodedOverlay.height, inInclusiveRange(16, 384));

      expect(res.explanationSummary, contains('ICDRS Consensus: Healthy Retina'));
      expect(res.secondOpinionPrompt, contains('No Diabetic Retinopathy (Grade 0)'));
      expect(res.secondOpinionPrompt, contains('Clinical Verification Request'));
      expect(res.targetLayer, 'conv_head.saliency_cam');
    });

    test('generates focal activation rationale for Grade 2 (Moderate NPDR)', () {
      final bytes = _syntheticFundus(size: 256);
      final req = LocalExplanationRequest(
        imageBytes: bytes,
        predictedGrade: 2,
        confidence: 0.88,
        probabilities: [0.02, 0.05, 0.88, 0.03, 0.02],
      );

      final res = generateLocalExplanationWorker(req);
      expect(res.overlayBytes, isNotEmpty);
      expect(res.explanationSummary, contains('ICDRS Consensus: Moderate NPDR'));
      expect(res.secondOpinionPrompt, contains('Moderate Non-Proliferative DR (Grade 2)'));
      expect(res.secondOpinionPrompt, contains('88.0%'));
    });

    test('generates high-risk activation rationale for Grade 4 (PDR)', () {
      final bytes = _syntheticFundus(size: 256);
      final req = LocalExplanationRequest(
        imageBytes: bytes,
        predictedGrade: 4,
        confidence: 0.91,
      );

      final res = generateLocalExplanationWorker(req);
      expect(res.overlayBytes, isNotEmpty);
      expect(res.explanationSummary, contains('ICDRS Consensus: Proliferative DR'));
      expect(res.secondOpinionPrompt, contains('Proliferative Diabetic Retinopathy (Grade 4)'));
    });

    test('throws FormatException on undecodable image bytes', () {
      final req = LocalExplanationRequest(
        imageBytes: Uint8List.fromList([1, 2, 3, 4]),
        predictedGrade: 1,
      );
      expect(
        () => generateLocalExplanationWorker(req),
        throwsFormatException,
      );
    });
  });
}
