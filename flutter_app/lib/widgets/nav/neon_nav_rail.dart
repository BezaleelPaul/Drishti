import 'package:flutter/material.dart';

import '../../l10n/lang_scope.dart';
import '../../screens/about_screen.dart';
import '../../screens/admin/admin_portal_screen.dart';
import '../../screens/doctor_review_screen.dart';
import '../../screens/figma_dashboard_screen.dart';
import '../../screens/figma_help_screen.dart';
import '../../screens/figma_history_screen.dart';
import '../../screens/flow/flow_register_screen.dart';
import '../../screens/queue_screen.dart';
import '../../screens/auth/hospital_login_screen.dart';
import '../../services/api_service.dart';
import '../../services/hospital_auth_service.dart';
import '../../theme/design_system.dart';
import '../scanner/scanner_theme.dart';

/// A single destination in the application navigation drawer.
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
  final String? section;
  final Color accent;
  final bool isPrimary;
}

/// Calm, accessible navigation for the clinical workspace.
///
/// The original particle/shimmer treatment was intentionally replaced with a
/// quiet hierarchy: clear sections, one selected accent, generous touch
/// targets, and an honest connection summary. This keeps attention on patient
/// work and avoids continuous motion in a diagnostic environment.
class NeonNavRail extends StatelessWidget {
  const NeonNavRail({
    super.key,
    required this.entries,
    this.activeLabel,
    this.queuedCount = 0,
    this.online,
  });

  final List<NavEntry> entries;
  final String? activeLabel;
  final int queuedCount;

  /// null = still probing; true/false = resolved link state.
  final bool? online;

  void _go(BuildContext context, NavEntry entry) {
    Navigator.pop(context);
    Navigator.push(context, MaterialPageRoute(builder: (_) => entry.page));
  }

  @override
  Widget build(BuildContext context) {
    final online = this.online;
    final statusColor = online == null
        ? DrsTokens.textMuted
        : (online ? DrsTokens.success : DrsTokens.danger);
    final statusText = online == null
        ? '…'
        : context.tr(online ? 'online' : 'offline');

    return Drawer(
      backgroundColor: ScannerHUDTheme.background,
      surfaceTintColor: Colors.transparent,
      width: 296,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.zero,
        side: BorderSide(color: DrsTokens.border),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Divider(height: 1),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                children: _buildSectionedList(context),
              ),
            ),
            _footer(context, statusColor, statusText),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSectionedList(BuildContext context) {
    final widgets = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      final previous = i > 0 ? entries[i - 1].section : null;
      if (entry.section != null && entry.section != previous) {
        widgets.add(_sectionHeader(entry.section!));
      }
      widgets.add(_item(context, entry));
    }
    return widgets;
  }

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 18, 10, 7),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: DrsTokens.textSubtle,
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _header() {
    final session = HospitalAuthService.instance.session;
    final isClinician = session?.isClinician ?? false;
    final roleColor = isClinician ? DrsTokens.success : DrsTokens.accent;
    final roleBadge = session?.role.badgeLabel ?? 'LOCAL CLINIC';
    final staffName = session?.staffName ?? 'Hospital Staff';
    final hospitalName = session?.hospitalName ?? 'District General Hospital';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: DrsTokens.accent.withValues(alpha: 0.09),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(
                    color: DrsTokens.accent.withValues(alpha: 0.22),
                  ),
                ),
                child: Image.asset(
                  'assets/branding/drishti_mark.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DRISHTI',
                      style: TextStyle(
                        color: DrsTokens.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        height: 1.2,
                        letterSpacing: 1.1,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Retinal screening',
                      style: TextStyle(
                        color: DrsTokens.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: DrsTokens.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: DrsTokens.border),
            ),
            child: Row(
              children: [
                Icon(
                  isClinician
                      ? Icons.medical_services_rounded
                      : Icons.photo_camera_rounded,
                  size: 16,
                  color: roleColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        roleBadge,
                        style: TextStyle(
                          color: roleColor,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      Text(
                        staffName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DrsTokens.textPrimary,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        hospitalName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DrsTokens.textSubtle,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, NavEntry entry) {
    final selected = entry.label == activeLabel;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: DrsTokens.radii.mdRadius,
            onTap: () => _go(context, entry),
            hoverColor: DrsTokens.textPrimary.withValues(alpha: 0.035),
            splashColor: entry.accent.withValues(alpha: 0.08),
            child: AnimatedContainer(
              duration: DrsTokens.motion.fast,
              curve: DrsTokens.motion.ease,
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: selected
                    ? entry.accent.withValues(alpha: 0.10)
                    : Colors.transparent,
                borderRadius: DrsTokens.radii.mdRadius,
                border: Border.all(
                  color: selected
                      ? entry.accent.withValues(alpha: 0.22)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    entry.icon,
                    size: 20,
                    color: selected ? entry.accent : DrsTokens.textMuted,
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.25,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: selected
                            ? DrsTokens.textPrimary
                            : DrsTokens.textSecondary,
                      ),
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: entry.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, Color statusColor, String statusText) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: DrsTokens.surface,
              borderRadius: DrsTokens.radii.mdRadius,
              border: Border.all(color: DrsTokens.border),
            ),
            child: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    online == null
                        ? Icons.sync_rounded
                        : (online!
                              ? Icons.cloud_done_outlined
                              : Icons.cloud_off_outlined),
                    size: 18,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'CONNECTION',
                        style: TextStyle(
                          color: DrsTokens.textSubtle,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        statusText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                      if (queuedCount > 0)
                        Text(
                          '$queuedCount queued',
                          style: const TextStyle(
                            fontSize: 10,
                            color: DrsTokens.textMuted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: () {
              Navigator.pop(context);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const HospitalLoginScreen(),
                ),
              );
            },
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.swap_horiz_rounded,
                      size: 14,
                      color: DrsTokens.accent,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'Switch Role / Facility',
                      style: TextStyle(
                        color: DrsTokens.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_outline, size: 11, color: DrsTokens.textSubtle),
              SizedBox(width: 5),
              Text(
                'Private  ·  v1.10',
                style: TextStyle(
                  color: DrsTokens.textSubtle,
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Canonical clinical-workflow entry set, grouped by task rather than by
/// implementation prototype. Daily destinations come first; support last.
List<NavEntry> buildNavEntries(BuildContext context) {
  final api = ApiService();
  return [
    NavEntry(
      icon: Icons.dashboard_outlined,
      label: context.tr('nav_dashboard'),
      section: 'Screening',
      page: const FigmaDashboardScreen(),
      accent: DrsTokens.accent,
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
      accent: DrsTokens.accent,
    ),
    NavEntry(
      icon: Icons.help_outline,
      label: 'Help & Guidelines',
      section: 'Support',
      page: const FigmaHelpScreen(),
      accent: const Color(0xFFA78BFA),
    ),
    NavEntry(
      icon: Icons.info_outline,
      label: 'About / System Info',
      section: 'Support',
      page: const AboutScreen(),
      accent: DrsTokens.textMuted,
    ),
  ];
}
