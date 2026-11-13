import 'package:flutter/material.dart';

import '../l10n/lang_scope.dart';
import '../services/api_service.dart';
import '../services/db/local_store.dart';
import '../services/offline_queue_service.dart';
import '../theme/figma_theme.dart';
import '../widgets/scanner/scanner_theme.dart';
import '../widgets/status_badge.dart';
import 'figma_dashboard_screen.dart';

/// Patient History — real longitudinal records only, dark HUD chrome
/// consistent with the clinical shell. Server rows when the screening
/// service is reachable; otherwise the screenings recorded on this device
/// via LocalStore. There is no fabricated fallback: with no records on
/// either source the screen shows an honest empty state.
class FigmaHistoryScreen extends StatefulWidget {
  const FigmaHistoryScreen({super.key});

  @override
  State<FigmaHistoryScreen> createState() => _FigmaHistoryScreenState();
}

class _FigmaHistoryScreenState extends State<FigmaHistoryScreen> {
  bool _loading = true;
  bool _fromServer = false;
  List<(String, String, String, String, FigmaStatus)> _rows = const [];
  String _searchQuery = '';
  String _selectedFilter = 'all';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaitedLoad();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<(String, String, String, String, FigmaStatus)> get _filteredRows {
    return _rows.where((r) {
      final pid = r.$1.toLowerCase();
      final name = r.$2.toLowerCase();
      final res = r.$4.toLowerCase();
      final status = r.$5;

      if (_selectedFilter == 'urgent') {
        final isUrgent = status == FigmaStatus.referral ||
            res.contains('severe') ||
            res.contains('pdr') ||
            res.contains('grade 3') ||
            res.contains('grade 4');
        if (!isUrgent) return false;
      } else if (_selectedFilter == 'awaiting') {
        final isAwaiting = status == FigmaStatus.awaitingAi ||
            status == FigmaStatus.awaitingSpecialist;
        if (!isAwaiting) return false;
      } else if (_selectedFilter == 'normal') {
        final isNormal = status == FigmaStatus.verified ||
            res.contains('no dr') ||
            res.contains('mild');
        if (!isNormal) return false;
      }

      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        return pid.contains(q) || name.contains(q) || res.contains(q);
      }
      return true;
    }).toList();
  }

  Future<void> unawaitedLoad() async {
    final api = ApiService();
    final remote = await api.ping()
        ? await api.getDashboardScreenings(limit: 20)
        : null;
    List<(String, String, String, String, FigmaStatus)> rows = const [];
    var fromServer = false;
    if (remote != null &&
        remote['items'] is List &&
        (remote['items'] as List).isNotEmpty) {
      fromServer = true;
      rows = (remote['items'] as List)
          .whereType<Map<String, dynamic>>()
          .map(
            (item) => (
              (item['patient_id'] ?? '').toString(),
              (item['patient_name'] as String? ?? '').isNotEmpty
                  ? (item['patient_name'] as String)
                  : (item['patient_id'] ?? '').toString(),
              formatScreeningDate(item['created_at'] as String?),
              (item['result_text'] ?? '').toString(),
              liveStatusFor(item['status'] as String?),
            ),
          )
          .toList();
    } else {
      try {
        final password = await OfflineQueueService.resolveDbPassword();
        final store = await LocalStore.open(dbPassword: password);
        try {
          final local = await store.recentScreenings(limit: 40);
          rows = local.map(localScreeningRow).toList();
        } finally {
          await store.close();
        }
      } catch (_) {
        // Storage unavailable: honest empty state, never demo rows.
        rows = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = rows;
      _fromServer = fromServer;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: Text(
          context.tr('history_title'),
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                context.tr('screening_history'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 10),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: ScannerHUDTheme.neonCyan,
                    ),
                  ),
                )
              else if (_rows.isEmpty)
                Container(
                  padding: const EdgeInsets.all(20),
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
                    border: Border.all(color: const Color(0xFF1E2D4A)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF162344),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.folder_off_outlined,
                          color: Color(0xFF94A3B8),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Text(
                          'No screening records yet — capture a screening '
                          'for a patient and it appears here.',
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                _searchAndFilterBar(context),
                const SizedBox(height: 12),
                if (_filteredRows.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: ScannerHUDTheme.darkSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF1E2D4A)),
                    ),
                    child: Center(
                      child: Column(
                        children: [
                          const Icon(
                            Icons.search_off_rounded,
                            color: Color(0xFF64748B),
                            size: 26,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No records matching "$_searchQuery"'
                                : 'No records in this category',
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  ..._filteredRows.map(
                    (e) {
                      final initial = e.$2.isNotEmpty ? e.$2.trim()[0].toUpperCase() : 'P';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
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
                          border: Border.all(color: const Color(0xFF1E2D4A), width: 1),
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
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: const LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    Color(0xFF0E7490),
                                    Color(0xFF00B4D8),
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF00B4D8).withValues(alpha: 0.25),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                              child: Center(
                                child: Text(
                                  initial,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          e.$2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 14,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      if (e.$1.isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 5,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF1A2642),
                                            borderRadius: BorderRadius.circular(4),
                                            border: Border.all(color: const Color(0xFF283A64)),
                                          ),
                                          child: Text(
                                            e.$1,
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF7DF9FF),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${e.$4} · ${e.$3}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF94A3B8),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            StatusBadge(status: e.$5),
                          ],
                        ),
                      );
                    },
                  ),
              ],
              if (!_loading && _rows.isNotEmpty && !_fromServer)
                const SizedBox(height: 8),
              if (!_loading && _rows.isNotEmpty && !_fromServer)
                const Text(
                  'On-device records · sync pending',
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _searchAndFilterBar(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 4, bottom: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF101A33),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF223254)),
          ),
          child: TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Search records by name or patient ID...',
              hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 13),
              prefixIcon: const Icon(
                Icons.search,
                color: Color(0xFF94A3B8),
                size: 18,
              ),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Color(0xFF94A3B8),
                        size: 16,
                      ),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _filterChip('all', 'All (${_rows.length})', null),
              const SizedBox(width: 6),
              _filterChip('urgent', 'Urgent / Referral', const Color(0xFFEF4444)),
              const SizedBox(width: 6),
              _filterChip('awaiting', 'Pending Review', const Color(0xFFF59E0B)),
              const SizedBox(width: 6),
              _filterChip('normal', 'Normal / Mild', const Color(0xFF10B981)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _filterChip(String id, String label, Color? dotColor) {
    final isSelected = _selectedFilter == id;
    return InkWell(
      onTap: () => setState(() => _selectedFilter = id),
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? ScannerHUDTheme.neonCyan.withValues(alpha: 0.18)
              : const Color(0xFF101932),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? ScannerHUDTheme.neonCyan
                : const Color(0xFF223254),
            width: isSelected ? 1.2 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor,
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                color: isSelected
                    ? ScannerHUDTheme.neonCyan
                    : const Color(0xFF94A3B8),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
