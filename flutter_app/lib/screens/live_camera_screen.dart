import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/lang_scope.dart';
import '../services/platform/platform_files.dart';
import '../theme/figma_theme.dart';
import '../widgets/scanner/scanner_theme.dart';

/// A desktop video source resolved for `ffmpeg`.
///
/// Linux uses V4L2 (`/dev/video*`), macOS uses AVFoundation device indexes,
/// and Windows uses a DirectShow device name. Keeping the prefix/device split
/// lets each platform receive the correct input-option ordering.
class _DesktopVideoSource {
  const _DesktopVideoSource({
    required this.label,
    required this.formatArgs,
    required this.device,
  });

  final String label;
  final List<String> formatArgs;
  final String device;

  List<String> inputArgs(String size) => [
        ...formatArgs,
        '-video_size',
        size,
        '-i',
        device,
      ];
}

/// Live fundus capture with cross-platform support.
///
/// On mobile (Android / iOS): uses CameraController and CameraPreview.
/// On desktop (Linux / V4L2): captures live frames from the device webcam via ffmpeg pipe.
/// Provides tap-to-capture, centering retinal viewfinder HUD, and file fallback.
class LiveFundusCameraScreen extends StatefulWidget {
  const LiveFundusCameraScreen({super.key});

  @override
  State<LiveFundusCameraScreen> createState() => _LiveFundusCameraScreenState();
}

class _LiveFundusCameraScreenState extends State<LiveFundusCameraScreen> {
  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  int _lens = 0;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  // Desktop webcam streaming (Linux V4L2 / macOS AVFoundation / Windows DirectShow)
  bool _isDesktop = false;
  _DesktopVideoSource? _desktopSource;
  Uint8List? _desktopFrameBytes;
  Timer? _desktopStreamTimer;
  Timer? _desktopStartupTimer;
  bool _isFetchingDesktopFrame = false;
  bool? _ffmpegAvailableCache;

  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;
  double _pinchStartZoom = 1.0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _desktopStreamTimer?.cancel();
    _desktopStartupTimer?.cancel();
    setState(() {
      _initializing = true;
      _error = null;
      _zoom = 1.0;
      _minZoom = 1.0;
      _maxZoom = 1.0;
      _isDesktop = false;
      _desktopSource = null;
      _desktopFrameBytes = null;
    });

    // 1. On Linux, prefer a directly attached V4L2 device. The `camera`
    //    plugin has no Linux implementation, so probing it first only adds a
    //    noisy MissingPluginException to the log.
    if (Platform.isLinux) {
      final source = await _resolveDesktopSource();
      if (source != null) {
        await _startDesktopCamera(source);
        return;
      }
    }

    // 2. Native camera plugin (Android/iOS, plus platforms that add an
    //    implementation such as Windows/macOS community packages).
    try {
      final cameras = await availableCameras();
      if (cameras.isNotEmpty) {
        _cameras = cameras;
        // Prefer the back camera for fundus capture.
        _lens = cameras.indexWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
        );
        if (_lens < 0) _lens = 0;
        await _open(_cameras[_lens]);
        return;
      }
    } catch (e) {
      debugPrint('Standard camera initialization error: $e');
    }

    // 3. Desktop fallback: ffmpeg capture for V4L2 / AVFoundation / DirectShow.
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final source = await _resolveDesktopSource();
      if (source != null) {
        await _startDesktopCamera(source);
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _initializing = false;
      _error = Platform.isMacOS || Platform.isWindows || Platform.isLinux
          ? 'No camera was detected. Install ffmpeg for live desktop capture, '
              'or choose Upload Photo to analyse an existing fundus image.'
          : 'No camera available on this device.';
    });
  }

  String? _detectLinuxVideoDevice() {
    for (int i = 0; i < 4; i++) {
      final path = '/dev/video$i';
      if (File(path).existsSync()) {
        return path;
      }
    }
    return null;
  }

  Future<bool> _ffmpegAvailable() async {
    if (_ffmpegAvailableCache != null) return _ffmpegAvailableCache!;
    try {
      final result = await Process.run('ffmpeg', ['-version']);
      _ffmpegAvailableCache = result.exitCode == 0;
    } catch (_) {
      _ffmpegAvailableCache = false;
    }
    return _ffmpegAvailableCache!;
  }

  /// Resolves the best available desktop capture source for this OS.
  Future<_DesktopVideoSource?> _resolveDesktopSource() async {
    if (!await _ffmpegAvailable()) return null;

    if (Platform.isLinux) {
      final device = _detectLinuxVideoDevice();
      if (device == null) return null;
      return _DesktopVideoSource(
        label: device,
        formatArgs: const ['-f', 'v4l2'],
        device: device,
      );
    }

    if (Platform.isMacOS) {
      final index = await _firstAvFoundationVideoIndex();
      return _DesktopVideoSource(
        label: 'AVFoundation camera $index',
        formatArgs: const ['-f', 'avfoundation', '-framerate', '30'],
        device: index,
      );
    }

    if (Platform.isWindows) {
      final device = await _firstDirectShowVideoDevice();
      if (device == null) return null;
      return _DesktopVideoSource(
        label: device,
        formatArgs: const ['-f', 'dshow'],
        device: 'video=$device',
      );
    }

    return null;
  }

  Future<String> _firstAvFoundationVideoIndex() async {
    try {
      final result = await Process.run(
        'ffmpeg',
        ['-f', 'avfoundation', '-list_devices', 'true', '-i', ''],
      );
      final output = '${result.stderr}';
      var inVideoSection = false;
      final pattern = RegExp(r'\[(\d+)\]\s+(.+)$');
      for (final line in output.split('\n')) {
        if (line.contains('AVFoundation video devices')) {
          inVideoSection = true;
          continue;
        }
        if (line.contains('AVFoundation audio devices')) {
          inVideoSection = false;
          continue;
        }
        if (!inVideoSection) continue;
        final match = pattern.firstMatch(line.trim());
        if (match != null) return match.group(1)!;
      }
    } catch (e) {
      debugPrint('AVFoundation device probe failed: $e');
    }
    return '0'; // ffmpeg's default device index
  }

  Future<String?> _firstDirectShowVideoDevice() async {
    try {
      final result = await Process.run(
        'ffmpeg',
        ['-list_devices', 'true', '-f', 'dshow', '-i', 'dummy'],
      );
      final output = '${result.stderr}';
      final match = RegExp(r'"([^"]+)"\s*\(video\)').firstMatch(output);
      if (match != null) return match.group(1);
    } catch (e) {
      debugPrint('DirectShow device probe failed: $e');
    }
    return null;
  }

  Future<void> _startDesktopCamera(_DesktopVideoSource source) async {
    _desktopSource = source;
    _isDesktop = true;
    _initializing = false;
    if (mounted) setState(() {});

    await _fetchDesktopFrame();

    _desktopStreamTimer?.cancel();
    _desktopStreamTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _fetchDesktopFrame(),
    );

    // Never leave the operator on an endless spinner when ffmpeg cannot open
    // the device (permission denied, camera busy, wrong device name).
    _desktopStartupTimer?.cancel();
    _desktopStartupTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || _desktopFrameBytes != null) return;
      _desktopStreamTimer?.cancel();
      setState(() {
        _isDesktop = false;
        _desktopSource = null;
        _initializing = false;
        _error =
            'Could not read frames from ${source.label}. Check the camera '
            'permission and use Upload Photo as a fallback.';
      });
    });
  }

  Future<Uint8List?> _grabDesktopFrame(String size) async {
    final source = _desktopSource;
    if (source == null) return null;
    try {
      final res = await Process.run(
        'ffmpeg',
        [
          ...source.inputArgs(size),
          '-vframes', '1',
          '-f', 'image2',
          '-vcodec', 'mjpeg',
          'pipe:1',
        ],
        stdoutEncoding: null,
      );
      if (res.exitCode == 0 && res.stdout is List<int>) {
        final bytes = Uint8List.fromList(res.stdout as List<int>);
        return bytes.isEmpty ? null : bytes;
      }
      debugPrint('ffmpeg frame grab exited ${res.exitCode}: ${res.stderr}');
    } catch (e) {
      debugPrint('Desktop frame grab error: $e');
    }
    return null;
  }

  Future<void> _fetchDesktopFrame() async {
    if (_isFetchingDesktopFrame || !mounted || !_isDesktop) return;
    _isFetchingDesktopFrame = true;
    try {
      final bytes = await _grabDesktopFrame('640x480');
      if (bytes != null && mounted) {
        setState(() {
          _desktopFrameBytes = bytes;
          _error = null;
        });
      }
    } finally {
      _isFetchingDesktopFrame = false;
    }
  }

  Future<void> _open(CameraDescription description) async {
    final previous = _controller;
    final controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;
    await controller.initialize();
    if (!mounted) {
      await controller.dispose();
      return;
    }

    double minZoom = 1.0;
    double maxZoom = 1.0;
    try {
      minZoom = await controller.getMinZoomLevel();
      maxZoom = await controller.getMaxZoomLevel();
    } on CameraException {
      // Zoom is optional hardware capability; preview still works without it.
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    if (minZoom <= 0 || !minZoom.isFinite) minZoom = 1.0;
    if (maxZoom < minZoom || !maxZoom.isFinite) maxZoom = minZoom;

    unawaited(previous?.dispose());
    setState(() {
      _initializing = false;
      _minZoom = minZoom;
      _maxZoom = maxZoom;
      _zoom = minZoom;
    });
  }

  Future<void> _switchLens() async {
    if (_cameras.length < 2) return;
    setState(() {
      _initializing = true;
      _zoom = 1.0;
      _minZoom = 1.0;
      _maxZoom = 1.0;
    });
    _lens = (_lens + 1) % _cameras.length;
    await _open(_cameras[_lens]);
  }

  Future<void> _setZoom(double value) async {
    final controller = _controller;
    if (controller == null ||
        !controller.value.isInitialized ||
        _maxZoom <= _minZoom) {
      return;
    }
    final next = value.clamp(_minZoom, _maxZoom).toDouble();
    if ((next - _zoom).abs() < 0.01) return;
    setState(() => _zoom = next);
    try {
      await controller.setZoomLevel(next);
    } on CameraException {
      // Keep the last requested indicator; unsupported values are ignored.
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    _pinchStartZoom = _zoom;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    unawaited(_setZoom(_pinchStartZoom * details.scale));
  }

  void _toggleZoom() {
    if (_maxZoom <= _minZoom) return;
    unawaited(HapticFeedback.selectionClick());
    if (_zoom > _minZoom + 0.05) {
      unawaited(_setZoom(_minZoom));
    } else {
      unawaited(_setZoom(math.min(_maxZoom, math.max(2.0, _minZoom))));
    }
  }

  Future<void> _capture() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      if (_isDesktop) {
        if (_desktopFrameBytes != null && _desktopFrameBytes!.isNotEmpty) {
          if (!mounted) return;
          Navigator.pop(context, _desktopFrameBytes);
          return;
        }
        // Force an immediate higher-resolution snapshot if no buffered frame.
        final bytes = await _grabDesktopFrame('1280x720');
        if (bytes != null && mounted) {
          Navigator.pop(context, bytes);
          return;
        }
      }

      final controller = _controller;
      if (controller == null) return;
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      Navigator.pop(context, bytes);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Capture failed: $e'),
          backgroundColor: FigmaColors.danger,
        ),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _pickFallbackFile() async {
    try {
      final result = await PlatformFileService.pickFundusImage(
        dialogTitle: 'Select a fundus photo',
      );
      if (result.cancelled) return;
      final bytes = result.bytes;
      if (bytes != null && bytes.isNotEmpty && mounted) {
        Navigator.pop(context, bytes);
      }
    } catch (e) {
      debugPrint('Fallback file pick failed: $e');
    }
  }

  @override
  void dispose() {
    _desktopStreamTimer?.cancel();
    _desktopStartupTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = _isDesktop || (controller != null && controller.value.isInitialized);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          context.tr('capture_title'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (!_isDesktop && _cameras.length > 1)
            IconButton(
              tooltip: 'Switch camera',
              onPressed: _initializing ? null : _switchLens,
              icon: const Icon(Icons.cameraswitch_outlined),
            ),
        ],
      ),
      body: Center(child: _buildBody(ready, controller)),
    );
  }

  Widget _buildBody(bool ready, CameraController? controller) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              color: FigmaColors.danger,
              size: 42,
            ),
            const SizedBox(height: 10),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _start,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _pickFallbackFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Upload Photo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ScannerHUDTheme.neonCyan,
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (_isDesktop) {
      final hasFrame = _desktopFrameBytes != null && _desktopFrameBytes!.isNotEmpty;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (hasFrame)
            Center(
              child: Image.memory(
                _desktopFrameBytes!,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            )
          else
            const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: ScannerHUDTheme.neonCyan),
                  SizedBox(height: 12),
                  Text(
                    'Initializing Live Camera…',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ),
          // Retinal circular viewfinder guide
          IgnorePointer(
            child: Center(
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: ScannerHUDTheme.neonCyan, width: 2),
                  boxShadow: [
                    BoxShadow(
                      color: ScannerHUDTheme.neonCyan.withValues(alpha: 0.3),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Live status badge
          Positioned(
            top: 14,
            left: 14,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF0F2942),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.videocam, size: 14, color: Color(0xFF00E5FF)),
                  SizedBox(width: 6),
                  Text(
                    'LIVE CAMERA (ACTIVE)',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: _captureButton(),
            ),
          ),
        ],
      );
    }

    if (_initializing || !ready || controller == null) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 12),
            Text(
              'Starting camera…',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onDoubleTap: _toggleZoom,
          child: CameraPreview(controller),
        ),
        // Framing guide: a centered retinal-field circle, purely visual.
        IgnorePointer(
          child: Center(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54, width: 2),
              ),
            ),
          ),
        ),
        if (_maxZoom > _minZoom)
          Positioned(top: 14, right: 14, child: _zoomBadge()),
        if (_maxZoom > _minZoom)
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: 116),
              child: IgnorePointer(
                child: Text(
                  'Pinch or double-tap to zoom',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                  ),
                ),
              ),
            ),
          ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: _captureButton(),
          ),
        ),
      ],
    );
  }

  Widget _zoomBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_zoom.toStringAsFixed(1)}×',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (_zoom > _minZoom + 0.05) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => unawaited(_setZoom(_minZoom)),
              child: const Icon(
                Icons.restart_alt,
                size: 16,
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _captureButton() {
    return GestureDetector(
      onTap: _capturing ? null : _capture,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _capturing ? Colors.white38 : Colors.white,
            ),
            child: _capturing
                ? const Padding(
                    padding: EdgeInsets.all(22),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
