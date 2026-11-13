import 'package:flutter/material.dart';

import '../scanner/scanner.dart';

/// Animation-only states for the orbital retinal scanner.
///
/// These describe visual presentation only. Callers must map them from real,
/// verified application state; the orbit widget never derives progress,
/// model readiness, confidence, predictions, or clinical status itself.
enum OrbitScannerState {
  /// Ambient idle; slow orbit with no active sweep.
  idle,

  /// Image-quality gate running; calibration sweep.
  qualityCheck,

  /// Model prepare/initialise stage reported by the caller.
  modelLoading,

  /// Inference stage reported by the caller.
  inference,

  /// Result produced locally and awaiting clinician sign-off.
  preliminaryResult,

  /// Result confirmed by an external validation the caller actually observed.
  /// Never produced by [OrbitScannerState.fromScannerAnimationState];
  /// screens must pass it explicitly only after verifying a real confirmation.
  confirmedResult,

  /// Quality rejection or inference failure; scan halted.
  failure,

  /// Caller-reported user cancellation.
  cancelled;

  String get displayName {
    switch (this) {
      case OrbitScannerState.idle:
        return 'SYSTEM READY';
      case OrbitScannerState.qualityCheck:
        return 'OPTICS CALIBRATING';
      case OrbitScannerState.modelLoading:
        return 'LOADING MODEL';
      case OrbitScannerState.inference:
        return 'INFERENCE RUNNING';
      case OrbitScannerState.preliminaryResult:
        return 'PRELIMINARY // AWAITING SIGN-OFF';
      case OrbitScannerState.confirmedResult:
        return 'SERVICE CONFIRMED';
      case OrbitScannerState.failure:
        return 'ANALYSIS FAILED';
      case OrbitScannerState.cancelled:
        return 'CANCELLED';
    }
  }

  Color get color {
    switch (this) {
      case OrbitScannerState.idle:
        return const Color(0xFF00B4D8);
      case OrbitScannerState.qualityCheck:
        return const Color(0xFF38BDF8);
      case OrbitScannerState.modelLoading:
        return const Color(0xFF7DF9FF);
      case OrbitScannerState.inference:
        return const Color(0xFF06B6D4);
      case OrbitScannerState.preliminaryResult:
        return const Color(0xFFA855F7);
      case OrbitScannerState.confirmedResult:
        return const Color(0xFF10B981);
      case OrbitScannerState.failure:
        return const Color(0xFFEF4444);
      case OrbitScannerState.cancelled:
        return const Color(0xFF64748B);
    }
  }

  /// Only actively looping states animate; everything else holds a static
  /// frame so failure, cancellation and results never appear "in progress".
  bool get isActiveLoop =>
      this == OrbitScannerState.qualityCheck ||
      this == OrbitScannerState.modelLoading ||
      this == OrbitScannerState.inference;

  /// Adapter from the existing scanner vocabulary.
  ///
  /// Conservative by design: [ScannerAnimationState.resultReady] maps to
  /// preliminary (an on-device result is not service-confirmed), and no
  /// current scanner state maps to [OrbitScannerState.confirmedResult] or
  /// [OrbitScannerState.cancelled] because no verified confirmation signal
  /// or cancellation event exists in that vocabulary.
  static OrbitScannerState fromScannerAnimationState(
    ScannerAnimationState source,
  ) {
    switch (source) {
      case ScannerAnimationState.idle:
        return OrbitScannerState.idle;
      case ScannerAnimationState.qualityCheck:
        return OrbitScannerState.qualityCheck;
      case ScannerAnimationState.scanning:
        return OrbitScannerState.modelLoading;
      case ScannerAnimationState.analyzing:
        return OrbitScannerState.inference;
      case ScannerAnimationState.reviewRequired:
      case ScannerAnimationState.resultReady:
        return OrbitScannerState.preliminaryResult;
      case ScannerAnimationState.rejected:
      case ScannerAnimationState.error:
        return OrbitScannerState.failure;
    }
  }
}
