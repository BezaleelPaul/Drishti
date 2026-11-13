import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/models/screening_models.dart';
import 'package:netra_ai_mobile/widgets/review/gradcam_explanation_card.dart';

ScreeningAnalysisModel analysis({String? gradcamUrl, String? backend}) =>
    ScreeningAnalysisModel(
      screeningId: 'SCR-TEST-1',
      patientId: 'P-TEST-1',
      eyeSide: 'Right',
      cameraProfile: 'Remidio FOP (Smartphone Handheld)',
      qualityGrade: 'A',
      qualityScore: 0.92,
      qualityPassed: true,
      rejectionReasons: const [],
      drGrade: 2,
      drLabel: 'Moderate NPDR',
      predictionScore: 0.87,
      isReferable: true,
      requiresHumanReview: false,
      originalImageUrl: '',
      gradcamOverlayUrl: gradcamUrl,
      gradcamTargetLayer: gradcamUrl == null ? null : 'block_5_conv_3',
      modelBackend: backend ?? 'tflite-fp32',
      actionRecommendation: 'Refer',
      plainLanguageAdvice: 'Refer to an eye doctor.',
      smsReferralSlip:
          'ELYTRIVA: Moderate NPDR (Grade 2). Refer. Screening:SCR-TEST-1',
    );

Uint8List _png() {
  final image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(200, 60, 60));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  testWidgets('no gradcam URL renders the explicit unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradcamExplanationCard(analysis: analysis())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explanation unavailable'), findsOneWidget);
    expect(find.text('Model attention (Grad-CAM++)'), findsNothing);
  });

  testWidgets('on-device result explains that no attention data exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: GradcamExplanationCard(analysis: analysis())),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('graded on-device'), findsOneWidget);
  });

  testWidgets('server result without a heatmap states the honesty rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(analysis: analysis(backend: 'keras')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('did not generate'), findsOneWidget);
  });

  testWidgets('failed gradcam fetch renders the unavailable state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Explanation unavailable'), findsOneWidget);
    expect(find.text('Model attention (Grad-CAM++)'), findsNothing);
  });

  testWidgets('successful gradcam fetch renders the attention overlay card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => _png(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Model attention (Grad-CAM++)'), findsOneWidget);
    expect(find.text('Layer: block_5_conv_3'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('Explanation unavailable'), findsNothing);
  });

  testWidgets('available card carries the advisory-not-diagnosis disclaimer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GradcamExplanationCard(
            analysis: analysis(gradcamUrl: '/results/SCR-TEST-1/g.png'),
            fetcher: (_) async => _png(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Advisory'), findsOneWidget);
  });
}
