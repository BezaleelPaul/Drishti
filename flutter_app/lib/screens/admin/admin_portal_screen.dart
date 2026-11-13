import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/smtp/smtp_service.dart';
import '../../theme/figma_theme.dart';
import '../../widgets/scanner/scanner_theme.dart';

class AdminPortalScreen extends StatefulWidget {
  const AdminPortalScreen({super.key});

  @override
  State<AdminPortalScreen> createState() => _AdminPortalScreenState();
}

class _AdminPortalScreenState extends State<AdminPortalScreen> {
  final _formKey = GlobalKey<FormState>();
  final _smtpService = SmtpService();

  late final TextEditingController _senderEmail;
  late final TextEditingController _password;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _specialistEmail;
  late final TextEditingController _senderName;
  late final TextEditingController _testRecipient;

  bool _useSsl = true;
  bool _autoSendOnDr = true;
  int _minGrade = 1;
  bool _obscurePassword = true;

  bool _testing = false;
  bool _saving = false;
  String? _testResult;
  String? _testTranscript;

  @override
  void initState() {
    super.initState();
    _senderEmail = TextEditingController();
    _password = TextEditingController();
    _host = TextEditingController(text: 'smtp.gmail.com');
    _port = TextEditingController(text: '465');
    _specialistEmail = TextEditingController();
    _senderName = TextEditingController(text: 'Drishti AI Automated Screening');
    _testRecipient = TextEditingController();

    _loadExistingConfig();
  }

  Future<void> _loadExistingConfig() async {
    final cfg = await _smtpService.loadConfig();
    setState(() {
      _senderEmail.text = cfg.senderEmail;
      _password.text = cfg.senderPassword;
      _host.text = cfg.smtpHost;
      _port.text = cfg.smtpPort.toString();
      _specialistEmail.text = cfg.specialistEmail;
      _senderName.text = cfg.senderName;
      _testRecipient.text = cfg.specialistEmail;
      _useSsl = cfg.useSsl;
      _autoSendOnDr = cfg.autoSendOnDr;
      _minGrade = cfg.minSeverityGrade;
    });
  }

  @override
  void dispose() {
    _senderEmail.dispose();
    _password.dispose();
    _host.dispose();
    _port.dispose();
    _specialistEmail.dispose();
    _senderName.dispose();
    _testRecipient.dispose();
    super.dispose();
  }

  void _applyPreset(String name) {
    setState(() {
      switch (name) {
        case 'gmail':
          _host.text = 'smtp.gmail.com';
          _port.text = '465';
          _useSsl = true;
          break;
        case 'outlook':
          _host.text = 'smtp.office365.com';
          _port.text = '587';
          _useSsl = false;
          break;
        case 'ses':
          _host.text = 'email-smtp.us-east-1.amazonaws.com';
          _port.text = '465';
          _useSsl = true;
          break;
      }
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final config = SmtpConfig(
        senderEmail: _senderEmail.text.trim(),
        senderPassword: _password.text.trim(),
        smtpHost: _host.text.trim(),
        smtpPort: int.tryParse(_port.text.trim()) ?? 465,
        useSsl: _useSsl,
        specialistEmail: _specialistEmail.text.trim(),
        senderName: _senderName.text.trim(),
        autoSendOnDr: _autoSendOnDr,
        minSeverityGrade: _minGrade,
      );
      await _smtpService.saveConfig(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Admin & SMTP settings successfully saved!'),
          backgroundColor: FigmaColors.success,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    // Save current values first
    await _save();

    final target = _testRecipient.text.trim().isNotEmpty
        ? _testRecipient.text.trim()
        : _specialistEmail.text.trim();

    if (target.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a specialist or test email address.'),
          backgroundColor: FigmaColors.danger,
        ),
      );
      return;
    }

    setState(() {
      _testing = true;
      _testResult = null;
      _testTranscript = null;
    });

    try {
      final res = await _smtpService.sendTestEmail(testRecipient: target);
      if (!mounted) return;
      setState(() {
        _testResult = res.message;
        _testTranscript = res.transcript;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(res.success
              ? 'Test email delivered successfully!'
              : 'Failed to send test email.'),
          backgroundColor: res.success ? FigmaColors.success : FigmaColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      appBar: AppBar(
        backgroundColor: ScannerHUDTheme.darkSurface,
        foregroundColor: ScannerHUDTheme.neonCyan,
        elevation: 0,
        title: const Text(
          'Admin Portal & SMTP Settings',
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 18,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: ScannerHUDTheme.neonCyan),
                  )
                : const Icon(Icons.check, color: ScannerHUDTheme.neonCyan),
            tooltip: 'Save Settings',
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Info banner
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F1E38),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.mark_email_read_outlined,
                            color: ScannerHUDTheme.neonCyan, size: 28),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Automated Specialist Referral Gateway',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Whenever a patient is diagnosed with Diabetic Retinopathy, the system automatically dispatches the full clinical report and fundus photograph to the specialist doctor.',
                                style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Section 1: Specialist Dispatch Settings
                  _sectionHeader(
                    title: 'Specialist Recipient Settings',
                    subtitle: 'Doctor and hospital alert destinations',
                    icon: Icons.local_hospital_outlined,
                  ),
                  const SizedBox(height: 10),
                  _card([
                    _textInput(
                      label: 'Specialist Doctor Email(s)',
                      controller: _specialistEmail,
                      hint: 'dr.specialist@hospital.org (comma-separated)',
                      icon: Icons.alternate_email,
                      required: true,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Automatic Dispatch on DR Detection',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _autoSendOnDr
                                    ? 'Active: Alert is sent instantly upon diagnosis'
                                    : 'Disabled: Manual referral only',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _autoSendOnDr,
                          activeThumbColor: ScannerHUDTheme.neonCyan,
                          activeTrackColor: ScannerHUDTheme.neonCyan.withValues(alpha: 0.5),
                          onChanged: (v) => setState(() => _autoSendOnDr = v),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int>(
                      initialValue: _minGrade,
                      dropdownColor: const Color(0xFF101A33),
                      style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 13),
                      decoration: InputDecoration(
                        labelText: 'Minimum Severity Trigger',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        filled: true,
                        fillColor: const Color(0xFF0F172A),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('Any DR (Grade 1 - Mild, Moderate, Severe, PDR)')),
                        DropdownMenuItem(value: 2, child: Text('Referable DR (Grade 2 - Moderate, Severe, PDR)')),
                        DropdownMenuItem(value: 3, child: Text('Sight-Threatening DR Only (Grade 3 - Severe, PDR)')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _minGrade = v);
                      },
                    ),
                  ]),

                  const SizedBox(height: 24),

                  // Section 2: Sender SMTP Configuration
                  _sectionHeader(
                    title: 'Sender SMTP Server Configuration',
                    subtitle: 'Authenticated gateway credentials (e.g. Gmail, Outlook)',
                    icon: Icons.dns_outlined,
                  ),
                  const SizedBox(height: 10),
                  _card([
                    // Quick Presets
                    Row(
                      children: [
                        const Text('Presets: ', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                        const SizedBox(width: 8),
                        _presetChip('Gmail (Port 465)', () => _applyPreset('gmail')),
                        const SizedBox(width: 6),
                        _presetChip('Outlook (Port 587)', () => _applyPreset('outlook')),
                        const SizedBox(width: 6),
                        _presetChip('AWS SES', () => _applyPreset('ses')),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _textInput(
                      label: 'Sender Email Address',
                      controller: _senderEmail,
                      hint: 'clinic.drishti@gmail.com',
                      icon: Icons.email_outlined,
                      required: true,
                    ),
                    const SizedBox(height: 12),
                    _textInput(
                      label: 'SMTP Password / Google App Password',
                      controller: _password,
                      hint: '16-character Google App Password (e.g. abcd efgh ijkl mnop)',
                      icon: Icons.key_outlined,
                      obscureText: _obscurePassword,
                      required: true,
                      suffix: IconButton(
                        icon: Icon(
                          _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                          color: const Color(0xFF94A3B8),
                        ),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: _textInput(
                            label: 'SMTP Host',
                            controller: _host,
                            hint: 'smtp.gmail.com',
                            icon: Icons.cloud_queue_outlined,
                            required: true,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 1,
                          child: _textInput(
                            label: 'Port',
                            controller: _port,
                            hint: '465',
                            keyboard: TextInputType.number,
                            required: true,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Direct SSL/TLS Encryption',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _useSsl ? 'Port 465 (SMTPS SSL/TLS)' : 'Port 587 (STARTTLS Handshake)',
                                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _useSsl,
                          activeThumbColor: ScannerHUDTheme.neonCyan,
                          activeTrackColor: ScannerHUDTheme.neonCyan.withValues(alpha: 0.5),
                          onChanged: (v) => setState(() => _useSsl = v),
                        ),
                      ],
                    ),
                  ]),

                  const SizedBox(height: 24),

                  // Section 3: Diagnostic Test Dispatch
                  _sectionHeader(
                    title: 'Test Email Dispatch & Handshake',
                    subtitle: 'Verify SMTP connection and immediate delivery',
                    icon: Icons.send_and_archive_outlined,
                  ),
                  const SizedBox(height: 10),
                  _card([
                    Row(
                      children: [
                        Expanded(
                          child: _textInput(
                            label: 'Test Recipient Email',
                            controller: _testRecipient,
                            hint: 'doctor@hospital.org',
                            icon: Icons.send_outlined,
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _testing ? null : _testConnection,
                          icon: _testing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.bolt, size: 18),
                          label: Text(_testing ? 'Connecting...' : 'Send Test'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00B4D8),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    ),
                    if (_testResult != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _testResult!.contains('successfully')
                                ? FigmaColors.success
                                : FigmaColors.danger,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _testResult!.contains('successfully')
                                      ? Icons.check_circle
                                      : Icons.error_outline,
                                  size: 16,
                                  color: _testResult!.contains('successfully')
                                      ? FigmaColors.success
                                      : FigmaColors.danger,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    _testResult!,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _testResult!.contains('successfully')
                                          ? const Color(0xFF34D399)
                                          : const Color(0xFFF87171),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (_testTranscript != null) ...[
                              const SizedBox(height: 8),
                              const Text('SMTP Transcript:',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
                              const SizedBox(height: 4),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black45,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  _testTranscript!,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                    color: Color(0xFFE2E8F0),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ]),

                  const SizedBox(height: 28),

                  // Save Button
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ScannerHUDTheme.neonCyan,
                      foregroundColor: const Color(0xFF0B1120),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 4,
                    ),
                    child: Text(
                      _saving ? 'Saving...' : 'Save Admin & SMTP Settings',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return Row(
      children: [
        Icon(icon, color: ScannerHUDTheme.neonCyan, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card(List<Widget> children) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ScannerHUDTheme.darkSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF1E2D4A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _presetChip(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF38BDF8), fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  Widget _textInput({
    required String label,
    required TextEditingController controller,
    String? hint,
    IconData? icon,
    bool obscureText = false,
    bool required = false,
    TextInputType? keyboard,
    Widget? suffix,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboard,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      validator: required
          ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null
          : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF64748B), fontSize: 12),
        labelStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        prefixIcon: icon != null ? Icon(icon, color: const Color(0xFF64748B), size: 18) : null,
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1E293B)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF1E293B)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: ScannerHUDTheme.neonCyan),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    );
  }
}
