import 'dart:typed_data';

import '../../models/retinal_markers.dart';
import '../../models/screening_models.dart';
import '../../models/specialist_models.dart';

/// Shared mutable state for the Figma screening flow.
///
/// Supports dual-eye sequential screening (OD = Right eye, OS = Left eye)
/// under a unified patient session and token.
class FlowState {
  PatientModel patient;
  DiabetesRiskModel? risk;
  Uint8List? imageBytes;
  String filename;
  String cameraProfile;
  String eyeSide; // 'Right' | 'Left'
  RetinalQualityModel? quality;
  ScreeningAnalysisModel? analysis;

  /// Classical-CV landmark markers for current image.
  RetinalMarkers? markers;

  /// On-device recapture loop counter.
  int recaptureAttemptCount;

  /// Specialist verdict: 'CONFIRM' | 'CHANGE' | 'REEXAMINE'.
  String? verdict;
  int? correctedGrade;
  String specialistNotes;
  bool referralSent;

  /// Offline referral routing decision.
  ReferralPlan? referralPlan;

  /// True after the clinical dossier has been delivered over SMTP.
  bool specialistEmailSent;

  // --- Dual-Eye (OD / OS) Session Management ---
  Uint8List? odImageBytes;
  String odFilename;
  RetinalQualityModel? odQuality;
  ScreeningAnalysisModel? odAnalysis;
  RetinalMarkers? odMarkers;

  Uint8List? osImageBytes;
  String osFilename;
  RetinalQualityModel? osQuality;
  ScreeningAnalysisModel? osAnalysis;
  RetinalMarkers? osMarkers;

  FlowState({
    required this.patient,
    this.risk,
    this.imageBytes,
    this.filename = '2_clear_eye_normal.jpg',
    this.cameraProfile = 'Remidio FOP (Smartphone Handheld)',
    this.eyeSide = 'Right',
    this.quality,
    this.analysis,
    this.markers,
    this.recaptureAttemptCount = 0,
    this.verdict,
    this.correctedGrade,
    this.specialistNotes = '',
    this.referralSent = false,
    this.referralPlan,
    this.specialistEmailSent = false,
    this.odImageBytes,
    this.odFilename = '',
    this.odQuality,
    this.odAnalysis,
    this.odMarkers,
    this.osImageBytes,
    this.osFilename = '',
    this.osQuality,
    this.osAnalysis,
    this.osMarkers,
  });

  /// Persists current active eye buffers into the corresponding OD/OS slot.
  void saveCurrentEye() {
    if (eyeSide == 'Right') {
      odImageBytes = imageBytes;
      odFilename = filename;
      odQuality = quality;
      odAnalysis = analysis;
      odMarkers = markers;
    } else {
      osImageBytes = imageBytes;
      osFilename = filename;
      osQuality = quality;
      osAnalysis = analysis;
      osMarkers = markers;
    }
  }

  /// Switches active eye between Right (OD) and Left (OS), preserving images.
  void switchToOtherEye() {
    saveCurrentEye();
    if (eyeSide == 'Right') {
      eyeSide = 'Left';
      imageBytes = osImageBytes;
      filename = osFilename.isNotEmpty ? osFilename : 'os_fundus.jpg';
      quality = osQuality;
      analysis = osAnalysis;
      markers = osMarkers;
    } else {
      eyeSide = 'Right';
      imageBytes = odImageBytes;
      filename = odFilename.isNotEmpty ? odFilename : 'od_fundus.jpg';
      quality = odQuality;
      analysis = odAnalysis;
      markers = odMarkers;
    }
  }

  /// True if both eyes have been analyzed or captured in this session.
  bool get hasBothEyesCaptured =>
      (odAnalysis != null || odImageBytes != null) &&
      (osAnalysis != null || osImageBytes != null);
}
