/// Compile-time application configuration shared by UI and services.
class AppConfig {
  AppConfig._();

  /// Keep this in sync with pubspec.yaml. Centralised so the About screen,
  /// diagnostics and referral metadata never drift from the release tag.
  static const String version = '1.10.0';
  static const int buildNumber = 10;

  /// Demonstration data is NEVER enabled implicitly in a clinical build.
  /// Build with `--dart-define=DRISHTI_DEMO_MODE=true` for kiosk/demo use.
  static const bool demoMode = bool.fromEnvironment(
    'DRISHTI_DEMO_MODE',
    defaultValue: false,
  );
}
