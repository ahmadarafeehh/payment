// lib/screens/Profile_page/custom_camera_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:photo_manager/photo_manager.dart';
import 'package:permission_handler/permission_handler.dart';
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

  // Tracks which permission(s) are missing so _buildPreview() can show a
  // clear recovery screen instead of spinning forever. Previously a denied
  // permission was logged but never surfaced to the user at all.
  bool _cameraDenied = false;
  bool _microphoneDenied = false;

  // Gallery access is checked before navigating to GalleryPickerScreen. If
  // denied, the same recovery screen is shown with an "Access gallery"
  // button instead of silently failing to open the picker (or opening it
  // into an empty/broken state).
  bool _galleryDenied = false;
  bool _checkingGalleryPermission = false;

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

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
    _loadGalleryThumbnail();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _recordingTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      // FIX: previously this disposed the controller without clearing
      // _controller/_isInitialized, leaving a dangling reference to a
      // disposed native camera session. Any later code (including the
      // preview widget rebuild, or this screen briefly becoming current
      // again during a multi-pop navigation) could then try to render
      // through that disposed controller, which is a strong candidate for
      // the black-screen-after-post bug.
      _controller?.dispose();
      _controller = null;
      _isInitialized = false;
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  // ===========================================================================
  // CAMERA INIT
  // ===========================================================================

  Future<void> _initCamera() async {
    // Reset any previous denial state on every attempt so a retry after
    // fixing permissions in Settings actually gets a clean run. Also clears
    // _galleryDenied: reaching _initCamera() means we're (re)entering the
    // camera flow, so any leftover gallery-gate state from earlier in this
    // screen's lifetime shouldn't linger and combine with a fresh
    // camera/mic denial.
    if (mounted) {
      setState(() {
        _cameraDenied = false;
        _microphoneDenied = false;
        _galleryDenied = false;
      });
    }

    try {
      _cameras = await availableCameras();
      
      if (_cameras.isEmpty) {
        
        return;
      }

      final camera = _isFrontCamera
          ? _cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.front,
              orElse: () => _cameras.first)
          : _cameras.firstWhere(
              (c) => c.lensDirection == CameraLensDirection.back,
              orElse: () => _cameras.first);

      final controller = CameraController(
        camera,
        ResolutionPreset.high,
        enableAudio: true,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      
      await controller.setFlashMode(_flashMode);
      
      if (mounted) {
        setState(() {
          _controller = controller;
          _isInitialized = true;
        });
        
      } else {
        
        // Screen was disposed while initializing — don't leak the session.
        await controller.dispose();
      }
    } catch (e, st) {
      final stStr = st.toString();
      
      await _logError('_initCamera', e,
          stackTrace: stStr,
          additionalData: {
            'isFrontCamera': _isFrontCamera,
            'cameraCount': _cameras.length,
          });

      // FIX: previously the error was only logged — nothing was shown to
      // the user, leaving them stuck on an endless loading spinner with no
      // way forward except force-quitting the app. Now check each
      // permission individually so the recovery screen can tell the user
      // exactly what's missing, TikTok-style.
      final cameraStatus = await Permission.camera.status;
      final micStatus = await Permission.microphone.status;
      if (mounted) {
        setState(() {
          _isInitialized = false;
          _cameraDenied = !cameraStatus.isGranted;
          _microphoneDenied = !micStatus.isGranted;
        });
      }
    }
  }

  Future<void> _switchCamera() async {
    
    if (_cameras.length < 2) {
      
      return;
    }
    try {
      setState(() => _isInitialized = false);
      await _controller?.dispose();
      _controller = null;
      _isFrontCamera = !_isFrontCamera;
      
      await _initCamera();
    } catch (e, st) {
      // FIX: previously this method had no error handling at all — if
      // disposing the old controller or switching lenses failed, nothing
      // was logged anywhere, and the user could be left on a broken
      // preview with zero record of it happening. Logged to both tables
      // since a broken preview can block posting entirely.
      final stStr = st.toString();
      
      await _logError('_switchCamera', e,
          stackTrace: stStr,
          additionalData: {'switchingToFront': _isFrontCamera});
      if (mounted) {
        setState(() => _isInitialized = false);
      }
    }
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
      
    } catch (e) {
      
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
  // PREVIEW PAUSE / RESUME (around forward navigation)
  // ===========================================================================

  /// Pauses the live camera preview without tearing down the session.
  /// Called before navigating forward to the editor/composer, since those
  /// screens sit on top of this one for several seconds (editing, upload,
  /// optional boost purchase) while this screen — and its camera texture —
  /// stays mounted underneath, fully obscured. Leaving the preview running
  /// that whole time is unnecessary and a likely contributor to the
  /// black-screen-after-post bug when this route briefly becomes current
  /// again during the post-success navigation pop.
  Future<void> _pausePreviewSafely() async {
    if (_controller == null || !_isInitialized) return;
    try {
      await _controller!.pausePreview();
      
    } catch (e) {
      
      // FIX: previously only logged for observability, not error-tracked. Doesn't block posting, but now
      // also recorded in posts_errors for visibility.
      await _logError('_pausePreview', e);
    }
  }

  /// Resumes the live camera preview after returning from the
  /// editor/composer (e.g. user backs out without posting).
  Future<void> _resumePreviewSafely() async {
    if (!mounted || _controller == null || !_isInitialized) return;
    try {
      await _controller!.resumePreview();
    } catch (e) {
      // Resume failures are non-fatal (preview just stays paused); no
      // dedicated error log for this path.
    }
  }

  // ===========================================================================
  // GALLERY THUMBNAIL
  // ===========================================================================

  Future<void> _loadGalleryThumbnail() async {
    
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      
      if (!permission.isAuth) return;

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        onlyAll: true,
      );
      
      if (albums.isEmpty) return;

      final assets =
          await albums.first.getAssetListRange(start: 0, end: 1);
      
      if (assets.isEmpty) return;

      final asset = assets.first;
      final thumb =
          await asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));

      if (mounted && thumb != null) {
        setState(() {
          _galleryThumbnail = thumb;
          _lastGalleryAssetIsVideo = asset.type == AssetType.video;
        });
        
      }
    } catch (e, st) {
      final stStr = st.toString();
      
      // FIX: previously only logged for observability, not error-tracked. Doesn't block posting (only the
      // thumbnail preview is affected), but now also recorded in
      // posts_errors for a single-table view of all posting-flow issues.
      await _logError('_loadGalleryThumbnail', e, stackTrace: stStr);
    }
  }

  // ===========================================================================
  // SHUTTER
  // ===========================================================================

  Future<void> _onShutterTap() async {
    
    if (_isRecordingVideo) {
      await _stopVideoRecording();
    } else {
      await _capturePhoto();
    }
  }

  Future<void> _capturePhoto() async {
    
    if (_controller == null || !_isInitialized || _isCapturing) {
      
      return;
    }
    setState(() => _isCapturing = true);

    try {
      final XFile photo = await _controller!.takePicture();
      
      Uint8List bytes = await photo.readAsBytes();
      
      if (_isFrontCamera) {
        final decoded = img.decodeJpg(bytes);
        if (decoded != null) {
          final flipped = img.flipHorizontal(decoded);
          bytes =
              Uint8List.fromList(img.encodeJpg(flipped, quality: 92));
          
        } else {
          // FIX: previously this wasn't logged as an error. The photo still
          // gets posted (unflipped/mirrored), so this doesn't block
          // posting outright, but a failed decode can indicate a
          // corrupted capture, so it's now also recorded in posts_errors
          // for visibility alongside other posting-flow issues.
          
          await _logError(
              '_capturePhoto_decodeFailedSkippingFlip',
              'decodeJpg returned null',
              additionalData: {'byteLength': bytes.length});
        }
      }

      if (mounted) {
        // FIX: pause the live camera preview before this screen gets
        // buried under the editor + composer for the duration of editing,
        // uploading, and (iOS) an optional boost purchase. Previously the
        // preview stayed live and fully obscured that whole time.
        await _pausePreviewSafely();

        if (!mounted) return;

        await Navigator.push(
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
        
        // Only reached if the user backed out without completing a post
        // (on success, postMedia() pops this route away entirely via
        // popUntil('cameraFromProfile') + pop(), so this screen — and this
        // resume call — never comes back into play).
        await _resumePreviewSafely();
      } else {
        
      }
    } catch (e, st) {
      final stStr = st.toString();
      
      await _logError('_capturePhoto', e, stackTrace: stStr);
      if (mounted) _showError('Could not capture photo. Please try again.');
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  Future<void> _startVideoRecording() async {
    
    if (_controller == null || !_isInitialized || _isRecordingVideo) {
      
      return;
    }
    try {
      await _controller!.startVideoRecording();
      setState(() {
        _isRecordingVideo = true;
        _recordingSeconds = 0;
      });
      
      _recordingTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _recordingSeconds++);
      });
    } catch (e, st) {
      final stStr = st.toString();
      
      await _logError('_startVideoRecording', e, stackTrace: stStr);
    }
  }

  Future<void> _stopVideoRecording() async {
    
    if (_controller == null || !_isRecordingVideo) {
      
      return;
    }
    try {
      final XFile video = await _controller!.stopVideoRecording();
      
      _recordingTimer?.cancel();
      _recordingTimer = null;
      setState(() {
        _isRecordingVideo = false;
        _recordingSeconds = 0;
      });

      if (mounted) {
        // FIX: same rationale as _capturePhoto() — pause the live preview
        // before this screen sits buried under the editor + composer.
        await _pausePreviewSafely();

        if (!mounted) return;

        await Navigator.push(
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
        
        // Only reached if the user backed out without completing a post.
        await _resumePreviewSafely();
      } else {
        
      }
    } catch (e, st) {
      _recordingTimer?.cancel();
      _recordingTimer = null;
      setState(() {
        _isRecordingVideo = false;
        _recordingSeconds = 0;
      });
      final stStr = st.toString();
      
      await _logError('_stopVideoRecording', e,
          stackTrace: stStr,
          additionalData: {'elapsedSeconds': _recordingSeconds});
    }
  }

  // ===========================================================================
  // GALLERY PICKER
  // ===========================================================================

  void _openGallery() async {
    
    if (!mounted) {
      
      return;
    }

    // Check gallery permission before navigating. Previously this always
    // pushed GalleryPickerScreen regardless of permission state, silently
    // failing/looking broken if access was denied. A denial shows the same
    // "Post on Reactly" recovery screen used for camera/mic, with an
    // "Access gallery" button.
    if (mounted) setState(() => _checkingGalleryPermission = true);
    final permission = await PhotoManager.requestPermissionExtend();
    if (mounted) setState(() => _checkingGalleryPermission = false);

    if (!permission.isAuth) {
      // FIX: previously wasn't logged as an error. This blocks the user's
      // gallery-posting path entirely, so it's now also recorded in
      // posts_errors for visibility alongside other posting-flow issues.
      await _logError('_openGallery_permission_denied', 'Gallery access denied',
          additionalData: {'permissionStatus': permission.name});
      if (mounted) {
        setState(() {
          _galleryDenied = true;
          // FIX: previously _cameraDenied/_microphoneDenied were left
          // untouched here. If the user reached this method via "Upload
          // from Library instead" on the camera/mic gate (i.e. camera and
          // mic were already denied), all three flags would end up true
          // simultaneously, and _buildPermissionGate() would render all
          // three pills together since each is gated by an independent
          // `if`, not a mutually exclusive branch. Explicitly clearing the
          // camera/mic flags here makes the gallery gate show only the
          // gallery pill, and correctly unlocks the "Back to camera"
          // escape-hatch link (which requires both flags to be false).
          _cameraDenied = false;
          _microphoneDenied = false;
        });
      }
      return;
    }

    if (mounted) setState(() => _galleryDenied = false);

    // FIX: same rationale as the camera-capture paths — this screen (and
    // its live preview) stays mounted underneath the gallery picker and
    // whatever it pushes next, so pause it here too.
    await _pausePreviewSafely();
    if (!mounted) return;

    await Navigator.push(
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

    await _resumePreviewSafely();
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// Legacy error logger kept for backward compatibility, extended to make
  /// use of the full posts_errors schema (stack_trace, additional_data)
  /// instead of only user_id/operation_type/error_message. media_url is
  /// left null here since this file doesn't have a media URL at the point
  /// most of these errors occur (they're pre-upload, camera/gallery-side).
  Future<void> _logError(
    String operation,
    dynamic error, {
    String? stackTrace,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      await Supabase.instance.client.from('posts_errors').insert({
        'user_id': user?.uid,
        'operation_type': 'camera/$operation',
        'error_message': error.toString(),
        'stack_trace': stackTrace,
        'additional_data': additionalData,
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
    // Gallery was denied via the gallery button — show the gate regardless
    // of camera state, since the user explicitly tried to use the gallery.
    // (As of the fix in _openGallery(), _cameraDenied/_microphoneDenied are
    // guaranteed false whenever _galleryDenied is true, so this always
    // renders the gallery-only gate.)
    if (_galleryDenied) {
      return _buildPermissionGate();
    }

    // Nothing has failed yet — genuinely still loading for the first time.
    if (_controller == null &&
        !_isInitialized &&
        !_cameraDenied &&
        !_microphoneDenied) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.white));
    }

    // FIX: previously a denied permission left _isInitialized false forever
    // with no recovery path — just an endless spinner. Now show a clear,
    // TikTok-style screen naming exactly what access is missing.
    if (!_isInitialized && (_cameraDenied || _microphoneDenied)) {
      return _buildPermissionGate();
    }

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

  /// TikTok-style recovery screen shown when camera, microphone, and/or
  /// gallery access is missing. Each button opens the phone's Settings
  /// directly, since re-requesting a permission the user already denied
  /// does nothing on iOS/Android — the only way forward is Settings.
  ///
  /// _cameraDenied/_microphoneDenied and _galleryDenied are maintained as
  /// mutually exclusive states (see _openGallery() and _initCamera()), so
  /// this never renders a mix of the camera/mic pills and the gallery pill
  /// together.
  Widget _buildPermissionGate() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Post on Reactly',
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            Text(
              _galleryDenied
                  ? 'Allow access to your photos to choose something to post.'
                  : 'Allow access to your camera and microphone to start recording.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 15,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (_cameraDenied) ...[
              _PermissionPill(
                icon: Icons.camera_alt_rounded,
                label: 'Access camera',
                onTap: () async {
                  
                  await openAppSettings();
                },
              ),
              if (_microphoneDenied) const SizedBox(height: 14),
            ],
            if (_microphoneDenied)
              _PermissionPill(
                icon: Icons.mic_rounded,
                label: 'Access microphone',
                onTap: () async {
                  
                  await openAppSettings();
                },
              ),
            if (_galleryDenied)
              _PermissionPill(
                icon: Icons.photo_library_rounded,
                label: 'Access gallery',
                onTap: () async {
                  
                  await openAppSettings();
                },
              ),
            const SizedBox(height: 20),
            // A single, context-appropriate escape hatch: offer the gallery
            // as an alternative when camera/mic is the problem, or offer a
            // way back to camera when gallery is the problem (and camera
            // itself is fine).
            if (!_galleryDenied)
              GestureDetector(
                onTap: _openGallery,
                child: Text(
                  'Upload from Library instead',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white.withOpacity(0.35),
                  ),
                ),
              )
            else if (!_cameraDenied && !_microphoneDenied)
              GestureDetector(
                onTap: () => setState(() => _galleryDenied = false),
                child: Text(
                  'Back to camera',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.underline,
                    decorationColor: Colors.white.withOpacity(0.35),
                  ),
                ),
              ),
          ],
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
                      onTap: () => Navigator.pop(context),
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
                      onTap: _checkingGalleryPermission ? null : _openGallery,
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
                        child: _checkingGalleryPermission
                            ? const Center(
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : _galleryThumbnail == null
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

/// TikTok-style pill button used on the permission-recovery screen.
class _PermissionPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _PermissionPill({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.black, size: 20),
            const SizedBox(width: 10),
            Text(
              label,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
