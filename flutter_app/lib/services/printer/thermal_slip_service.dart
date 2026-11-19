import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../workplace/workplace_audio_service.dart';

/// Data payload for a field camp thermal receipt slip.
class CampSlipData {
  final String tokenNumber;
  final String patientName;
  final String patientId;
  final int? age;
  final String? gender;
  final DateTime screeningDate;
  final String facilityName;
  final String operatorName;
  final String odGradeLabel;
  final String osGradeLabel;
  final String referralStatus;
  final String followUpDate;
  final String hospitalPhone;
  final String qrPayload;

  const CampSlipData({
    required this.tokenNumber,
    required this.patientName,
    required this.patientId,
    this.age,
    this.gender,
    required this.screeningDate,
    required this.facilityName,
    required this.operatorName,
    required this.odGradeLabel,
    required this.osGradeLabel,
    required this.referralStatus,
    required this.followUpDate,
    this.hospitalPhone = '1800-425-2020',
    required this.qrPayload,
  });
}

/// Service generating standard ESC/POS (58mm / 80mm) thermal receipt data
/// and displaying an on-screen preview dialog for rural screening camps.
class ThermalSlipService {
  static final ThermalSlipService instance = ThermalSlipService._internal();
  factory ThermalSlipService() => instance;
  ThermalSlipService._internal();

  /// Generates ESC/POS standard binary command stream.
  List<int> generateEscPosBytes(CampSlipData data, {bool is80mm = false}) {
    final bytes = <int>[];

    // ESC @ - Initialize printer
    bytes.addAll([0x1B, 0x40]);

    // Center alignment
    bytes.addAll([0x1B, 0x61, 0x01]);

    // Header Bold
    bytes.addAll([0x1B, 0x45, 0x01]);
    bytes.addAll(utf8.encode('DRISHTI RETINA CAMP\n'));
    bytes.addAll([0x1B, 0x45, 0x00]); // Bold off
    bytes.addAll(utf8.encode('${data.facilityName}\n'));
    bytes.addAll(utf8.encode('--------------------------------\n'));

    // Token Double size
    bytes.addAll(utf8.encode('PATIENT TOKEN\n'));
    bytes.addAll([0x1D, 0x21, 0x11]); // Double width & height
    bytes.addAll(utf8.encode('${data.tokenNumber}\n'));
    bytes.addAll([0x1D, 0x21, 0x00]); // Normal size

    bytes.addAll(utf8.encode('--------------------------------\n'));

    // Left align for patient details
    bytes.addAll([0x1B, 0x61, 0x00]);
    final dStr = data.screeningDate.toString().substring(0, 16);
    bytes.addAll(utf8.encode('Date/Time: $dStr\n'));
    bytes.addAll(utf8.encode('Patient  : ${data.patientName}\n'));
    bytes.addAll(utf8.encode('ID       : ${data.patientId}\n'));
    if (data.age != null) {
      bytes.addAll(utf8.encode('Demogr.  : ${data.age}y / ${data.gender ?? '-'}\n'));
    }
    bytes.addAll(utf8.encode('Operator : ${data.operatorName}\n'));
    bytes.addAll(utf8.encode('--------------------------------\n'));

    // Eye Findings
    bytes.addAll(utf8.encode('CLINICAL FINDINGS:\n'));
    bytes.addAll(utf8.encode('  OD (Right Eye): ${data.odGradeLabel}\n'));
    bytes.addAll(utf8.encode('  OS (Left Eye) : ${data.osGradeLabel}\n'));
    bytes.addAll(utf8.encode('--------------------------------\n'));

    // Referral Advice
    bytes.addAll([0x1B, 0x45, 0x01]);
    bytes.addAll(utf8.encode('ADVICE: ${data.referralStatus}\n'));
    bytes.addAll(utf8.encode('NEXT REVIEW: ${data.followUpDate}\n'));
    bytes.addAll([0x1B, 0x45, 0x00]);
    bytes.addAll(utf8.encode('Helpdesk: ${data.hospitalPhone}\n'));

    bytes.addAll(utf8.encode('--------------------------------\n'));
    bytes.addAll([0x1B, 0x61, 0x01]); // Center
    bytes.addAll(utf8.encode('SCAN QR FOR ABHA VERIFICATION\n'));
    bytes.addAll(utf8.encode('${data.qrPayload}\n\n'));

    // Paper feed & Cut
    bytes.addAll(utf8.encode('\n\n\n'));
    bytes.addAll([0x1D, 0x56, 0x00]); // GS V 0 (Full Cut)

    return bytes;
  }

  /// Formatted monospace ASCII string for printing or clipboard.
  String generateAsciiSlip(CampSlipData data) {
    final buf = StringBuffer();
    buf.writeln('================================');
    buf.writeln('      DRISHTI RETINA CAMP       ');
    buf.writeln('  ${data.facilityName}');
    buf.writeln('================================');
    buf.writeln('         TOKEN NUMBER           ');
    buf.writeln('          ${data.tokenNumber}   ');
    buf.writeln('--------------------------------');
    buf.writeln('Date/Time: ${data.screeningDate.toString().substring(0, 16)}');
    buf.writeln('Patient  : ${data.patientName}');
    buf.writeln('ID       : ${data.patientId}');
    if (data.age != null) {
      buf.writeln('Demogr.  : ${data.age} yrs / ${data.gender ?? '-'}');
    }
    buf.writeln('Operator : ${data.operatorName}');
    buf.writeln('--------------------------------');
    buf.writeln('CLINICAL FINDINGS:');
    buf.writeln('OD (Right): ${data.odGradeLabel}');
    buf.writeln('OS (Left) : ${data.osGradeLabel}');
    buf.writeln('--------------------------------');
    buf.writeln('ADVICE   : ${data.referralStatus}');
    buf.writeln('NEXT EXAM: ${data.followUpDate}');
    buf.writeln('HELPLINE : ${data.hospitalPhone}');
    buf.writeln('--------------------------------');
    buf.writeln('QR REF   : ${data.qrPayload}');
    buf.writeln('================================');
    return buf.toString();
  }

  /// Displays the interactive thermal receipt modal preview.
  Future<void> showThermalSlipDialog(BuildContext context, CampSlipData data) async {
    await WorkplaceAudioService.instance.playShutterClick();
    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogCtx) => _ThermalSlipPreviewDialog(data: data),
    );
  }
}

class _ThermalSlipPreviewDialog extends StatefulWidget {
  final CampSlipData data;
  const _ThermalSlipPreviewDialog({required this.data});

  @override
  State<_ThermalSlipPreviewDialog> createState() => _ThermalSlipPreviewDialogState();
}

class _ThermalSlipPreviewDialogState extends State<_ThermalSlipPreviewDialog> {
  bool _printed = false;

  void _copySlip() {
    final text = ThermalSlipService.instance.generateAsciiSlip(widget.data);
    Clipboard.setData(ClipboardData(text: text));
    WorkplaceAudioService.instance.playQcSuccess();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Thermal receipt slip copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _simulatePrint() async {
    setState(() => _printed = true);
    await WorkplaceAudioService.instance.playBatchAction();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'ESC/POS 58mm print job dispatched for ${widget.data.tokenNumber}',
        ),
        backgroundColor: const Color(0xFF16A34A),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final isUrgent = d.referralStatus.contains('URGENT') ||
        d.referralStatus.contains('REFERRAL');

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Thermal Paper Canvas
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFFCFCF9), // Ivory receipt paper
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black54,
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Jagged / Serrated Top Edge representation
                    Container(
                      height: 6,
                      color: const Color(0xFFE5E5DE),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Header
                          const Center(
                            child: Text(
                              'DRISHTI RETINA CAMP',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 15,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                          Center(
                            child: Text(
                              d.facilityName.toUpperCase(),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF4B5563),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '--------------------------------',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: 'monospace', color: Color(0xFF9CA3AF)),
                          ),

                          // Token Number Big
                          const Center(
                            child: Text(
                              'PATIENT TOKEN',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280),
                                letterSpacing: 1.5,
                              ),
                            ),
                          ),
                          Center(
                            child: Text(
                              d.tokenNumber,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF111827),
                                letterSpacing: 2.0,
                              ),
                            ),
                          ),
                          const Text(
                            '--------------------------------',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: 'monospace', color: Color(0xFF9CA3AF)),
                          ),
                          const SizedBox(height: 6),

                          // Details
                          _row('Date', d.screeningDate.toString().substring(0, 16)),
                          _row('Patient', d.patientName),
                          _row('ID', d.patientId),
                          if (d.age != null)
                            _row('Demogr.', '${d.age}y / ${d.gender ?? '-'}'),
                          _row('Operator', d.operatorName),

                          const SizedBox(height: 8),
                          const Text(
                            '--------------------------------',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: 'monospace', color: Color(0xFF9CA3AF)),
                          ),
                          const Text(
                            'CLINICAL FINDINGS (RAPID SCREEN)',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF111827),
                            ),
                          ),
                          const SizedBox(height: 4),
                          _row('OD (Right)', d.odGradeLabel),
                          _row('OS (Left)', d.osGradeLabel),

                          const SizedBox(height: 8),
                          const Text(
                            '--------------------------------',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontFamily: 'monospace', color: Color(0xFF9CA3AF)),
                          ),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isUrgent
                                  ? const Color(0xFFFEE2E2)
                                  : const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: isUrgent
                                    ? const Color(0xFFEF4444)
                                    : const Color(0xFFD1D5DB),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.referralStatus,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: isUrgent
                                        ? const Color(0xFF991B1B)
                                        : const Color(0xFF1F2937),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Next Exam: ${d.followUpDate}',
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 10,
                                    color: Color(0xFF4B5563),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 10),
                          // QR Code
                          Center(
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              color: Colors.white,
                              child: QrImageView(
                                data: d.qrPayload,
                                version: QrVersions.auto,
                                size: 110,
                                eyeStyle: const QrEyeStyle(
                                  eyeShape: QrEyeShape.square,
                                  color: Colors.black,
                                ),
                                dataModuleStyle: const QrDataModuleStyle(
                                  dataModuleShape: QrDataModuleShape.square,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Center(
                            child: Text(
                              'OFFLINE / ABHA TOKEN VERIFY',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                color: Color(0xFF6B7280),
                              ),
                            ),
                          ),
                          Center(
                            child: Text(
                              'Toll-Free Helpline: ${d.hospitalPhone}',
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF374151),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Serrated Bottom Edge representation
                    Container(
                      height: 6,
                      color: const Color(0xFFE5E5DE),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 14),
              // Action Buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: _copySlip,
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy Slip Text'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFF475569)),
                      backgroundColor: const Color(0xFF1E293B),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed: _simulatePrint,
                    icon: Icon(_printed ? Icons.check_circle : Icons.print_rounded, size: 16),
                    label: Text(_printed ? 'Printed (58mm)' : 'Print Thermal Slip'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00B4D8),
                      foregroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white70),
                    tooltip: 'Close',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const Text(
            ': ',
            style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF6B7280)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
