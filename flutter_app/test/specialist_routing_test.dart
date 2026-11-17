import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drishti/models/specialist_models.dart';
import 'package:drishti/services/routing/routing_engine.dart';
import 'package:drishti/services/routing/specialist_directory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const engine = RoutingEngine();
  const origin = ScreeningCentre(
    name: 'PHC Bhor',
    location: GeoPoint(18.1700, 73.8450),
  );

  Specialist sp({
    required String id,
    required String name,
    double? lat,
    double? lng,
    String email = 'doctor@example.org',
    Set<String> capabilities = const {'retina'},
    int maxGrade = 4,
    int waitDays = 2,
    bool inPerson = true,
    bool teleconsult = true,
    bool active = true,
    String teleconsultUrl = 'https://tele.example.org/room',
  }) {
    return Specialist(
      id: id,
      name: name,
      facilityName: '$name Eye Centre',
      location: lat == null || lng == null ? null : GeoPoint(lat, lng),
      email: email,
      phone: '+91 90000 00000',
      teleconsultUrl: teleconsultUrl,
      capabilities: capabilities,
      maxGrade: maxGrade,
      averageWaitDays: waitDays,
      acceptsInPerson: inPerson,
      teleconsultEnabled: teleconsult,
      active: active,
    );
  }

  group('GeoPoint', () {
    test('Haversine distance is realistic for Pune–Mumbai', () {
      const pune = GeoPoint(18.5204, 73.8567);
      const mumbai = GeoPoint(19.0760, 72.8777);
      expect(pune.distanceKmTo(mumbai), closeTo(120, 10));
    });
  });

  group('RoutingEngine', () {
    test('ranks the nearer suitable specialist first', () {
      final routes = engine.rank(
        grade: 2,
        origin: origin,
        specialists: [
          sp(id: 'far', name: 'Far', lat: 19.0760, lng: 72.8777),
          sp(id: 'near', name: 'Near', lat: 18.3000, lng: 73.9000),
        ],
      );
      expect(routes, hasLength(2));
      expect(routes.first.specialist.id, 'near');
      expect(routes.first.distanceKm, lessThan(routes.last.distanceKm!));
    });

    test('urgent far case prefers teleconsultation when available', () {
      final routes = engine.rank(
        grade: 4,
        origin: origin,
        specialists: [
          sp(id: 'far-vr', name: 'VR', lat: 19.0760, lng: 72.8777),
        ],
      );
      expect(routes.single.mode, ReferralMode.teleconsult);
      expect(routes.single.rationale, contains('teleconsult'));
    });

    test('inactive and unsupported destinations are excluded', () {
      final routes = engine.rank(
        grade: 4,
        origin: origin,
        specialists: [
          sp(id: 'off', name: 'Off', lat: 18.2, lng: 73.9, active: false),
          sp(id: 'junior', name: 'Junior', lat: 18.3, lng: 73.9, maxGrade: 1),
        ],
      );
      expect(routes.map((r) => r.specialist.id), isNot(contains('off')));
      expect(routes.map((r) => r.specialist.id), isNot(contains('junior')));
    });

    test('general ophthalmologist is used when no retinal specialist exists', () {
      final routes = engine.rank(
        grade: 3,
        origin: origin,
        specialists: [
          sp(
            id: 'general',
            name: 'General',
            lat: 18.3,
            lng: 73.9,
            capabilities: const {'general'},
          ),
        ],
      );
      expect(routes, hasLength(1));
      expect(routes.single.specialist.id, 'general');
    });

    test('plan exposes a primary, alternates and addressed recipient', () {
      final plan = engine.plan(
        grade: 2,
        origin: origin,
        specialists: [
          sp(id: 'a', name: 'Alpha', lat: 18.3, lng: 73.9),
          sp(id: 'b', name: 'Beta', lat: 18.4, lng: 73.9),
          sp(id: 'c', name: 'Gamma', lat: 18.5, lng: 73.9),
          sp(id: 'd', name: 'Delta', lat: 18.6, lng: 73.9),
        ],
      );
      expect(plan, isNotNull);
      expect(plan!.primary.specialist.id, 'a');
      expect(plan.alternates, hasLength(2));
      expect(plan.addressedTo, contains('Dr. Alpha'));
      expect(plan.urgency, ReferralUrgency.routine);
    });

    test('teleconsult-only specialist without coordinates is still routable', () {
      final routes = engine.rank(
        grade: 2,
        origin: origin,
        specialists: [
          sp(id: 'remote', name: 'Remote', lat: null, lng: null, inPerson: false),
        ],
      );
      expect(routes, hasLength(1));
      expect(routes.single.mode, ReferralMode.teleconsult);
      expect(routes.single.distanceKm, isNull);
    });

    test('withPrimary promotes an alternate without duplicating it', () {
      final plan = engine.plan(
        grade: 2,
        origin: origin,
        specialists: [
          sp(id: 'a', name: 'Alpha', lat: 18.3, lng: 73.9),
          sp(id: 'b', name: 'Beta', lat: 18.4, lng: 73.9),
          sp(id: 'c', name: 'Gamma', lat: 18.5, lng: 73.9),
        ],
      )!;
      final alternate = plan.alternates.first;
      final promoted = plan.withPrimary(alternate);
      expect(promoted.primary.specialist.id, alternate.specialist.id);
      expect(
        promoted.allRoutes.where((r) => r.specialist.id == alternate.specialist.id),
        hasLength(1),
      );
    });

    test('specialist JSON round-trips', () {
      final original = sp(
        id: 'roundtrip',
        name: 'Round Trip',
        lat: 18.5,
        lng: 73.8,
        capabilities: const {'retina', 'vitreoretinal'},
      );
      final restored = Specialist.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.location?.latitude, original.location?.latitude);
      expect(restored.capabilities, original.capabilities);
    });
  });

  group('SpecialistDirectoryService', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('demo directory produces a plan from PHC Bhor', () async {
      final service = SpecialistDirectoryService.instance;
      await service.clearAll();
      await service.loadDemoDirectory();
      final plan = service.planForGrade(3);
      expect(plan, isNotNull);
      expect(plan!.specialist.name, isNotEmpty);
      expect(plan.primary.distanceKm, isNotNull);
      expect(plan.primary.specialist.isDemo, isTrue);
      expect(plan.algorithm, RoutingMetadata.algorithm);
    });

    test('manual specialist can be saved and removed', () async {
      final service = SpecialistDirectoryService.instance;
      await service.clearAll();
      await service.saveSpecialist(
        sp(id: '', name: 'Manual', lat: 18.3, lng: 73.9),
      );
      expect(service.specialists, hasLength(1));
      expect(service.specialists.first.id, isNotEmpty);
      await service.deleteSpecialist(service.specialists.first.id);
      expect(service.specialists, isEmpty);
    });
  });
}
