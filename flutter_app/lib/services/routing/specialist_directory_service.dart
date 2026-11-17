import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/specialist_models.dart';
import '../app_config.dart';
import 'routing_engine.dart';

/// Locally persisted specialist directory + screening-centre origin.
///
/// The directory contains professional contact data only (no patient PHI), so
/// it lives in SharedPreferences and is available fully offline. Patient data
/// never enters this service. The directory can be maintained from the Admin
/// Portal and is seeded with clearly-labelled demo entries only when demo mode
/// is explicitly enabled.
class SpecialistDirectoryService with ChangeNotifier {
  SpecialistDirectoryService._();

  static final SpecialistDirectoryService instance = SpecialistDirectoryService._();

  static const String _directoryKey = 'drishti_specialist_directory_v1';
  static const String _originKey = 'drishti_screening_centre_v1';

  final RoutingEngine _engine = const RoutingEngine();

  List<Specialist> _specialists = const [];
  ScreeningCentre? _origin;
  bool _loaded = false;

  static int _idCounter = 0;

  List<Specialist> get specialists => List.unmodifiable(_specialists);
  ScreeningCentre? get origin => _origin;
  bool get isLoaded => _loaded;
  bool get isRoutable => _origin?.isRoutable == true && _specialists.isNotEmpty;

  Specialist? specialistById(String id) {
    for (final s in _specialists) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> load({bool reload = false}) async {
    if (_loaded && !reload) return;
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString(_directoryKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _specialists = decoded
            .whereType<Map>()
            .map((e) => Specialist.fromJson(Map<String, dynamic>.from(e)))
            .where((s) => s.id.isNotEmpty && s.name.isNotEmpty)
            .toList();
      } catch (e) {
        debugPrint('Specialist directory decode failed: $e');
        _specialists = const [];
      }
    }

    final rawOrigin = prefs.getString(_originKey);
    if (rawOrigin != null && rawOrigin.isNotEmpty) {
      try {
        _origin = ScreeningCentre.fromJson(
          Map<String, dynamic>.from(jsonDecode(rawOrigin) as Map),
        );
      } catch (e) {
        debugPrint('Screening centre decode failed: $e');
        _origin = null;
      }
    }

    if (_specialists.isEmpty && _origin == null && AppConfig.demoMode) {
      _loadDemoState(markDemo: true);
      await _persist();
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> setOrigin(ScreeningCentre centre) async {
    _origin = centre;
    await _persist();
    notifyListeners();
  }

  Future<void> saveSpecialist(Specialist specialist) async {
    final normalized = specialist.id.isEmpty
        ? specialist.copyWith(id: _newId())
        : specialist;
    final index = _specialists.indexWhere((s) => s.id == normalized.id);
    final next = [..._specialists];
    if (index >= 0) {
      next[index] = normalized;
    } else {
      next.add(normalized);
    }
    _specialists = next;
    await _persist();
    notifyListeners();
  }

  Future<void> deleteSpecialist(String id) async {
    _specialists = _specialists.where((s) => s.id != id).toList();
    await _persist();
    notifyListeners();
  }

  /// Explicitly loads the synthetic directory (Admin action). The entries are
  /// flagged `is_demo` and rendered with a DEMO badge.
  Future<void> loadDemoDirectory() async {
    _loadDemoState(markDemo: true);
    await _persist();
    notifyListeners();
  }

  Future<void> clearAll() async {
    _specialists = const [];
    _origin = null;
    await _persist();
    notifyListeners();
  }

  List<SpecialistRoute> rankForGrade(int grade) {
    final origin = _origin;
    if (origin == null || !origin.isRoutable) return const [];
    return _engine.rank(
      grade: grade,
      specialists: _specialists,
      origin: origin,
    );
  }

  ReferralPlan? planForGrade(int grade) {
    final origin = _origin;
    if (origin == null || !origin.isRoutable) return null;
    return _engine.plan(
      grade: grade,
      specialists: _specialists,
      origin: origin,
    );
  }

  String _newId() {
    _idCounter++;
    return 'sp-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$_idCounter';
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _directoryKey,
      jsonEncode(_specialists.map((e) => e.toJson()).toList()),
    );
    final origin = _origin;
    if (origin == null) {
      await prefs.remove(_originKey);
    } else {
      await prefs.setString(_originKey, jsonEncode(origin.toJson()));
    }
  }

  void _loadDemoState({required bool markDemo}) {
    _origin = const ScreeningCentre(
      name: 'PHC Bhor (Demo)',
      address: 'Bhor, Pune District, Maharashtra',
      location: GeoPoint(18.1700, 73.8450),
    );
    _specialists = _demoSpecialists(markDemo: markDemo);
  }

  static List<Specialist> _demoSpecialists({required bool markDemo}) {
    Specialist demo({
      required String id,
      required String name,
      required String qualification,
      required String facility,
      required String address,
      required String city,
      required String district,
      required GeoPoint location,
      required String email,
      required String phone,
      String teleconsultUrl = '',
      required Set<String> capabilities,
      required int maxGrade,
      required int waitDays,
      required bool inPerson,
      required bool teleconsult,
      String? idSuffix,
    }) {
      return Specialist(
        id: 'demo-$id${idSuffix ?? ''}',
        name: name,
        qualification: qualification,
        facilityName: facility,
        address: address,
        city: city,
        district: district,
        location: location,
        email: email,
        phone: phone,
        teleconsultUrl: teleconsultUrl,
        capabilities: capabilities,
        maxGrade: maxGrade,
        averageWaitDays: waitDays,
        acceptsInPerson: inPerson,
        teleconsultEnabled: teleconsult,
        active: true,
        isDemo: markDemo,
      );
    }

    return [
      demo(
        id: 'sassoon',
        name: 'Dr. Ananya Deshmukh',
        qualification: 'MS Ophthalmology, Retina Fellowship',
        facility: 'Sassoon General Hospital — Retina Clinic',
        address: 'Sassoon Road, Agarkar Nagar',
        city: 'Pune',
        district: 'Pune',
        location: const GeoPoint(18.5196, 73.8553),
        email: 'retina.sassoon@example.org',
        phone: '+91 20 2612 8000',
        teleconsultUrl: 'https://teleconsult.example.org/sassoon-retina',
        capabilities: const {'retina', 'vitreoretinal'},
        maxGrade: 4,
        waitDays: 1,
        inPerson: true,
        teleconsult: true,
      ),
      demo(
        id: 'ruby',
        name: 'Dr. Vikram Joshi',
        qualification: 'MS Ophthalmology, VR Surgery',
        facility: 'Ruby Hall Clinic — Vitreoretinal Services',
        address: '40 Sassoon Road',
        city: 'Pune',
        district: 'Pune',
        location: const GeoPoint(18.5310, 73.8770),
        email: 'vr.rubyhall@example.org',
        phone: '+91 20 6645 5555',
        teleconsultUrl: 'https://teleconsult.example.org/ruby-vr',
        capabilities: const {'retina', 'vitreoretinal'},
        maxGrade: 4,
        waitDays: 2,
        inPerson: true,
        teleconsult: true,
      ),
      demo(
        id: 'kEM',
        name: 'Dr. Meera Kulkarni',
        qualification: 'MD Ophthalmology',
        facility: 'KEM Hospital — Ophthalmology',
        address: 'Rasta Peth',
        city: 'Pune',
        district: 'Pune',
        location: const GeoPoint(18.5140, 73.8730),
        email: 'ophth.kem@example.org',
        phone: '+91 20 2612 7000',
        teleconsultUrl: 'https://teleconsult.example.org/kem-eye',
        capabilities: const {'retina', 'general'},
        maxGrade: 3,
        waitDays: 3,
        inPerson: true,
        teleconsult: true,
      ),
      demo(
        id: 'satara',
        name: 'Dr. Rohan Patil',
        qualification: 'MS Ophthalmology',
        facility: 'District Eye Care Centre — Satara',
        address: 'Sadar Bazar',
        city: 'Satara',
        district: 'Satara',
        location: const GeoPoint(17.6805, 74.0183),
        email: 'eyecare.satara@example.org',
        phone: '+91 2162 234 567',
        capabilities: const {'retina', 'general'},
        maxGrade: 4,
        waitDays: 5,
        inPerson: true,
        teleconsult: false,
      ),
      demo(
        id: 'shirwal',
        name: 'Dr. Sneha More',
        qualification: 'MBBS, DO',
        facility: 'Shirwal Rural Eye Centre',
        address: 'Station Road',
        city: 'Shirwal',
        district: 'Satara',
        location: const GeoPoint(18.1350, 73.9860),
        email: 'eyecare.shirwal@example.org',
        phone: '+91 2162 255 100',
        teleconsultUrl: 'https://teleconsult.example.org/shirwal',
        capabilities: const {'general'},
        maxGrade: 1,
        waitDays: 1,
        inPerson: true,
        teleconsult: true,
      ),
      demo(
        id: 'aundh',
        name: 'Dr. Farah Khan',
        qualification: 'DNB Ophthalmology',
        facility: 'Aundh District Hospital',
        address: 'Aundh',
        city: 'Pune',
        district: 'Pune',
        location: const GeoPoint(18.5590, 73.8070),
        email: 'ophth.aundh@example.org',
        phone: '+91 20 2588 9000',
        teleconsultUrl: 'https://teleconsult.example.org/aundh-eye',
        capabilities: const {'general'},
        maxGrade: 2,
        waitDays: 2,
        inPerson: true,
        teleconsult: true,
      ),
    ];
  }
}
