import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/widgets/orbit/orbit.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner.dart';

void main() {
  group('OrbitScannerState unit tests', () {
    test('every state exposes a label and a color', () {
      for (final state in OrbitScannerState.values) {
        expect(state.displayName, isNotEmpty);
        expect(state.color, isA<Color>());
      }
    });

    test('isActiveLoop only covers transient processing states', () {
      expect(OrbitScannerState.qualityCheck.isActiveLoop, isTrue);
      expect(OrbitScannerState.modelLoading.isActiveLoop, isTrue);
      expect(OrbitScannerState.inference.isActiveLoop, isTrue);

      expect(OrbitScannerState.idle.isActiveLoop, isFalse);
      expect(OrbitScannerState.preliminaryResult.isActiveLoop, isFalse);
      expect(OrbitScannerState.confirmedResult.isActiveLoop, isFalse);
      expect(OrbitScannerState.failure.isActiveLoop, isFalse);
      expect(OrbitScannerState.cancelled.isActiveLoop, isFalse);
    });

    test(
      'adapter maps every scanner state, never to confirmed or cancelled',
      () {
        const confirmedOrCancelled = {
          OrbitScannerState.confirmedResult,
          OrbitScannerState.cancelled,
        };
        for (final scanner in ScannerAnimationState.values) {
          final mapped = OrbitScannerState.fromScannerAnimationState(scanner);
          expect(
            confirmedOrCancelled.contains(mapped),
            isFalse,
            reason: '$scanner must not map to confirmed/cancelled',
          );
        }

        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.idle,
          ),
          OrbitScannerState.idle,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.qualityCheck,
          ),
          OrbitScannerState.qualityCheck,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.scanning,
          ),
          OrbitScannerState.modelLoading,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.analyzing,
          ),
          OrbitScannerState.inference,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.resultReady,
          ),
          OrbitScannerState.preliminaryResult,
          reason: 'a completed local result is preliminary, not confirmed',
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.reviewRequired,
          ),
          OrbitScannerState.preliminaryResult,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.rejected,
          ),
          OrbitScannerState.failure,
        );
        expect(
          OrbitScannerState.fromScannerAnimationState(
            ScannerAnimationState.error,
          ),
          OrbitScannerState.failure,
        );
      },
    );
  });

  group('OrbitScanner widget tests', () {
    Future<void> pumpOrbit(
      WidgetTester tester, {
      required OrbitScannerState state,
      String? statusText,
      String? technicalLabel,
      bool? reduceMotion,
      VoidCallback? onCancel,
      Uint8List? imageBytes,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 320,
                child: OrbitScanner(
                  state: state,
                  statusText: statusText,
                  technicalLabel: technicalLabel,
                  reduceMotion: reduceMotion,
                  onCancel: onCancel,
                  imageBytes: imageBytes,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('renders the verified label for each configured state', (
      tester,
    ) async {
      for (final state in OrbitScannerState.values) {
        await pumpOrbit(tester, state: state);
        expect(
          find.text(state.displayName),
          findsOneWidget,
          reason: 'state ${state.name} must show its label',
        );
      }
    });

    testWidgets('does not invent a technical label when none is provided', (
      tester,
    ) async {
      await pumpOrbit(tester, state: OrbitScannerState.inference);
      // Only the state label pill and semantics may exist; no backend readout.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data);
      expect(texts.where((t) => t != null && t.contains('tflite')), isEmpty);
      expect(texts.where((t) => t != null && t.contains('ms')), isEmpty);
    });

    testWidgets('renders caller-verified technical label when provided', (
      tester,
    ) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.preliminaryResult,
        technicalLabel: 'backend: tflite-fp32',
      );
      expect(find.text('BACKEND: TFLITE-FP32'), findsOneWidget);
    });

    testWidgets('statusText overrides the default label', (tester) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.preliminaryResult,
        statusText: 'AWAITING CLINICIAN SIGN-OFF',
      );
      expect(find.text('AWAITING CLINICIAN SIGN-OFF'), findsOneWidget);
      expect(
        find.text(OrbitScannerState.preliminaryResult.displayName),
        findsNothing,
      );
    });

    testWidgets('exposes state and technical label through semantics', (
      tester,
    ) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.inference,
        technicalLabel: 'backend: tflite-fp32',
      );
      final semantics = tester.widget<Semantics>(
        find.descendant(
          of: find.byType(OrbitScanner),
          matching: find.byType(Semantics),
          matchRoot: true,
        ),
      );
      expect(semantics.properties.label, contains('INFERENCE RUNNING'));
      expect(semantics.properties.label, contains('backend: tflite-fp32'));
    });

    testWidgets('reduced motion holds a static frame while active state', (
      tester,
    ) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.inference,
        reduceMotion: true,
      );
      final painter1 = _orbitPainter(tester);
      expect(painter1.reducedMotion, isTrue);

      await tester.pump(const Duration(seconds: 2));
      final painter2 = _orbitPainter(tester);
      expect(
        painter2.animationValue,
        painter1.animationValue,
        reason: 'reduced motion must not advance the animation',
      );
      expect(painter2.animationValue, 0.0);
    });

    testWidgets('animates the loop for transient states when motion allowed', (
      tester,
    ) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.inference,
        reduceMotion: false,
      );
      await tester.pump(const Duration(seconds: 1));
      final advanced = _orbitPainter(tester);
      expect(advanced.animationValue, greaterThan(0.0));
      expect(advanced.reducedMotion, isFalse);
    });

    testWidgets('result and failure states do not animate', (tester) async {
      for (final state in [
        OrbitScannerState.preliminaryResult,
        OrbitScannerState.confirmedResult,
        OrbitScannerState.failure,
        OrbitScannerState.cancelled,
        OrbitScannerState.idle,
      ]) {
        await pumpOrbit(tester, state: state, reduceMotion: false);
        await tester.pump(const Duration(seconds: 2));
        expect(
          _orbitPainter(tester).animationValue,
          0.0,
          reason: '${state.name} must hold a static frame',
        );
      }
    });

    testWidgets('cancel control invokes the caller callback', (tester) async {
      var cancelled = false;
      await pumpOrbit(
        tester,
        state: OrbitScannerState.inference,
        onCancel: () => cancelled = true,
      );
      expect(find.byKey(const Key('orbit_cancel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('orbit_cancel')));
      await tester.pump();
      expect(cancelled, isTrue);
    });

    testWidgets('cancel control is absent without a callback', (tester) async {
      await pumpOrbit(tester, state: OrbitScannerState.inference);
      expect(find.byKey(const Key('orbit_cancel')), findsNothing);
    });

    testWidgets('falls back to the eye emblem when image bytes are invalid', (
      tester,
    ) async {
      await pumpOrbit(
        tester,
        state: OrbitScannerState.idle,
        imageBytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      // errorBuilder must build the fallback emblem; decode errors are
      // surfaced through the test framework but must not prevent rendering.
      final exception = tester.takeException();
      if (exception != null) expect(exception, isA<Exception>());
      expect(find.byType(Image), findsOneWidget);
    });
  });
}

OrbitPainter _orbitPainter(WidgetTester tester) {
  final custom = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(OrbitScanner),
      matching: find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is OrbitPainter,
      ),
    ),
  );
  return custom.painter! as OrbitPainter;
}
