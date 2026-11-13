import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/screens/splash/futuristic_splash_screen.dart';
import 'package:netra_ai_mobile/widgets/futuristic/futuristic_ui.dart';

void main() {
  group('FuturisticGlowButton Widget Tests', () {
    testWidgets('Renders label and triggers onPressed', (tester) async {
      var pressed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: FuturisticGlowButton(
                label: 'INITIALIZE SCAN',
                onPressed: () => pressed = true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('INITIALIZE SCAN'), findsOneWidget);

      await tester.tap(find.text('INITIALIZE SCAN'));
      await tester.pump();

      expect(pressed, isTrue);
    });

    testWidgets('Displays progress indicator when isLoading is true', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: FuturisticGlowButton(
                label: 'INITIALIZE SCAN',
                isLoading: true,
                onPressed: null,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('INITIALIZE SCAN'), findsNothing);
    });
  });

  group('FuturisticGlassCard Widget Tests', () {
    testWidgets('Renders title and child content with HUD aesthetics', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: FuturisticGlassCard(
                title: 'Telemetric Sensors',
                child: Text('Optics 100% Calibrated'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('TELEMETRIC SENSORS'), findsOneWidget);
      expect(find.text('Optics 100% Calibrated'), findsOneWidget);
      expect(find.byType(FuturisticGlassCard), findsOneWidget);
    });
  });

  group('FuturisticSplashScreen Widget Tests', () {
    testWidgets('Renders branding and Flame-backed scanner calibration', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: FuturisticSplashScreen()),
      );

      await tester.pump(const Duration(milliseconds: 100));

      // ELYTRIVA brand identity: the wordmark and the brand mark are
      // bundled assets (assets/branding), not painted text.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/elytriva_logo_horizontal_no_tagline.png',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/elytriva_mark.png',
        ),
        findsOneWidget,
      );
      expect(find.text('ELYTRIVA // OS v1.2'), findsOneWidget);
      expect(
        find.text(
          'EXPLAINABLE RETINAL SCREENING  ·  GOOD / BORDERLINE / REJECT',
        ),
        findsOneWidget,
      );
      expect(find.text('SKIP BOOT ▶'), findsOneWidget);
    });

    testWidgets('Splash composes without overflow on a small phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: FuturisticSplashScreen()),
      );
      await tester.pump(const Duration(milliseconds: 400));

      // Brand mark and wordmark must both be present and inside the viewport.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/elytriva_mark.png',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Image &&
              (w.image as AssetImage).assetName ==
                  'assets/branding/elytriva_logo_horizontal_no_tagline.png',
        ),
        findsOneWidget,
      );
      // No RenderFlex overflow: the test binding fails on overflow errors.
      // (Exception intentionally NOT captured so the framework prints the
      // offending widget's creator chain.)
      await tester.pump();
    });
  });
}
