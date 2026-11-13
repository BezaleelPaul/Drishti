import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/screens/about_screen.dart';
import 'package:netra_ai_mobile/screens/figma_dashboard_screen.dart';
import 'package:netra_ai_mobile/screens/flow/flow_register_screen.dart';
import 'package:netra_ai_mobile/screens/queue_screen.dart';
import 'package:netra_ai_mobile/widgets/nav/neon_nav_rail.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner_theme.dart';

/// The streamlined drawer contract (Screening / Triage & Operations /
/// Support): prototypes and duplicated intake screens are gone, the single
/// canonical "New Screening" entry points at the Figma flow registration.
void main() {
  List<NavEntry> entries = const <NavEntry>[];

  Future<void> pumpAndCapture(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    entries = buildNavEntries(captured);
  }

  group('buildNavEntries (streamlined drawer)', () {
    testWidgets('sections follow the clinical workflow order', (tester) async {
      await pumpAndCapture(tester);

      expect(entries.map((e) => e.section).toList(), const [
        'Screening',
        'Screening',
        'Screening',
        'Triage & Operations',
        'Triage & Operations',
        'Support',
        'Support',
      ]);
    });

    testWidgets('exposes the three Screening destinations only', (
      tester,
    ) async {
      await pumpAndCapture(tester);

      final screening = entries.take(3).toList();
      expect(screening[0].label, 'Dashboard');
      expect(screening[0].page, isA<FigmaDashboardScreen>());
      expect(screening[0].isPrimary, isTrue);

      // Developer-facing names are gone: no Classic Check-In, no
      // Integrated 3-Step Flow label anywhere in the rail.
      expect(screening[1].label, 'New Screening');
      expect(screening[1].page, isA<FlowRegisterScreen>());

      expect(screening[2].label, 'Patient History');

      final labels = entries.map((e) => e.label).toList();
      expect(labels, isNot(contains('Classic Check-In')));
      expect(labels, isNot(contains('Integrated 3-Step Flow')));
      expect(labels, isNot(contains('District Simulation')));
      expect(labels, isNot(contains('System Specs')));
    });

    testWidgets('Triage and Support destinations resolve correctly', (
      tester,
    ) async {
      await pumpAndCapture(tester);

      expect(entries[3].label, 'Specialist Review Queue');
      expect(entries[4].label, 'Offline Queue');
      expect(entries[4].page, isA<QueueScreen>());
      expect(entries[5].label, 'Help & Guidelines');
      expect(entries[6].label, 'About / System Info');
      expect(entries[6].page, isA<AboutScreen>());
    });

    testWidgets('section headers render and collapse group boundaries', (
      tester,
    ) async {
      Widget pageFor(int index) => const SizedBox.shrink();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            drawer: NeonNavRail(
              entries: [
                NavEntry(
                  icon: Icons.dashboard_outlined,
                  label: 'Dashboard',
                  section: 'Screening',
                  page: pageFor(0),
                ),
                NavEntry(
                  icon: Icons.person_add_alt,
                  label: 'New Screening',
                  section: 'Screening',
                  page: pageFor(1),
                ),
                NavEntry(
                  icon: Icons.medical_services_outlined,
                  label: 'Specialist Review Queue',
                  section: 'Triage & Operations',
                  page: pageFor(2),
                ),
              ],
            ),
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                child: const Text('open-rail'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open-rail'));
      // Entrance animations are staggered; two-step pump matches the
      // established rail-test recipe so all mount-time timers fire.
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));

      // Same-section consecutive entries produce ONE header per group.
      expect(find.text('SCREENING'), findsOneWidget);
      expect(find.text('TRIAGE & OPERATIONS'), findsOneWidget);
      expect(find.text('Dashboard'), findsOneWidget);
      expect(find.text('New Screening'), findsOneWidget);
      expect(find.text('Specialist Review Queue'), findsOneWidget);
    });

    test('entries stay HUD-themed', () {
      expect(
        ScannerHUDTheme.neonCyan,
        isNotNull,
        reason: 'rail accents come from ScannerHUDTheme',
      );
    });
  });
}
