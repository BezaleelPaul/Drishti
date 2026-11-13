# Netra AI Retinal Scanner Component

A real-time, hardware-accelerated animated retinal scanner built using **Flame**'s game loop and Flutter's canvas drawing APIs. No pre-rendered GIFs, MP4s, or heavy Lottie dependencies are used.

---

## 1. Architecture Overview

```
                      ┌────────────────────────┐
                      │    Diagnostic Model    │
                      │   (OnDevicePipeline)   │
                      └───────────┬────────────┘
                                  │ ScannerAnimationState
                                  ▼
┌─────────────────────────────────────────────────────────────────┐
│                          ScannerView                            │
│  - Image Decompression (dart:ui.Image)                         │
│  - Clinical HUD Overlay (Corner Reticles, Telemetry, Semantics) │
│  - App Lifecycle Watcher (Pause/Resume Engine)                  │
├─────────────────────────────────────────────────────────────────┤
│                          ScannerGame                            │
│  - Viewport & Canvas Transforms                                 │
│  - Concentric Calibrated Rings (4-Ring Optics)                  │
│  - Counter-Rotating Segmented Arcs                              │
│  - 360° Sweeping Laser Beam                                     │
│  - 36-Node Dynamic Particle System                              │
│  - Vignetted Circular Retinal Aperture                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Animation State Machine

The scanner transitions deterministically based on clinical model events:

| State | Behavior | Clinical Trigger | User Action |
|---|---|---|---|
| `idle` | Slow pulse, gentle ambient drifting particles | Camera standby / waiting for capture | Capture or upload image |
| `qualityCheck` | Calibrating sweep, steady crosshairs | Optic alignment & focus verification | Wait or cancel |
| `scanning` | Active counter-rotating rings, laser sweep | Reading retinal image features | Cancel if needed |
| `analyzing` | High-frequency concentric pulse, progress arc | Inference running across biomarkers | Wait for results |
| `reviewRequired` | Frozen rings, steady purple boundary | Borderline quality or uncertain grade | Open clinician review |
| `resultReady` | Calm completion halo, steady green glow | Model inference finished successfully | View diagnosis |
| `rejected` | Scan halts, amber/red warning boundary | Image ungradable / blurry / artifact | Retake retinal photo |
| `error` | Diagnostic effects stopped, error alert | Inference or connection exception | Retry analysis |

> **Safety Guarantee**: Ungradable images never transition into diagnostic result states. Animation completion is never treated as clinical evidence.

---

## 3. Quick Usage Example

```dart
import 'package:flutter/material.dart';
import 'package:netra_ai_mobile/widgets/scanner/scanner.dart';

class RetinalScreeningPage extends StatelessWidget {
  final Uint8List fundusBytes;

  const RetinalScreeningPage({super.key, required this.fundusBytes});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 340,
        height: 340,
        child: ScannerView(
          imageBytes: fundusBytes,
          state: ScannerAnimationState.analyzing,
          progress: 0.65,
          onCancel: () => Navigator.pop(context),
        ),
      ),
    );
  }
}
```

---

## 4. Accessibility & Performance

- **Reduced Motion**: Setting `reduceMotion: true` disables high-speed sweeps and locks animations to calm, accessible keyframes.
- **Screen Reader Semantics**: Renders accessible live regions informing Assistive Technologies of the current diagnostic state.
- **Engine Lifecycle**: Automatically pauses Flame's game loop when the application is backgrounded or inactive to conserve battery and GPU resources.

---

## 5. Verification Commands

```bash
# Analyze component
flutter analyze

# Run scanner test suite
flutter test test/retinal_scanner_test.dart

# Run all test suites
flutter test
```
