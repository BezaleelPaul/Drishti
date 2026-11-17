import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/specialist_models.dart';
import '../../services/routing/specialist_directory_service.dart';
import '../../widgets/scanner/scanner_theme.dart';

/// Admin maintenance for the offline specialist routing directory.
///
/// The directory stores professional contact/facility data only (no patient
/// PHI) and is used by the Dijkstra referral router. Entries can be added
/// manually or loaded from a clearly-labelled demo set.
class SpecialistRoutingScreen extends StatefulWidget {
  const SpecialistRoutingScreen({super.key});

  @override
  State<SpecialistRoutingScreen> createState() => _SpecialistRoutingScreenState();
}

class _SpecialistRoutingScreenState extends State<SpecialistRoutingScreen> {
  final _service = SpecialistDirectoryService.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _service.load(reload: true);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final origin = _service.origin;
    final specialists = _service.specialists;
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: const Text(
          'Specialist Routing Directory',
          style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: ScannerHUDTheme.neonCyan),
            )
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _infoCard(),
                    const SizedBox(height: 12),
                    _originCard(origin),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => _editSpecialist(),
                            icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                            label: const Text('Add Specialist'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: ScannerHUDTheme.neonCyan,
                              foregroundColor: ScannerHUDTheme.background,
                              padding: const EdgeInsets.symmetric(vertical: 13),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        OutlinedButton.icon(
                          onPressed: _confirmLoadDemo,
                          icon: const Icon(Icons.science_outlined, size: 18),
                          label: const Text('Load Demo'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFF59E0B),
                            side: const BorderSide(color: Color(0x66F59E0B)),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (specialists.isEmpty)
                      const _EmptyDirectoryCard()
                    else ...[
                      Text(
                        '${specialists.length} destination(s)',
                        style: const TextStyle(
                          color: Color(0xFF94A3B8),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final s in specialists) _specialistTile(s),
                    ],
                    const SizedBox(height: 24),
                    const Text(
                      'Routing uses Dijkstra over a facility graph built from '
                      'Haversine road-adjusted edges. Imported road graphs can '
                      'replace those edges without changing the app. Always '
                      'confirm the destination before sending a clinical report.',
                      style: TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 11,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _infoCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0B2239),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0x6600E5FF)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.alt_route, color: ScannerHUDTheme.neonCyan, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Offline-first routing. The nearest suitable specialist is ranked '
              'by travel time, retinal capability, waiting time and teleconsult '
              'availability. Patient data never leaves the device during routing.',
              style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 12, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _originCard(ScreeningCentre? origin) {
    final configured = origin?.isRoutable == true;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: configured ? const Color(0xFF1E2D4A) : const Color(0x80F59E0B),
        ),
      ),
      child: Row(
        children: [
          Icon(
            configured ? Icons.my_location : Icons.location_off_outlined,
            color: configured ? const Color(0xFF34D399) : const Color(0xFFF59E0B),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'SCREENING CENTRE ORIGIN',
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 10,
                    letterSpacing: 0.7,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  configured ? origin!.name : 'Location not configured',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  configured
                      ? '${origin!.address} · ${origin.location}'
                      : 'Set coordinates to enable distance/travel ranking.',
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => _editOrigin(origin),
            child: Text(configured ? 'Edit' : 'Set'),
          ),
        ],
      ),
    );
  }

  Widget _specialistTile(Specialist s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF111C38),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF1E2D4A)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: ScannerHUDTheme.neonCyan.withValues(alpha: 0.14),
            child: Text(
              s.name.trim().isEmpty ? '?' : s.name.trim()[0].toUpperCase(),
              style: const TextStyle(
                color: ScannerHUDTheme.neonCyan,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        s.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (s.isDemo) ...[
                      const SizedBox(width: 6),
                      const _Badge('DEMO', Color(0xFFF59E0B)),
                    ],
                    if (!s.active) ...[
                      const SizedBox(width: 6),
                      const _Badge('OFF', Color(0xFFEF4444)),
                    ],
                  ],
                ),
                Text(
                  '${s.qualification} · ${s.facilityName}',
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _Badge(
                      'Max G${s.maxGrade}',
                      const Color(0xFF38BDF8),
                    ),
                    _Badge(
                      '${s.averageWaitDays}d wait',
                      const Color(0xFFA78BFA),
                    ),
                    if (s.teleconsultEnabled)
                      const _Badge('Teleconsult', Color(0xFF34D399)),
                    if (!s.hasLocation)
                      const _Badge('No location', Color(0xFFF59E0B)),
                    for (final c in s.capabilities.take(2))
                      _Badge(c, const Color(0xFF64748B)),
                  ],
                ),
                if (s.email.isNotEmpty)
                  Text(
                    s.email,
                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
                  ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            color: ScannerHUDTheme.darkSurface,
            icon: const Icon(Icons.more_vert, color: Color(0xFF94A3B8)),
            onSelected: (value) {
              if (value == 'edit') _editSpecialist(s);
              if (value == 'delete') _confirmDelete(s);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(Specialist s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ScannerHUDTheme.darkSurface,
        title: const Text('Remove destination?', style: TextStyle(color: Colors.white)),
        content: Text(
          '${s.displayName} — ${s.facilityName} will no longer receive routed referrals.',
          style: const TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _service.deleteSpecialist(s.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmLoadDemo() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ScannerHUDTheme.darkSurface,
        title: const Text('Load demo directory?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'This replaces the current directory with synthetic Pune/Satara '
          'facilities and training@example.org contacts. Every entry is marked '
          'DEMO and must not be used for real clinical referrals.',
          style: TextStyle(color: Color(0xFF94A3B8), height: 1.45),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFF59E0B)),
            child: const Text('Load demo'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _service.loadDemoDirectory();
      if (mounted) setState(() {});
    }
  }

  Future<void> _editOrigin(ScreeningCentre? current) async {
    final name = TextEditingController(text: current?.name ?? '');
    final address = TextEditingController(text: current?.address ?? '');
    final lat = TextEditingController(
      text: current?.location?.latitude.toString() ?? '',
    );
    final lng = TextEditingController(
      text: current?.location?.longitude.toString() ?? '',
    );
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ScannerHUDTheme.darkSurface,
        title: const Text('Screening centre location', style: TextStyle(color: Colors.white)),
        content: Form(
          key: formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _dialogField(name, 'Centre name', required: true),
                const SizedBox(height: 8),
                _dialogField(address, 'Address / village'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _dialogField(lat, 'Latitude', number: true, required: true)),
                    const SizedBox(width: 8),
                    Expanded(child: _dialogField(lng, 'Longitude', number: true, required: true)),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tip: long-press a point in Google Maps to copy coordinates.',
                  style: TextStyle(color: Color(0xFF64748B), fontSize: 10.5),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Save origin'),
          ),
        ],
      ),
    );
    if (result != true) return;
    final latValue = double.tryParse(lat.text.trim());
    final lngValue = double.tryParse(lng.text.trim());
    await _service.setOrigin(
      ScreeningCentre(
        name: name.text.trim(),
        address: address.text.trim(),
        location: latValue != null && lngValue != null
            ? GeoPoint(latValue, lngValue)
            : null,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editSpecialist([Specialist? existing]) async {
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: existing?.name ?? '');
    final qualification = TextEditingController(
      text: existing?.qualification ?? 'MS Ophthalmology',
    );
    final facility = TextEditingController(text: existing?.facilityName ?? '');
    final address = TextEditingController(text: existing?.address ?? '');
    final city = TextEditingController(text: existing?.city ?? '');
    final district = TextEditingController(text: existing?.district ?? '');
    final email = TextEditingController(text: existing?.email ?? '');
    final phone = TextEditingController(text: existing?.phone ?? '');
    final teleconsult = TextEditingController(text: existing?.teleconsultUrl ?? '');
    final lat = TextEditingController(
      text: existing?.location?.latitude.toString() ?? '',
    );
    final lng = TextEditingController(
      text: existing?.location?.longitude.toString() ?? '',
    );
    final caps = {...(existing?.capabilities ?? {'retina'})};
    var maxGrade = existing?.maxGrade ?? 4;
    var waitDays = existing?.averageWaitDays ?? 3;
    var inPerson = existing?.acceptsInPerson ?? true;
    var teleconsultEnabled = existing?.teleconsultEnabled ?? true;
    var active = existing?.active ?? true;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: ScannerHUDTheme.darkSurface,
          title: Text(
            existing == null ? 'Add specialist destination' : 'Edit specialist',
            style: const TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 560,
            child: Form(
              key: formKey,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _dialogField(name, 'Doctor name', required: true),
                    const SizedBox(height: 8),
                    _dialogField(qualification, 'Qualification'),
                    const SizedBox(height: 8),
                    _dialogField(facility, 'Facility / hospital', required: true),
                    const SizedBox(height: 8),
                    _dialogField(address, 'Street address'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _dialogField(city, 'City')),
                        const SizedBox(width: 8),
                        Expanded(child: _dialogField(district, 'District')),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _dialogField(email, 'Email', email: true),
                    const SizedBox(height: 8),
                    _dialogField(phone, 'Phone'),
                    const SizedBox(height: 8),
                    _dialogField(teleconsult, 'Teleconsult URL'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(child: _dialogField(lat, 'Latitude', number: true)),
                        const SizedBox(width: 8),
                        Expanded(child: _dialogField(lng, 'Longitude', number: true)),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Capabilities',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final cap in const [
                          'retina',
                          'vitreoretinal',
                          'general',
                          'glaucoma',
                        ])
                          FilterChip(
                            label: Text(cap),
                            selected: caps.contains(cap),
                            onSelected: (v) => setLocal(() {
                              if (v) {
                                caps.add(cap);
                              } else {
                                caps.remove(cap);
                              }
                            }),
                            selectedColor: ScannerHUDTheme.neonCyan.withValues(alpha: 0.25),
                            labelStyle: const TextStyle(fontSize: 11),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: maxGrade,
                            dropdownColor: ScannerHUDTheme.darkSurface,
                            decoration: _decoration('Max ICDR grade'),
                            items: [
                              for (var i = 0; i <= 4; i++)
                                DropdownMenuItem(value: i, child: Text('Grade $i')),
                            ],
                            onChanged: (v) => setLocal(() => maxGrade = v ?? 4),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            initialValue: waitDays.clamp(0, 30),
                            dropdownColor: ScannerHUDTheme.darkSurface,
                            decoration: _decoration('Average wait (days)'),
                            items: [
                              for (var i = 0; i <= 30; i++)
                                DropdownMenuItem(value: i, child: Text('$i day(s)')),
                            ],
                            onChanged: (v) => setLocal(() => waitDays = v ?? 3),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Accepts in-person referrals',
                          style: TextStyle(fontSize: 12, color: Colors.white)),
                      value: inPerson,
                      onChanged: (v) => setLocal(() => inPerson = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Teleconsultation available',
                          style: TextStyle(fontSize: 12, color: Colors.white)),
                      value: teleconsultEnabled,
                      onChanged: (v) => setLocal(() => teleconsultEnabled = v),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Active destination',
                          style: TextStyle(fontSize: 12, color: Colors.white)),
                      value: active,
                      onChanged: (v) => setLocal(() => active = v),
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('Save destination'),
            ),
          ],
        ),
      ),
    );

    if (result != true) return;
    final latValue = double.tryParse(lat.text.trim());
    final lngValue = double.tryParse(lng.text.trim());
    await _service.saveSpecialist(
      Specialist(
        id: existing?.id ?? '',
        name: name.text.trim(),
        qualification: qualification.text.trim(),
        facilityName: facility.text.trim(),
        address: address.text.trim(),
        city: city.text.trim(),
        district: district.text.trim(),
        location: latValue != null && lngValue != null
            ? GeoPoint(latValue, lngValue)
            : null,
        email: email.text.trim(),
        phone: phone.text.trim(),
        teleconsultUrl: teleconsult.text.trim(),
        capabilities: caps.isEmpty ? {'general'} : caps,
        maxGrade: maxGrade,
        averageWaitDays: waitDays,
        acceptsInPerson: inPerson,
        teleconsultEnabled: teleconsultEnabled,
        active: active,
        isDemo: existing?.isDemo ?? false,
      ),
    );
    if (mounted) setState(() {});
  }

  InputDecoration _decoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
        isDense: true,
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF334155)),
        ),
      );

  Widget _dialogField(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool number = false,
    bool email = false,
  }) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(color: Colors.white, fontSize: 12),
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : email
              ? TextInputType.emailAddress
              : TextInputType.text,
      decoration: _decoration(label),
      validator: (value) {
        final v = value?.trim() ?? '';
        if (required && v.isEmpty) return 'Required';
        if (email && v.isNotEmpty && !v.contains('@')) return 'Invalid email';
        if (number && v.isNotEmpty && double.tryParse(v) == null) {
          return 'Invalid number';
        }
        return null;
      },
    );
  }
}

class _EmptyDirectoryCard extends StatelessWidget {
  const _EmptyDirectoryCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E2D4A)),
      ),
      child: const Column(
        children: [
          Icon(Icons.location_searching, color: Color(0xFF64748B), size: 32),
          SizedBox(height: 8),
          Text(
            'No specialist destinations yet',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 4),
          Text(
            'Add a real facility, or load the synthetic demo directory to test routing.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.65)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w700),
      ),
    );
  }
}
