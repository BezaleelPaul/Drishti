import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/widgets/orbit/orbit.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner_game.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner_state.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner_view.dart';

/// LAYOUT REGRESSION GUARD
///
/// The console/scanner surfaces are dense clinical UI on 320-360 dp phones.
/// These tests assert the STRUCTURAL invariant that made the previous
/// build unusable: no HUD text may ever share pixels with the animated
/// scanner artwork.
///
/// Invariants:
///  1. ScannerView: the canvas track and the telemetry band never overlap;
///     the status band and the canvas never overlap.
///  2. OrbitScanner: the orbit-rings layer and the status/technical chips
///     never overlap (the chips live BELOW the canvas in normal flow).
///  3. Chrome-less mode (splash): no console bands at all.
void main() {
  testWidgets(
    'ScannerView: status / canvas / telemetry tracks do not overlap',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 640,
                child: ScannerView(
                  state: ScannerAnimationState.scanning,
                  progress: 0.29,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      final status = tester.getRect(find.text('SCANNING RETINA'));
      final fov = tester.getRect(find.text('FOV: 45° | MACULA CENTERED'));
      final game = tester.getRect(find.byType(GameWidget<ScannerGame>));

      // The canvas track must sit strictly between the two console bands.
      expect(game.top, greaterThanOrEqualTo(status.bottom));
      expect(fov.top, greaterThanOrEqualTo(game.bottom));
      expect(status.overlaps(fov), isFalse);
      expect(status.overlaps(game), isFalse);
      expect(game.overlaps(fov), isFalse);
    },
  );

  testWidgets('ScannerView chrome-less mode renders no console bands', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 268,
              height: 268,
              child: ScannerView(
                state: ScannerAnimationState.scanning,
                progress: 0.29,
                showConsoleChrome: false,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('FOV: 45° | MACULA CENTERED'), findsNothing);
    expect(find.text('ORIGINAL CAPTURE • NO SYNTHETIC OVERLAY'), findsNothing);
    // The animation surface itself is still present.
    expect(find.byType(GameWidget<ScannerGame>), findsOneWidget);
  });

  testWidgets('OrbitScanner: chips sit below the ring layer, never over it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              child: OrbitScanner(
                state: OrbitScannerState.qualityCheck,
                technicalLabel: 'backend: tflite-fp32',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    final status = tester.getRect(find.text('OPTICS CALIBRATING'));
    final technical = tester.getRect(find.text('BACKEND: TFLITE-FP32'));

    // The ring layer is the CustomPaint that draws the orbit rings.
    final ringsFinder = find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is OrbitPainter,
    );
    final rings = tester.getRect(ringsFinder);

    expect(ringsFinder, findsOneWidget);
    // The chips live BELOW the ring layer — never over the artwork.
    expect(status.top, greaterThanOrEqualTo(rings.bottom));
    expect(technical.top, greaterThanOrEqualTo(rings.bottom));
    expect(status.overlaps(rings), isFalse);
    expect(technical.overlaps(rings), isFalse);
    expect(status.overlaps(technical), isFalse);
  });
}
