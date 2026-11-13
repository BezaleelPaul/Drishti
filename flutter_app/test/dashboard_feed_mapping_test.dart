import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/screens/figma_dashboard_screen.dart';
import 'package:netra_ai_mobile/theme/figma_theme.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

void main() {
  group('liveStatusFor', () {
    test('maps backend status tokens to badges', () {
      expect(liveStatusFor('verified'), FigmaStatus.verified);
      expect(liveStatusFor('referral'), FigmaStatus.referral);
      expect(
        liveStatusFor('awaiting_specialist'),
        FigmaStatus.awaitingSpecialist,
      );
      expect(liveStatusFor('rejected'), FigmaStatus.rejected);
      expect(liveStatusFor('awaiting_ai'), FigmaStatus.awaitingAi);
    });

    test('unknown or missing status falls back to verified', () {
      expect(liveStatusFor(null), FigmaStatus.verified);
      expect(liveStatusFor(''), FigmaStatus.verified);
      expect(liveStatusFor('brand_new_state'), FigmaStatus.verified);
    });
  });

  group('formatScreeningDate', () {
    test('formats UTC ISO timestamp as dd MMM yyyy in local time', () {
      const iso = '2026-10-07T13:19:56.173427Z';
      final local = DateTime.parse(iso).toLocal();
      final day = local.day.toString().padLeft(2, '0');
      expect(
        formatScreeningDate(iso),
        '$day ${_months[local.month - 1]} ${local.year}',
      );
    });

    test('pads single-digit days', () {
      const iso = '2026-10-02T00:00:00Z';
      expect(formatScreeningDate(iso).startsWith('0'), isTrue);
    });

    test('handles missing and malformed timestamps', () {
      expect(formatScreeningDate(null), '\u2014');
      expect(formatScreeningDate(''), '\u2014');
      expect(formatScreeningDate('garbage'), 'garbage');
    });
  });

  group('localScreeningStatus (real LocalStore rows, never fabricated)', () {
    test('gate rejection codes render as rejected, not pending', () {
      expect(
        localScreeningStatus({
          'error_code': 'IMG_UNGRADABLE',
          'requires_human_review': 0,
          'sync_state': 'queued',
        }),
        FigmaStatus.rejected,
      );
      expect(
        localScreeningStatus({
          'error_code': 'IMG_NOT_FUNDUS',
          'requires_human_review': 0,
          'sync_state': 'acked',
        }),
        FigmaStatus.rejected,
      );
    });

    test('rows requiring human review are awaiting specialist', () {
      expect(
        localScreeningStatus({
          'error_code': null,
          'requires_human_review': 1,
          'sync_state': 'local_only',
        }),
        FigmaStatus.awaitingSpecialist,
      );
    });

    test('unsynced rows are offline, acknowledged rows are verified', () {
      for (final state in ['local_only', 'queued', 'sync_failed', '']) {
        expect(
          localScreeningStatus({
            'error_code': null,
            'requires_human_review': 0,
            'sync_state': state,
          }),
          FigmaStatus.offline,
          reason: 'sync_state $state must never claim server verification',
        );
      }
      expect(
        localScreeningStatus({
          'error_code': null,
          'requires_human_review': 0,
          'sync_state': 'acked',
        }),
        FigmaStatus.verified,
      );
      expect(
        localScreeningStatus({
          'error_code': null,
          'requires_human_review': 0,
          'sync_state': 'review_received',
        }),
        FigmaStatus.verified,
      );
    });
  });

  group('localScreeningResult (derived only from the row contents)', () {
    test('stored DR label wins', () {
      expect(
        localScreeningResult({
          'dr_label': 'Moderate NPDR',
          'dr_grade_num': 2,
          'error_code': null,
          'requires_human_review': 0,
        }),
        'Moderate NPDR',
      );
    });

    test('falls back to the canonical grade label from dr_grade_num', () {
      expect(
        localScreeningResult({
          'dr_label': null,
          'dr_grade_num': 3,
          'error_code': null,
          'requires_human_review': 0,
        }),
        'Severe NPDR',
      );
    });

    test('rejection codes surface verbatim; empty rows stay honest', () {
      expect(
        localScreeningResult({
          'dr_label': null,
          'dr_grade_num': null,
          'error_code': 'IMG_INVALID',
          'requires_human_review': 0,
        }),
        'IMG_INVALID',
      );
      expect(
        localScreeningResult({
          'dr_label': null,
          'dr_grade_num': null,
          'error_code': null,
          'requires_human_review': 0,
        }),
        'Pending AI',
      );
      expect(
        localScreeningResult({
          'dr_label': null,
          'dr_grade_num': null,
          'error_code': null,
          'requires_human_review': 1,
        }),
        'Awaiting review',
      );
    });
  });

  group('localScreeningRow (LocalStore join row → feed tuple)', () {
    test('uses the real patient name and formats the timestamp', () {
      const iso = '2026-10-07T13:19:56.173427Z';
      final local = DateTime.parse(iso).toLocal();
      final day = local.day.toString().padLeft(2, '0');
      final row = localScreeningRow({
        'name': 'Krishna Rao',
        'local_patient_id': 'LOCP-77',
        'created_at': iso,
        'dr_label': 'Mild NPDR',
        'error_code': null,
        'requires_human_review': 0,
        'sync_state': 'queued',
      });
      expect(row.$1, 'LOCP-77');
      expect(row.$2, 'Krishna Rao');
      expect(row.$3, '$day ${_months[local.month - 1]} ${local.year}');
      expect(row.$4, 'Mild NPDR');
      expect(row.$5, FigmaStatus.offline);
    });

    test('missing patient name degrades to the local patient id', () {
      final row = localScreeningRow({
        'name': '',
        'local_patient_id': 'LOCP-9',
        'created_at': '',
        'dr_label': null,
        'error_code': null,
        'requires_human_review': 0,
        'sync_state': 'local_only',
      });
      expect(row.$2, 'LOCP-9');
    });
  });
}
