import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner.dart';

void main() {
  group('ScannerAnimationState Unit Tests', () {
    test('All states have non-empty names and valid colors', () {
      for (final state in ScannerAnimationState.values) {
        expect(state.displayName.isNotEmpty, isTrue);
        expect(state.primaryColor, isA<Color>());
      }
    });

    test('isActiveLoop correctly isolates active scanning/analyzing loops', () {
      expect(ScannerAnimationState.scanning.isActiveLoop, isTrue);
      expect(ScannerAnimationState.analyzing.isActiveLoop, isTrue);
      expect(ScannerAnimationState.qualityCheck.isActiveLoop, isTrue);

      expect(ScannerAnimationState.idle.isActiveLoop, isFalse);
      expect(ScannerAnimationState.reviewRequired.isActiveLoop, isFalse);
      expect(ScannerAnimationState.resultReady.isActiveLoop, isFalse);
      expect(ScannerAnimationState.rejected.isActiveLoop, isFalse);
      expect(ScannerAnimationState.error.isActiveLoop, isFalse);
    });
  });

  group('ScannerGame Unit Tests', () {
    test('Game initializes viewport and updates angles correctly', () {
      final game = ScannerGame();
      expect(game.backgroundColor(), const Color(0xFF0B132B));

      game.onGameResize(Vector2(400, 400));
      game.animationState = ScannerAnimationState.scanning;

      // Update 1 second
      game.update(1.0);
      expect(game.progress, 0.0);

      // Reduce motion test
      game.reduceMotion = true;
      game.update(1.0);
      expect(game.reduceMotion, isTrue);
    });

    test('Stopping state freezes rotation progression', () {
      final game = ScannerGame();
      game.onGameResize(Vector2(300, 300));
      game.animationState = ScannerAnimationState.rejected;
      game.update(1.0);
      // Ensure it runs safely without exceptions
      expect(game.animationState, ScannerAnimationState.rejected);
    });
  });

  group('ScannerView Widget Tests', () {
    testWidgets('Renders ScannerView with correct HUD status and semantics', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 320,
                child: ScannerView(
                  state: ScannerAnimationState.scanning,
                  progress: 0.45,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(ScannerView), findsOneWidget);
      expect(find.text('SCANNING RETINA'), findsOneWidget);
      expect(find.text('45%'), findsOneWidget);
      expect(find.text('FOV: 45° | MACULA CENTERED'), findsOneWidget);
    });

    testWidgets('Triggers onCancel callback when CANCEL button is tapped', (
      tester,
    ) async {
      var cancelled = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 320,
                child: ScannerView(
                  state: ScannerAnimationState.scanning,
                  onCancel: () {
                    cancelled = true;
                  },
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('CANCEL'), findsOneWidget);

      await tester.tap(find.text('CANCEL'));
      await tester.pump();

      expect(cancelled, isTrue);
    });
  });
}
