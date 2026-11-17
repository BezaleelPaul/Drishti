import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Canonical, writable application directories shared by all platforms.
///
/// Before this helper, screening images were written to `Directory.systemTemp`
/// and PDFs to `$HOME/Downloads`. Both are macOS-friendly shortcuts but break
/// on Android/iOS (sandboxed, ephemeral temp) and on sandboxed macOS where
/// `~/Downloads` requires an explicit entitlement. Using the platform
/// application-support/documents containers keeps the same behaviour on every
/// OS and survives OS temp cleanup and app restarts.
class AppPaths {
  AppPaths._();

  static bool get isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

  /// Persistent, private directory for captured fundus images.
  static Future<Directory> screeningImagesDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'screenings'));
    return _ensure(dir);
  }

  /// Ordered list of candidate directories for exported clinical PDFs.
  ///
  /// Desktop starts with the user's Downloads folder (the previous macOS
  /// behaviour), then falls back to the app documents/support containers.
  /// Mobile starts directly with the app documents directory and exposes it
  /// through the iOS Files app (`UIFileSharingEnabled`).
  static Future<List<Directory>> reportDirectories() async {
    final candidates = <Directory>[];

    if (isDesktop) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) candidates.add(downloads);
      } catch (e) {
        debugPrint('Downloads directory unavailable: $e');
      }
    }

    try {
      final documents = await getApplicationDocumentsDirectory();
      candidates.add(Directory(p.join(documents.path, 'Drishti Reports')));
    } catch (e) {
      debugPrint('Documents directory unavailable: $e');
    }

    try {
      final support = await getApplicationSupportDirectory();
      candidates.add(Directory(p.join(support.path, 'reports')));
    } catch (e) {
      debugPrint('Application support directory unavailable: $e');
    }

    // Deduplicate while preserving preference order.
    final seen = <String>{};
    return [
      for (final dir in candidates)
        if (seen.add(p.normalize(dir.path))) dir,
    ];
  }

  static Future<Directory> _ensure(Directory dir) async {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}
