import 'package:flutter/material.dart';
import 'package:flutter_spinkit/flutter_spinkit.dart';
import '../l10n/lang_scope.dart';
import '../services/api_service.dart';
import '../widgets/fx/particle_field.dart';
import '../widgets/scanner/scanner_theme.dart';

/// Offline Queue — store-and-forward sync status, dark HUD chrome consistent
/// with the rest of the clinical shell. Status colours keep semantic meaning
/// (amber = awaiting sync, green = all clear, red = rejected) but render on
/// the dark surface instead of light pastels.
class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key});

  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  final ApiService _apiService = ApiService();
  bool _isSyncing = false;
  String? _syncMessage;
  bool _syncFailed = false;

  static const _amber = Color(0xFFF59E0B);
  static const _green = Color(0xFF10B981);
  static const _danger = Color(0xFFEF4444);

  Future<void> _handleSync() async {
    setState(() {
      _isSyncing = true;
      _syncMessage = null;
      _syncFailed = false;
    });

    final res = await _apiService.syncOfflineBatch();
    if (!mounted) return;
    final err = res['error']?.toString();
    final synced = (res['total_synced'] as num?)?.toInt() ?? 0;
    final received = (res['total_received'] as num?)?.toInt() ?? 0;
    final failed = res['failed_items'] is List
        ? (res['failed_items'] as List).length
        : 0;
    final failedPatients = res['failed_patients'] is List
        ? (res['failed_patients'] as List).length
        : 0;
    final dropped = (res['dropped_corrupt'] as num?)?.toInt() ?? 0;
    setState(() {
      _isSyncing = false;
      if (err != null) {
        _syncFailed = true;
        _syncMessage = 'Sync failed: $err';
      } else if (synced > 0) {
        _syncFailed = failed > 0 || failedPatients > 0;
        _syncMessage =
            'Synchronized $synced of $received record(s) with District Hospital.'
            '${failed > 0 ? ' $failed item(s) rejected — kept in queue.' : ''}'
            '${failedPatients > 0 ? ' $failedPatients patient(s) failed registration.' : ''}'
            '${dropped > 0 ? ' $dropped corrupt entr(y/ies) discarded.' : ''}';
      } else {
        _syncFailed = failed > 0 || failedPatients > 0;
        _syncMessage =
            (res['message'] ??
                    'Nothing uploaded. ${failed > 0 ? "$failed item(s) rejected — kept in queue." : "Check connectivity and retry."}')
                .toString();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = ApiService.offlineQueue;
    final pendingPatients = ApiService.offlinePatients.length;
    final hasPending = queue.isNotEmpty || pendingPatients > 0;

    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('offline_title'),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: ParticleField(
              particleCount: 16,
              opacity: 0.2,
              speed: 0.55,
              seed: 29,
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 672),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Summary Banner — dark surface with a semantic accent bar.
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Color(0xFF111C38),
                              Color(0xFF0C1428),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: !hasPending
                                ? _green.withValues(alpha: 0.5)
                                : _amber.withValues(alpha: 0.5),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: (!hasPending ? _green : _amber).withValues(alpha: 0.1),
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              !hasPending
                                  ? Icons.cloud_done
                                  : Icons.cloud_queue,
                              color: !hasPending ? _green : _amber,
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    !hasPending
                                        ? context.tr('sync_complete')
                                        : '${queue.length} ${context.tr('cases_waiting')}${pendingPatients > 0 ? ' + $pendingPatients' : ''}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 14,
                                      color: !hasPending ? _green : _amber,
                                    ),
                                  ),
                                  Text(
                                    !hasPending
                                        ? context.tr('sync1')
                                        : context.tr('offline_subtitle'),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF94A3B8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (_syncMessage != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ScannerHUDTheme.darkSurface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: _syncFailed
                                  ? _danger.withValues(alpha: 0.55)
                                  : _green.withValues(alpha: 0.55),
                            ),
                          ),
                          child: Text(
                            _syncMessage!,
                            style: TextStyle(
                              color: _syncFailed ? _danger : _green,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],

                      // Queue List
                      Expanded(
                        child: queue.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(
                                      Icons.check_circle_outline,
                                      size: 60,
                                      color: _green,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'Queue is Empty',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                        color: Colors.white,
                                      ),
                                    ),
                                    Text(
                                      'All rural field scans have been safely stored.',
                                      style: TextStyle(
                                        color: Color(0xFF94A3B8),
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                itemCount: queue.length,
                                itemBuilder: (context, index) {
                                  final item = queue[index];
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 14,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          Color(0xFF111B34),
                                          Color(0xFF0C1428),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: const Color(0xFF1E2D4A),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(alpha: 0.15),
                                          blurRadius: 10,
                                          offset: const Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        CircleAvatar(
                                          backgroundColor: ScannerHUDTheme
                                              .neonCyan
                                              .withValues(alpha: 0.16),
                                          child: const Icon(
                                            Icons.remove_red_eye_rounded,
                                            color: ScannerHUDTheme.neonCyan,
                                            size: 20,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${item['patient_id']} • ${item['eye_side']} Eye',
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                "Preset: ${item['camera_profile']}\nCaptured: ${item['timestamp'] ?? item['captured_at'] ?? '-'}",
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  height: 1.35,
                                                  color: Color(0xFF94A3B8),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),

                      // Sync Button
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00B4D8),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFF101932),
                          disabledForegroundColor: const Color(0xFF475569),
                          minimumSize: const Size.fromHeight(52),
                          elevation: 3,
                          shadowColor: const Color(0x6600B4D8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: _isSyncing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: SpinKitFadingCube(
                                  color: ScannerHUDTheme.background,
                                  size: 18,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: Text(
                          _isSyncing
                              ? context.tr('syncing')
                              : context.tr('btn_sync'),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        onPressed: _isSyncing || !hasPending
                            ? null
                            : _handleSync,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
