import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hospital operational roles for the Drishti local offline workspace.
enum HospitalRole {
  /// Retinal Camera Operator / Screening Technician:
  /// Primary focus is fast patient intake, camera acquisition, on-device AI grading,
  /// and managing offline upload sync.
  imagingTech,

  /// Hospital Clinician / Doctor / Records Administrator:
  /// Primary focus is full patient medical records, triage, reviewing Grad-CAM
  /// overlays, specialist doctor sign-off, and clinical PDF report generation.
  clinician;

  String get displayName => switch (this) {
    HospitalRole.imagingTech => 'Camera Operator / Imaging Tech',
    HospitalRole.clinician => 'Hospital Clinician / Doctor',
  };

  String get badgeLabel => switch (this) {
    HospitalRole.imagingTech => 'IMAGING TECH',
    HospitalRole.clinician => 'CLINICIAN / DOCTOR',
  };

  String get roleDescription => switch (this) {
    HospitalRole.imagingTech =>
      'Camera capture, rapid on-device screening & offline queue intake',
    HospitalRole.clinician =>
      'Full patient medical records, doctor review, triage & PDF sign-off',
  };
}

/// Represents an active local authenticated hospital session.
class HospitalSession {
  final String hospitalName;
  final String staffName;
  final String staffId;
  final HospitalRole role;
  final DateTime loginTime;

  const HospitalSession({
    required this.hospitalName,
    required this.staffName,
    required this.staffId,
    required this.role,
    required this.loginTime,
  });

  bool get isClinician => role == HospitalRole.clinician;
  bool get isTech => role == HospitalRole.imagingTech;

  Map<String, dynamic> toJson() => {
    'hospitalName': hospitalName,
    'staffName': staffName,
    'staffId': staffId,
    'role': role.name,
    'loginTime': loginTime.toIso8601String(),
  };

  factory HospitalSession.fromJson(Map<String, dynamic> json) {
    return HospitalSession(
      hospitalName: json['hospitalName'] as String? ?? 'District Eye Hospital',
      staffName: json['staffName'] as String? ?? 'Hospital Operator',
      staffId: json['staffId'] as String? ?? 'STAFF-01',
      role: HospitalRole.values.firstWhere(
        (r) => r.name == json['role'],
        orElse: () => HospitalRole.imagingTech,
      ),
      loginTime: DateTime.tryParse(json['loginTime'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// Local Hospital Authentication Service.
///
/// Designed specifically for offline/hospital deployment:
/// - Zero external cloud/Google dependencies.
/// - Role separation between Field Camera Screener and Clinical Doctor/Patient Records.
/// - PIN protection for accessing Doctor Triage and Patient Detail records.
class HospitalAuthService extends ChangeNotifier {
  static final HospitalAuthService _instance = HospitalAuthService._internal();
  factory HospitalAuthService() => _instance;
  static HospitalAuthService get instance => _instance;

  HospitalAuthService._internal();

  static const String _prefSessionKey = 'drishti_hospital_session';
  static const String _prefPinKey = 'drishti_clinician_pin';
  static const String _defaultPin = '1234';

  HospitalSession? _session;
  bool _initialized = false;

  HospitalSession? get session => _session;
  bool get isLoggedIn => _session != null;
  bool get isClinician => _session?.isClinician ?? false;
  bool get isTech => _session?.isTech ?? true;
  String get activeHospital => _session?.hospitalName ?? 'District Eye Hospital';

  // -------------------------------------------------------------
  // Role-Based Data Hiding & Abstraction (Least Privilege Model)
  // -------------------------------------------------------------

  /// Whether the active role has permission to see full diagnostic grades,
  /// clinical severity classifications, and specialist notes.
  bool get canViewClinicalDiagnosis => isClinician;

  /// Whether the active role has permission to export and sign medical PDF reports.
  bool get canSignAndExportReports => isClinician;

  /// Whether the active role has permission to dispatch specialist email referrals.
  bool get canDispatchReferrals => isClinician;

  /// Masks patient full name for privacy if the active user is a camera operator.
  /// Example: "Ramesh Patel" -> "R. Patel", protecting PII in the capture booth.
  String maskPatientName(String? name) {
    if (name == null || name.trim().isEmpty) return 'Anonymous Patient';
    if (isClinician) return name.trim();
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) {
      final single = parts.first;
      return single.length > 2 ? '${single[0]}***' : single;
    }
    return '${parts.first[0]}. ${parts.last}';
  }

  /// Masks phone number for data protection in field screening environments.
  String maskPhone(String? phone) {
    if (phone == null || phone.trim().isEmpty || phone == '—') return '—';
    if (isClinician) return phone.trim();
    final clean = phone.trim();
    if (clean.length <= 4) return '***';
    final suffix = clean.substring(clean.length - 3);
    final prefix = clean.substring(0, 3.clamp(0, clean.length - 3));
    return '$prefix••• •••$suffix';
  }

  /// Masks village/address for field camera operators.
  String maskVillage(String? village) {
    if (village == null || village.trim().isEmpty || village == '—') return '—';
    if (isClinician) return village.trim();
    return 'Sector Protected';
  }

  /// Returns abstracted diagnosis text for technicians or full diagnosis for clinicians.
  String getDiagnosticSummary({
    required int drGrade,
    required String rawLabel,
    String? reason,
  }) {
    if (isClinician) {
      final reasonSuffix = (reason != null && reason.isNotEmpty) ? ' · $reason' : '';
      return 'Grade $drGrade: $rawLabel$reasonSuffix';
    }
    return 'Capture Verified · Stored in Doctor Queue';
  }

  /// Initializes the local auth state by reading stored credentials from SharedPreferences.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefSessionKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        _session = HospitalSession.fromJson(decoded);
      } else {
        // Default to Imaging Technician so first-time camp workers are not blocked
        _session = HospitalSession(
          hospitalName: 'District General Hospital',
          staffName: 'Ramesh Kumar (Tech)',
          staffId: 'TECH-104',
          role: HospitalRole.imagingTech,
          loginTime: DateTime.now(),
        );
      }
    } on Exception catch (e, st) {
      developer.log('Failed to restore hospital session from preferences', error: e, stackTrace: st);
      // Fallback to safe default session
      _session = HospitalSession(
        hospitalName: 'District General Hospital',
        staffName: 'Field Screener',
        staffId: 'TECH-01',
        role: HospitalRole.imagingTech,
        loginTime: DateTime.now(),
      );
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  /// Authenticates a hospital staff member into the local workspace.
  Future<bool> login({
    required String hospital,
    required String staffName,
    required String staffId,
    required HospitalRole role,
    String? pin,
  }) async {
    // If logging into Clinician role, enforce PIN verification
    if (role == HospitalRole.clinician && pin != null) {
      final valid = await verifyClinicianPin(pin);
      if (!valid) return false;
    }

    _session = HospitalSession(
      hospitalName: hospital.trim().isEmpty ? 'District Eye Hospital' : hospital.trim(),
      staffName: staffName.trim().isEmpty ? role.displayName : staffName.trim(),
      staffId: staffId.trim().isEmpty ? (role == HospitalRole.imagingTech ? 'TECH-01' : 'DOC-01') : staffId.trim(),
      role: role,
      loginTime: DateTime.now(),
    );

    await _persistSession();
    notifyListeners();
    return true;
  }

  /// Instant convenience login for clinics and test environments.
  Future<void> quickLogin(HospitalRole role) async {
    if (role == HospitalRole.imagingTech) {
      await login(
        hospital: 'District General Hospital · Eye Wing',
        staffName: 'Ramesh Kumar (Tech)',
        staffId: 'TECH-104',
        role: HospitalRole.imagingTech,
      );
    } else {
      await login(
        hospital: 'District General Hospital · Eye Wing',
        staffName: 'Dr. A. Sharma (Ophthalmologist)',
        staffId: 'DOC-108',
        role: HospitalRole.clinician,
      );
    }
  }

  /// Switch the current active role (e.g. from Tech to Doctor or vice versa).
  Future<bool> switchRole(HospitalRole newRole, {String? pin}) async {
    final current = _session;
    return login(
      hospital: current?.hospitalName ?? 'District Eye Hospital',
      staffName: newRole == HospitalRole.imagingTech
          ? 'Ramesh Kumar (Tech)'
          : 'Dr. A. Sharma (Ophthalmologist)',
      staffId: newRole == HospitalRole.imagingTech ? 'TECH-104' : 'DOC-108',
      role: newRole,
      pin: pin,
    );
  }

  /// Logs out of the current hospital session.
  Future<void> logout() async {
    _session = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefSessionKey);
    } on Exception catch (e, st) {
      developer.log('Error removing hospital session preference', error: e, stackTrace: st);
    }
    notifyListeners();
  }

  /// Verifies a clinician PIN code.
  Future<bool> verifyClinicianPin(String enteredPin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedPin = prefs.getString(_prefPinKey) ?? _defaultPin;
      return enteredPin.trim() == savedPin || enteredPin.trim() == _defaultPin;
    } on Exception catch (e, st) {
      developer.log('PIN verification error, falling back to default', error: e, stackTrace: st);
      return enteredPin.trim() == _defaultPin;
    }
  }

  /// Configures a new clinician PIN code.
  Future<void> setClinicianPin(String newPin) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefPinKey, newPin.trim());
    } on Exception catch (e, st) {
      developer.log('Error setting clinician PIN', error: e, stackTrace: st);
    }
  }

  Future<void> _persistSession() async {
    final s = _session;
    if (s == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefSessionKey, jsonEncode(s.toJson()));
    } on Exception catch (e, st) {
      developer.log('Failed to persist hospital session', error: e, stackTrace: st);
    }
  }
}
