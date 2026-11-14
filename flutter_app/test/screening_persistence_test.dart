import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drishti/models/screening_models.dart';
import 'package:drishti/screens/figma_dashboard_screen.dart';
import 'package:drishti/screens/flow/flow_state.dart';
import 'package:drishti/services/db/screening_persistence_service.dart';
import 'package:drishti/theme/figma_theme.dart';
import 'package:drishti/widgets/status_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('ScreeningPersistenceService Tests', () {
    test('getRecentScreenings returns default clinical records when empty', () async {
      final service = ScreeningPersistenceService();
      final records = await service.getRecentScreenings(limit: 10);

      expect(records, isNotEmpty);
      expect(records.length, greaterThanOrEqualTo(3));

      final first = records.first;
      expect(first['local_patient_id'], isNotNull);
      expect(first['name'], isNotNull);
      expect(first['dr_label'], isNotNull);

      // Verify mapping to localScreeningRow
      final row = localScreeningRow(first);
      expect(row.$1, isNotEmpty); // pid
      expect(row.$2, isNotEmpty); // name
      expect(row.$3, isNotEmpty); // date
      expect(row.$4, isNotEmpty); // result label
      expect(row.$5, isA<FigmaStatus>()); // status
    });

    test('saveScreening saves a new screening and prepends to getRecentScreenings', () async {
      final service = ScreeningPersistenceService();

      final state = FlowState(
        patient: PatientModel(
          patientId: 'PT-TEST-999',
          name: 'Meera Sharma',
          age: 52,
          gender: 'Female',
          phone: '9822000000',
          abhaId: '',
          village: 'Koregaon Park',
          knownDiabetes: 'Yes',
          diabetesDurationYears: 5.0,
          hba1c: 7.8,
        ),
        eyeSide: 'Right',
        analysis: ScreeningAnalysisModel.fromJson({
          'screening_id': 'LOC-SCR-999',
          'patient_id': 'PT-TEST-999',
          'eye_side': 'Right',
          'camera_profile': 'Remidio FOP (Smartphone Handheld)',
          'quality_grade': 'GOOD',
          'quality_score': 0.98,
          'quality_passed': true,
          'rejection_reasons': <String>[],
          'dr_grade': 1,
          'dr_label': 'Mild NPDR',
          'prediction_score': 0.96,
          'is_referable': false,
          'requires_human_review': false,
          'original_image_url': '',
          'action_recommendation': 'Annual screening',
          'plain_language_advice': 'Mild changes noted, monitor annually',
          'sms_referral_slip': '',
        }),
      );

      final ok = await service.saveScreening(state);
      expect(ok, isTrue);

      final updated = await service.getRecentScreenings(limit: 10);
      expect(updated, isNotEmpty);
      final meera = updated.firstWhere(
        (r) => r['local_patient_id'] == 'PT-TEST-999',
      );
      expect(meera['name'], 'Meera Sharma');
      expect(meera['dr_label'], 'Mild NPDR');
      expect(meera['dr_grade_num'], 1);

      final row = localScreeningRow(meera);
      expect(row.$1, 'PT-TEST-999');
      expect(row.$2, 'Meera Sharma');
      expect(row.$4, 'Mild NPDR');
    });

    test('updateRecord modifies existing patient details and persists', () async {
      final service = ScreeningPersistenceService();
      final records = await service.getRecentScreenings();
      final first = Map<String, dynamic>.from(records.first);
      final sid = first['local_screening_id'] as String;

      first['name'] = 'Updated Patient Name';
      first['age'] = 62;
      first['dr_label'] = 'Severe NPDR';
      first['dr_grade_num'] = 3;

      final ok = await service.updateRecord(first);
      expect(ok, isTrue);

      final updatedRecords = await service.getRecentScreenings();
      final target = updatedRecords.firstWhere((r) => r['local_screening_id'] == sid);
      expect(target['name'], 'Updated Patient Name');
      expect(target['age'], 62);
      expect(target['dr_grade_num'], 3);
    });

    test('createManualRecord and deleteRecord manage manual patient history entries', () async {
      final service = ScreeningPersistenceService();
      final manual = {
        'local_screening_id': 'SCR-MANUAL-12345',
        'local_patient_id': 'PT-12345',
        'name': 'Kavita Rao',
        'age': 44,
        'gender': 'Female',
        'village': 'Shirwal',
        'phone': '9876543210',
        'eye_side': 'Left',
        'dr_grade_num': 2,
        'dr_label': 'Moderate NPDR',
        'human_review_reason': 'Manual entry verification',
      };

      final created = await service.createManualRecord(manual);
      expect(created, isTrue);

      var records = await service.getRecentScreenings();
      expect(records.any((r) => r['local_screening_id'] == 'SCR-MANUAL-12345'), isTrue);

      final deleted = await service.deleteRecord('SCR-MANUAL-12345');
      expect(deleted, isTrue);

      records = await service.getRecentScreenings();
      expect(records.any((r) => r['local_screening_id'] == 'SCR-MANUAL-12345'), isFalse);
    });
  });
}
