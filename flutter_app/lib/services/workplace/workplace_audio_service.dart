import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Non-blocking clinical audio cues for eyes-free fundus screening.
///
/// In darkroom and high-volume mobile camp workflows, the camera technician
/// looks through the fundus camera ocular or monitors patient pupil positioning.
/// Audio cues provide instantaneous verification without forcing the operator
/// to break visual alignment to check the PC display.
class WorkplaceAudioService extends ChangeNotifier {
  static final WorkplaceAudioService instance = WorkplaceAudioService._internal();
  factory WorkplaceAudioService() => instance;
  WorkplaceAudioService._internal();

  static const _prefKey = 'drishti_workplace_audio_enabled';
  bool _enabled = true;
  bool get enabled => _enabled;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
      notifyListeners();
    } catch (e) {
      debugPrint('WorkplaceAudioService init error: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      debugPrint('WorkplaceAudioService save error: $e');
    }
  }

  Future<void> toggle() => setEnabled(!_enabled);

  /// Shutter click triggered by USB foot switch or Spacebar capture.
  Future<void> playShutterClick() async {
    if (!_enabled) return;
    try {
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  /// Positive feedback chime: Retinal image is sharp and calibrated.
  Future<void> playQcSuccess() async {
    if (!_enabled) return;
    try {
      await SystemSound.play(SystemSoundType.click);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  /// Warning feedback alert: Image is blurry, poorly illuminated or rejected.
  Future<void> playQcAlert() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.heavyImpact();
      await SystemSound.play(SystemSoundType.alert);
    } catch (_) {}
  }

  /// Sequence advance chime: Right eye (OD) stored; switched to Left eye (OS).
  Future<void> playEyeAdvance() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.mediumImpact();
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }

  /// Batch sign-off tone for clinicians clearing review decks.
  Future<void> playBatchAction() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.selectionClick();
      await SystemSound.play(SystemSoundType.click);
    } catch (_) {}
  }
}
