import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:netra_ai_mobile/models/retinal_markers.dart';
import 'package:netra_ai_mobile/widgets/review/lesion_marker_painter.dart';
import 'package:netra_ai_mobile/widgets/review/zoomable_fundus_screen.dart';

Uint8List _png() {
  final image = img.Image(width: 32, height: 32);
  img.fill(image, color: img.ColorRgb8(120, 40, 40));
  return Uint8List.fromList(img.encodePng(image));
}

RetinalMarkers _markers() => RetinalMarkers(
  reviewId: 'R-TEST',
  available: true,
  width: 32,
  height: 32,
  opticDisc: MarkerCircle(x: 10, y: 16, r: 4),
  fovea: MarkerPoint(x: 22, y: 16),
  maCandidates: [MarkerCircle(x: 22, y: 20, r: 3)],
);

Iterable<CustomPaint> _markerPainters(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .where((p) => p.painter is LesionMarkerPainter);

void main() {
  testWidgets('zoom buttons change and reset the displayed scale', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ZoomableFundusScreen(imageBytes: _png())),
    );
    await tester.pumpAndSettle();

    expect(find.text('1.0×'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('fundus-zoom-in')));
    await tester.pumpAndSettle();
    expect(find.text('1.4×'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fundus-zoom-reset')));
    await tester.pumpAndSettle();
    expect(find.text('1.0×'), findsOneWidget);
  });

  testWidgets('double tap zooms in and double tap again resets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: ZoomableFundusScreen(imageBytes: _png())),
    );
    await tester.pumpAndSettle();

    final canvas = find.byKey(const ValueKey('fundus-zoom-canvas'));
    final centre = tester.getCenter(canvas);
    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(find.text('2.5×'), findsOneWidget);

    await tester.tapAt(centre);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(centre);
    await tester.pumpAndSettle();
    expect(find.text('1.0×'), findsOneWidget);
  });

  testWidgets('landmark marker arrows render and can be toggled off', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ZoomableFundusScreen(imageBytes: _png(), markers: _markers()),
      ),
    );
    await tester.pumpAndSettle();

    // Arrows (LesionMarkerPainter) are drawn by default when markers exist…
    expect(_markerPainters(tester), isNotEmpty);
    expect(find.byKey(const ValueKey('fundus-markers-toggle')), findsOneWidget);

    // …and the toggle removes them without touching the image.
    await tester.tap(find.byKey(const ValueKey('fundus-markers-toggle')));
    await tester.pumpAndSettle();
    expect(_markerPainters(tester), isEmpty);
  });

  testWidgets('unavailable markers render no painter and no toggle', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ZoomableFundusScreen(
          imageBytes: _png(),
          markers: RetinalMarkers(
            reviewId: 'R-TEST',
            available: false,
            reason: 'no retinal region',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_markerPainters(tester), isEmpty);
    expect(find.byKey(const ValueKey('fundus-markers-toggle')), findsNothing);
  });

  testWidgets('dense overlapping candidate cluster renders without crash', (
    tester,
  ) async {
    // Five candidates stacked at nearly the same point: the collision-aware
    // callout placement must fan the labels out without overlapping pills
    // and without throwing.
    await tester.pumpWidget(
      MaterialApp(
        home: ZoomableFundusScreen(
          imageBytes: _png(),
          markers: RetinalMarkers(
            reviewId: 'R-TEST',
            available: true,
            width: 32,
            height: 32,
            opticDisc: MarkerCircle(x: 10, y: 16, r: 4),
            fovea: MarkerPoint(x: 22, y: 16),
            maCandidates: [
              MarkerCircle(x: 22, y: 20, r: 3),
              MarkerCircle(x: 23, y: 21, r: 3),
              MarkerCircle(x: 21, y: 21, r: 3),
              MarkerCircle(x: 22, y: 22, r: 3),
              MarkerCircle(x: 23, y: 20, r: 3),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_markerPainters(tester), isNotEmpty);
  });
}
