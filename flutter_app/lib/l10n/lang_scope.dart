import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_strings.dart';

/// Figma prototype languages: English, Kannada, Hindi, Telugu, Tamil.
enum AppLang { en, kn, hi, te, ta }

extension AppLangMeta on AppLang {
  String get code => name;

  String get displayName =>
      FigmaStrings.languageNames[code] ?? code.toUpperCase();
}

/// App-wide language state, persisted across restarts.
/// Held by [DrishtiApp], read via [BuildContext.tr].
class LangController extends ValueNotifier<AppLang> {
  static const _prefsKey = 'drishti_lang';
  bool _userChangedLanguage = false;

  LangController() : super(AppLang.en) {
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefsKey);
    if (code == null || _userChangedLanguage) return;
    final match = AppLang.values.where((l) => l.code == code);
    if (match.isNotEmpty && !_userChangedLanguage) {
      super.value = match.first;
    }
  }

  @override
  set value(AppLang next) {
    _userChangedLanguage = true;
    if (value == next) {
      SharedPreferences.getInstance().then(
        (prefs) => prefs.setString(_prefsKey, next.code),
      );
      return;
    }
    super.value = next;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setString(_prefsKey, next.code),
    );
  }
}

class LangScope extends InheritedNotifier<LangController> {
  const LangScope({
    super.key,
    required LangController super.notifier,
    required super.child,
  });

  static AppLang langOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LangScope>()
          ?.notifier
          ?.value ??
      AppLang.en;

  static void setLang(BuildContext context, AppLang lang) {
    context.dependOnInheritedWidgetOfExactType<LangScope>()?.notifier?.value =
        lang;
  }
}

/// `context.tr('dash_title')` — Figma string in the active language,
/// falling back to English, then to the key itself.
extension TrExt on BuildContext {
  String tr(String key) {
    final code = LangScope.langOf(this).code;
    return FigmaStrings.values[code]?[key] ??
        FigmaStrings.values['en']?[key] ??
        key;
  }
}
