import 'dart:math' as math;

import '../../models/specialist_models.dart';

/// Offline referral routing.
///
/// The router models every referral destination as a node in a facility graph
/// and runs Dijkstra's algorithm to find the least-cost path from the
/// screening centre. By default the graph is built from Haversine facility
/// edges adjusted by a rural road factor (documented as an estimate); an
/// imported road graph can replace those edges without changing the engine.
///
/// Cost is not just distance: the engine also considers urgency, the
/// destination's highest manageable ICDR grade, retinal capability, waiting
/// time and whether teleconsultation is available. The result is an explicit,
/// explainable [ReferralPlan] that is stored with the screening and printed in
/// the clinical dossier.
class RoutingEngine {
  const RoutingEngine();

  static const double _roadFactor = 1.25;
  static const double _ruralSpeedKph = 35.0;
  static const double _perLegOverheadMinutes = 4.0;
  static const double _maxLegKm = 180.0;

  /// Ranks every eligible destination. Lower score is better.
  List<SpecialistRoute> rank({
    required int grade,
    required List<Specialist> specialists,
    required ScreeningCentre origin,
  }) {
    final originPoint = origin.location;
    if (originPoint == null) return const [];

    final urgency = ReferralUrgency.forGrade(grade);
    final active = specialists
        .where((s) => s.active && s.canReceiveReferral && s.name.trim().isNotEmpty)
        .toList();
    if (active.isEmpty) return const [];

    // Prefer destinations that can manage this grade and have the right
    // capability. Relax the capability requirement (a general ophthalmologist
    // may still receive the case) but NEVER route a case to a destination
    // whose declared maximum grade is lower than this screening.
    var eligible = active
        .where((s) => s.supportsGrade(grade) && s.hasCapabilityFor(grade))
        .toList();
    if (eligible.isEmpty) {
      eligible = active.where((s) => s.supportsGrade(grade)).toList();
    }
    if (eligible.isEmpty) return const [];

    final graph = _RoutingGraph.haversine(
      originId: 'origin',
      origin: originPoint,
      destinations: {
        for (final s in eligible)
          if (s.location != null) s.id: s.location!,
      },
      roadFactor: _roadFactor,
      speedKph: _ruralSpeedKph,
      perLegOverheadMinutes: _perLegOverheadMinutes,
      maxLegKm: _maxLegKm,
    );
    final shortest = graph.shortestPathsFrom('origin');

    final routes = <SpecialistRoute>[];
    for (final specialist in eligible) {
      final path = specialist.hasLocation ? shortest[specialist.id] : null;
      final distanceKm = path?.distanceKm;
      final travelMinutes = path?.minutes;

      final canTeleconsult = specialist.canTeleconsult;
      final teleconsultSlotMinutes = _teleconsultSlotMinutes(
        specialist,
        urgency,
      );

      ReferralMode mode;
      if (!specialist.acceptsInPerson && canTeleconsult) {
        mode = ReferralMode.teleconsult;
      } else if (canTeleconsult &&
          (urgency != ReferralUrgency.routine) &&
          (travelMinutes == null || travelMinutes > 45 || (distanceKm ?? 0) > 40)) {
        mode = ReferralMode.teleconsult;
      } else if ((!specialist.hasLocation || path == null) && canTeleconsult) {
        mode = ReferralMode.teleconsult;
      } else {
        mode = ReferralMode.inPerson;
      }

      double score = 0;
      if (mode == ReferralMode.teleconsult) {
        score += switch (urgency) {
          ReferralUrgency.urgent => 20,
          ReferralUrgency.priority => 55,
          ReferralUrgency.routine => 140,
        };
        score += specialist.averageWaitDays * 8;
      } else {
        score += (travelMinutes ?? 600) * (urgency == ReferralUrgency.urgent ? 1.2 : 0.8);
        score += specialist.averageWaitDays * 18;
        if ((distanceKm ?? 0) > 80) score += 110;
      }
      if (!specialist.supportsGrade(grade)) score += 220;
      if (!specialist.hasCapabilityFor(grade)) score += 160;
      // Deterministic tie-break; demo entries never silently outrank real ones.
      if (specialist.isDemo) score += 0.5;
      if (!specialist.canEmail && canTeleconsult) score += 25;

      routes.add(
        SpecialistRoute(
          specialist: specialist,
          distanceKm: distanceKm,
          travelMinutes: travelMinutes,
          teleconsultMinutes: teleconsultSlotMinutes,
          mode: mode,
          score: score,
          pathFacilityIds: path?.path ?? const [],
          rationale: _rationale(
            specialist: specialist,
            grade: grade,
            mode: mode,
            distanceKm: distanceKm,
            travelMinutes: travelMinutes,
          ),
        ),
      );
    }

    routes.sort((a, b) {
      final byScore = a.score.compareTo(b.score);
      if (byScore != 0) return byScore;
      return a.specialist.id.compareTo(b.specialist.id);
    });
    return routes;
  }

  /// Builds the primary + escalation plan for a screening.
  ReferralPlan? plan({
    required int grade,
    required List<Specialist> specialists,
    required ScreeningCentre origin,
  }) {
    final routes = rank(grade: grade, specialists: specialists, origin: origin);
    if (routes.isEmpty) return null;
    return ReferralPlan(
      origin: origin,
      grade: grade,
      urgency: ReferralUrgency.forGrade(grade),
      primary: routes.first,
      alternates: routes.skip(1).take(2).toList(),
      generatedAt: DateTime.now().toUtc(),
      usedFallbackGraph: true,
    );
  }

  int _teleconsultSlotMinutes(Specialist s, ReferralUrgency urgency) {
    if (!s.canTeleconsult) return 0;
    if (urgency == ReferralUrgency.urgent) {
      // Urgent teleconsults are triaged the same working day.
      return math.max(30, s.averageWaitDays * 60);
    }
    // A day-based wait is converted to minutes so the UI can render days.
    return math.max(60, s.averageWaitDays * 24 * 60);
  }

  String _rationale({
    required Specialist specialist,
    required int grade,
    required ReferralMode mode,
    required double? distanceKm,
    required int? travelMinutes,
  }) {
    final capability = specialist.capabilities.contains('vitreoretinal')
        ? 'Vitreoretinal specialist'
        : specialist.capabilities.contains('retina')
            ? 'Retina specialist'
            : 'Ophthalmologist';
    final distance = distanceKm == null
        ? 'location not configured'
        : '${distanceKm.toStringAsFixed(1)} km'
            '${travelMinutes == null ? '' : ' / ~$travelMinutes min'}';
    final modeText = mode == ReferralMode.teleconsult
        ? 'teleconsult available'
        : 'in-person clinic';
    final gradeText = grade >= 2 ? ' · retinal capability' : '';
    return '$capability$gradeText · $distance · $modeText';
  }
}

class _RouteLeg {
  const _RouteLeg({required this.to, required this.minutes, required this.distanceKm});
  final String to;
  final double minutes;
  final double distanceKm;
}

class _ShortestPath {
  const _ShortestPath({required this.minutes, required this.distanceKm, required this.path});
  final int minutes;
  final double distanceKm;
  final List<String> path;
}

class _RoutingGraph {
  _RoutingGraph({required this.adjacency});

  final Map<String, List<_RouteLeg>> adjacency;

  factory _RoutingGraph.haversine({
    required String originId,
    required GeoPoint origin,
    required Map<String, GeoPoint> destinations,
    required double roadFactor,
    required double speedKph,
    required double perLegOverheadMinutes,
    required double maxLegKm,
  }) {
    final nodes = <String, GeoPoint>{originId: origin, ...destinations};
    final ids = nodes.keys.toList();
    final adjacency = <String, List<_RouteLeg>>{for (final id in ids) id: []};

    void connect(String a, String b) {
      if (a == b) return;
      final straight = nodes[a]!.distanceKmTo(nodes[b]!);
      if (straight <= 0 || straight > maxLegKm) return;
      final roadKm = straight * roadFactor;
      final minutes = roadKm / speedKph * 60 + perLegOverheadMinutes;
      adjacency[a]!.add(_RouteLeg(to: b, minutes: minutes, distanceKm: roadKm));
      adjacency[b]!.add(_RouteLeg(to: a, minutes: minutes, distanceKm: roadKm));
    }

    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        connect(ids[i], ids[j]);
      }
    }
    return _RoutingGraph(adjacency: adjacency);
  }

  /// Dijkstra over travel minutes (O(V^2); facility graphs are small).
  Map<String, _ShortestPath> shortestPathsFrom(String originId) {
    final distances = <String, double>{for (final id in adjacency.keys) id: double.infinity};
    final roadKm = <String, double>{for (final id in adjacency.keys) id: double.infinity};
    final previous = <String, String?>{for (final id in adjacency.keys) id: null};
    final visited = <String>{};
    distances[originId] = 0;
    roadKm[originId] = 0;

    while (visited.length < adjacency.length) {
      String? current;
      var best = double.infinity;
      for (final entry in distances.entries) {
        if (!visited.contains(entry.key) && entry.value < best) {
          best = entry.value;
          current = entry.key;
        }
      }
      if (current == null || best == double.infinity) break;
      visited.add(current);
      for (final leg in adjacency[current] ?? const <_RouteLeg>[]) {
        if (visited.contains(leg.to)) continue;
        final alt = distances[current]! + leg.minutes;
        if (alt < distances[leg.to]!) {
          distances[leg.to] = alt;
          roadKm[leg.to] = roadKm[current]! + leg.distanceKm;
          previous[leg.to] = current;
        }
      }
    }

    final result = <String, _ShortestPath>{};
    for (final id in adjacency.keys) {
      if (id == originId || distances[id] == double.infinity) continue;
      final path = <String>[];
      String? cursor = id;
      while (cursor != null && cursor != originId) {
        path.add(cursor);
        cursor = previous[cursor];
      }
      path.add(originId);
      result[id] = _ShortestPath(
        minutes: distances[id]!.round(),
        distanceKm: roadKm[id]!,
        path: path.reversed.toList(),
      );
    }
    return result;
  }
}
