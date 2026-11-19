import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Clinical Darkroom modes for retinal screening booths & non-mydriatic camps.
///
/// In fundus photography, ambient light is minimized so pupils dilate naturally.
/// Bright or blue-weighted screens trigger the pupillary light reflex (PLR),
/// constricting pupils and degrading optical fundus quality.
/// - [standard]: Standard high-contrast cyan/dark HUD.
/// - [ruby]: Monochromatic deep red (approx 630-660nm). Preserves scotopic dark
///   adaptation and prevents rhodopsin photobleaching.
/// - [amber]: Monochromatic warm amber (approx 590nm). Filters out blue/violet
///   wavelengths to prevent pupil constriction while maximizing text legibility.
enum DarkroomMode {
  standard,
  ruby,
  amber,
}

class DarkroomService extends ChangeNotifier {
  static final DarkroomService instance = DarkroomService._internal();
  factory DarkroomService() => instance;
  DarkroomService._internal();

  static const _prefKey = 'drishti_darkroom_mode';

  DarkroomMode _mode = DarkroomMode.standard;
  DarkroomMode get mode => _mode;
  bool get isDarkroom => _mode != DarkroomMode.standard;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefKey);
      if (saved != null) {
        _mode = DarkroomMode.values.firstWhere(
          (m) => m.name == saved,
          orElse: () => DarkroomMode.standard,
        );
        notifyListeners();
      }
    } catch (e) {
      debugPrint('DarkroomService init error: $e');
    }
  }

  Future<void> setMode(DarkroomMode mode) async {
    if (_mode == mode) return;
    _mode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, mode.name);
    } catch (e) {
      debugPrint('DarkroomService save error: $e');
    }
  }

  Future<DarkroomMode> toggleNext() async {
    final nextIndex = (_mode.index + 1) % DarkroomMode.values.length;
    final next = DarkroomMode.values[nextIndex];
    await setMode(next);
    return next;
  }

  String get label => switch (_mode) {
    DarkroomMode.standard => 'Standard HUD',
    DarkroomMode.ruby => 'Ruby Darkroom (650nm)',
    DarkroomMode.amber => 'Amber Darkroom (590nm)',
  };

  String get description => switch (_mode) {
    DarkroomMode.standard => 'High-contrast cyan & dark blue HUD',
    DarkroomMode.ruby => 'Zero rhodopsin bleaching · preserves pupil dilation',
    DarkroomMode.amber => 'Low blue light · minimal pupillary constriction reflex',
  };

  IconData get icon => switch (_mode) {
    DarkroomMode.standard => Icons.nightlight_round,
    DarkroomMode.ruby => Icons.wb_twilight_rounded,
    DarkroomMode.amber => Icons.wb_sunny_rounded,
  };

  Color get background => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF0B132B),
    DarkroomMode.ruby => const Color(0xFF0D0003),
    DarkroomMode.amber => const Color(0xFF0F0B05),
  };

  Color get surface => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF0F172A),
    DarkroomMode.ruby => const Color(0xFF1E0307),
    DarkroomMode.amber => const Color(0xFF1A1408),
  };

  Color get surfaceHighlight => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF1E293B),
    DarkroomMode.ruby => const Color(0xFF33060E),
    DarkroomMode.amber => const Color(0xFF2C220E),
  };

  Color get border => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF334155),
    DarkroomMode.ruby => const Color(0xFF6B0E1B),
    DarkroomMode.amber => const Color(0xFF5A3C10),
  };

  Color get accent => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF7DF9FF),
    DarkroomMode.ruby => const Color(0xFFFF2A4B),
    DarkroomMode.amber => const Color(0xFFF59E0B),
  };

  Color get accentSecondary => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF00B4D8),
    DarkroomMode.ruby => const Color(0xFFDC2626),
    DarkroomMode.amber => const Color(0xFFD97706),
  };

  Color get textPrimary => switch (_mode) {
    DarkroomMode.standard => Colors.white,
    DarkroomMode.ruby => const Color(0xFFFFB4BF),
    DarkroomMode.amber => const Color(0xFFFEF3C7),
  };

  Color get textSecondary => switch (_mode) {
    DarkroomMode.standard => const Color(0xFF94A3B8),
    DarkroomMode.ruby => const Color(0xFFC04B5C),
    DarkroomMode.amber => const Color(0xFFB4833E),
  };
}
