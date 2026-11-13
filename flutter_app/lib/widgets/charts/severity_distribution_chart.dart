import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../l10n/lang_scope.dart';
import '../scanner/scanner_theme.dart';

/// One severity bucket in the DR distribution.
class SeverityBucket {
  const SeverityBucket({
    required this.labelKey,
    required this.count,
    required this.color,
  });

  /// l10n key for the bucket label (e.g. `sev_no_dr`).
  final String labelKey;
  final int count;
  final Color color;
}

/// Maps a free-text `result_text` value from the live feed onto the
/// canonical 5-step DR scale. Returns null for values that don't map (e.g.
/// "Pending", empty, or an unrecognized string) so they are excluded from the
/// distribution rather than silently folded into a real bucket.
String? severityKeyForResultText(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.isEmpty) return null;
  if (t.contains('proliferative') || t == 'pdr' || t.contains(' pdr')) {
    return 'sev_pdr';
  }
  if (t.contains('severe')) return 'sev_severe_npdr';
  if (t.contains('moderate')) return 'sev_moderate_npdr';
  if (t.contains('mild')) return 'sev_mild_npdr';
  if (t.contains('no dr') || t.contains('normal') || t.contains('none')) {
    return 'sev_no_dr';
  }
  return null;
}

/// Aggregates raw `result_text` strings into ordered severity buckets.
///
/// Unmappable values (pending, unknown) are dropped, so the chart only ever
/// reflects real graded results — never fabricated counts.
List<SeverityBucket> buildSeverityBuckets(Iterable<String> resultTexts) {
  final counts = <String, int>{
    'sev_no_dr': 0,
    'sev_mild_npdr': 0,
    'sev_moderate_npdr': 0,
    'sev_severe_npdr': 0,
    'sev_pdr': 0,
  };
  for (final raw in resultTexts) {
    final key = severityKeyForResultText(raw);
    if (key != null) counts[key] = (counts[key] ?? 0) + 1;
  }
  return [
    SeverityBucket(
      labelKey: 'sev_no_dr',
      count: counts['sev_no_dr']!,
      color: ScannerHUDTheme.success,
    ),
    SeverityBucket(
      labelKey: 'sev_mild_npdr',
      count: counts['sev_mild_npdr']!,
      color: const Color(0xFF38BDF8),
    ),
    SeverityBucket(
      labelKey: 'sev_moderate_npdr',
      count: counts['sev_moderate_npdr']!,
      color: ScannerHUDTheme.warning,
    ),
    SeverityBucket(
      labelKey: 'sev_severe_npdr',
      count: counts['sev_severe_npdr']!,
      color: const Color(0xFFF97316),
    ),
    SeverityBucket(
      labelKey: 'sev_pdr',
      count: counts['sev_pdr']!,
      color: ScannerHUDTheme.danger,
    ),
  ];
}

/// DR severity distribution bar chart.
///
/// Renders the buckets passed in; if every bucket is empty the chart is NOT
/// drawn and an explicit "no graded results yet" placeholder is shown instead,
/// so an empty feed never masquerades as a real distribution.
class SeverityDistributionChart extends StatelessWidget {
  const SeverityDistributionChart({super.key, required this.buckets});

  final List<SeverityBucket> buckets;

  int get _total => buckets.fold(0, (s, b) => s + b.count);

  @override
  Widget build(BuildContext context) {
    final total = _total;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr('severity_distribution'),
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$total ${context.tr('severity_graded_count')}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 16),
          if (total == 0)
            _emptyState(context)
          else
            SizedBox(
              height: 168,
              child: BarChart(
                _chartData(context),
                duration: const Duration(milliseconds: 450),
                curve: Curves.easeOutCubic,
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bar_chart, color: Color(0xFF334155), size: 28),
            const SizedBox(height: 8),
            Text(
              context.tr('severity_empty'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  BarChartData _chartData(BuildContext context) {
    final maxCount = buckets.fold<int>(1, (m, b) => b.count > m ? b.count : m);
    return BarChartData(
      alignment: BarChartAlignment.spaceAround,
      maxY: (maxCount * 1.25).ceilToDouble(),
      barTouchData: BarTouchData(enabled: false),
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(
          sideTitles: SideTitles(showTitles: false),
        ),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            reservedSize: 44,
            getTitlesWidget: (value, meta) {
              final i = value.toInt();
              if (i < 0 || i >= buckets.length) return const SizedBox.shrink();
              final b = buckets[i];
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  context.tr(b.labelKey),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: b.count > 0 ? b.color : const Color(0xFF475569),
                  ),
                ),
              );
            },
          ),
        ),
      ),
      barGroups: [
        for (var i = 0; i < buckets.length; i++)
          BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: buckets[i].count.toDouble(),
                width: 20,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(5),
                ),
                gradient: buckets[i].count > 0
                    ? LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [
                          buckets[i].color,
                          buckets[i].color.withValues(alpha: 0.55),
                        ],
                      )
                    : null,
                color: buckets[i].count > 0 ? null : const Color(0xFF1E293B),
              ),
            ],
          ),
      ],
    );
  }
}
