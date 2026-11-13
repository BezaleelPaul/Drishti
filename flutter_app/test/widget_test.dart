import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:drishti/l10n/lang_scope.dart';
import 'package:drishti/main.dart';
import 'package:drishti/screens/figma_dashboard_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Drishti App Smoke Test', (WidgetTester tester) async {
    // No network or platform channels in widget tests.
    GoogleFonts.config.allowRuntimeFetching = false;
    SharedPreferences.setMockInitialValues(const {});
    await tester.pumpWidget(
      DrishtiApp(
        langController: LangController(),
        initialHome: const FigmaDashboardScreen(),
      ),
    );
    // Figma dashboard home (English default).
    expect(find.text('PHC Dashboard'), findsOneWidget);
    expect(find.text('+ Start New Screening'), findsOneWidget);
    expect(find.text('Recent Screenings'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.language));
    await tester.pumpAndSettle();
    await tester.tap(find.text('हिन्दी'));
    await tester.pumpAndSettle();

    expect(find.text('PHC Dashboard'), findsNothing);
    expect(find.text('PHC डैशबोर्ड'), findsOneWidget);
  });
}
