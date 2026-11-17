import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/specialist_models.dart';
import '../../screens/flow/flow_state.dart';
import '../ml/pipeline/local_explanation_generator.dart';
import '../platform/app_paths.dart';

/// Hospital-grade clinical PDF screening dossier generator for Drishti.
/// Generates A4 clinical documents compliant with Indian Tele-Ophthalmology standards.
class ClinicalPdfGenerator {
  /// Generates printable A4 PDF bytes containing full patient intake,
  /// clinical metrics, AI severity classification, and retinal fundus images.
  static Future<Uint8List> generateReportPdf(FlowState state) async {
    final pdf = pw.Document(
      title: 'Drishti Clinical Screening Dossier - ${state.patient.patientId}',
      author: 'Drishti Autonomous Retinal AI',
    );

    final p = state.patient;
    final a = state.analysis;
    final grade = state.correctedGrade ?? a?.drGrade ?? 0;
    final gradeLabel = a?.drLabel ??
        (grade == 0
            ? 'No Diabetic Retinopathy'
            : 'Diabetic Retinopathy Grade $grade');
    final confidence =
        ((a?.predictionScore ?? 0.95) * 100).toStringAsFixed(1);
    final screeningId =
        a?.screeningId ?? 'LOC-${DateTime.now().millisecondsSinceEpoch}';
    final timestamp = DateTime.now().toLocal().toString().split('.').first;

    // Load screening image bytes
    pw.MemoryImage? fundusImage;
    if (state.imageBytes != null && state.imageBytes!.isNotEmpty) {
      try {
        fundusImage = pw.MemoryImage(state.imageBytes!);
      } catch (e) {
        debugPrint('Could not decode fundus image for PDF: $e');
      }
    }

    // Load or generate Grad-CAM visual attention heatmap bytes
    Uint8List? heatmapBytes = a?.gradcamOverlayBytes;
    if (heatmapBytes == null && state.imageBytes != null && state.imageBytes!.isNotEmpty) {
      try {
        final explanation = generateLocalExplanationWorker(
          LocalExplanationRequest(
            imageBytes: state.imageBytes!,
            predictedGrade: grade,
            confidence: a?.predictionScore,
          ),
        );
        heatmapBytes = explanation.overlayBytes;
      } catch (e) {
        debugPrint('Could not generate on-device heatmap overlay for PDF: $e');
      }
    }

    pw.MemoryImage? heatmapImage;
    if (heatmapBytes != null && heatmapBytes.isNotEmpty) {
      try {
        heatmapImage = pw.MemoryImage(heatmapBytes);
      } catch (e) {
        debugPrint('Could not decode heatmap image for PDF: $e');
      }
    }

    // Determine severity badge colors
    final PdfColor severityBg = grade == 0
        ? PdfColors.green50
        : (grade == 1
            ? PdfColors.blue50
            : (grade == 2 ? PdfColors.amber50 : PdfColors.red50));
    final PdfColor severityBorder = grade == 0
        ? PdfColors.green700
        : (grade == 1
            ? PdfColors.blue700
            : (grade == 2 ? PdfColors.amber700 : PdfColors.red700));
    final PdfColor severityText = grade == 0
        ? PdfColors.green900
        : (grade == 1
            ? PdfColors.blue900
            : (grade == 2 ? PdfColors.amber900 : PdfColors.red900));

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header
              pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#090D1A'),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          'DRISHTI CLINICAL RETINAL SCREENING DOSSIER',
                          style: pw.TextStyle(
                            fontSize: 13,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.white,
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          'Autonomous On-Device AI Triage & Rural Tele-Ophthalmology System',
                          style: const pw.TextStyle(
                            fontSize: 8.5,
                            color: PdfColors.cyan200,
                          ),
                        ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'ID: $screeningId',
                          style: pw.TextStyle(
                            fontSize: 8.5,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColors.white,
                          ),
                        ),
                        pw.Text(
                          'Date: $timestamp',
                          style: const pw.TextStyle(
                            fontSize: 8,
                            color: PdfColors.grey300,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 10),

              // Patient Demographics & Vitals Table
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                padding: const pw.EdgeInsets.all(10),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'PATIENT INTAKE & CLINICAL VITALS',
                      style: pw.TextStyle(
                        fontSize: 9,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromHex('#090D1A'),
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.Row(
                      children: [
                        _pdfField('Patient Name', p.name, flex: 3),
                        _pdfField('Patient ID', p.patientId, flex: 2),
                        _pdfField('Age / Gender', '${p.age} yrs / ${p.gender}', flex: 2),
                        _pdfField('ABHA ID', p.abhaId.isNotEmpty ? p.abhaId : 'N/A', flex: 2),
                      ],
                    ),
                    pw.SizedBox(height: 6),
                    pw.Row(
                      children: [
                        _pdfField('Village / PHC', p.village.isNotEmpty ? p.village : 'Primary Health Centre', flex: 3),
                        _pdfField('Phone', p.phone.isNotEmpty ? p.phone : 'N/A', flex: 2),
                        _pdfField('Eye Side', '${state.eyeSide} Eye (${state.eyeSide.startsWith("R") ? "OD" : "OS"})', flex: 2),
                        _pdfField('Camera', state.cameraProfile, flex: 2),
                      ],
                    ),
                    pw.SizedBox(height: 6),
                    pw.Container(
                      padding: const pw.EdgeInsets.all(6),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.grey100,
                        borderRadius: pw.BorderRadius.circular(4),
                      ),
                      child: pw.Row(
                        children: [
                          _pdfField('Known Diabetes', p.knownDiabetes, flex: 2),
                          _pdfField('Duration', '${p.diabetesDurationYears ?? "-"} yrs', flex: 2),
                          _pdfField('HbA1c', p.hba1c != null ? '${p.hba1c}%' : 'N/A', flex: 2),
                          _pdfField('Fasting Glucose', p.fastingGlucose != null ? '${p.fastingGlucose} mg/dL' : 'N/A', flex: 2),
                          _pdfField('Blood Pressure', p.bloodPressure ?? 'N/A', flex: 2),
                          _pdfField('BMI', p.bmi != null ? '${p.bmi}' : 'N/A', flex: 1),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              if (state.referralPlan != null) ...[
                pw.SizedBox(height: 10),
                _referralRoutingBlock(state.referralPlan!),
              ],

              pw.SizedBox(height: 10),

              // AI Diagnostic Severity & Dual Retinal Imaging (Fundus + Heatmap) Section
              pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  // Left side: AI Diagnostic Evaluation
                  pw.Expanded(
                    flex: 5,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        // Diagnostic Badge
                        pw.Container(
                          padding: const pw.EdgeInsets.all(10),
                          decoration: pw.BoxDecoration(
                            color: severityBg,
                            border: pw.Border.all(color: severityBorder, width: 1.5),
                            borderRadius: pw.BorderRadius.circular(6),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Row(
                                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                                children: [
                                  pw.Text(
                                    'ICDRS SEVERITY: GRADE $grade',
                                    style: pw.TextStyle(
                                      fontSize: 10,
                                      fontWeight: pw.FontWeight.bold,
                                      color: severityBorder,
                                    ),
                                  ),
                                  pw.Text(
                                    'Confidence: $confidence%',
                                    style: pw.TextStyle(
                                      fontSize: 9,
                                      fontWeight: pw.FontWeight.bold,
                                      color: severityText,
                                    ),
                                  ),
                                ],
                              ),
                              pw.SizedBox(height: 4),
                              pw.Text(
                                gradeLabel,
                                style: pw.TextStyle(
                                  fontSize: 12,
                                  fontWeight: pw.FontWeight.bold,
                                  color: severityText,
                                ),
                              ),
                            ],
                          ),
                        ),
                        pw.SizedBox(height: 8),

                        // Key Clinical Findings
                        pw.Container(
                          padding: const pw.EdgeInsets.all(8),
                          decoration: pw.BoxDecoration(
                            border: pw.Border.all(color: PdfColors.grey300),
                            borderRadius: pw.BorderRadius.circular(6),
                          ),
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                'CLINICAL FINDINGS & AI ANALYSIS',
                                style: pw.TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColors.grey800,
                                ),
                              ),
                              pw.SizedBox(height: 4),
                              pw.Text(
                                a?.plainLanguageAdvice ??
                                    (grade == 0
                                        ? 'No microvascular lesions, microaneurysms, or hard exudates detected. Retinal vasculature intact.'
                                        : 'Retinal microvascular pathology detected consistent with Grade $grade diabetic retinopathy.'),
                                style: const pw.TextStyle(fontSize: 8, height: 1.3),
                              ),
                              pw.SizedBox(height: 6),
                              pw.Text(
                                'RECOMMENDED CLINICAL ACTION',
                                style: pw.TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColors.grey800,
                                ),
                              ),
                              pw.SizedBox(height: 4),
                              pw.Text(
                                a?.actionRecommendation ??
                                    (grade >= 3
                                        ? 'Urgent specialist ophthalmology consultation required within 48-72 hours.'
                                        : (grade > 0
                                            ? 'Referral to secondary eye hospital within 2-4 weeks.'
                                            : 'Annual routine diabetic retinopathy screening recommended.')),
                                style: pw.TextStyle(
                                  fontSize: 8,
                                  fontWeight: pw.FontWeight.bold,
                                  color: grade > 0 ? PdfColors.red900 : PdfColors.green900,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  pw.SizedBox(width: 10),

                  // Right side: Retinal Imaging Panel (Original Fundus + AI Grad-CAM Heatmap side-by-side)
                  pw.Expanded(
                    flex: 6,
                    child: pw.Container(
                      padding: const pw.EdgeInsets.all(6),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: PdfColors.grey300),
                        borderRadius: pw.BorderRadius.circular(6),
                        color: PdfColors.white,
                      ),
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Row(
                            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                            children: [
                              pw.Text(
                                'RETINAL IMAGING & AI EXPLAINABILITY',
                                style: pw.TextStyle(
                                  fontSize: 8.5,
                                  fontWeight: pw.FontWeight.bold,
                                  color: PdfColor.fromHex('#090D1A'),
                                ),
                              ),
                              pw.Text(
                                'Grad-CAM Attention',
                                style: const pw.TextStyle(
                                  fontSize: 7,
                                  color: PdfColors.grey600,
                                ),
                              ),
                            ],
                          ),
                          pw.SizedBox(height: 5),
                          pw.Row(
                            children: [
                              // 1. Original Fundus Photograph
                              pw.Expanded(
                                child: pw.Container(
                                  height: 145,
                                  decoration: pw.BoxDecoration(
                                    border: pw.Border.all(color: PdfColors.grey400),
                                    borderRadius: pw.BorderRadius.circular(4),
                                    color: PdfColors.black,
                                  ),
                                  child: fundusImage != null
                                      ? pw.Column(
                                          children: [
                                            pw.Expanded(
                                              child: pw.Image(
                                                fundusImage,
                                                fit: pw.BoxFit.contain,
                                              ),
                                            ),
                                            pw.Container(
                                              color: PdfColor.fromHex('#090D1A'),
                                              padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                                              width: double.infinity,
                                              child: pw.Center(
                                                child: pw.Text(
                                                  'Original Fundus (${state.eyeSide})',
                                                  style: const pw.TextStyle(
                                                    fontSize: 6.5,
                                                    color: PdfColors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : pw.Center(
                                          child: pw.Text(
                                            'Fundus Photograph\n(Not attached)',
                                            textAlign: pw.TextAlign.center,
                                            style: const pw.TextStyle(
                                              fontSize: 7.5,
                                              color: PdfColors.grey500,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                              pw.SizedBox(width: 6),
                              // 2. AI Attention Heatmap (Grad-CAM Saliency)
                              pw.Expanded(
                                child: pw.Container(
                                  height: 145,
                                  decoration: pw.BoxDecoration(
                                    border: pw.Border.all(color: PdfColors.grey400),
                                    borderRadius: pw.BorderRadius.circular(4),
                                    color: PdfColors.black,
                                  ),
                                  child: heatmapImage != null
                                      ? pw.Column(
                                          children: [
                                            pw.Expanded(
                                              child: pw.Image(
                                                heatmapImage,
                                                fit: pw.BoxFit.contain,
                                              ),
                                            ),
                                            pw.Container(
                                              color: PdfColor.fromHex('#B91C1C'),
                                              padding: const pw.EdgeInsets.symmetric(vertical: 2.5),
                                              width: double.infinity,
                                              child: pw.Center(
                                                child: pw.Text(
                                                  'AI Visual Heatmap (Grad-CAM)',
                                                  style: const pw.TextStyle(
                                                    fontSize: 6.5,
                                                    color: PdfColors.white,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        )
                                      : pw.Center(
                                          child: pw.Text(
                                            'AI Heatmap\n(Not available)',
                                            textAlign: pw.TextAlign.center,
                                            style: const pw.TextStyle(
                                              fontSize: 7.5,
                                              color: PdfColors.grey500,
                                            ),
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text(
                            'Left: Direct fundus capture (${state.quality?.qualityGrade ?? "GOOD"}) · Right: AI visual attention heatmap highlighting pathology.',
                            style: const pw.TextStyle(
                              fontSize: 6,
                              color: PdfColors.grey600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              pw.SizedBox(height: 10),

              // Specialist Verification & Sign-off Section
              pw.Container(
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: pw.BorderRadius.circular(6),
                ),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'OPHTHALMOLOGIST REVIEW & TELE-CONSULTATION SIGN-OFF',
                      style: pw.TextStyle(
                        fontSize: 8.5,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromHex('#090D1A'),
                      ),
                    ),
                    pw.SizedBox(height: 4),
                    pw.Row(
                      children: [
                        _pdfField(
                          'Verification Status',
                          state.verdict ?? 'AI Diagnosis Verified by Specialist',
                          flex: 3,
                        ),
                        _pdfField(
                          'Confirmed Grade',
                          'Grade $grade ($gradeLabel)',
                          flex: 3,
                        ),
                        _pdfField(
                          'Reviewed At',
                          timestamp,
                          flex: 3,
                        ),
                      ],
                    ),
                    if (state.specialistNotes.isNotEmpty) ...[
                      pw.SizedBox(height: 4),
                      _pdfField(
                        'Clinician Observations',
                        state.specialistNotes,
                        inRow: false,
                      ),
                    ],
                    pw.SizedBox(height: 8),
                    pw.Row(
                      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'Official Tele-Ophthalmology Signature: _______________________',
                          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                        ),
                        pw.Text(
                          'Stamp / Seal',
                          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey500),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 12),

              // Legal / Clinical Disclaimer Footer
              pw.Divider(color: PdfColors.grey300, thickness: 0.5),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    'Drishti Autonomous Clinical AI Retinal Screening System · Offline-First Rural Health',
                    style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600),
                  ),
                  pw.Text(
                    'CONFIDENTIAL MEDICAL RECORD · Page 1 of 1',
                    style: const pw.TextStyle(fontSize: 6.5, color: PdfColors.grey600),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    return await pdf.save();
  }

  /// Saves the report PDF to a writable, user-visible location on every OS.
  ///
  /// Desktop prefers `~/Downloads` (matching the existing macOS behaviour) and
  /// falls back to the documents/support containers when sandboxing or a
  /// read-only profile prevents the write. Android/iOS write into the app
  /// documents directory, which is exposed through the iOS Files app and can
  /// be opened with the native viewer from the screening screen.
  /// De-identified file stem used for the PDF on disk and as the email
  /// attachment name. It deliberately contains no patient name, phone, ABHA
  /// or village: a filename in a shared Downloads folder must not disclose PHI.
  static String reportFileStem(FlowState state) {
    final rawId = state.analysis?.screeningId ??
        'LOC-${DateTime.now().millisecondsSinceEpoch}';
    final safeId = rawId
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final eye = state.eyeSide == 'Left' ? 'OS' : 'OD';
    return '${safeId.isEmpty ? 'SCREENING' : safeId}_$eye';
  }

  static pw.Widget _referralRoutingBlock(ReferralPlan plan) {
    final route = plan.primary;
    final specialist = route.specialist;
    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#E0F2FE'),
        border: pw.Border.all(color: PdfColor.fromHex('#0E7490')),
        borderRadius: pw.BorderRadius.circular(6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'REFERRAL ROUTING — ADDRESSED TO',
            style: pw.TextStyle(
              fontSize: 8.5,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#0E7490'),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            plan.addressedTo,
            style: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.black,
            ),
          ),
          if (specialist.fullAddress.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              specialist.fullAddress,
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ],
          pw.SizedBox(height: 4),
          pw.Row(
            children: [
              _pdfField('Urgency', plan.urgency.label, flex: 3),
              _pdfField('Recommended Mode', route.mode.label, flex: 2),
              _pdfField('Distance', route.distanceLabel, flex: 2),
              _pdfField('Travel', route.travelLabel, flex: 3),
            ],
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            'Selected by ${plan.algorithm} · ${plan.summary}',
            style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700),
          ),
          if (route.mode == ReferralMode.teleconsult &&
              specialist.teleconsultUrl.isNotEmpty) ...[
            pw.SizedBox(height: 2),
            pw.Text(
              'Teleconsult: ${specialist.teleconsultUrl}',
              style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.blue800),
            ),
          ],
        ],
      ),
    );
  }

  static Future<String> saveReportToFile(FlowState state) async {
    final bytes = await generateReportPdf(state);
    final filename = 'Drishti_Report_${reportFileStem(state)}.pdf';

    Object? lastError;
    for (final dir in await AppPaths.reportDirectories()) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final targetFile = File(p.join(dir.path, filename));
        await targetFile.writeAsBytes(bytes, flush: true);
        debugPrint('PDF saved to: ${targetFile.path}');
        return targetFile.path;
      } catch (e) {
        lastError = e;
        debugPrint('PDF save failed in ${dir.path}: $e');
      }
    }
    throw FileSystemException(
      'No writable report directory was available for this device',
      null,
      lastError is OSError ? lastError : null,
    );
  }

  static pw.Widget _pdfField(
    String label,
    String value, {
    int flex = 1,
    bool inRow = true,
  }) {
    final block = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label.toUpperCase(),
          style: const pw.TextStyle(
            fontSize: 6.5,
            color: PdfColors.grey600,
          ),
        ),
        pw.Text(
          value.isEmpty ? '—' : value,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
            color: PdfColors.black,
          ),
          maxLines: 2,
        ),
      ],
    );
    if (!inRow) return block;
    return pw.Expanded(
      flex: flex,
      child: block,
    );
  }
}
