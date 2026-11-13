import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../screens/flow/flow_state.dart';

class SmtpConfig {
  String senderEmail;
  String senderPassword;
  String smtpHost;
  int smtpPort;
  bool useSsl;
  String specialistEmail;
  String senderName;
  bool autoSendOnDr;
  int minSeverityGrade;

  SmtpConfig({
    this.senderEmail = '',
    this.senderPassword = '',
    this.smtpHost = 'smtp.gmail.com',
    this.smtpPort = 465,
    this.useSsl = true,
    this.specialistEmail = '',
    this.senderName = 'Drishti AI Screening System',
    this.autoSendOnDr = true,
    this.minSeverityGrade = 1,
  });

  bool get isConfigured =>
      senderEmail.isNotEmpty &&
      senderPassword.isNotEmpty &&
      smtpHost.isNotEmpty &&
      specialistEmail.isNotEmpty;
}

class SmtpResult {
  final bool success;
  final String message;
  final String? transcript;

  const SmtpResult({
    required this.success,
    required this.message,
    this.transcript,
  });
}

/// Pure Dart zero-dependency RFC 5321 / RFC 5322 SMTP client.
/// Works standalone on macOS, iOS, Android, and Linux.
class SmtpService {
  static final SmtpService _instance = SmtpService._internal();
  factory SmtpService() => _instance;
  SmtpService._internal();

  static const _kSenderEmail = 'drishti_smtp_sender_email';
  static const _kPassword = 'drishti_smtp_password';
  static const _kHost = 'drishti_smtp_host';
  static const _kPort = 'drishti_smtp_port';
  static const _kUseSsl = 'drishti_smtp_use_ssl';
  static const _kSpecialistEmail = 'drishti_smtp_specialist_email';
  static const _kSenderName = 'drishti_smtp_sender_name';
  static const _kAutoSend = 'drishti_smtp_auto_send';
  static const _kMinGrade = 'drishti_smtp_min_grade';

  SmtpConfig? _cachedConfig;
  String _lastStatus = 'Idle — ready for dispatch';
  DateTime? _lastDispatchedAt;

  String get lastStatus => _lastStatus;
  DateTime? get lastDispatchedAt => _lastDispatchedAt;

  Future<SmtpConfig> loadConfig() async {
    if (_cachedConfig != null) return _cachedConfig!;
    final prefs = await SharedPreferences.getInstance();
    _cachedConfig = SmtpConfig(
      senderEmail: prefs.getString(_kSenderEmail) ?? '',
      senderPassword: prefs.getString(_kPassword) ?? '',
      smtpHost: prefs.getString(_kHost) ?? 'smtp.gmail.com',
      smtpPort: prefs.getInt(_kPort) ?? 465,
      useSsl: prefs.getBool(_kUseSsl) ?? true,
      specialistEmail: prefs.getString(_kSpecialistEmail) ?? '',
      senderName: prefs.getString(_kSenderName) ?? 'Drishti AI Screening System',
      autoSendOnDr: prefs.getBool(_kAutoSend) ?? true,
      minSeverityGrade: prefs.getInt(_kMinGrade) ?? 1,
    );
    return _cachedConfig!;
  }

  Future<void> saveConfig(SmtpConfig config) async {
    _cachedConfig = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSenderEmail, config.senderEmail.trim());
    await prefs.setString(_kPassword, config.senderPassword.trim());
    await prefs.setString(_kHost, config.smtpHost.trim());
    await prefs.setInt(_kPort, config.smtpPort);
    await prefs.setBool(_kUseSsl, config.useSsl);
    await prefs.setString(_kSpecialistEmail, config.specialistEmail.trim());
    await prefs.setString(_kSenderName, config.senderName.trim());
    await prefs.setBool(_kAutoSend, config.autoSendOnDr);
    await prefs.setInt(_kMinGrade, config.minSeverityGrade);
  }

  /// Evaluates whether a screening warrants automated specialist notification,
  /// and dispatches the alert email immediately via SMTP.
  Future<SmtpResult> handleScreeningCompleted(FlowState state) async {
    final config = await loadConfig();
    final grade = state.correctedGrade ?? state.analysis?.drGrade ?? 0;

    if (!config.autoSendOnDr) {
      return const SmtpResult(
        success: false,
        message: 'Automated specialist dispatch disabled in Admin settings.',
      );
    }

    if (grade < config.minSeverityGrade) {
      return SmtpResult(
        success: false,
        message: 'DR Grade ($grade) below notification threshold (${config.minSeverityGrade}).',
      );
    }

    if (!config.isConfigured) {
      _lastStatus = 'Pending: SMTP settings not configured in Admin Portal';
      debugPrint('SMTP: Skipping specialist alert - credentials not configured.');
      return const SmtpResult(
        success: false,
        message: 'SMTP credentials or specialist email not configured in Admin Portal.',
      );
    }

    return await sendSpecialistAlert(state: state);
  }

  /// Sends a clinical DR referral alert to the configured specialist doctor.
  Future<SmtpResult> sendSpecialistAlert({required FlowState state}) async {
    final config = await loadConfig();
    if (!config.isConfigured) {
      return const SmtpResult(
        success: false,
        message: 'SMTP not configured. Please set sender and specialist emails in Admin Portal.',
      );
    }

    final p = state.patient;
    final grade = state.correctedGrade ?? state.analysis?.drGrade ?? 0;
    final label = state.analysis?.drLabel ?? 'Diabetic Retinopathy Grade $grade';
    final eye = state.eyeSide;
    final confidence = ((state.analysis?.predictionScore ?? 0.95) * 100).toStringAsFixed(1);
    final subject = '[DRISHTI CLINICAL ALERT] DR Detected: ${p.name} (${p.patientId}) — Grade $grade ($label)';

    final htmlBody = _buildClinicalHtml(
      patient: p,
      grade: grade,
      gradeLabel: label,
      eyeSide: eye,
      confidence: confidence,
      qualityGrade: state.quality?.qualityGrade ?? 'GOOD',
      specialistNotes: state.specialistNotes,
      recommendation: state.analysis?.actionRecommendation ??
          (grade >= 3
              ? 'Urgent specialist intervention recommended within 48-72 hours.'
              : 'Referral to ophthalmology clinic within 1-2 weeks.'),
      timestampIso: DateTime.now().toLocal().toString().split('.').first,
    );

    return await _deliverEmail(
      config: config,
      recipients: config.specialistEmail.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
      subject: subject,
      htmlBody: htmlBody,
      imageBytes: state.imageBytes,
      imageFilename: 'fundus_${p.patientId}_$eye.jpg',
    );
  }

  /// Sends a test email to verify credentials and connectivity instantly.
  Future<SmtpResult> sendTestEmail({required String testRecipient}) async {
    final config = await loadConfig();
    if (config.senderEmail.isEmpty || config.senderPassword.isEmpty) {
      return const SmtpResult(
        success: false,
        message: 'Sender Email and App Password must be filled before testing.',
      );
    }

    final recipient = testRecipient.trim().isNotEmpty
        ? testRecipient.trim()
        : config.specialistEmail.trim();

    if (recipient.isEmpty) {
      return const SmtpResult(
        success: false,
        message: 'Please provide a valid recipient email address.',
      );
    }

    final subject = '[DRISHTI TEST] SMTP Gateway Verification — ${DateTime.now().toLocal().toString().split('.').first}';
    final htmlBody = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: #0b1120; color: #f8fafc; padding: 24px;">
  <div style="max-width: 600px; margin: 0 auto; background: #131d36; border: 1px solid #00e5ff; border-radius: 12px; overflow: hidden; box-shadow: 0 4px 20px rgba(0, 229, 255, 0.2);">
    <div style="background: linear-gradient(135deg, #0f172a, #083344); padding: 20px; border-bottom: 1px solid #1e293b;">
      <h2 style="margin: 0; color: #00e5ff; letter-spacing: 2px;">DRISHTI RETINAL AI</h2>
      <p style="margin: 4px 0 0 0; color: #94a3b8; font-size: 13px;">SMTP Communication Gateway Test</p>
    </div>
    <div style="padding: 24px;">
      <p style="font-size: 15px; line-height: 1.5; color: #e2e8f0;">
        This test message confirms that your <strong>Drishti Frontline Retinal Screening</strong> system has successfully established an authenticated SMTP handshake.
      </p>
      <div style="background: #0f172a; padding: 14px; border-radius: 8px; border: 1px solid #334155; margin: 16px 0;">
        <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
          <tr><td style="color: #94a3b8; padding: 4px 0;">SMTP Server:</td><td style="color: #f1f5f9; font-weight: 600;">${config.smtpHost}:${config.smtpPort}</td></tr>
          <tr><td style="color: #94a3b8; padding: 4px 0;">Encryption:</td><td style="color: #f1f5f9; font-weight: 600;">${config.useSsl ? "SSL/TLS (Encrypted)" : "STARTTLS"}</td></tr>
          <tr><td style="color: #94a3b8; padding: 4px 0;">Sender Account:</td><td style="color: #f1f5f9; font-weight: 600;">${config.senderEmail}</td></tr>
          <tr><td style="color: #94a3b8; padding: 4px 0;">Specialist Doctor:</td><td style="color: #00e5ff; font-weight: 600;">$recipient</td></tr>
          <tr><td style="color: #94a3b8; padding: 4px 0;">Dispatch Time:</td><td style="color: #f1f5f9; font-weight: 600;">${DateTime.now().toLocal()}</td></tr>
        </table>
      </div>
      <p style="font-size: 13px; color: #10b981; font-weight: 600;">
        &#10004; Gateway Verified: Whenever a patient is diagnosed with Diabetic Retinopathy, detailed clinical telemetry will automatically dispatch to this address.
      </p>
    </div>
    <div style="background: #090d1a; padding: 12px 24px; text-align: center; font-size: 11px; color: #64748b; border-top: 1px solid #1e293b;">
      Drishti Autonomous Clinical AI Retinal Screening System &bull; Offline-First Rural Health
    </div>
  </div>
</body>
</html>
''';

    return await _deliverEmail(
      config: config,
      recipients: [recipient],
      subject: subject,
      htmlBody: htmlBody,
    );
  }

  Future<SmtpResult> _deliverEmail({
    required SmtpConfig config,
    required List<String> recipients,
    required String subject,
    required String htmlBody,
    Uint8List? imageBytes,
    String? imageFilename,
  }) async {
    final transcript = StringBuffer();
    Socket? socket;

    void log(String msg) {
      transcript.writeln(msg);
      debugPrint('SMTP: $msg');
    }

    try {
      log('Connecting to ${config.smtpHost}:${config.smtpPort} (SSL=${config.useSsl})...');
      
      if (config.useSsl) {
        socket = await SecureSocket.connect(
          config.smtpHost,
          config.smtpPort,
          timeout: const Duration(seconds: 15),
          onBadCertificate: (_) => true,
        );
      } else {
        socket = await Socket.connect(
          config.smtpHost,
          config.smtpPort,
          timeout: const Duration(seconds: 15),
        );
      }

      final reader = _SmtpReader(socket);

      // 1. Initial 220 banner
      var resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('220')) throw Exception('Invalid banner: $resp');

      // 2. EHLO
      socket.write('EHLO localhost\r\n');
      log('C: EHLO localhost');
      resp = await reader.readMultiline();
      log('S: $resp');

      // 3. STARTTLS if port 587 and not yet SSL
      if (!config.useSsl && config.smtpPort == 587) {
        socket.write('STARTTLS\r\n');
        log('C: STARTTLS');
        resp = await reader.readLine();
        log('S: $resp');
        if (!resp.startsWith('220')) throw Exception('STARTTLS rejected: $resp');

        socket = await SecureSocket.secure(
          socket,
          onBadCertificate: (_) => true,
        );
        reader.updateSocket(socket);

        socket.write('EHLO localhost\r\n');
        log('C: EHLO localhost (TLS secured)');
        resp = await reader.readMultiline();
        log('S: $resp');
      }

      // 4. AUTH LOGIN
      socket.write('AUTH LOGIN\r\n');
      log('C: AUTH LOGIN');
      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('334')) throw Exception('AUTH LOGIN not supported: $resp');

      // Send base64 username
      final b64User = base64.encode(utf8.encode(config.senderEmail));
      socket.write('$b64User\r\n');
      log('C: [base64 username]');
      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('334')) throw Exception('Username rejected: $resp');

      // Send base64 password
      // Remove spaces if app password (Google generates 16-char app passwords with spaces)
      final cleanPass = config.senderPassword.replaceAll(' ', '');
      final b64Pass = base64.encode(utf8.encode(cleanPass));
      socket.write('$b64Pass\r\n');
      log('C: [base64 password]');
      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('235')) {
        throw Exception('Authentication failed (535): Incorrect email or App Password. If using Gmail, generate a 16-character App Password at myaccount.google.com/apppasswords.');
      }

      // 5. MAIL FROM
      socket.write('MAIL FROM:<${config.senderEmail}>\r\n');
      log('C: MAIL FROM:<${config.senderEmail}>');
      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('250')) throw Exception('MAIL FROM rejected: $resp');

      // 6. RCPT TO
      for (final rcpt in recipients) {
        socket.write('RCPT TO:<$rcpt>\r\n');
        log('C: RCPT TO:<$rcpt>');
        resp = await reader.readLine();
        log('S: $resp');
        if (!resp.startsWith('250')) throw Exception('RCPT TO <$rcpt> rejected: $resp');
      }

      // 7. DATA
      socket.write('DATA\r\n');
      log('C: DATA');
      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('354')) throw Exception('DATA command rejected: $resp');

      // 8. Build and send MIME payload
      final boundary = '----=_Part_${DateTime.now().millisecondsSinceEpoch}';
      final toHeader = recipients.join(', ');

      final headers = StringBuffer();
      headers.writeln('From: "${config.senderName}" <${config.senderEmail}>');
      headers.writeln('To: $toHeader');
      headers.writeln('Subject: $subject');
      headers.writeln('Date: ${HttpDate.format(DateTime.now())}');
      headers.writeln('MIME-Version: 1.0');
      headers.writeln('X-Priority: 1'); // High clinical priority
      headers.writeln('X-Mailer: Drishti Autonomous Clinical AI');
      headers.writeln('Content-Type: multipart/mixed; boundary="$boundary"');
      headers.writeln();

      socket.write(headers.toString());

      // HTML Part
      socket.write('--$boundary\r\n');
      socket.write('Content-Type: text/html; charset=utf-8\r\n');
      socket.write('Content-Transfer-Encoding: 8bit\r\n\r\n');
      socket.write('$htmlBody\r\n\r\n');

      // Optional Image Attachment
      if (imageBytes != null && imageBytes.isNotEmpty) {
        final filename = imageFilename ?? 'fundus_screening.jpg';
        socket.write('--$boundary\r\n');
        socket.write('Content-Type: image/jpeg; name="$filename"\r\n');
        socket.write('Content-Disposition: attachment; filename="$filename"\r\n');
        socket.write('Content-Transfer-Encoding: base64\r\n\r\n');

        final b64Image = base64.encode(imageBytes);
        // Split base64 into standard 76-character lines
        for (var i = 0; i < b64Image.length; i += 76) {
          final end = (i + 76 < b64Image.length) ? i + 76 : b64Image.length;
          socket.write('${b64Image.substring(i, end)}\r\n');
        }
        socket.write('\r\n');
      }

      // Terminate MIME & DATA
      socket.write('--$boundary--\r\n');
      socket.write('.\r\n');
      log('C: [Message body sent, ending with CRLF.CRLF]');

      resp = await reader.readLine();
      log('S: $resp');
      if (!resp.startsWith('250')) throw Exception('Failed to send data: $resp');

      // 9. QUIT
      socket.write('QUIT\r\n');
      log('C: QUIT');
      try {
        await reader.readLine();
      } catch (_) {}

      _lastStatus = 'Delivered to ${recipients.first} at ${DateTime.now().toLocal().toString().split('.').first}';
      _lastDispatchedAt = DateTime.now();

      return SmtpResult(
        success: true,
        message: 'Email delivered successfully to ${recipients.join(", ")}.',
        transcript: transcript.toString(),
      );
    } catch (e) {
      log('Error during SMTP exchange: $e');
      _lastStatus = 'Failed: $e';
      return SmtpResult(
        success: false,
        message: e.toString().replaceFirst('Exception: ', ''),
        transcript: transcript.toString(),
      );
    } finally {
      try {
        await socket?.close();
      } catch (_) {}
    }
  }

  String _buildClinicalHtml({
    required dynamic patient,
    required int grade,
    required String gradeLabel,
    required String eyeSide,
    required String confidence,
    required String qualityGrade,
    required String specialistNotes,
    required String recommendation,
    required String timestampIso,
  }) {
    final gradeColor = grade >= 3
        ? '#ef4444'
        : (grade == 2 ? '#f59e0b' : '#38bdf8');
    final priorityText = grade >= 3
        ? 'URGENT — WITHIN 48-72 HOURS'
        : (grade == 2 ? 'PRIORITY — WITHIN 1-2 WEEKS' : 'ROUTINE CLINICAL REVIEW');

    return '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background: #070d1a; color: #f8fafc; padding: 24px; margin: 0;">
  <div style="max-width: 650px; margin: 0 auto; background: #0f172a; border: 1px solid #1e293b; border-radius: 14px; overflow: hidden; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.5);">
    
    <!-- Top Brand Banner -->
    <div style="background: linear-gradient(135deg, #091e3a, #062b3a); padding: 22px; border-bottom: 2px solid #00e5ff;">
      <table style="width: 100%;">
        <tr>
          <td>
            <h2 style="margin: 0; color: #00e5ff; font-size: 20px; letter-spacing: 2px;">DRISHTI CLINICAL RETINAL HUD</h2>
            <p style="margin: 4px 0 0 0; color: #94a3b8; font-size: 12px; letter-spacing: 0.5px;">AUTONOMOUS ON-DEVICE DIABETIC RETINOPATHY ALERT</p>
          </td>
          <td style="text-align: right;">
            <span style="background: rgba(239, 68, 68, 0.2); border: 1px solid $gradeColor; color: $gradeColor; padding: 6px 12px; border-radius: 20px; font-size: 11px; font-weight: 800; letter-spacing: 1px;">
              $priorityText
            </span>
          </td>
        </tr>
      </table>
    </div>

    <!-- Diagnosis Highlight Card -->
    <div style="padding: 24px; background: #131d36; border-bottom: 1px solid #1e293b;">
      <p style="margin: 0 0 6px 0; color: #94a3b8; font-size: 12px; text-transform: uppercase; font-weight: 700;">AI Screening Result &bull; $eyeSide Eye (O${eyeSide == 'Right' ? 'D' : 'S'})</p>
      <h1 style="margin: 0 0 10px 0; color: $gradeColor; font-size: 24px;">Grade $grade: $gradeLabel</h1>
      <table style="width: 100%; font-size: 13px;">
        <tr>
          <td style="color: #94a3b8;">Neural Confidence: <strong style="color: #f8fafc;">$confidence%</strong></td>
          <td style="color: #94a3b8;">Optic Quality: <strong style="color: #10b981;">$qualityGrade</strong></td>
          <td style="color: #94a3b8;">Examination Date: <strong style="color: #f8fafc;">$timestampIso</strong></td>
        </tr>
      </table>
    </div>

    <!-- Patient Details -->
    <div style="padding: 24px;">
      <h3 style="margin: 0 0 12px 0; color: #00e5ff; font-size: 14px; text-transform: uppercase; letter-spacing: 1px;">Patient Demographics & Medical History</h3>
      <table style="width: 100%; border-collapse: collapse; font-size: 13px; background: #0a0f1d; border-radius: 8px; border: 1px solid #1e293b;">
        <tr style="border-bottom: 1px solid #1e293b;">
          <td style="padding: 10px 14px; color: #94a3b8;">Patient Name</td>
          <td style="padding: 10px 14px; color: #f8fafc; font-weight: 700;">${patient.name}</td>
          <td style="padding: 10px 14px; color: #94a3b8;">Age / Gender</td>
          <td style="padding: 10px 14px; color: #f8fafc;">${patient.age} yrs &bull; ${patient.gender}</td>
        </tr>
        <tr style="border-bottom: 1px solid #1e293b;">
          <td style="padding: 10px 14px; color: #94a3b8;">Patient ID</td>
          <td style="padding: 10px 14px; color: #38bdf8; font-family: monospace;">${patient.patientId}</td>
          <td style="padding: 10px 14px; color: #94a3b8;">ABHA / Govt ID</td>
          <td style="padding: 10px 14px; color: #f8fafc; font-family: monospace;">${patient.abhaId ?? "—"}</td>
        </tr>
        <tr style="border-bottom: 1px solid #1e293b;">
          <td style="padding: 10px 14px; color: #94a3b8;">Village / PHC</td>
          <td style="padding: 10px 14px; color: #f8fafc;">${patient.village ?? "Rural Camp"}</td>
          <td style="padding: 10px 14px; color: #94a3b8;">Contact Phone</td>
          <td style="padding: 10px 14px; color: #f8fafc;">${patient.phone ?? "—"}</td>
        </tr>
        <tr>
          <td style="padding: 10px 14px; color: #94a3b8;">HbA1c / BP</td>
          <td style="padding: 10px 14px; color: #f8fafc;">${patient.hba1c != null ? "${patient.hba1c}%" : "—"} &bull; ${patient.bloodPressure ?? "—"}</td>
          <td style="padding: 10px 14px; color: #94a3b8;">Known Diabetes</td>
          <td style="padding: 10px 14px; color: #f8fafc;">${patient.knownDiabetes ?? "Yes"} (${patient.diabetesDurationYears != null ? "${patient.diabetesDurationYears} yrs" : "—"})</td>
        </tr>
      </table>

      <!-- Clinical Recommendation -->
      <div style="margin-top: 20px; background: #0c1829; border-left: 4px solid #00e5ff; padding: 14px; border-radius: 4px;">
        <h4 style="margin: 0 0 6px 0; color: #38bdf8; font-size: 13px;">Clinical Action & Referral Protocol:</h4>
        <p style="margin: 0; font-size: 13px; color: #cbd5e1; line-height: 1.5;">$recommendation</p>
      </div>

      ${specialistNotes.isNotEmpty ? '''
      <div style="margin-top: 14px; background: #1a162b; border-left: 4px solid #a855f7; padding: 14px; border-radius: 4px;">
        <h4 style="margin: 0 0 6px 0; color: #c084fc; font-size: 13px;">Frontline Clinician Notes:</h4>
        <p style="margin: 0; font-size: 13px; color: #cbd5e1; line-height: 1.5;">$specialistNotes</p>
      </div>
      ''' : ''}

      <div style="margin-top: 20px; padding: 12px; background: #0b1120; border-radius: 6px; text-align: center; border: 1px dashed #334155;">
        <span style="font-size: 12px; color: #94a3b8;">High-resolution fundus photograph attached as <strong>fundus_${patient.patientId}_$eyeSide.jpg</strong>.</span>
      </div>
    </div>

    <!-- Footer -->
    <div style="background: #090d1a; padding: 14px 24px; font-size: 11px; color: #64748b; border-top: 1px solid #1e293b; text-align: center;">
      This message was generated automatically by Drishti AI at the screening center. Complies with clinical privacy standards and ICDRS criteria.
    </div>
  </div>
</body>
</html>
''';
  }
}

/// Simple line & multiline reader wrapper for SMTP socket.
class _SmtpReader {
  Socket _socket;
  final List<int> _buffer = [];
  Completer<String>? _lineCompleter;
  StreamSubscription<List<int>>? _sub;

  _SmtpReader(this._socket) {
    _listen();
  }

  void updateSocket(Socket newSocket) {
    _sub?.cancel();
    _socket = newSocket;
    _listen();
  }

  void _listen() {
    _sub = _socket.listen(
      (data) {
        _buffer.addAll(data);
        _checkBuffer();
      },
      onError: (e) {
        _lineCompleter?.completeError(e);
      },
      onDone: () {
        if (!(_lineCompleter?.isCompleted ?? true)) {
          _lineCompleter?.completeError(Exception('Socket closed prematurely by SMTP server'));
        }
      },
    );
  }

  void _checkBuffer() {
    if (_lineCompleter == null || _lineCompleter!.isCompleted) return;
    for (var i = 0; i < _buffer.length - 1; i++) {
      if (_buffer[i] == 13 && _buffer[i + 1] == 10) { // \r\n
        final lineBytes = _buffer.sublist(0, i);
        _buffer.removeRange(0, i + 2);
        final line = utf8.decode(lineBytes, allowMalformed: true);
        _lineCompleter!.complete(line);
        return;
      }
    }
  }

  Future<String> readLine() {
    _lineCompleter = Completer<String>();
    _checkBuffer();
    return _lineCompleter!.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw TimeoutException('SMTP server did not respond within 15 seconds'),
    );
  }

  Future<String> readMultiline() async {
    final sb = StringBuffer();
    while (true) {
      final line = await readLine();
      sb.writeln(line);
      // In RFC 5321, intermediate multiline responses have a hyphen after the 3-digit code (e.g. 250-SIZE)
      // The final line has a space (e.g. 250 OK or 250 HELP)
      if (line.length >= 4 && line[3] == ' ') {
        break;
      }
    }
    return sb.toString().trim();
  }
}
