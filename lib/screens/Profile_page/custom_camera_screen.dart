// lib/screens/Profile_page/custom_camera_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:Ratedly/screens/Profile_page/media_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/add_post_screen.dart';
import 'package:Ratedly/screens/Profile_page/gallery_picker_screen.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:provider/provider.dart';

class CustomCameraScreen extends StatefulWidget {
  final VoidCallback? onPostUploaded;

  /// Profile-flow callbacks. When either is non-null the screen is operating
  /// in profile mode: VideoEditScreen receives the 5-second cap via onResult,
  /// and MediaEditScreen delivers rendered bytes via onResult instead of
  /// pushing AddPostScreen.
  final ValueChanged<Uint8List>? onImageResult;
  final ValueChanged<VideoEditResult>? onVideoResult;

  const CustomCameraScreen({
    Key? key,
    this.onPostUploaded,
    this.onImageResult,
    this.onVideoResult,
  }) : super(key: key);

  @override
  State<CustomCameraScreen> createState() => _CustomCameraScreenState();
}

class _CustomCameraScreenState extends State<CustomCameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = [];
  CameraController? _controller;
  bool _isFrontCamera = true;
  bool _isInitialized = false;
  FlashMode _flashMode = FlashMode.off;
  bool _isRecordingVideo = false;
  bool _isCapturing = false;

  // Recording timer
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  // Gallery thumbnail
  Uint8List? _galleryThumbnail;
  bool _lastGalleryAssetIsVideo = false;

  // True when the screen is being used from the profile editing flow.
  bool get _isProfileFlow =>
      widget.onImageResult != null || widget.onVideoResult != null;

  // ===========================================================================
  // LOGGING
  // ===========================================================================

  /// Sends a structured log row to the [editprof] table.
  /// Never throws — all errors are swallowed so logging never breaks the UI.
  Future<void> _log(
    String event, {
    String? details,
    String? errorMessage,
  }) async {
    try {
      String? userId;
      try {
        final user = Provider.of<UserProvider>(context, listen: false).user;
        userId = user?.uid;
      } catch (e) {
        userId = 'provider_unavailable: $e';
      }

      await Supabase.instance.client.from('editprof').insert({
        'user_id': userId,
        'screen': 'CustomCameraScreen',
        'event': event,
        'details': details,
        'error_message': errorMessage,
      });
    } catch (e) {
      // Logging must never crash the app.
      debugPrint('[editprof] Failed to log "$event": $e');
    }
  }

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _log('initState',
        details: 'isProfileFlow=$_isProfileFlow '
            'hasImageResult=${widget.onImageResult != null} '
            'hasVideoResult=${widget.onVideoResult != null} '
            'hasPostUploaded=${widget.onPostUploaded != null}');
    _initCamera();
    _loadGalleryThumbnail();
  }

  @override
  void dispose() {
    _log('dispose');
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _log('lifecycleChange',
        details: 'state=${state.name} '
            'controllerNull=${_controller == null} '
            'isInitialized=$_isInitialized');
    if (_controller == null || !_isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _controller?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // ===========================================================================
  // CAMERA INIT
  // ===========================================================================

  Future<void> _initCamera() async {
    await _log('initCamera_start',
        details: 'isFrontCamera=$_isFrontCamera flashMode=${_flashMode.name}');
    try {
      _cameras = await availableCameras();
      await _log('initCamera_camerasFound',
          details: 'count=${_cameras.length} '
              'directions=${_cameras.map((c) => c.lensDirection.name).join(',')}');

      if (_cameras.isEmpty) {
        await _log('initCamera_noCameras');
        return;
      }

      final camera = _isFrontCamera
          ? _cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.front,
              orElse: () => _cameras.first)
          : _cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.back,
              orElse: () => _cameras.first);

      await _log('initCamera_selectedCamera',
          details:
              'name=${camera.name} direction=${camera.lensDirection.name}');

      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      await _log('initCamera_controllerInitialized',
          details: 'previewSize=${controller.value.previewSize}');

      await controller.setFlashMode(_flashMode);
      await _log('initCamera_flashSet',
          details: 'flashMode=${_flashMode.name}');

      if (mounted) {
        setState(() {
          _controller = controller;
          _isInitialized = true;
        });
        await _log('initCamera_success');
      } else {
        await _log('initCamera_notMounted_afterInit');
      }
    } catch (e, st) {
      final stStr = st.toString();
      await _log('initCamera_error',
          details:
              'stackTrace=${stStr.substring(0, stStr.length.clamp(0, 400))}',
          errorMessage: e.toString());
      await _logError('_initCamera', e);
    }
  }

  Future<void> _switchCamera() async {
    await _log('switchCamera_start',
        details:
            'currentFront=$_isFrontCamera cameraCount=${_cameras.length}');
    if (_cameras.length < 2) {
      await _log('switchCamera_skipped', details: 'only one camera available');
      return;
    }
    setState(() => _isInitialized = false);
    await _controller?.dispose();
    _controller = null;
    _isFrontCamera = !_isFrontCamera;
    await _log('switchCamera_switching', details: 'newFront=$_isFrontCamera');
    await _initCamera();
  }

  Future<void> _toggleFlash() async {
    if (_controller == null || !_isInitialized) return;
    final FlashMode prev = _flashMode;
    FlashMode next;
    switch (_flashMode) {
      case FlashMode.off:
        next = FlashMode.auto;
        break;
      case FlashMode.auto:
        next = FlashMode.always;
        break;
      default:
        next = FlashMode.off;
    }
    try {
      await _controller!.setFlashMode(next);
      setState(() => _flashMode = next);
      await _log('toggleFlash', details: 'from=${prev.name} to=${next.name}');
    } catch (e) {
      await _log('toggleFlash_error', errorMessage: e.toString());
    }
  }

  IconData get _flashIcon {
    switch (_flashMode) {
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      default:
        return Icons.flash_off;
    }
  }

  // ===========================================================================
  // GALLERY THUMBNAIL
  // ===========================================================================

  Future<void> _loadGalleryThumbnail() async {
    await _log('loadGalleryThumbnail_start');
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      await _log('loadGalleryThumbnail_permission',
          details:
              'isAuth=${permission.isAuth} status=${permission.name}');
      if (!permission.isAuth) return;

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      await _log('loadGalleryThumbnail_albums',
          details: 'albumCount=${albums.length}');
      if (albums.isEmpty) return;

      final assets =
          await albums.first.getAssetListRange(start: 0, end: 1);
      await _log('loadGalleryThumbnail_assets',
          details: 'assetCount=${assets.length}');
      if (assets.isEmpty) return;

      final asset = assets.first;
      final thumb =
          await asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));

      await _log('loadGalleryThumbnail_thumb',
          details: 'thumbNull=${thumb == null} '
              'assetType=${asset.type.name} '
              'assetId=${asset.id}');

      if (mounted && thumb != null) {
        setState(() {
          _galleryThumbnail = thumb;
          _lastGalleryAssetIsVideo = asset.type == AssetType.video;
        });
        await _log('loadGalleryThumbnail_success',
            details: 'isVideo=$_lastGalleryAssetIsVideo');
      }
    } catch (e, st) {
      final stStr = st.toString();
      await _log('loadGalleryThumbnail_error',
          details:
              'stackTrace=${stStr.substring(0, stStr.length.clamp(0, 400))}',
          errorMessage: e.toString());
    }
  }

  // ===========================================================================
  // SHUTTER
  // ===========================================================================

  Future<void> _onShutterTap() async {
    await _log('shutterTap',
        details:
            'isRecordingVideo=$_isRecordingVideo isCapturing=$_isCapturing');
    if (_isRecordingVideo) {
      await _stopVideoRecording();
    } else {
      await _capturePhoto();
    }
  }

  Future<void> _capturePhoto() async {
    await _log('capturePhoto_start',
        details: 'controllerNull=${_controller == null} '
            'isInitialized=$_isInitialized '
            'isCapturing=$_isCapturing '
            'isProfileFlow=$_isProfileFlow '
            'hasImageResult=${widget.onImageResult != null}');

    if (_controller == null || !_isInitialized || _isCapturing) {
      await _log('capturePhoto_skipped',
          details: 'controllerNull=${_controller == null} '
              'isInitialized=$_isInitialized '
              'isCapturing=$_isCapturing');
      return;
    }
    setState(() => _isCapturing = true);

    try {
      final XFile photo = await _controller!.takePicture();
      await _log('capturePhoto_taken', details: 'path=${photo.path}');

      Uint8List bytes = await photo.readAsBytes();
      await _log('capturePhoto_bytesRead',
          details: 'byteLength=${bytes.length} isFront=$_isFrontCamera');

      if (_isFrontCamera) {
        final decoded = img.decodeJpg(bytes);
        if (decoded != null) {
          final flipped = img.flipHorizontal(decoded);
          bytes =
              Uint8List.fromList(img.encodeJpg(flipped, quality: 92));
          await _log('capturePhoto_frontFlipped',
              details: 'newByteLength=${bytes.length}');
        } else {
          await _log('capturePhoto_decodeFailedSkippingFlip');
        }
      }

      await _log('capturePhoto_navigating',
          details: 'pushingMediaEditScreen '
              'hasOnResult=${widget.onImageResult != null} '
              'hasOnPostUploaded=${widget.onPostUploaded != null}');

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaEditScreen(
              imageBytes: bytes,
              // Pass the profile callback so MediaEditScreen returns bytes
              // instead of pushing AddPostScreen.
              onResult: widget.onImageResult,
              onPostUploaded: widget.onPostUploaded,
            ),
          ),
        );
        await _log('capturePhoto_navigated');
      } else {
        await _log('capturePhoto_notMounted_beforeNavigate');
      }
    } catch (e, st) {
      final stStr = st.toString();
      await _log('capturePhoto_error',
          details:
              'stackTrace=${stStr.substring(0, stStr.length.clamp(0, 400))}',
          errorMessage: e.toString());
      await _logError('_capturePhoto', e);
      if (mounted) _showError('Could not capture photo. Please try again.');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _startVideoRecording() async {
    await _log('startVideoRecording_start',
        details: 'controllerNull=${_controller == null} '
            'isInitialized=$_isInitialized '
            'isRecording=$_isRecordingVideo');

    if (_controller == null || !_isInitialized || _isRecordingVideo) {
      await _log('startVideoRecording_skipped');
      return;
    }
    try {
      await _controller!.startVideoRecording();
      setState(() {
        _isRecordingVideo = true;
        _recordingSeconds = 0;
      });
      await _log('startVideoRecording_started');
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } catch (e, st) {
      final stStr = st.toString();
      await _log('startVideoRecording_error',
          details:
              'stackTrace=${stStr.substring(0, stStr.length.clamp(0, 400))}',
          errorMessage: e.toString());
      await _logError('_startVideoRecording', e);
    }
  }

  Future<void> _stopVideoRecording() async {
    await _log('stopVideoRecording_start',
        details: 'controllerNull=${_controller == null} '
            'isRecording=$_isRecordingVideo '
            'elapsedSeconds=$_recordingSeconds '
            'isProfileFlow=$_isProfileFlow '
            'hasVideoResult=${widget.onVideoResult != null}');

    if (_controller == null || !_isRecordingVideo) {
      await _log('stopVideoRecording_skipped');
      return;
    }
    try {
      final XFile video = await _controller!.stopVideoRecording();
      await _log('stopVideoRecording_stopped',
          details:
              'path=${video.path} elapsedSeconds=$_recordingSeconds');

      _recordingTimer?.cancel();
      _recordingTimer = null;
      setState(() {
        _isRecordingVideo = false;
        _recordingSeconds = 0;
      });

      await _log('stopVideoRecording_navigating',
          details: 'pushingVideoEditScreen '
              'hasOnResult=${widget.onVideoResult != null} '
              'hasOnPostUploaded=${widget.onPostUploaded != null}');

      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => VideoEditScreen(
              videoFile: File(video.path),
              // Pass the profile callback so VideoEditScreen uses the 5-second
              // trim cap and returns the result instead of pushing AddPostScreen.
              onResult: widget.onVideoResult,
              onPostUploaded: widget.onPostUploaded,
            ),
          ),
        );
        await _log('stopVideoRecording_navigated');
      } else {
        await _log('stopVideoRecording_notMounted_beforeNavigate');
      }
    } catch (e, st) {
      _recordingTimer?.cancel();
      _recordingTimer = null;
      setState(() {
        _isRecordingVideo = false;
        _recordingSeconds = 0;
      });
      final stStr = st.toString();
      await _log('stopVideoRecording_error',
          details:
              'stackTrace=${stStr.substring(0, stStr.length.clamp(0, 400))}',
          errorMessage: e.toString());
      await _logError('_stopVideoRecording', e);
    }
  }

  // ===========================================================================
  // GALLERY PICKER
  // ===========================================================================

  void _openGallery() async {
    await _log('openGallery_start',
        details: 'mounted=$mounted '
            'isProfileFlow=$_isProfileFlow '
            'hasImageResult=${widget.onImageResult != null} '
            'hasVideoResult=${widget.onVideoResult != null} '
            'hasPostUploaded=${widget.onPostUploaded != null}');

    if (!mounted) {
      await _log('openGallery_notMounted');
      return;
    }

    await _log('openGallery_navigating',
        details: 'GalleryPickerScreen '
            'onImageResult=${widget.onImageResult != null} '
            'onVideoResult=${widget.onVideoResult != null}');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GalleryPickerScreen(
          onPostUploaded: widget.onPostUploaded,
          // Forward profile-flow callbacks so gallery picks also respect the
          // 5-second trim cap and return results instead of pushing AddPostScreen.
          onImageResult: widget.onImageResult,
          onVideoResult: widget.onVideoResult,
        ),
      ),
    );

    await _log('openGallery_navigated');
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// Legacy error logger kept for backward compatibility.
  Future<void> _logError(String operation, dynamic error) async {
    try {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      await Supabase.instance.client.from('posts_errors').insert({
        'user_id': user?.uid,
        'operation_type': 'camera/$operation',
        'error_message': error.toString(),
      });
    } catch (_) {}
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatRecordingTime(int totalSeconds) {
    final m = totalSeconds ~/ 60;
    final s = totalSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // ===========================================================================
  // PREVIEW
  // ===========================================================================

  Widget _buildPreview() {
    if (!_isInitialized || _controller == null) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    final previewSize = _controller!.value.previewSize;
    if (previewSize == null) return CameraPreview(_controller!);

    final double previewW = previewSize.height;
    final double previewH = previewSize.width;

    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: previewW,
          height: previewH,
          child: CameraPreview(_controller!),
        ),
      ),
    );
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(child: _buildPreview()),

          // ── Top bar ──────────────────────────────────────────────────────
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _CircleIconButton(
                      icon: Icons.close,
                      onTap: () {
                        _log('closeTapped');
                        Navigator.pop(context);
                      },
                    ),
                    _CircleIconButton(
                      icon: _flashIcon,
                      onTap: _toggleFlash,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Recording indicator ───────────────────────────────────────────
          if (_isRecordingVideo)
            Positioned(
              top: MediaQuery.of(context).padding.top + 56,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.circle, color: Colors.red, size: 10),
                      const SizedBox(width: 6),
                      Text(
                        _formatRecordingTime(_recordingSeconds),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Bottom controls ───────────────────────────────────────────────
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Gallery thumbnail
                    GestureDetector(
                      onTap: _openGallery,
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: Colors.white.withOpacity(0.6),
                              width: 1.5),
                          color: Colors.grey[900],
                          image: _galleryThumbnail != null
                              ? DecorationImage(
                                  image: MemoryImage(_galleryThumbnail!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _galleryThumbnail == null
                            ? Icon(Icons.photo_library_rounded,
                                color: Colors.white.withOpacity(0.6),
                                size: 22)
                            : _lastGalleryAssetIsVideo
                                ? const Align(
                                    alignment: Alignment.topRight,
                                    child: Padding(
                                      padding: EdgeInsets.all(3),
                                      child: Icon(Icons.play_circle_fill,
                                          color: Colors.white, size: 14),
                                    ),
                                  )
                                : null,
                      ),
                    ),

                    // Shutter
                    GestureDetector(
                      onTap: _onShutterTap,
                      onLongPressStart: (_) => _startVideoRecording(),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: _isRecordingVideo ? 64 : 76,
                        height: _isRecordingVideo ? 64 : 76,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              _isRecordingVideo ? Colors.red : Colors.white,
                          border: Border.all(
                            color: Colors.white.withOpacity(0.8),
                            width: _isRecordingVideo ? 4 : 5,
                          ),
                        ),
                        child: _isCapturing
                            ? const Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    color: Colors.black,
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              )
                            : _isRecordingVideo
                                ? const Icon(Icons.stop_rounded,
                                    color: Colors.white, size: 28)
                                : null,
                      ),
                    ),

                    // Flip camera
                    _CircleIconButton(
                      icon: Icons.flip_camera_ios_rounded,
                      size: 28,
                      onTap: _switchCamera,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Hint ─────────────────────────────────────────────────────────
          Positioned(
            bottom: MediaQuery.of(context).padding.bottom + 120,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                _isRecordingVideo ? 'Tap to stop' : 'Hold for video',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 12,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double size;

  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withOpacity(0.35),
        ),
        child: Icon(icon, color: Colors.white, size: size),
      ),
    );
  }
}
