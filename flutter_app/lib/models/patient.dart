import 'dart:convert';

class Patient {
  final String patientId;
  final String abhaId;
  final String name;
  final int age;
  final String gender;
  final String phone;
  final String village;
  final String screeningCentre;
  final String knownDiabetes;
  final double diabetesDurationYears;
  // Nullable vitals: null means "not measured" and the key is OMITTED from
  // toJson, because the backend rejects 0.0 (hba1c ge=3, fasting ge=20,
  // bmi ge=10). Never send invented zeros as clinical measurements.
  final double? hba1c;
  final double? fastingGlucose;
  final String bloodPressure;
  final double? bmi;
  final bool familyHistory;
  final String physicalActivity;
  final List<String> symptoms;
  final String? createdAt;

  /// Clinical fields default to neutral "unknown" values matching the
  /// backend (`known_diabetes="Unknown"`, nullables unset). Never invent a
  /// clinical profile: the check-in form must supply real measurements.
  Patient({
    required this.patientId,
    required this.abhaId,
    required this.name,
    required this.age,
    required this.gender,
    required this.phone,
    required this.village,
    required this.screeningCentre,
    this.knownDiabetes = 'Unknown',
    this.diabetesDurationYears = 0.0,
    this.hba1c,
    this.fastingGlucose,
    this.bloodPressure = '',
    this.bmi,
    this.familyHistory = false,
    this.physicalActivity = 'Moderate',
    this.symptoms = const [],
    this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'patient_id': patientId,
    'abha_id': abhaId,
    'name': name,
    'age': age,
    'gender': gender,
    'phone': phone,
    'village': village,
    'screening_centre': screeningCentre,
    'known_diabetes': knownDiabetes,
    'diabetes_duration_years': diabetesDurationYears,
    if (hba1c != null) 'hba1c': hba1c,
    if (fastingGlucose != null) 'fasting_glucose': fastingGlucose,
    if (bloodPressure.isNotEmpty) 'blood_pressure': bloodPressure,
    if (bmi != null) 'bmi': bmi,
    'family_history': familyHistory,
    'physical_activity': physicalActivity,
    'symptoms': symptoms,
    if (createdAt != null) 'created_at': createdAt,
  };

  static List<String> _parseSymptoms(dynamic raw) {
    if (raw == null) return [];
    if (raw is String) {
      if (raw.trim().isEmpty) return [];
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          return decoded.map((e) => e.toString()).toList();
        }
        return [];
      } catch (_) {
        return [];
      }
    }
    if (raw is List) {
      return raw.map((e) => e.toString()).toList();
    }
    return [];
  }

  factory Patient.fromJson(Map<String, dynamic> json) => Patient(
    patientId: json['patient_id'] ?? '',
    abhaId: json['abha_id'] ?? '',
    name: json['name'] ?? '',
    age: json['age'] ?? 0,
    gender: json['gender'] ?? 'Unknown',
    phone: json['phone'] ?? '',
    village: json['village'] ?? '',
    screeningCentre: json['screening_centre'] ?? '',
    knownDiabetes: json['known_diabetes'] ?? 'Unknown',
    diabetesDurationYears:
        (json['diabetes_duration_years'] as num?)?.toDouble() ?? 0.0,
    hba1c: (json['hba1c'] as num?)?.toDouble(),
    fastingGlucose: (json['fasting_glucose'] as num?)?.toDouble(),
    bloodPressure: json['blood_pressure'] ?? '',
    bmi: (json['bmi'] as num?)?.toDouble(),
    familyHistory:
        json['family_history'] == true || json['family_history'] == 1,
    physicalActivity: json['physical_activity'] ?? 'Unknown',
    symptoms: _parseSymptoms(json['symptoms']),
    createdAt: json['created_at']?.toString(),
  );
}
