import 'dart:math' as math;

/// Geographic point used by the offline referral router.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  /// Great-circle distance in kilometres (Haversine).
  double distanceKmTo(GeoPoint other) {
    const earthRadiusKm = 6371.0088;
    final dLat = _toRadians(other.latitude - latitude);
    final dLon = _toRadians(other.longitude - longitude);
    final lat1 = _toRadians(latitude);
    final lat2 = _toRadians(other.latitude);
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * earthRadiusKm * math.asin(math.min(1, math.sqrt(h)));
  }

  static double _toRadians(double degrees) => degrees * math.pi / 180.0;

  Map<String, dynamic> toJson() => {
        'lat': latitude,
        'lng': longitude,
      };

  static GeoPoint? fromJson(Object? value) {
    if (value is! Map) return null;
    final lat = (value['lat'] as num?)?.toDouble();
    final lng = (value['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
    return GeoPoint(lat, lng);
  }

  @override
  String toString() =>
      '${latitude.toStringAsFixed(4)},${longitude.toStringAsFixed(4)}';
}

/// The screening site that acts as the origin of a referral route.
class ScreeningCentre {
  const ScreeningCentre({
    required this.name,
    required this.location,
    this.address = '',
  });

  final String name;
  final GeoPoint? location;
  final String address;

  bool get isRoutable => location != null;

  ScreeningCentre copyWith({String? name, GeoPoint? location, String? address}) {
    return ScreeningCentre(
      name: name ?? this.name,
      location: location ?? this.location,
      address: address ?? this.address,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'address': address,
        'location': location?.toJson(),
      };

  factory ScreeningCentre.fromJson(Map<String, dynamic> json) {
    return ScreeningCentre(
      name: json['name']?.toString() ?? 'Screening Centre',
      address: json['address']?.toString() ?? '',
      location: GeoPoint.fromJson(json['location']),
    );
  }
}

/// A referral destination. A specialist is attached to a facility; the
/// facility coordinates are what the router uses.
class Specialist {
  const Specialist({
    required this.id,
    required this.name,
    required this.facilityName,
    this.qualification = 'MS Ophthalmology',
    this.address = '',
    this.city = '',
    this.district = '',
    this.location,
    this.email = '',
    this.phone = '',
    this.teleconsultUrl = '',
    this.capabilities = const {'retina'},
    this.maxGrade = 4,
    this.averageWaitDays = 3,
    this.acceptsInPerson = true,
    this.teleconsultEnabled = true,
    this.active = true,
    this.isDemo = false,
  });

  final String id;
  final String name;
  final String qualification;
  final String facilityName;
  final String address;
  final String city;
  final String district;
  final GeoPoint? location;
  final String email;
  final String phone;
  final String teleconsultUrl;

  /// e.g. `retina`, `vitreoretinal`, `glaucoma`, `general`.
  final Set<String> capabilities;

  /// Highest ICDR grade this destination is equipped to manage.
  final int maxGrade;
  final int averageWaitDays;
  final bool acceptsInPerson;
  final bool teleconsultEnabled;
  final bool active;

  /// Synthetic directory entries are labelled in the UI and never presented
  /// as a real clinical destination.
  final bool isDemo;

  bool get hasLocation => location != null;
  bool get canEmail => email.trim().isNotEmpty;
  bool get canTeleconsult =>
      teleconsultEnabled && (teleconsultUrl.trim().isNotEmpty || phone.trim().isNotEmpty);
  bool get canReceiveReferral => canEmail || canTeleconsult;

  bool supportsGrade(int grade) => grade <= maxGrade;

  bool hasCapabilityFor(int grade) {
    if (grade < 2) return true;
    return capabilities.contains('retina') ||
        capabilities.contains('vitreoretinal') ||
        capabilities.contains('ophthalmology');
  }

  String get displayName =>
      name.trim().toLowerCase().startsWith('dr') ? name.trim() : 'Dr. ${name.trim()}';

  String get fullAddress {
    final parts = [facilityName, address, city, district]
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    return parts.join(', ');
  }

  Specialist copyWith({
    String? id,
    String? name,
    String? qualification,
    String? facilityName,
    String? address,
    String? city,
    String? district,
    GeoPoint? location,
    bool clearLocation = false,
    String? email,
    String? phone,
    String? teleconsultUrl,
    Set<String>? capabilities,
    int? maxGrade,
    int? averageWaitDays,
    bool? acceptsInPerson,
    bool? teleconsultEnabled,
    bool? active,
    bool? isDemo,
  }) {
    return Specialist(
      id: id ?? this.id,
      name: name ?? this.name,
      qualification: qualification ?? this.qualification,
      facilityName: facilityName ?? this.facilityName,
      address: address ?? this.address,
      city: city ?? this.city,
      district: district ?? this.district,
      location: clearLocation ? null : (location ?? this.location),
      email: email ?? this.email,
      phone: phone ?? this.phone,
      teleconsultUrl: teleconsultUrl ?? this.teleconsultUrl,
      capabilities: capabilities ?? this.capabilities,
      maxGrade: maxGrade ?? this.maxGrade,
      averageWaitDays: averageWaitDays ?? this.averageWaitDays,
      acceptsInPerson: acceptsInPerson ?? this.acceptsInPerson,
      teleconsultEnabled: teleconsultEnabled ?? this.teleconsultEnabled,
      active: active ?? this.active,
      isDemo: isDemo ?? this.isDemo,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'qualification': qualification,
        'facility_name': facilityName,
        'address': address,
        'city': city,
        'district': district,
        'location': location?.toJson(),
        'email': email,
        'phone': phone,
        'teleconsult_url': teleconsultUrl,
        'capabilities': capabilities.toList()..sort(),
        'max_grade': maxGrade,
        'average_wait_days': averageWaitDays,
        'accepts_in_person': acceptsInPerson,
        'teleconsult_enabled': teleconsultEnabled,
        'active': active,
        'is_demo': isDemo,
      };

  factory Specialist.fromJson(Map<String, dynamic> json) {
    final capabilities = (json['capabilities'] as List?)
            ?.map((e) => e.toString().trim().toLowerCase())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        <String>{'retina'};
    return Specialist(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      qualification: json['qualification']?.toString() ?? 'MS Ophthalmology',
      facilityName: json['facility_name']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      city: json['city']?.toString() ?? '',
      district: json['district']?.toString() ?? '',
      location: GeoPoint.fromJson(json['location']),
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      teleconsultUrl: json['teleconsult_url']?.toString() ?? '',
      capabilities: capabilities,
      maxGrade: (json['max_grade'] as num?)?.toInt().clamp(0, 4) ?? 4,
      averageWaitDays: (json['average_wait_days'] as num?)?.toInt() ?? 3,
      acceptsInPerson: json['accepts_in_person'] as bool? ?? true,
      teleconsultEnabled: json['teleconsult_enabled'] as bool? ?? true,
      active: json['active'] as bool? ?? true,
      isDemo: json['is_demo'] as bool? ?? false,
    );
  }
}

enum ReferralUrgency {
  routine,
  priority,
  urgent;

  static ReferralUrgency forGrade(int grade) {
    if (grade >= 4) return ReferralUrgency.urgent;
    if (grade >= 3) return ReferralUrgency.priority;
    return ReferralUrgency.routine;
  }

  String get label => switch (this) {
        ReferralUrgency.urgent => 'Urgent — within 48 hours',
        ReferralUrgency.priority => 'Priority — within 1 week',
        ReferralUrgency.routine => 'Routine — within 4 weeks',
      };

  String get shortLabel => switch (this) {
        ReferralUrgency.urgent => 'Urgent',
        ReferralUrgency.priority => 'Priority',
        ReferralUrgency.routine => 'Routine',
      };
}

enum ReferralMode {
  inPerson,
  teleconsult;

  String get label => switch (this) {
        ReferralMode.inPerson => 'In person',
        ReferralMode.teleconsult => 'Teleconsult',
      };
}

/// A scored route to one specialist.
class SpecialistRoute {
  const SpecialistRoute({
    required this.specialist,
    required this.distanceKm,
    required this.travelMinutes,
    required this.teleconsultMinutes,
    required this.mode,
    required this.score,
    required this.pathFacilityIds,
    required this.rationale,
  });

  final Specialist specialist;

  /// Null when the specialist has no coordinates (teleconsult-only entry).
  final double? distanceKm;
  final int? travelMinutes;
  final int teleconsultMinutes;
  final ReferralMode mode;
  final double score;
  final List<String> pathFacilityIds;
  final String rationale;

  String get distanceLabel => distanceKm == null
      ? 'Location not configured'
      : '${distanceKm!.toStringAsFixed(1)} km';

  String get travelLabel =>
      travelMinutes == null ? 'Travel time unavailable' : '~${travelMinutes!} min by road';

  String get waitLabel => switch (mode) {
        ReferralMode.teleconsult =>
          'Teleconsult slot in ~${teleconsultMinutes < 60 ? '$teleconsultMinutes min' : '${(teleconsultMinutes / 60).ceil()} day(s)'}',
        ReferralMode.inPerson =>
          'Next appointment in ~${specialist.averageWaitDays} day(s)',
      };

  Map<String, dynamic> toJson() => {
        'specialist_id': specialist.id,
        'specialist_name': specialist.displayName,
        'specialist': specialist.toJson(),
        'facility': specialist.facilityName,
        'distance_km': distanceKm,
        'travel_minutes': travelMinutes,
        'teleconsult_minutes': teleconsultMinutes,
        'mode': mode.name,
        'score': score,
        'path': pathFacilityIds,
        'rationale': rationale,
      };

  static SpecialistRoute? tryParse(Object? value) {
    if (value is! Map) return null;
    final route = Map<String, dynamic>.from(value);
    final specialistJson = route['specialist'];
    final specialist = specialistJson is Map
        ? Specialist.fromJson(Map<String, dynamic>.from(specialistJson))
        : null;
    if (specialist == null || specialist.id.isEmpty) return null;
    final mode = ReferralMode.values.firstWhere(
      (m) => m.name == route['mode'],
      orElse: () => ReferralMode.inPerson,
    );
    return SpecialistRoute(
      specialist: specialist,
      distanceKm: (route['distance_km'] as num?)?.toDouble(),
      travelMinutes: (route['travel_minutes'] as num?)?.toInt(),
      teleconsultMinutes: (route['teleconsult_minutes'] as num?)?.toInt() ?? 0,
      mode: mode,
      score: (route['score'] as num?)?.toDouble() ?? 0,
      pathFacilityIds: (route['path'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          const [],
      rationale: route['rationale']?.toString() ?? '',
    );
  }
}

/// Complete routing decision for one screening. Persisted with the record and
/// embedded in the clinical dossier so the receiving specialist knows exactly
/// why they were selected.
class ReferralPlan {
  const ReferralPlan({
    required this.origin,
    required this.grade,
    required this.urgency,
    required this.primary,
    required this.alternates,
    required this.generatedAt,
    this.algorithm = RoutingMetadata.algorithm,
    this.usedFallbackGraph = false,
  });

  final ScreeningCentre origin;
  final int grade;
  final ReferralUrgency urgency;
  final SpecialistRoute primary;
  final List<SpecialistRoute> alternates;
  final DateTime generatedAt;
  final String algorithm;

  /// True when the route used Haversine facility edges instead of an imported
  /// road graph. Surfaced in the UI so the estimate is never mistaken for a
  /// turn-by-turn road route.
  final bool usedFallbackGraph;

  List<SpecialistRoute> get allRoutes => [primary, ...alternates];

  Specialist get specialist => primary.specialist;

  bool get isTeleconsult => primary.mode == ReferralMode.teleconsult;

  String get addressedTo =>
      '${specialist.displayName}, ${specialist.facilityName}';

  String get summary {
    final parts = <String>[
      primary.rationale,
      if (alternates.isNotEmpty) '${alternates.length} alternate(s) available',
    ];
    return parts.join(' · ');
  }

  ReferralPlan withPrimary(SpecialistRoute route) {
    final remaining = <SpecialistRoute>[
      primary,
      ...alternates,
    ].where((r) => r.specialist.id != route.specialist.id).toList();
    return ReferralPlan(
      origin: origin,
      grade: grade,
      urgency: urgency,
      primary: route,
      alternates: remaining.take(2).toList(),
      generatedAt: generatedAt,
      algorithm: algorithm,
      usedFallbackGraph: usedFallbackGraph,
    );
  }

  Map<String, dynamic> toJson() => {
        'origin': origin.toJson(),
        'grade': grade,
        'urgency': urgency.name,
        'primary': primary.toJson(),
        'alternates': alternates.map((e) => e.toJson()).toList(),
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'algorithm': algorithm,
        'used_fallback_graph': usedFallbackGraph,
      };

  static ReferralPlan? tryParse(Object? value) {
    if (value is! Map) return null;
    try {
      final json = Map<String, dynamic>.from(value);
      final primary = SpecialistRoute.tryParse(json['primary']);
      if (primary == null) return null;
      final originJson = json['origin'];
      final origin = originJson is Map
          ? ScreeningCentre.fromJson(Map<String, dynamic>.from(originJson))
          : const ScreeningCentre(name: 'Screening Centre', location: null);
      final alternates = (json['alternates'] as List?)
              ?.map(SpecialistRoute.tryParse)
              .whereType<SpecialistRoute>()
              .toList() ??
          const <SpecialistRoute>[];
      final urgency = ReferralUrgency.values.firstWhere(
        (u) => u.name == json['urgency'],
        orElse: () => ReferralUrgency.forGrade(
          (json['grade'] as num?)?.toInt() ?? 0,
        ),
      );
      return ReferralPlan(
        origin: origin,
        grade: (json['grade'] as num?)?.toInt() ?? 0,
        urgency: urgency,
        primary: primary,
        alternates: alternates,
        generatedAt: DateTime.tryParse(
              json['generated_at']?.toString() ?? '',
            ) ??
            DateTime.now().toUtc(),
        algorithm: json['algorithm']?.toString() ?? RoutingMetadata.algorithm,
        usedFallbackGraph: json['used_fallback_graph'] as bool? ?? true,
      );
    } catch (_) {
      return null;
    }
  }
}

class RoutingMetadata {
  RoutingMetadata._();

  static const algorithm = 'dijkstra-facility-graph-v1';
  static const graphVersion = 1;
}
