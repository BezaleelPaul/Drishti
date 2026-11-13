import 'package:flutter/material.dart';

/// Animation states following clinical diagnostic lifecycle.
/// An ungradable image or inference error must never transition
/// automatically into diagnostic result states.
enum ScannerAnimationState {
  /// Low-intensity subtle pulse and ambient particle drift.
  idle,

  /// Short calibration sweep across optical alignment reticles.
  qualityCheck,

  /// Active rings rotation and radial sweeping beam.
  scanning,

  /// Structured multi-stage inference resonance with real progress events.
  analyzing,

  /// Borderline/uncertain case requiring clinician review; diagnostic effects freeze.
  reviewRequired,

  /// Diagnostic inference complete; calm green transition glow.
  resultReady,

  /// Quality check failed or ungradable image; scan halted with warning border.
  rejected,

  /// Inference or network exception; effects stopped.
  error;

  String get displayName {
    switch (this) {
      case ScannerAnimationState.idle:
        return 'Ready';
      case ScannerAnimationState.qualityCheck:
        return 'Calibrating Optics';
      case ScannerAnimationState.scanning:
        return 'Scanning Retina';
      case ScannerAnimationState.analyzing:
        return 'AI Inference Running';
      case ScannerAnimationState.reviewRequired:
        return 'Review Required';
      case ScannerAnimationState.resultReady:
        return 'Scan Completed';
      case ScannerAnimationState.rejected:
        return 'Image Ungradable';
      case ScannerAnimationState.error:
        return 'Analysis Failed';
    }
  }

  Color get primaryColor {
    switch (this) {
      case ScannerAnimationState.idle:
        return const Color(0xFF00B4D8);
      case ScannerAnimationState.qualityCheck:
        return const Color(0xFF38BDF8);
      case ScannerAnimationState.scanning:
        return const Color(0xFF7DF9FF);
      case ScannerAnimationState.analyzing:
        return const Color(0xFF06B6D4);
      case ScannerAnimationState.reviewRequired:
        return const Color(0xFFA855F7);
      case ScannerAnimationState.resultReady:
        return const Color(0xFF10B981);
      case ScannerAnimationState.rejected:
        return const Color(0xFFF59E0B);
      case ScannerAnimationState.error:
        return const Color(0xFFEF4444);
    }
  }

  bool get isActiveLoop =>
      this == ScannerAnimationState.scanning ||
      this == ScannerAnimationState.analyzing ||
      this == ScannerAnimationState.qualityCheck;
}
