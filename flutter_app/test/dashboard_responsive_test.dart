import 'package:drishti/screens/figma_dashboard_screen.dart';
import 'package:drishti/widgets/orbit/orbit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues(const {});
  });

  testWidgets('dashboard composes without overflow on a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: FigmaDashboardScreen()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(OrbitScanner), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('+ Start New Screening'), findsOneWidget);
  });

  testWidgets('dashboard composes without overflow on desktop', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: FigmaDashboardScreen()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(OrbitScanner), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Recent Screenings'), findsOneWidget);
  });
}
