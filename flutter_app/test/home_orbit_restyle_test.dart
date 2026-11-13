import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:netra_ai_mobile/screens/figma_dashboard_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_register_screen.dart';
import 'package:netra_ai_mobile/widgets/orbit/orbit.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets(
    'home renders dark orbit palette with an honest hero link state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: FigmaDashboardScreen()));
      // Settle also proves the idle hero schedules no perpetual animation
      // (the dashboard smoke test depends on this).
      await tester.pumpAndSettle();

      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(scaffold.backgroundColor, ScannerHUDTheme.background);

      expect(find.byType(OrbitScanner), findsOneWidget);
      const honestLabels = ['PROBING LINK', 'LINK ONLINE', 'LINK OFFLINE'];
      expect(
        honestLabels.any((l) => find.text(l).evaluate().isNotEmpty),
        isTrue,
        reason:
            'hero must show a real link state; '
            'none of $honestLabels found',
      );

      // The idle hero must never emit in-progress or unearned claims.
      for (final claim in [
        'SERVICE CONFIRMED',
        'INFERENCE RUNNING',
        'LOADING MODEL',
        'OPTICS CALIBRATING',
        'ANALYSIS FAILED',
        'PRELIMINARY // AWAITING SIGN-OFF',
      ]) {
        expect(
          find.text(claim),
          findsNothing,
          reason: 'unearned claim on home: $claim',
        );
      }

      // Existing smoke contract (mirrors widget_test.dart expectations).
      expect(find.text('PHC Dashboard'), findsOneWidget);
      expect(find.text('+ Start New Screening'), findsOneWidget);
      expect(find.text('Recent Screenings'), findsOneWidget);
    },
  );

  testWidgets('start screening button navigates to the register screen', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: FigmaDashboardScreen()));
    await tester.pumpAndSettle();

    final start = find.text('+ Start New Screening');
    await tester.ensureVisible(start);
    await tester.tap(start);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(FlowRegisterScreen), findsOneWidget);
  });
}
