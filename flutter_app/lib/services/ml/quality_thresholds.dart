/// Byte-parity port of src/quality/checker.py `QualityThresholds` defaults.
/// DO NOT hand-edit values here without retuning in checker.py first — the
/// Python file is the source of truth; these constants exist so a Python
/// retune cannot silently drift from the Dart quality gate (Ticket A-3).
///
/// Calibrated against 600 stratified EyePACS screening images (blur_bad 15)
/// and 400 labeled EyePACS domain-gate images; see checker.py comments.
library;

const double kBlurGoodThreshold = 85.0;
const double kBlurBadThreshold = 15.0;

const double kMinBrightnessGood = 40.0;
const double kMinBrightnessBad = 20.0;
const double kMaxBrightnessGood = 210.0;
const double kMaxBrightnessBad = 235.0;

const double kMinContrastGood = 16.0;
const double kMinContrastBad = 7.0;

const double kMinFovRatioGood = 0.35;
const double kMinFovRatioBad = 0.15;

const double kMinRedToBlueRatio = 1.10;

const double kMinMlQualityGood = 0.70;
const double kMinMlQualityBad = 0.38;

/// Stricter thresholds for borderline reassessment (checker.strict()).
const double kStrictBlurGood = 110.0;
const double kStrictBlurBad = 45.0;
const double kStrictMinBrightnessGood = 50.0;
const double kStrictMinBrightnessBad = 25.0;
const double kStrictMaxBrightnessGood = 200.0;
const double kStrictMaxBrightnessBad = 230.0;
const double kStrictMinContrastGood = 22.0;
const double kStrictMinContrastBad = 10.0;
const double kStrictMinFovGood = 0.45;
const double kStrictMinFovBad = 0.20;
const double kStrictMinRedToBlue = 1.15;
const double kStrictMinMlGood = 0.80;
const double kStrictMinMlBad = 0.48;

/// ConfidenceEvaluator thresholds (src/pipeline/confidence.py).
const double kMinConfidenceThreshold = 0.70;
const double kMinAmbiguityMargin = 0.15;
const bool kAlwaysFlagHighRisk = true;

/// Domain gate (src/quality/fundus_gate.py, heuristic provider).
const int kFundusMinSize = 64;
const double kFundusMinVariance = 2.0;
const double kMinOrangeBandFrac = 0.45;
const double kMinOrangeBandFracBright = 0.85;
const double kMinOrangeBandFracLit = 0.55;
const double kMinOrangeBandFracLitWeak = 0.35;
const double kMinRingDarkFrac = 0.40;
const double kMinRingDarkFracStruct = 0.75;
const double kMaxCornerMean = 20.0;
const double kMinBrightPixelFrac = 0.05;
const double kRingWidthFrac = 0.08;
const double kRingDarkLuma = 60.0;
/// Retinal warm hue window: supports crimson, orange, and bright golden-yellow retinas [325°, 50°].
const double kOrangeHueMin = 325.0;
const double kOrangeHueMax = 50.0;
/// Saturated retinal threshold.
const double kOrangeMinSat = 0.35;
const double kDeferBelowBrightness = 20.0;
const double kDeferAboveBrightness = 235.0;

/// Calibrated clinical thresholds for handheld and portable fundus cameras
/// (Remidio FOP, Forus 3nethra, Volk iNview) where aperture ratio is 0.20-0.30
/// and sharpness sits naturally in the 45-75 range.
const double kClinicalBlurGood = 45.0;
const double kClinicalMinBrightnessGood = 30.0;
const double kClinicalMaxBrightnessGood = 235.0;
const double kClinicalMinContrastGood = 12.0;
const double kClinicalMinFovGood = 0.20;

/// Fusion weights of the multi-scale ML-quality score (checker.py:469-483).
const double kFusionBlurWeight = 0.40;
const double kFusionIllumWeight = 0.30;
const double kFusionContrastWeight = 0.20;
const double kFusionFovWeight = 0.10;
const double kIllumOptimum = 115.0;
const double kIllumSigma = 55.0;
const double kContrastSlope = 0.25;
const double kContrastCenter = 12.0;
const double kBlurSlope = 0.05;
const double kFovNormalization = 0.35;

/// Router invariants (src/pipeline/router.py).
const int kMaxRecaptureCap = 2;

/// Borderline reassessment floors (router.py:176-198).
const int kMinOdRadiusFloor = 2;
const double kOdRadiusScale = 0.02;
const int kMinVesselPxFloor = 5;
const double kVesselPxScale = 0.005;
const double kVesselDensityGate = 0.8;

/// Retinal/background threshold shared by all stages (src/image_io.py).
const double kRetinalBgThreshold = 15.0;

/// Calibrated clinical operating point (APTOS holdout t*=0.6450, 96.28% Recall, 91.03% Specificity, QWK 0.8739, Acc 80.03%).
const double kReferableMassThreshold = 0.6450;
