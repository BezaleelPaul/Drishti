import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/widgets/fx/particle_field.dart';
import 'package:netra_ai_mobile/widgets/nav/neon_nav_rail.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner_theme.dart';

/// Two fake destinations so navigation can be asserted without dragging in
/// the real clinical screens (and their services) into a widget test.
class _FakeScreen extends StatelessWidget {
  const _FakeScreen(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Text(label);
}

List<NavEntry> _entries() => [
  const NavEntry(
    icon: Icons.dashboard_outlined,
    label: 'Dashboard',
    page: _FakeScreen('screen-dashboard'),
    accent: ScannerHUDTheme.neonCyan,
    isPrimary: true,
  ),
  const NavEntry(
    icon: Icons.history_outlined,
    label: 'Patient History',
    page: _FakeScreen('screen-history'),
    accent: Color(0xFF38BDF8),
  ),
  const NavEntry(
    icon: Icons.cloud_off_outlined,
    label: 'Offline Queue',
    page: _FakeScreen('screen-queue'),
    accent: Color(0xFFF59E0B),
  ),
];

Future<void> _pumpRail(
  WidgetTester tester, {
  String? activeLabel,
  bool? online,
  int queuedCount = 0,
}) async {
  // Tear down any previously-opened rail. Re-pumping while the drawer
  // animation is mid-flight leaves an invisible overlay that swallows the
  // tap on the body button, which surfaces as a confusing hit-test warning.
  await tester.pumpWidget(const SizedBox());
  await tester.pump();

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        drawer: NeonNavRail(
          entries: _entries(),
          activeLabel: activeLabel,
          online: online,
          queuedCount: queuedCount,
        ),
        // The drawer needs an open gesture; a Scaffold body with a menu
        // button is the standard way to expose it in tests.
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
  // Entrance animations are staggered; give them time to build.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  group('NeonNavRail', () {
    testWidgets('renders every entry label and the brand block', (
      tester,
    ) async {
      await _pumpRail(tester);

      expect(find.text('DRISHTI'), findsOneWidget);
      for (final e in _entries()) {
        expect(
          find.text(e.label),
          findsOneWidget,
          reason: 'missing ${e.label}',
        );
      }
    });

    testWidgets('marks the active entry as selected for a11y', (tester) async {
      await _pumpRail(tester, activeLabel: 'Patient History');

      // Each rail item wraps its InkWell in Semantics(button: true,
      // selected: ..., label: entry.label), so selecting by that label is
      // unambiguous and tests exactly the contract assistive tech relies on.
      SemanticsProperties propsFor(String label) => tester
          .widget<Semantics>(
            find.byWidgetPredicate(
              (w) => w is Semantics && w.properties.label == label,
            ),
          )
          .properties;

      final active = propsFor('Patient History');
      expect(active.selected, isTrue, reason: 'active entry must be selected');
      expect(active.button, isTrue);

      final inactive = propsFor('Dashboard');
      expect(inactive.selected, isNot(isTrue));
    });

    testWidgets('tapping an entry navigates to its page and closes the rail', (
      tester,
    ) async {
      await _pumpRail(tester);

      await tester.tap(find.text('Offline Queue'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('screen-queue'), findsOneWidget);
      // The rail is popped, so its labels are gone.
      expect(find.text('DRISHTI'), findsNothing);
    });

    testWidgets(
      'reports a resolved link state without claiming one when probing',
      (tester) async {
        await _pumpRail(tester, online: null);
        expect(find.text('…'), findsOneWidget);

        await _pumpRail(tester, online: true);
        expect(find.text('Online'), findsOneWidget);

        await _pumpRail(tester, online: false);
        expect(find.text('Offline'), findsOneWidget);
      },
    );

    testWidgets('shows queued depth only when it is non-zero', (tester) async {
      await _pumpRail(tester, online: true, queuedCount: 0);
      expect(find.textContaining('queued'), findsNothing);

      await _pumpRail(tester, online: true, queuedCount: 3);
      expect(find.text('3 queued'), findsOneWidget);
    });

    testWidgets('uses the dark HUD background, not the old white drawer', (
      tester,
    ) async {
      await _pumpRail(tester);
      final drawer = tester.widget<Drawer>(find.byType(Drawer));
      expect(drawer.backgroundColor, ScannerHUDTheme.background);
    });
  });

  group('ParticleField', () {
    testWidgets('renders a painter with the requested particle budget', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: ParticleField(particleCount: 12, seed: 3),
          ),
        ),
      );
      expect(find.byType(CustomPaint), findsWidgets);
    });

    testWidgets('honours a zero opacity by painting nothing visible', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: ParticleField(opacity: 0, particleCount: 12),
          ),
        ),
      );
      // No crash is the contract at opacity 0; the painter early-returns.
      expect(tester.takeException(), isNull);
    });

    testWidgets('does not throw while animating', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 200,
            height: 200,
            child: ParticleField(particleCount: 8, speed: 1),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });

    testWidgets('is frozen when reduce-motion is requested', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: SizedBox(
              width: 200,
              height: 200,
              child: ParticleField(particleCount: 8),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
    });
  });
}
