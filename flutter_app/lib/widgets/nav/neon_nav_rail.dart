import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:shimmer/shimmer.dart';

import '../../l10n/lang_scope.dart';
import '../../services/api_service.dart';
import '../../screens/about_screen.dart';
import '../../screens/admin/admin_portal_screen.dart';
import '../../screens/doctor_review_screen.dart';
import '../../screens/figma_dashboard_screen.dart';
import '../../screens/figma_help_screen.dart';
import '../../screens/figma_history_screen.dart';
import '../../screens/flow/flow_register_screen.dart';
import '../../screens/queue_screen.dart';
import '../../widgets/scanner/scanner_theme.dart';
import '../fx/particle_field.dart';

/// A single entry in the [NeonNavRail].
class NavEntry {
  const NavEntry({
    required this.icon,
    required this.label,
    required this.page,
    this.section,
    this.accent = ScannerHUDTheme.neonCyan,
    this.isPrimary = false,
  });

  final IconData icon;
  final String label;
  final Widget page;

  /// Section header this entry groups under. When non-null and different
  /// from the previous entry's section, a small HUD section header renders.
  final String? section;

  /// Per-item accent so the rail reads as a spectrum rather than flat cyan.
  final Color accent;

  /// Primary items render a filled glyph; secondary stay outline-only.
  final bool isPrimary;
}

/// Neural-link style navigation rail.
///
/// Replaces the plain white [Drawer] with a dark HUD rail that slides in from
/// the left over a live particle field. Each item:
///   * staggers in (fade + slide) so the rail feels like it "boots up",
///   * carries its own accent colour used for the glyph and the active bar,
///   * shows a shimmer sweep when selected, so the active destination is
///     unmistakable without relying on colour alone.
///
/// A11y: the rail is a real [Drawer], so the system back gesture, focus order
/// and screen-reader traversal all keep working. Every item exposes a
/// [Semantics] label and the selected state is announced.
class NeonNavRail extends StatelessWidget {
  const NeonNavRail({
    super.key,
    required this.entries,
    this.activeLabel,
    this.queuedCount = 0,
    this.online,
  });

  final List<NavEntry> entries;

  /// Label of the currently selected destination (drives the active bar).
  final String? activeLabel;

  /// Offline queue depth shown in the footer chip.
  final int queuedCount;

  /// null = still probing; true/false = resolved link state.
  final bool? online;

  void _go(BuildContext context, NavEntry entry) {
    Navigator.pop(context); // close the rail first
    Navigator.push(context, MaterialPageRoute(builder: (_) => entry.page));
  }

  @override
  Widget build(BuildContext context) {
    final online = this.online;
    final statusColor = online == null
        ? const Color(0xFF94A3B8)
        : (online ? ScannerHUDTheme.success : ScannerHUDTheme.danger);
    final statusText = online == null
        ? '…'
        : context.tr(online ? 'online' : 'offline');

    return Drawer(
      backgroundColor: ScannerHUDTheme.background,
      width: 300,
      shape: const RoundedRectangleBorder(),
      child: Stack(
        children: [
          // Ambient particle backdrop, clipped to the rail.
          Positioned.fill(
            child: ParticleField(particleCount: 26, opacity: 0.4, speed: 0.8),
          ),
          // Subtle vertical neon gradient so the rail reads as glass, not flat.
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    ScannerHUDTheme.neonCyan.withValues(alpha: 0.07),
                    Colors.transparent,
                    ScannerHUDTheme.purple.withValues(alpha: 0.05),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(context),
                const SizedBox(height: 4),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    children: _buildSectionedList(context),
                  ),
                ),
                _footer(context, statusColor, statusText),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Entries grouped under their declared [NavEntry.section] header; entries
  /// without a section render flat (as tests and any custom rail expect).
  List<Widget> _buildSectionedList(BuildContext context) {
    final widgets = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final previous = i > 0 ? entries[i - 1].section : null;
      if (entry.section != null && entry.section != previous) {
        widgets.add(_sectionHeader(entry.section!));
      }
      widgets.add(_item(context, entry, i));
    }
    return widgets;
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: ScannerHUDTheme.hudMonoStyle.copyWith(
              fontSize: 9,
              letterSpacing: 1.8,
              color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 6),
          Divider(
            height: 1,
            thickness: 1,
            color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.14),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Row(
        children: [
          // Pulsing brand mark.
          Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFF0F172A),
                  border: Border.all(color: ScannerHUDTheme.neonCyan, width: 1.5),
                  boxShadow: [
                    BoxShadow(
                      color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.4),
                      blurRadius: 14,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(6),
                child: Image.asset(
                  'assets/branding/drishti_mark.png',
                  fit: BoxFit.contain,
                ),
              )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .shimmer(
                duration: 1800.ms,
                color: Colors.white.withValues(alpha: 0.4),
              ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'DRISHTI',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                    letterSpacing: 0.3,
                  ),
                ),
                Text(
                  'RETINAL HUD // V1.2',
                  style: ScannerHUDTheme.hudMonoStyle.copyWith(
                    fontSize: 8,
                    letterSpacing: 1.4,
                    color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ).animate().fadeIn(duration: 320.ms).slideX(begin: -0.3),
    );
  }

  Widget _item(BuildContext context, NavEntry entry, int index) {
    final selected = entry.label == activeLabel;
    final delay = (60 + index * 45).milliseconds;

    final content = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _go(context, entry),
        child: AnimatedContainer(
          duration: 220.ms,
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? entry.accent.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected
                  ? entry.accent.withValues(alpha: 0.35)
                  : Colors.transparent,
            ),
          ),
          child: Row(
            children: [
              // Active indicator bar — grows in when selected.
              AnimatedContainer(
                duration: 260.ms,
                curve: Curves.easeOut,
                width: 3,
                height: selected ? 22 : 0,
                decoration: BoxDecoration(
                  color: entry.accent,
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: selected
                      ? [
                          BoxShadow(
                            color: entry.accent.withValues(alpha: 0.7),
                            blurRadius: 8,
                          ),
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                entry.icon,
                size: 19,
                color: selected ? entry.accent : const Color(0xFF94A3B8),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? Colors.white : const Color(0xFFCBD5E1),
                  ),
                ),
              ),
              if (selected)
                Icon(Icons.chevron_right, size: 18, color: entry.accent),
            ],
          ),
        ),
      ),
    );

    // Shimmer sweep only on the selected item so it draws the eye.
    // NOTE: the shimmer shader REPLACES child colours, so the base/highlight
    // must be fully opaque — low-alpha values here rendered the selected
    // row nearly black-on-dark (unreadable).
    final wrapped = selected
        ? Shimmer.fromColors(
            baseColor: entry.accent,
            highlightColor: Colors.white.withValues(alpha: 0.92),
            period: const Duration(milliseconds: 1600),
            child: content,
          )
        : content;

    return Semantics(
          button: true,
          selected: selected,
          label: entry.label,
          child: wrapped,
        )
        .animate()
        .fadeIn(delay: delay, duration: 300.ms)
        .slideX(begin: -0.35, end: 0, delay: delay, curve: Curves.easeOutCubic);
  }

  Widget _footer(BuildContext context, Color statusColor, String statusText) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: Row(
        children: [
          // Live status dot with a slow pulse.
          Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: statusColor,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              )
              .animate(onPlay: (c) => c.repeat(reverse: true))
              .scale(
                begin: const Offset(0.8, 0.8),
                end: const Offset(1.15, 1.15),
                duration: 1100.ms,
              ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
                if (queuedCount > 0)
                  Text(
                    '$queuedCount queued',
                    style: ScannerHUDTheme.hudMonoStyle.copyWith(
                      fontSize: 9,
                      color: const Color(0xFF94A3B8),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 260.ms).slideY(begin: 0.3);
  }
}

/// Canonical clinical-workflow entry set, grouped by section:
///   Screening            — Dashboard, New Screening, Patient History
///   Triage & Operations  — Specialist Review Queue, Offline Queue
///   Support              — Help & Guidelines, About / System Info
/// Developer/facing prototypes (District Simulation, System Specs) are
/// reachable from About / System Info instead of daily navigation.
List<NavEntry> buildNavEntries(BuildContext context) {
  final api = ApiService();
  return [
    // --- Screening ---
    NavEntry(
      icon: Icons.dashboard_outlined,
      label: context.tr('nav_dashboard'),
      section: 'Screening',
      page: const FigmaDashboardScreen(),
      accent: ScannerHUDTheme.neonCyan,
      isPrimary: true,
    ),
    NavEntry(
      icon: Icons.person_add_alt,
      label: 'New Screening',
      section: 'Screening',
      page: const FlowRegisterScreen(),
      accent: const Color(0xFF34D399),
      isPrimary: true,
    ),
    NavEntry(
      icon: Icons.history_outlined,
      label: context.tr('nav_history'),
      section: 'Screening',
      page: const FigmaHistoryScreen(),
      accent: const Color(0xFF38BDF8),
    ),
    // --- Triage & Operations ---
    NavEntry(
      icon: Icons.medical_services_outlined,
      label: 'Specialist Review Queue',
      section: 'Triage & Operations',
      page: DoctorReviewScreen(apiService: api),
      accent: const Color(0xFFF472B6),
    ),
    NavEntry(
      icon: Icons.cloud_off_outlined,
      label: context.tr('nav_offline'),
      section: 'Triage & Operations',
      page: const QueueScreen(),
      accent: const Color(0xFFF59E0B),
    ),
    NavEntry(
      icon: Icons.admin_panel_settings_outlined,
      label: 'Admin Portal (SMTP)',
      section: 'Triage & Operations',
      page: const AdminPortalScreen(),
      accent: ScannerHUDTheme.neonCyan,
    ),
    // --- Support ---
    NavEntry(
      icon: Icons.help_outline,
      label: 'Help & Guidelines',
      section: 'Support',
      page: const FigmaHelpScreen(),
      accent: const Color(0xFFA855F7),
    ),
    NavEntry(
      icon: Icons.info_outline,
      label: 'About / System Info',
      section: 'Support',
      page: const AboutScreen(),
      accent: const Color(0xFF94A3B8),
    ),
  ];
}
