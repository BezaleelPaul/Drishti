import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/lang_scope.dart';
import '../theme/figma_theme.dart';
import '../widgets/scanner/scanner_theme.dart';

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

  // Desktop webcam streaming (Linux / V4L2)
  bool _isDesktop = false;
  String _desktopDevice = '/dev/video0';
  Uint8List? _desktopFrameBytes;
  Timer? _desktopStreamTimer;
  bool _isFetchingDesktopFrame = false;

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
    setState(() {
      _initializing = true;
      _error = null;
      _zoom = 1.0;
      _minZoom = 1.0;
      _maxZoom = 1.0;
      _isDesktop = false;
    });

    // 1. On Linux desktop, check for local video device (/dev/video*) first
    if (Platform.isLinux) {
      final videoDevice = _detectLinuxVideoDevice();
      if (videoDevice != null) {
        await _startDesktopCamera(videoDevice);
        return;
      }
    }

    // 2. Mobile or platform with standard camera plugin support
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (Platform.isLinux) {
          final dev = _detectLinuxVideoDevice();
          if (dev != null) {
            await _startDesktopCamera(dev);
            return;
          }
        }
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _error = 'No camera available on this device.';
        });
        return;
      }
      _cameras = cameras;
      // Prefer the back camera for fundus capture.
      _lens = cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
      );
      if (_lens < 0) _lens = 0;
      await _open(_cameras[_lens]);
    } catch (e) {
      debugPrint('Standard camera initialization error: $e');
      if (Platform.isLinux) {
        final dev = _detectLinuxVideoDevice();
        if (dev != null) {
          await _startDesktopCamera(dev);
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Camera error: $e'.trim();
      });
    }
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

  Future<void> _startDesktopCamera(String devicePath) async {
    _isDesktop = true;
    _desktopDevice = devicePath;
    _initializing = false;
    if (mounted) setState(() {});

    await _fetchDesktopFrame();

    _desktopStreamTimer?.cancel();
    _desktopStreamTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (_) => _fetchDesktopFrame(),
    );
  }

  Future<void> _fetchDesktopFrame() async {
    if (_isFetchingDesktopFrame || !mounted || !_isDesktop) return;
    _isFetchingDesktopFrame = true;
    try {
      final res = await Process.run(
        'ffmpeg',
        [
          '-f', 'v4l2',
          '-video_size', '640x480',
          '-i', _desktopDevice,
          '-vframes', '1',
          '-f', 'image2',
          '-vcodec', 'mjpeg',
          'pipe:1',
        ],
        stdoutEncoding: null,
      );
      if (res.exitCode == 0 && res.stdout is List<int>) {
        final bytes = Uint8List.fromList(res.stdout as List<int>);
        if (bytes.isNotEmpty && mounted) {
          setState(() {
            _desktopFrameBytes = bytes;
            _error = null;
          });
        }
      }
    } catch (e) {
      debugPrint('Desktop frame grab error: $e');
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
        // Force immediate snapshot if no buffered frame yet
        final res = await Process.run(
          'ffmpeg',
          [
            '-f', 'v4l2',
            '-video_size', '1280x720',
            '-i', _desktopDevice,
            '-vframes', '1',
            '-f', 'image2',
            '-vcodec', 'mjpeg',
            'pipe:1',
          ],
          stdoutEncoding: null,
        );
        if (res.exitCode == 0 && res.stdout is List<int>) {
          final bytes = Uint8List.fromList(res.stdout as List<int>);
          if (!mounted) return;
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
      if (!kIsWeb && Platform.isMacOS) {
        await FilePicker.skipEntitlementsChecks().catchError((_) {});
      }
      final files = await FilePicker.pickFiles(
        dialogTitle: 'Select a fundus photo',
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
      );
      if (files.isEmpty) return;
      final picked = files.first;
      Uint8List? bytes;
      if (picked.path != null && picked.path!.isNotEmpty) {
        final f = File(picked.path!);
        if (await f.exists()) {
          try {
            bytes = await f.readAsBytes();
          } catch (_) {}
        }
      }
      bytes ??= await picked.readAsBytes();
      if (bytes.isNotEmpty && mounted) {
        Navigator.pop(context, bytes);
      }
    } catch (e) {
      debugPrint('Fallback file pick failed: $e');
    }
  }

  @override
  void dispose() {
    _desktopStreamTimer?.cancel();
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
