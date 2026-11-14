import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n/lang_scope.dart';
import 'screens/splash/futuristic_splash_screen.dart';
import 'services/api_service.dart';
import 'services/db/local_store.dart';
import 'services/offline_queue_service.dart';
import 'services/referral_uplink_service.dart';
import 'theme/figma_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isMacOS) {
    unawaited(FilePicker.skipEntitlementsChecks().catchError((_) {}));
  }
  // Ticket B-2: open the durable offline queue (SQLCipher, key in Keystore)
  // and rehydrate the in-memory mirrors. On any failure the queue degrades
  // to memory-only with an honest isPersisted=false flag — the app never
  // crashes at boot over storage.
  unawaited(_initOfflinePersistence());
  runApp(DrishtiApp(langController: LangController()));
}

Future<void> _initOfflinePersistence() async {
  try {
    await OfflineQueueService.init();
    await ApiService.restoreQueues();
    // Ticket D-2: connectivity window at boot — flush consented de-identified
    // referrals that were store-and-forwarded during field camps. Best
    // effort: failures keep them queued for the next window.
    final uplink = await ReferralUplinkService.create();
    await uplink.flushQueued();
  } catch (_) {
    // Boot proceeds with the in-memory queue (loss on restart is possible,
    // but screening never depends on it).
  }
  // Ticket C-5: purge ACKED local screenings past the retention window
  // (90 days, mirroring the server recommendation). Unsynced data is never
  // purged. Best effort — storage failure never blocks the app.
  try {
    final password = await OfflineQueueService.resolveDbPassword();
    final store = await LocalStore.open(dbPassword: password);
    await store.purgeExpiredData(retentionDays: 90);
    await store.close();
  } catch (_) {
    // Purge is maintenance, not a boot dependency.
  }
}

class DrishtiApp extends StatelessWidget {
  final LangController langController;
  final Widget? initialHome;

  const DrishtiApp({
    super.key,
    required this.langController,
    this.initialHome,
  });

  @override
  Widget build(BuildContext context) {
    return LangScope(
      notifier: langController,
      child: MaterialApp(
        title: 'DRISHTI · Rural Retinal Screening',
        debugShowCheckedModeBanner: false,
        theme: buildFigmaTheme(),
        home: initialHome ?? const FuturisticSplashScreen(),
        // Accessibility-scaling guard: OS-level font sizes (Android "Font
        // size: largest", iOS Larger Text) scale the OS textScaler to 2.0+,
        // which shatters the high-density diagnostic HUD rows and 320dp
        // screening matrices. Clamp every text to 1.0x–1.25x system scale:
        // never shrink below the OS baseline (1.0 floor preserves user
        // minimums), never exceed 1.25x. Implemented ONCE at the root so
        // every screen inherits it — per-screen MediaQueries (e.g. the
        // dashboard's 480x480 MATLAB embed) are built downstream and only
        // override size, not textScaler.
        builder: (context, child) {
          // Effective OS multiplier (textScaler.scale(1.0) == the linear
          // factor for a 1px reference), clamped to the 1.0x–1.25x band.
          final osScale = MediaQuery.of(context).textScaler.scale(1.0);
          final clamped = osScale.clamp(1.0, 1.25).toDouble();
          return MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(clamped)),
            child: child ?? const SizedBox.shrink(),
          );
        },
      ),
    );
  }
}
