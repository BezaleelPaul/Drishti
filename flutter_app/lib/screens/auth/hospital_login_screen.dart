import 'package:flutter/material.dart';
import '../../services/hospital_auth_service.dart';
import '../../theme/design_system.dart';
import '../../widgets/scanner/scanner_theme.dart';
import '../figma_dashboard_screen.dart';

/// Local Hospital Login Screen for Drishti Retinal Screening.
///
/// Tailored exclusively for hospital intranet and offline clinical environments.
/// Provides dedicated role-based entry for:
/// 1. Imaging Technician / Camera Operator ("Guy who takes photos").
/// 2. Hospital Clinician / Doctor ("Patient details, triage & report sign-off").
class HospitalLoginScreen extends StatefulWidget {
  final VoidCallback? onLoginSuccess;

  const HospitalLoginScreen({super.key, this.onLoginSuccess});

  @override
  State<HospitalLoginScreen> createState() => _HospitalLoginScreenState();
}

class _HospitalLoginScreenState extends State<HospitalLoginScreen> {
  final _auth = HospitalAuthService.instance;
  final _formKey = GlobalKey<FormState>();

  late TextEditingController _hospitalController;
  late TextEditingController _staffNameController;
  late TextEditingController _staffIdController;
  late TextEditingController _pinController;

  HospitalRole _selectedRole = HospitalRole.imagingTech;
  bool _obscurePin = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    final session = _auth.session;
    _hospitalController = TextEditingController(
      text: session?.hospitalName ?? 'District General Hospital · Eye Wing',
    );
    _staffNameController = TextEditingController(
      text: session?.staffName ?? 'Ramesh Kumar',
    );
    _staffIdController = TextEditingController(
      text: session?.staffId ?? 'TECH-104',
    );
    _pinController = TextEditingController(text: '1234');
    _selectedRole = session?.role ?? HospitalRole.imagingTech;
  }

  @override
  void dispose() {
    _hospitalController.dispose();
    _staffNameController.dispose();
    _staffIdController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  void _onRoleChanged(HospitalRole role) {
    setState(() {
      _selectedRole = role;
      _errorMessage = null;
      if (role == HospitalRole.imagingTech) {
        _staffNameController.text = 'Ramesh Kumar';
        _staffIdController.text = 'TECH-104';
      } else {
        _staffNameController.text = 'Dr. A. Sharma';
        _staffIdController.text = 'DOC-108';
      }
    });
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final success = await _auth.login(
        hospital: _hospitalController.text,
        staffName: _staffNameController.text,
        staffId: _staffIdController.text,
        role: _selectedRole,
        pin: _selectedRole == HospitalRole.clinician ? _pinController.text : null,
      );

      if (!mounted) return;

      if (!success) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Invalid Clinician PIN. Default demo PIN is 1234.';
        });
        return;
      }

      setState(() => _isLoading = false);

      if (widget.onLoginSuccess != null) {
        widget.onLoginSuccess!();
      } else {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const FigmaDashboardScreen()),
        );
      }
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Login failed: ${e.toString()}';
      });
    }
  }

  Future<void> _handleQuickLogin(HospitalRole role) async {
    setState(() => _isLoading = true);
    await _auth.quickLogin(role);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (widget.onLoginSuccess != null) {
      widget.onLoginSuccess!();
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const FigmaDashboardScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ScannerHUDTheme.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 580),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(),
                    const SizedBox(height: 28),
                    _buildRoleSelectionCards(),
                    const SizedBox(height: 24),
                    _buildCredentialsForm(),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 16),
                      _buildErrorBanner(_errorMessage!),
                    ],
                    const SizedBox(height: 24),
                    _buildSubmitButton(),
                    const SizedBox(height: 20),
                    _buildQuickAccessSection(),
                    const SizedBox(height: 24),
                    _buildOfflineFooter(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 58,
          height: 58,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: DrsTokens.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: DrsTokens.accent.withValues(alpha: 0.25)),
          ),
          child: Image.asset(
            'assets/branding/drishti_mark.png',
            fit: BoxFit.contain,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          'DRISHTI CLINICAL WORKSPACE',
          style: TextStyle(
            color: DrsTokens.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Hospital-Local Access & Role-Based Clinical Triage',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: DrsTokens.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildRoleSelectionCards() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'SELECT YOUR HOSPITAL ROLE',
          style: TextStyle(
            color: DrsTokens.textSubtle,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildRoleCard(
                role: HospitalRole.imagingTech,
                title: 'Camera Operator',
                subtitle: 'Takes fundus scans & runs AI',
                icon: Icons.photo_camera_rounded,
                accentColor: DrsTokens.accent,
                badgeText: 'IMAGING TECH',
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _buildRoleCard(
                role: HospitalRole.clinician,
                title: 'Hospital Doctor',
                subtitle: 'Patient details & report triage',
                icon: Icons.medical_services_rounded,
                accentColor: DrsTokens.success,
                badgeText: 'CLINICIAN / DR',
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRoleCard({
    required HospitalRole role,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String badgeText,
  }) {
    final isSelected = _selectedRole == role;
    return InkWell(
      onTap: () => _onRoleChanged(role),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? accentColor.withValues(alpha: 0.12)
              : DrsTokens.surface.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? accentColor : DrsTokens.border,
            width: isSelected ? 1.8 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.18),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  )
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: accentColor, size: 20),
                ),
                const Spacer(),
                if (isSelected)
                  Icon(Icons.check_circle_rounded, color: accentColor, size: 18)
                else
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: DrsTokens.textSubtle),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                badgeText,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 8,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: const TextStyle(
                color: DrsTokens.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              style: const TextStyle(
                color: DrsTokens.textMuted,
                fontSize: 11,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCredentialsForm() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: DrsTokens.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: DrsTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildTextField(
            controller: _hospitalController,
            label: 'HOSPITAL / CLINIC FACILITY',
            hint: 'e.g. District General Hospital or Aravind Eye Camp',
            icon: Icons.local_hospital_outlined,
            validator: (v) => v == null || v.trim().isEmpty ? 'Hospital name required' : null,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildTextField(
                  controller: _staffNameController,
                  label: _selectedRole == HospitalRole.imagingTech ? 'OPERATOR NAME' : 'DOCTOR NAME',
                  hint: _selectedRole == HospitalRole.imagingTech ? 'e.g. Ramesh Kumar' : 'e.g. Dr. A. Sharma',
                  icon: Icons.person_outline,
                  validator: (v) => v == null || v.trim().isEmpty ? 'Name required' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: _buildTextField(
                  controller: _staffIdController,
                  label: 'STAFF ID',
                  hint: _selectedRole == HospitalRole.imagingTech ? 'TECH-104' : 'DOC-108',
                  icon: Icons.badge_outlined,
                  validator: (v) => v == null || v.trim().isEmpty ? 'ID required' : null,
                ),
              ),
            ],
          ),
          if (_selectedRole == HospitalRole.clinician) ...[
            const SizedBox(height: 16),
            _buildTextField(
              controller: _pinController,
              label: 'CLINICIAN SECURITY PIN (DISHA/HIPAA)',
              hint: 'Enter 4-digit PIN (Default: 1234)',
              icon: Icons.lock_outline,
              isPassword: true,
              obscureText: _obscurePin,
              onTogglePassword: () => setState(() => _obscurePin = !_obscurePin),
              validator: (v) => v == null || v.trim().length < 4 ? 'Min 4-digit PIN required' : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onTogglePassword,
    String? Function(String?)? validator,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: DrsTokens.textSubtle,
            fontSize: 9,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 7),
        TextFormField(
          controller: controller,
          obscureText: obscureText,
          validator: validator,
          style: const TextStyle(
            color: DrsTokens.textPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: const TextStyle(color: DrsTokens.textSubtle, fontSize: 12),
            prefixIcon: Icon(icon, size: 18, color: DrsTokens.textMuted),
            suffixIcon: isPassword
                ? IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 18,
                      color: DrsTokens.textMuted,
                    ),
                    onPressed: onTogglePassword,
                  )
                : null,
            filled: true,
            fillColor: ScannerHUDTheme.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DrsTokens.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DrsTokens.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: DrsTokens.accent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: DrsTokens.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DrsTokens.danger.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: DrsTokens.danger, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: DrsTokens.danger, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitButton() {
    final accent = _selectedRole == HospitalRole.imagingTech ? DrsTokens.accent : DrsTokens.success;
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleLogin,
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: const Color(0xFF070B14),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF070B14)),
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _selectedRole == HospitalRole.imagingTech
                        ? Icons.camera_alt_outlined
                        : Icons.assignment_ind_outlined,
                    size: 19,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    _selectedRole == HospitalRole.imagingTech
                        ? 'ENTER AS CAMERA OPERATOR'
                        : 'ENTER AS HOSPITAL DOCTOR',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                      letterSpacing: 0.6,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildQuickAccessSection() {
    return Column(
      children: [
        const Row(
          children: [
            Expanded(child: Divider(color: DrsTokens.border)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'QUICK CLINIC ACCESS (ONE-TAP)',
                style: TextStyle(
                  color: DrsTokens.textSubtle,
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            Expanded(child: Divider(color: DrsTokens.border)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _handleQuickLogin(HospitalRole.imagingTech),
                icon: const Icon(Icons.flash_on, size: 16, color: DrsTokens.accent),
                label: const Text('Quick: Camera Tech', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: DrsTokens.textPrimary,
                  side: const BorderSide(color: DrsTokens.border),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _handleQuickLogin(HospitalRole.clinician),
                icon: const Icon(Icons.verified_user_outlined, size: 16, color: DrsTokens.success),
                label: const Text('Quick: Doctor Review', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: DrsTokens.textPrimary,
                  side: const BorderSide(color: DrsTokens.border),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildOfflineFooter() {
    return const Center(
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        spacing: 6,
        children: [
          Icon(Icons.wifi_off_rounded, size: 13, color: DrsTokens.textSubtle),
          Text(
            '100% Offline Hospital Ready · Local Access Only',
            style: TextStyle(
              color: DrsTokens.textSubtle,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
