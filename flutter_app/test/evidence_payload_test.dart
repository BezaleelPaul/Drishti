import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/l10n/evidence_strings.dart';
import 'package:netra_ai_mobile/models/retinal_markers.dart';
import 'package:netra_ai_mobile/widgets/review/lesion_marker_painter.dart';

Map<String, dynamic> _evidencePayload() => {
  'review_id': 'REV-EVIDENCE',
  'available': true,
  'source': 'classical_cv_segmentation',
  'width': 400,
  'height': 300,
  'optic_disc': {'x': 150, 'y': 150, 'r': 40},
  'fovea': {'x': 260, 'y': 170},
  'ma_candidates': [
    {'x': 260, 'y': 180, 'r': 5},
  ],
  'schema_version': '1.0',
  'lesion_evidence': [
    {
      'lesion_id': 'LE-0001',
      'lesion_type': 'microaneurysm_candidate',
      'detection_status': 'detected',
      'x': 260,
      'y': 180,
      'radius': 5,
      'criterion_links': ['icdrss.ma_present', 'icdrss.fovea_involvement'],
      'evidence_notes': [
        'Classical-CV candidate (dark focal spot); not a confirmed lesion.',
      ],
      'detector_id': 'classical_cv_segmenter',
      'detector_version': '1.0',
      'image_width': 400,
      'image_height': 300,
    },
    {
      'lesion_id': 'LE-0002',
      'lesion_type': 'exudate_candidate',
      'detection_status': 'detected',
      'x': 120,
      'y': 200,
      'radius': 9,
      'criterion_links': ['icdrss.exudate_present'],
      'evidence_notes': ['Bright-lesion candidate.'],
      'image_width': 400,
      'image_height': 300,
    },
  ],
  'criteria_evaluation': [
    {
      'criterion_id': 'icdrss.ma_present',
      'status': 'satisfied',
      'supporting_evidence_ids': ['LE-0001'],
      'reason_codes': ['DETECTOR_RAN', 'CANDIDATES_PRESENT'],
      'explanation_key': 'criterion_ma_present',
    },
    {
      'criterion_id': 'icdrss.exudate_present',
      'status': 'satisfied',
      'supporting_evidence_ids': ['LE-0002'],
      'explanation_key': 'criterion_exudate_present',
    },
    {
      'criterion_id': 'icdrss.venous_beading',
      'status': 'not_evaluated',
      'reason_codes': ['DETECTOR_NOT_IMPLEMENTED'],
      'explanation_key': 'criterion_unsupported',
    },
  ],
  'grading_policy': {
    'policy_id': 'icdrss-subset',
    'policy_version': '1.0',
    'framework':
        'International Clinical Diabetic Retinopathy (ICDRS) severity scale',
  },
  'disagreement': {
    'status': 'adjacent',
    'reason_codes': ['CANDIDATES_PRESENT', 'EVIDENCE_ADJACENT'],
    'review_required': false,
    'cnn_grade': 2,
    'evidence_implied_grade': 1,
    'explanation_key': 'disagreement_adjacent',
    'policy_id': 'icdrss-subset',
    'policy_version': '1.0',
  },
};

void main() {
  group('evidence payload parsing (schema_version 1.0)', () {
    test('parses typed evidence, criteria, policy, and disagreement', () {
      final m = RetinalMarkers.fromJson(_evidencePayload());
      expect(m.hasEvidenceExtension, isTrue);
      expect(m.lesionEvidence, hasLength(2));
      expect(m.lesionEvidence[0].lesionId, 'LE-0001');
      expect(
        m.lesionEvidence[0].lesionType,
        LesionEvidenceItem.typeMaCandidate,
      );
      expect(m.lesionEvidence[0].geometryValid, isTrue);
      expect(m.lesionEvidence[0].criterionLinks, contains('icdrss.ma_present'));
      expect(m.criteriaEvaluation, hasLength(3));
      final vb = m.criteriaEvaluation[2];
      expect(vb.status, CriterionEvaluation.notEvaluated);
      expect(m.gradingPolicy!.policyVersion, '1.0');
      expect(m.disagreement!.status, DisagreementInfo.adjacent);
      expect(m.disagreement!.reviewRequired, isFalse);
      expect(m.disagreement!.cnnGrade, 2);
    });

    test('unknown lesion type and status degrade to unknown, never crash', () {
      final payload = _evidencePayload();
      payload['lesion_evidence'] = [
        {
          'lesion_id': 'LE-0009',
          'lesion_type': 'space_lesion',
          'detection_status': 'weird_status',
          'x': 10,
          'y': 10,
          'radius': 2,
        },
      ];
      final m = RetinalMarkers.fromJson(payload);
      expect(m.lesionEvidence[0].lesionType, LesionEvidenceItem.typeUnknown);
      expect(
        m.lesionEvidence[0].detectionStatus,
        LesionEvidenceItem.statusUnknown,
      );
      expect(m.lesionEvidence[0].typeKnown, isFalse);
    });

    test('out-of-bounds geometry is flagged invalid, not rendered', () {
      final payload = _evidencePayload();
      payload['lesion_evidence'] = [
        {
          'lesion_id': 'LE-0008',
          'lesion_type': 'microaneurysm_candidate',
          'detection_status': 'detected',
          'x': 9999,
          'y': -5,
          'radius': 2,
          'image_width': 400,
          'image_height': 300,
        },
      ];
      final m = RetinalMarkers.fromJson(payload);
      expect(m.lesionEvidence[0].geometryValid, isFalse);
      expect(
        LesionMarkerPainter.drawableMarkers(
          m,
          const Rect.fromLTWH(0, 0, 400, 300),
          1.0,
        ).where((k) => k.kind == MarkerKind.candidate),
        isEmpty,
      );
    });

    test('legacy payload (no extension keys) parses with empty extension', () {
      final m = RetinalMarkers.fromJson({
        'review_id': 'REV-OLD',
        'available': true,
        'source': 'classical_cv_segmentation',
        'width': 100,
        'height': 100,
        'optic_disc': {'x': 50, 'y': 50, 'r': 10},
        'fovea': {'x': 70, 'y': 55},
        'ma_candidates': [
          {'x': 80, 'y': 80, 'r': 4},
        ],
      });
      expect(m.hasEvidenceExtension, isFalse);
      expect(m.lesionEvidence, isEmpty);
      expect(m.criteriaEvaluation, isEmpty);
      expect(m.gradingPolicy, isNull);
      expect(m.disagreement, isNull);
      expect(m.maCandidates, hasLength(1));
    });
  });

  group('LesionMarkerPainter evidence rendering', () {
    test('evidence items take precedence over legacy candidates', () {
      final m = RetinalMarkers.fromJson(_evidencePayload());
      final markers = LesionMarkerPainter.drawableMarkers(
        m,
        const Rect.fromLTWH(0, 0, 400, 300),
        1.0,
      );
      final lesionMarkers = markers
          .where(
            (k) =>
                k.kind == MarkerKind.candidate ||
                k.kind == MarkerKind.exudateCandidate,
          )
          .toList();
      expect(lesionMarkers, hasLength(2));
      expect(lesionMarkers[0].lesionId, 'LE-0001');
      expect(lesionMarkers[1].lesionId, 'LE-0002');
      expect(lesionMarkers[1].kind, MarkerKind.exudateCandidate);
    });

    test('selection dims other markers', () {
      final m = RetinalMarkers.fromJson(_evidencePayload());
      final markers = LesionMarkerPainter.drawableMarkers(
        m,
        const Rect.fromLTWH(0, 0, 400, 300),
        1.0,
        selectedLesionId: 'LE-0001',
      );
      final one = markers.firstWhere((k) => k.lesionId == 'LE-0001');
      final two = markers.firstWhere((k) => k.lesionId == 'LE-0002');
      expect(one.selected, isTrue);
      expect(two.dimmed, isTrue);
    });

    test('criterion highlight flags linked markers', () {
      final m = RetinalMarkers.fromJson(_evidencePayload());
      final markers = LesionMarkerPainter.drawableMarkers(
        m,
        const Rect.fromLTWH(0, 0, 400, 300),
        1.0,
        highlightCriterionId: 'icdrss.exudate_present',
      );
      final exudate = markers.firstWhere((k) => k.lesionId == 'LE-0002');
      final ma = markers.firstWhere((k) => k.lesionId == 'LE-0001');
      expect(exudate.criterionHighlighted, isTrue);
      expect(ma.criterionHighlighted, isFalse);
    });
  });

  group('evidence strings', () {
    test('criterion ids resolve to titles; unknown falls back to key', () {
      expect(
        EvidenceStrings.t('icdrss.ma_present'),
        isNot('icdrss.ma_present'),
      );
      expect(EvidenceStrings.t('icdrss.unknown_thing'), 'icdrss.unknown_thing');
      expect(EvidenceStrings.t('policy_label', lang: 'hi'), isNotEmpty);
    });
  });
}
