import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/widgets/charts/severity_distribution_chart.dart';

// LangScope.langOf falls back to AppLang.en when no scope is present, so a
// plain MaterialApp is enough — context.tr resolves the English strings.
Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('severityKeyForResultText', () {
    test('maps real DR grades to canonical keys', () {
      expect(severityKeyForResultText('No DR'), 'sev_no_dr');
      expect(severityKeyForResultText('Mild NPDR'), 'sev_mild_npdr');
      expect(severityKeyForResultText('Moderate NPDR'), 'sev_moderate_npdr');
      expect(severityKeyForResultText('Severe NPDR'), 'sev_severe_npdr');
      expect(severityKeyForResultText('PDR'), 'sev_pdr');
      expect(severityKeyForResultText('Proliferative DR'), 'sev_pdr');
    });

    test('is case/whitespace insensitive', () {
      expect(severityKeyForResultText('  moderate npdr '), 'sev_moderate_npdr');
      expect(severityKeyForResultText('SEVERE NPDR'), 'sev_severe_npdr');
    });

    test('returns null for non-grade values (never fabricates a bucket)', () {
      expect(severityKeyForResultText('Pending'), isNull);
      expect(severityKeyForResultText(''), isNull);
      expect(severityKeyForResultText('   '), isNull);
      expect(severityKeyForResultText('Unknown'), isNull);
    });
  });

  group('buildSeverityBuckets', () {
    test('counts only graded results in DR-scale order', () {
      final buckets = buildSeverityBuckets([
        'No DR',
        'No DR',
        'Mild NPDR',
        'Moderate NPDR',
        'Severe NPDR',
        'Severe NPDR',
        'PDR',
        'Pending', // excluded
        'garbage', // excluded
      ]);
      expect(buckets.map((b) => b.labelKey).toList(), [
        'sev_no_dr',
        'sev_mild_npdr',
        'sev_moderate_npdr',
        'sev_severe_npdr',
        'sev_pdr',
      ]);
      expect(buckets.map((b) => b.count).toList(), [2, 1, 1, 2, 1]);
    });

    test('all-empty input yields all-zero buckets (no fabrication)', () {
      final buckets = buildSeverityBuckets(['Pending', '']);
      expect(buckets.every((b) => b.count == 0), isTrue);
    });
  });

  group('SeverityDistributionChart', () {
    testWidgets('shows honest empty state when no graded results', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SeverityDistributionChart(
            buckets: buildSeverityBuckets(const ['Pending']),
          ),
        ),
      );
      expect(find.textContaining('No graded results yet'), findsOneWidget);
      expect(find.byType(BarChart), findsNothing);
    });

    testWidgets('renders chart bars from real graded data', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SeverityDistributionChart(
            buckets: buildSeverityBuckets(const [
              'No DR',
              'Moderate NPDR',
              'PDR',
            ]),
          ),
        ),
      );
      expect(find.byType(BarChart), findsOneWidget);
      expect(find.textContaining('3 graded results'), findsOneWidget);
    });
  });
}
