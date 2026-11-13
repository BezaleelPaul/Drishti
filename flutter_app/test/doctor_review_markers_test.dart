import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/models/retinal_markers.dart';
import 'package:netra_ai_mobile/screens/doctor_review_screen.dart';
import 'package:netra_ai_mobile/services/api_service.dart';
import 'package:netra_ai_mobile/widgets/review/marker_viewer.dart';

/// Real 1x1 PNG so Image.memory decodes cleanly in the test binding.
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Uint8List _pngBytes() => base64Decode(_tinyPngBase64);

Map<String, dynamic> _markerPayload() => {
  'review_id': 'RV-A',
  'available': true,
  'source': 'classical_cv_segmentation',
  'width': 1024,
  'height': 640,
  'optic_disc': {'x': 300, 'y': 320, 'r': 80},
  'fovea': {'x': 640, 'y': 540},
  'ma_candidates': [
    {'x': 420, 'y': 310, 'r': 14},
    {'x': 500, 'y': 330, 'r': 12},
  ],
};

class _CapturedRequest {
  _CapturedRequest(this.path, this.apiKey);

  final String path;
  final String apiKey;
}

typedef _Responder = void Function(HttpRequest request);

class _LocalServer {
  _LocalServer._(this._server, this._subscription, this.requests);

  final HttpServer _server;
  final StreamSubscription<HttpRequest> _subscription;
  final List<_CapturedRequest> requests;

  void close() async {
    await _subscription.cancel();
    await _server.close(force: true);
  }
}

Future<_LocalServer> _bindServer(_Responder respond) async {
  _LocalServer? built;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <_CapturedRequest>[];
  final subscription = server.listen((request) {
    requests.add(
      _CapturedRequest(
        request.uri.toString(),
        request.headers.value('X-API-Key') ?? '',
      ),
    );
    respond(request);
  });
  built = _LocalServer._(server, subscription, requests);
  return built;
}

void _respondJson(HttpRequest request, int status, String body) {
  request.response.statusCode = status;
  request.response.headers.contentType = ContentType.json;
  request.response.write(body);
  request.response.close();
}

/// Fake for the screen: the base constructor is HTTPS-strict, but every
/// method the screen hits is overridden, so no real socket is ever opened.
class _FakeDoctorApiService extends ApiService {
  _FakeDoctorApiService();

  final List<String> markerCalls = [];
  final List<String> imageCalls = [];

  Map<String, dynamic> pendingItem() => {
    'review_id': 'RV-1',
    'patient_name': 'Patient One',
    'abha_id': 'ABHA-1',
    'screening_id': 'SCR-1',
    'eye_side': 'Right',
    'dr_grade_num': 2,
    'dr_confidence': 0.87,
    'dr_grade_label': 'Moderate NPDR',
    'human_review_reason': 'Confidence below the auto-grade threshold.',
    'original_image_url': '/results/SCR-1/SCR-1_orig.jpg',
    'status': 'PENDING',
  };

  @override
  Future<List<Map<String, dynamic>>> getPendingReviews({
    int limit = 100,
  }) async {
    return [pendingItem()];
  }

  @override
  Future<RetinalMarkers?> getReviewMarkers(String reviewId) async {
    markerCalls.add(reviewId);
    return RetinalMarkers.fromJson(_markerPayload());
  }

  @override
  Future<Uint8List?> fetchReviewImage(String imageUrlPath) async {
    imageCalls.add(imageUrlPath);
    return _pngBytes();
  }
}

class _UnknownIdDoctorApiService extends _FakeDoctorApiService {
  @override
  Future<List<Map<String, dynamic>>> getPendingReviews({
    int limit = 100,
  }) async {
    final item = Map<String, dynamic>.of(pendingItem());
    item.remove('review_id');
    item.remove('id');
    return [item];
  }
}

Future<void> _pumpQueue(WidgetTester tester, ApiService api) async {
  await tester.pumpWidget(
    MaterialApp(home: DoctorReviewScreen(apiService: api)),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The test binding's default HttpOverrides.global answers every
  // HttpClient request with an empty 400 (hermetic default). This suite
  // legitimately talks to a loopback HttpServer it owns, so the global
  // override is dropped for this file only (each test file runs in its own
  // isolate; other suites keep their hermetic default).
  HttpOverrides.global = null;

  group('review card affordance', () {
    testWidgets('shows View Markers instead of the removed View Heatmap stub', (
      tester,
    ) async {
      await _pumpQueue(tester, _FakeDoctorApiService());

      expect(find.text('View Markers'), findsOneWidget);
      expect(find.text('View Heatmap'), findsNothing);
      expect(find.textContaining('Grad-CAM'), findsNothing);
      expect(find.textContaining('Heatmap'), findsNothing);
      // The sign-off control must be untouched.
      expect(find.text('Sign Off Referral'), findsOneWidget);
    });

    testWidgets('tapping View Markers pushes the marker viewer route', (
      tester,
    ) async {
      final api = _FakeDoctorApiService();
      await _pumpQueue(tester, api);

      await tester.tap(find.text('View Markers'));
      // Bounded pumps: the pushed viewer's marker pulse is an intentional
      // looping animation, so an unbounded pumpAndSettle would never settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      final viewer = tester.widget<ClinicianMarkerViewer>(
        find.byType(ClinicianMarkerViewer),
      );
      expect(viewer.reviewId, 'RV-1');
      // The wiring really fetched this case's markers and image through
      // the injected ApiService methods.
      expect(api.markerCalls, ['RV-1']);
      expect(api.imageCalls, ['/results/SCR-1/SCR-1_orig.jpg']);
      // The viewer must not pre-claim any model-attention overlay.
      expect(find.textContaining('Grad-CAM'), findsNothing);
    });

    testWidgets('review_id Unknown keeps the marker action disabled', (
      tester,
    ) async {
      await _pumpQueue(tester, _UnknownIdDoctorApiService());

      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('View Markers'),
          matching: find.byType(TextButton),
        ),
      );
      expect(button.onPressed, isNull);

      await tester.tap(find.text('View Markers'));
      // Bounded pumps (the viewer's looping pulse must not be settled on).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byType(ClinicianMarkerViewer), findsNothing);
    });
  });

  group('ApiService.getReviewMarkers', () {
    test('parses a valid marker payload from the local server', () async {
      final server = await _bindServer((request) {
        _respondJson(request, 200, jsonEncode(_markerPayload()));
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final markers = await api.getReviewMarkers('RV-A');

      expect(markers, isNotNull);
      expect(markers!.available, isTrue);
      expect(markers.reviewId, 'RV-A');
      expect(markers.width, 1024);
      expect(markers.height, 640);
      expect(markers.opticDisc?.r, 80);
      expect(markers.fovea?.x, 640);
      expect(markers.maCandidates, hasLength(2));
      expect(markers.maCandidates.first.r, 14);
      // Honest path + key contract.
      expect(server.requests, hasLength(1));
      expect(server.requests.single.path, '/review/RV-A/markers');
      expect(server.requests.single.apiKey, 'dev-doctor-key');
    });

    test('server 500 returns null without throwing', () async {
      final server = await _bindServer((request) {
        _respondJson(request, 500, 'boom');
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final markers = await api.getReviewMarkers('RV-A');
      expect(markers, isNull);
    });

    test('200 with unparseable body returns null without throwing', () async {
      final server = await _bindServer((request) {
        _respondJson(request, 200, 'this is not json <html>');
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final markers = await api.getReviewMarkers('RV-A');
      expect(markers, isNull);
    });

    test('200 with unsupported marker source is rejected as null', () async {
      final bad = Map<String, dynamic>.of(_markerPayload())
        ..['source'] = 'model_attention_gradcam';
      final server = await _bindServer((request) {
        _respondJson(request, 200, jsonEncode(bad));
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final markers = await api.getReviewMarkers('RV-A');
      expect(markers, isNull);
    });
  });

  group('ApiService.fetchReviewImage', () {
    test('fetches a server-relative image path with the API key', () async {
      final server = await _bindServer((request) {
        if (request.uri.path == '/results/SCR-1/SCR-1_orig.jpg') {
          final bytes = _pngBytes();
          request.response.statusCode = 200;
          request.response.headers.contentType = ContentType.binary;
          request.response.add(bytes);
          request.response.close();
        }
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final bytes = await api.fetchReviewImage('/results/SCR-1/SCR-1_orig.jpg');

      expect(bytes, isNotNull);
      expect(bytes, _pngBytes());
      expect(server.requests.single.path, '/results/SCR-1/SCR-1_orig.jpg');
      expect(server.requests.single.apiKey, 'dev-doctor-key');
    });

    test('accepts an already-absolute http URL as-is', () async {
      final server = await _bindServer((request) {
        request.response.statusCode = 200;
        request.response.headers.contentType = ContentType.binary;
        request.response.add(_pngBytes());
        request.response.close();
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final bytes = await api.fetchReviewImage(
        'http://127.0.0.1:${server._server.port}/results/SCR-2/SCR-2_orig.jpg',
      );
      expect(bytes, isNotNull);
      expect(server.requests.single.path, '/results/SCR-2/SCR-2_orig.jpg');
    });

    test('server 404 returns null without throwing', () async {
      final server = await _bindServer((request) {
        _respondJson(request, 404, 'no image');
      });
      addTearDown(server.close);

      final api = ApiService.forTesting(
        baseUrl: 'http://127.0.0.1:${server._server.port}',
        key: 'dev-doctor-key',
      );
      final bytes = await api.fetchReviewImage('/results/SCR-404/missing.jpg');
      expect(bytes, isNull);
    });
  });
}
