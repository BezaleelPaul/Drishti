import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';

/// Result of a fundus-photo pick. [cancelled] distinguishes "operator closed
/// the dialog" from "the file could not be read" so the caller can show the
/// correct operator-visible message without guessing.
typedef FundusPickResult = ({
  bool cancelled,
  Uint8List? bytes,
  String name,
});

/// Cross-platform file workflows used by every operating system build.
///
/// macOS needs an extra entitlement pre-flight in `file_picker`; the other
/// platforms are no-ops. Keep that platform detail here instead of scattering
/// `Platform.isMacOS` checks through the screening screens so Linux, Windows,
/// Android and iOS follow the exact same resilient read path.
class PlatformFileService {
  PlatformFileService._();

  /// Prepares the native picker before it is shown.
  ///
  /// `file_picker`'s `skipEntitlementsChecks` only has an effect on macOS
  /// (it avoids a sandbox pre-flight that rejects valid user-selected files
  /// on signed builds). It is safely skipped everywhere else.
  static Future<void> preparePicker() async {
    if (kIsWeb || !Platform.isMacOS) return;
    try {
      await FilePicker.skipEntitlementsChecks();
    } catch (e) {
      debugPrint('File picker entitlement pre-flight skipped: $e');
    }
  }

  /// Opens the platform picker and reads the chosen fundus photograph.
  ///
  /// Reading is path-first and data-second: on desktop the picker returns a
  /// path, while on Android/iOS the bytes may arrive in-memory. Both are
  /// attempted so a sandboxed or content-URI provider cannot silently return
  /// an empty file.
  static Future<FundusPickResult> pickFundusImage({
    String dialogTitle = 'Select a fundus photo',
  }) async {
    await preparePicker();

    final files = await FilePicker.pickFiles(
      dialogTitle: dialogTitle,
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
    );

    if (files.isEmpty) {
      return (cancelled: true, bytes: null, name: '');
    }

    final picked = files.first;
    final bytes = await _readPickedFile(picked);
    final name = picked.name.trim().isNotEmpty
        ? picked.name.trim()
        : 'camera_capture.jpg';
    return (cancelled: false, bytes: bytes, name: name);
  }

  static Future<Uint8List?> _readPickedFile(PlatformFile picked) async {
    // 1. Direct path read (desktop, macOS sandbox-resolved URLs).
    final path = picked.path;
    if (path != null && path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        }
      } catch (e) {
        debugPrint('Direct file read failed ($path): $e');
      }
    }

    // 2. Last-resort platform read (ContentResolver / security-scoped URL).
    try {
      final bytes = await picked.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (e) {
      debugPrint('Platform file read failed (${picked.name}): $e');
      return null;
    }
  }

  /// Opens a saved file with the native handler on every platform.
  ///
  /// Uses `open_filex`, which maps to `open` on macOS, `xdg-open` on Linux,
  /// `ShellExecute` on Windows, and the platform document viewer on
  /// Android/iOS. Returns false when no handler is available so the caller
  /// can keep the success message but omit the "Open" action.
  static Future<bool> openFile(String path) async {
    if (path.isEmpty) return false;
    try {
      final result = await OpenFilex.open(path);
      if (result.type != ResultType.done) {
        debugPrint('Open file failed (${result.type}): ${result.message}');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('Open file failed: $e');
      return false;
    }
  }
}
