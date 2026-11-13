import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Versioned, per-patient consent records (Ticket C-3, DPDP S.5/S.6).
///
/// Stored locally ONLY (patient local id + decision — no PHI). Default is
/// refusal: nothing leaves the device unless the operator captured explicit
/// consent for THAT patient. Withdrawal is one tap and immediately flips
/// sync eligibility off.
class ConsentService {
  ConsentService({SharedPreferences? prefs}) : _prefs = prefs;

  static const consentVersion = 'v1-2026-09';
  static const _storeKey = 'netra_consent_records';

  SharedPreferences? _prefs;

  Future<SharedPreferences> _store() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  Future<ConsentRecord?> get(String localPatientId) async {
    final prefs = await _store();
    final raw = prefs.getString('$_storeKey:$localPatientId');
    if (raw == null) return null;
    try {
      return ConsentRecord.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    }
  }

  /// Records explicit consent for the referral uplink.
  Future<ConsentRecord> grant(
    String localPatientId, {
    String language = 'en',
  }) async {
    final record = ConsentRecord(
      localPatientId: localPatientId,
      version: consentVersion,
      granted: true,
      grantedAt: DateTime.now().toUtc(),
      language: language,
    );
    await _write(record);
    return record;
  }

  /// Records explicit refusal (stored so the operator sees the decision).
  Future<ConsentRecord> refuse(
    String localPatientId, {
    String language = 'en',
  }) async {
    final record = ConsentRecord(
      localPatientId: localPatientId,
      version: consentVersion,
      granted: false,
      grantedAt: DateTime.now().toUtc(),
      language: language,
    );
    await _write(record);
    return record;
  }

  /// DPDP right-to-withdraw: one tap, effective immediately.
  Future<ConsentRecord> withdraw(
    String localPatientId, {
    String language = 'en',
  }) async {
    final record = ConsentRecord(
      localPatientId: localPatientId,
      version: consentVersion,
      granted: false,
      grantedAt: DateTime.now().toUtc(),
      withdrawnAt: DateTime.now().toUtc(),
      language: language,
    );
    await _write(record);
    return record;
  }

  Future<void> _write(ConsentRecord record) async {
    final prefs = await _store();
    await prefs.setString(
      '$_storeKey:${record.localPatientId}',
      jsonEncode(record.toJson()),
    );
  }
}

class ConsentRecord {
  const ConsentRecord({
    required this.localPatientId,
    required this.version,
    required this.granted,
    required this.grantedAt,
    this.withdrawnAt,
    this.language = 'en',
  });

  final String localPatientId;
  final String version;
  final bool granted;
  final DateTime grantedAt;
  final DateTime? withdrawnAt;
  final String language;

  /// True only when consent is granted for the CURRENT version and has not
  /// been withdrawn — a stale version or a withdrawal both block upload.
  bool get isSyncAllowed => granted && withdrawnAt == null;

  Map<String, dynamic> toJson() => {
    'local_patient_id': localPatientId,
    'version': version,
    'granted': granted,
    'granted_at': grantedAt.toIso8601String(),
    'withdrawn_at': withdrawnAt?.toIso8601String(),
    'language': language,
  };

  factory ConsentRecord.fromJson(Map<String, dynamic> json) {
    return ConsentRecord(
      localPatientId: json['local_patient_id'] as String? ?? '',
      version: json['version'] as String? ?? '',
      granted: json['granted'] as bool? ?? false,
      grantedAt:
          DateTime.tryParse(json['granted_at'] as String? ?? '') ??
          DateTime.now().toUtc(),
      withdrawnAt: json['withdrawn_at'] == null
          ? null
          : DateTime.tryParse(json['withdrawn_at'] as String),
      language: json['language'] as String? ?? 'en',
    );
  }
}
