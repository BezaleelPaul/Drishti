import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netra_ai_mobile/models/retinal_markers.dart';
import 'package:netra_ai_mobile/widgets/review/lesion_marker_painter.dart';
import 'package:netra_ai_mobile/widgets/review/marker_viewer.dart';

/// Real 1x1 red PNG so Image.memory decodes cleanly in the test binding.
const String _tinyPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

Uint8List _pngBytes() => base64Decode(_tinyPngBase64);

RetinalMarkers _markers({
  bool available = true,
  String? reason,
  List<MarkerCircle>? candidates,
}) {
  return RetinalMarkers(
    reviewId: 'REV-TEST',
    available: available,
    reason: reason,
    width: available ? 1000 : 0,
    height: available ? 1000 : 0,
    opticDisc: available ? MarkerCircle(x: 300, y: 320, r: 80) : null,
    fovea: available ? MarkerPoint(x: 640, y: 540) : null,
    maCandidates:
        candidates ?? (available ? [MarkerCircle(x: 420, y: 310, r: 14)] : []),
  );
}

/// Payload built for the cross-component mapping tests: a square 1000x1000
/// source keeps the fitted rect a clean centering problem, and the optic disc
/// sits at the exact source centre so its chained display position must be
/// the fitted rect's centre in whatever viewport the viewer is pumped into.
RetinalMarkers _e2eMarkers() {
  return RetinalMarkers(
    reviewId: 'REV-E2E',
    available: true,
    width: 1000,
    height: 1000,
    opticDisc: MarkerCircle(x: 500, y: 500, r: 100),
    fovea: MarkerPoint(x: 750, y: 800),
    maCandidates: [MarkerCircle(x: 200, y: 150, r: 20)],
  );
}

Future<void> _pumpViewer(
  WidgetTester tester, {
  MarkerFetcher? fetchMarkers,
  ReviewImageFetcher? fetchImage,
  double surface = 400,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: surface,
            height: surface,
            child: ClinicianMarkerViewer(
              reviewId: 'REV-TEST',
              fetchMarkers: fetchMarkers,
              fetchImage: fetchImage,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

final Finder _markerPaintFinder = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is LesionMarkerPainter,
);

final Finder _wipeClipFinder = find.byWidgetPredicate(
  (w) => w is ClipRect && w.clipper is WipeFractionClipper,
);

Rect _wipeClip(WidgetTester tester) {
  final clip = tester.widget<ClipRect>(_wipeClipFinder);
  return (clip.clipper as WipeFractionClipper).getClip(const Size(400, 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('fittedImageRect computes the BoxFit.contain letterbox rect', () {
    expect(
      ClinicianMarkerViewer.fittedImageRect(const Size(400, 400), 1000, 500),
      Rect.fromLTWH(0, 100, 400, 200),
    );
    expect(
      ClinicianMarkerViewer.fittedImageRect(const Size(400, 400), 500, 1000),
      Rect.fromLTWH(100, 0, 200, 400),
    );
    expect(
      ClinicianMarkerViewer.fittedImageRect(const Size(400, 300), 1000, 1000),
      Rect.fromLTWH(50, 0, 300, 300),
    );
  });

  testWidgets(
    'available markers: both layers render, painter inside the one transform, slider present, default fully revealed',
    (tester) async {
      await _pumpViewer(
        tester,
        fetchMarkers: (_) async => _markers(),
        fetchImage: (_) async => _pngBytes(),
      );

      final viewer = find.byType(InteractiveViewer);
      expect(viewer, findsOneWidget);
      expect(
        find.descendant(of: viewer, matching: find.byType(Image)),
        findsNWidgets(2),
      );
      expect(
        find.descendant(of: viewer, matching: _markerPaintFinder),
        findsOneWidget,
      );
      expect(find.byType(Slider), findsOneWidget);

      final paint = tester.widget<CustomPaint>(_markerPaintFinder);
      final painter = paint.painter! as LesionMarkerPainter;
      expect(painter.strokeScale, 1.0);
      expect(painter.scale, closeTo(painter.imageRect.width / 1000, 1e-9));

      // Square 1000x1000 source contain-fits: square rect, centered on the
      // 400-wide viewport, within the Expanded height left by the footer.
      final imageRect = painter.imageRect;
      expect(imageRect.width, closeTo(imageRect.height, 1e-6));
      expect(imageRect.left, closeTo((400 - imageRect.width) / 2, 1e-6));
      expect(imageRect.width, greaterThan(0));
      expect(imageRect.height, lessThanOrEqualTo(400));

      expect(_wipeClip(tester), Rect.fromLTWH(0, 0, 400, 400));
    },
  );

  testWidgets('dragging the wipe slider shrinks the marked-layer clip', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async => _markers(),
      fetchImage: (_) async => _pngBytes(),
    );

    await tester.drag(find.byType(Slider), const Offset(-160, 0));
    await tester.pump();
    await tester.pump();

    final clip = _wipeClip(tester);
    expect(clip.left, 0.0);
    expect(clip.right, lessThan(400.0));
    expect(clip.right, greaterThanOrEqualTo(0.0));
  });

  testWidgets('zoom supports at least 3.5x with pan enabled', (tester) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async => _markers(),
      fetchImage: (_) async => _pngBytes(),
    );

    final iv = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
    expect(iv.maxScale, greaterThanOrEqualTo(3.5));
    expect(iv.minScale, 1.0);
    expect(iv.panEnabled, true);
  });

  testWidgets('unavailable markers: honest text, no slider, no painter', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async =>
          _markers(available: false, reason: 'segmentation failed'),
      fetchImage: (_) async => _pngBytes(),
    );

    expect(find.textContaining('unavailable'), findsWidgets);
    expect(find.textContaining('segmentation failed'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('marker fetch failure degrades to honest unavailable state', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async => throw Exception('network down'),
      fetchImage: (_) async => _pngBytes(),
    );

    expect(find.textContaining('unavailable'), findsWidgets);
    expect(find.byType(Image), findsOneWidget);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('available with empty candidates: painter + honest note', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async => _markers(candidates: const []),
      fetchImage: (_) async => _pngBytes(),
    );

    expect(_markerPaintFinder, findsOneWidget);
    expect(find.textContaining('No lesion candidates'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('image failure: honest error, no image, no markers, no slider', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      fetchMarkers: (_) async => _markers(),
      fetchImage: (_) async => throw Exception('boom'),
    );

    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);
  });

  testWidgets('loading: markers never render before real image pixels', (
    tester,
  ) async {
    final imageReady = Completer<Uint8List>();
    final markersReady = Completer<RetinalMarkers>();
    await _pumpViewer(
      tester,
      fetchMarkers: (_) => markersReady.future,
      fetchImage: (_) => imageReady.future,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);

    markersReady.complete(_markers());
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);

    imageReady.complete(_pngBytes());
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsNWidgets(2));
    expect(_markerPaintFinder, findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('markers pending after image loaded: honest loading note', (
    tester,
  ) async {
    final imageReady = Completer<Uint8List>();
    final markersReady = Completer<RetinalMarkers>();
    await _pumpViewer(
      tester,
      fetchMarkers: (_) => markersReady.future,
      fetchImage: (_) => imageReady.future,
    );

    imageReady.complete(_pngBytes());
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.textContaining('Loading markers'), findsOneWidget);
    expect(_markerPaintFinder, findsNothing);
    expect(find.byType(Slider), findsNothing);

    markersReady.complete(_markers());
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('Loading markers'), findsNothing);
    expect(_markerPaintFinder, findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  group(
    'Req 7.1 cross-component coordinate mapping (viewer fitRect -> painter)',
    () {
      testWidgets(
        'a marker at a known source coordinate lands on its chained display position in a real pumped viewer',
        (tester) async {
          await _pumpViewer(
            tester,
            fetchMarkers: (_) async => _e2eMarkers(),
            fetchImage: (_) async => _pngBytes(),
          );

          final paint = tester.widget<CustomPaint>(_markerPaintFinder);
          final painter = paint.painter! as LesionMarkerPainter;

          // The painter's canvas is the zoom child's viewport: it sits in
          // Positioned.fill under the ONE shared InteractiveViewer transform.
          final viewport = tester.getSize(_markerPaintFinder);

          // The viewer must hand the painter the REAL fitted rect of that
          // viewport, and the scale must follow from the same math - the
          // composition that the 3.1-only and 3.2-only tests verify apart.
          final fitted = ClinicianMarkerViewer.fittedImageRect(
            viewport,
            1000,
            1000,
          );
          expect(painter.imageRect, fitted);
          expect(painter.scale, closeTo(fitted.width / 1000, 1e-9));

          // The painter carries the fetched payload with source space intact.
          expect(painter.markers.width, 1000);
          expect(painter.markers.height, 1000);

          // Chain the mapping through: a marker at source (500,500) - the
          // image centre - maps exactly onto the fitted rect's centre.
          final centreSeen = LesionMarkerPainter.mapToDisplay(
            const Offset(500, 500),
            painter.imageRect,
            painter.scale,
          );
          expect(centreSeen.dx, closeTo(fitted.center.dx, 1e-9));
          expect(centreSeen.dy, closeTo(fitted.center.dy, 1e-9));

          // And the painter's drawable set places every fetched marker at
          // its chained position: fitted topLeft + source coordinate x viewed
          // scale, with the zoom-scaled radius.
          final drawable = LesionMarkerPainter.drawableMarkers(
            painter.markers,
            painter.imageRect,
            painter.scale,
          );
          expect(drawable, hasLength(3));
          expect(drawable[0].kind, MarkerKind.opticDisc);
          expect(
            drawable[0].position.dx,
            closeTo(fitted.left + 500 * painter.scale, 1e-9),
          );
          expect(
            drawable[0].position.dy,
            closeTo(fitted.top + 500 * painter.scale, 1e-9),
          );
          expect(drawable[0].radius, closeTo(100 * painter.scale, 1e-9));

          expect(drawable[1].kind, MarkerKind.fovea);
          expect(
            drawable[1].position.dx,
            closeTo(fitted.left + 750 * painter.scale, 1e-9),
          );
          expect(
            drawable[1].position.dy,
            closeTo(fitted.top + 800 * painter.scale, 1e-9),
          );

          expect(drawable[2].kind, MarkerKind.candidate);
          expect(
            drawable[2].position.dx,
            closeTo(fitted.left + 200 * painter.scale, 1e-9),
          );
          expect(
            drawable[2].position.dy,
            closeTo(fitted.top + 150 * painter.scale, 1e-9),
          );
          expect(drawable[2].radius, closeTo(20 * painter.scale, 1e-9));

          // Default wipe is fully revealed, so the chained positions are on
          // screen in the marked layer, not hidden behind the wipe edge.
          expect(_wipeClip(tester), Rect.fromLTWH(0, 0, 400, 400));
        },
      );

      testWidgets(
        'the fitRect -> painter -> display chain holds on differently sized surfaces (fit scale tracks the viewport)',
        (tester) async {
          double? previousScale;
          for (final surface in const [300.0, 600.0]) {
            await _pumpViewer(
              tester,
              fetchMarkers: (_) async => _e2eMarkers(),
              fetchImage: (_) async => _pngBytes(),
              surface: surface,
            );

            final painter =
                tester.widget<CustomPaint>(_markerPaintFinder).painter!
                    as LesionMarkerPainter;
            final viewport = tester.getSize(_markerPaintFinder);

            // Same chained invariant as the 400-surface test, on a fresh fit.
            final fitted = ClinicianMarkerViewer.fittedImageRect(
              viewport,
              1000,
              1000,
            );
            expect(painter.imageRect, fitted, reason: 'surface $surface');
            expect(
              painter.scale,
              closeTo(fitted.width / 1000, 1e-9),
              reason: 'surface $surface',
            );

            // The known disc source (500,500) still maps to the fitted
            // centre under the new scale - nothing was hardcoded to 400.
            final centre = LesionMarkerPainter.mapToDisplay(
              const Offset(500, 500),
              painter.imageRect,
              painter.scale,
            );
            expect(
              centre.dx,
              closeTo(fitted.center.dx, 1e-9),
              reason: 'surface $surface',
            );
            expect(
              centre.dy,
              closeTo(fitted.center.dy, 1e-9),
              reason: 'surface $surface',
            );

            // The fitted scale must actually track the surface: growing the
            // viewport surface grows the fit scale (both surfaces here fit
            // strictly inside the viewport, so the ordering is reliable).
            if (previousScale != null) {
              expect(
                painter.scale,
                greaterThan(previousScale),
                reason: 'the fitted scale must grow with the surface',
              );
            }
            previousScale = painter.scale;
          }
        },
      );
    },
  );

  group('Req 5.1/5.3 unavailable states draw no decorative overlay', () {
    testWidgets(
      'unavailable payload: honest text only over the plain image - no shader masks, no gradient boxes, no placeholder spectacle',
      (tester) async {
        await _pumpViewer(
          tester,
          fetchMarkers: (_) async =>
              _markers(available: false, reason: 'segmentation failed'),
          fetchImage: (_) async => _pngBytes(),
        );

        expect(find.textContaining('unavailable'), findsWidgets);
        expect(find.textContaining('segmentation failed'), findsOneWidget);

        // The real image stays; nothing painted in place of markers.
        expect(find.byType(Image), findsOneWidget);
        expect(_markerPaintFinder, findsNothing);
        expect(find.byType(Slider), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(ShaderMask), findsNothing);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                ((w.decoration as BoxDecoration).gradient != null ||
                    (w.decoration as BoxDecoration).boxShadow != null),
          ),
          findsNothing,
          reason:
              'a decorative gradient/glow box would be a synthetic overlay '
              'where markers are expected but unavailable (Req 5.3)',
        );
      },
    );

    testWidgets('marker fetch failure passes the same decorative sweep', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        fetchMarkers: (_) async => throw Exception('network down'),
        fetchImage: (_) async => _pngBytes(),
      );

      expect(find.textContaining('unavailable'), findsWidgets);
      expect(find.textContaining('Marker load failed'), findsOneWidget);

      expect(find.byType(Image), findsOneWidget);
      expect(_markerPaintFinder, findsNothing);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ShaderMask), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              ((w.decoration as BoxDecoration).gradient != null ||
                  (w.decoration as BoxDecoration).boxShadow != null),
        ),
        findsNothing,
      );
    });
  });
  group('Clinician analysis upgrades', () {
    testWidgets(
      'candidate markers pulse and carry callouts when markers are available',
      (tester) async {
        await _pumpViewer(
          tester,
          fetchMarkers: (_) async => _markers(),
          fetchImage: (_) async => _pngBytes(),
        );
        // Let the pulse loop tick so the overlay painter carries a live phase.
        await tester.pump(const Duration(milliseconds: 220));

        final painter =
            tester.widget<CustomPaint>(_markerPaintFinder).painter!
                as LesionMarkerPainter;
        expect(painter.showCallouts, isTrue);
        expect(painter.pulse, inInclusiveRange(0.0, 1.0));

        // Painting ran across the pumped frames without throwing.
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('compare button animates the before/after wipe', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        fetchMarkers: (_) async => _markers(),
        fetchImage: (_) async => _pngBytes(),
      );

      // Play: the marked layer sweeps from fully revealed toward hidden.
      await tester.tap(find.byIcon(Icons.motion_photos_on));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_wipeClip(tester).right, lessThan(400.0));

      // Stop: the sweep freezes at its current wipe fraction.
      await tester.tap(find.byIcon(Icons.stop_circle_outlined));
      await tester.pump();
      final frozen = _wipeClip(tester).right;
      expect(frozen, lessThan(400.0));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_wipeClip(tester).right, frozen);
    });

    testWidgets('double-tap toggles a ~2.4x zoom about the tap point', (
      tester,
    ) async {
      await _pumpViewer(
        tester,
        fetchMarkers: (_) async => _markers(),
        fetchImage: (_) async => _pngBytes(),
      );

      final ivFinder = find.byType(InteractiveViewer);
      // Two quick taps inside the double-tap timeout trigger the zoom. A
      // ticker started inside the second tap gets its elapsed time on the
      // NEXT pump, so two pumps complete the 240 ms zoom animation.
      await tester.tap(ivFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(ivFinder);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 250));

      final iv = tester.widget<InteractiveViewer>(ivFinder);
      final zoomed = iv.transformationController!.value.getMaxScaleOnAxis();
      expect(zoomed, closeTo(ClinicianMarkerViewer.tapZoom, 0.05));

      await tester.tap(ivFinder);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(ivFinder);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 250));
      final reset = iv.transformationController!.value.getMaxScaleOnAxis();
      expect(reset, closeTo(1.0, 0.05));
    });
  });
}
