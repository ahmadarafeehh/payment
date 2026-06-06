// lib/screens/Profile_page/add_post_screen.dart
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/colors.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/models/user.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';

// Identity matrix — passthrough when no filter/adjust is applied.
const List<double> _kIdentityMatrix = [
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
];

class AddPostScreen extends StatefulWidget {
  final VoidCallback? onPostUploaded;

  /// Pre-captured / pre-edited image bytes.
  final Uint8List? initialFile;

  /// Pre-edited video file passed from VideoEditScreen.
  final File? initialVideoFile;

  /// Full edit state from VideoEditScreen — filters, adjustments,
  /// draw strokes, text overlays, and rotation quarters are re-applied
  /// as widget layers on the preview AND serialised into the post record
  /// so every viewer can reconstruct the same visual output.
  final VideoEditResult? editResult;

  const AddPostScreen({
    Key? key,
    this.onPostUploaded,
    this.initialFile,
    this.initialVideoFile,
    this.editResult,
  }) : super(key: key);

  @override
  State<AddPostScreen> createState() => _AddPostScreenState();
}

class _AddPostScreenState extends State<AddPostScreen>
    with SingleTickerProviderStateMixin {
  Uint8List? _file;
  File? _videoFile;
  bool isLoading = false;
  bool _isVideo = false;
  final TextEditingController _descriptionController = TextEditingController();
  final FocusNode _captionFocusNode = FocusNode();
  final double _maxFileSize = 2.5 * 1024 * 1024;
  final double _maxVideoSize = 50 * 1024 * 1024;
  bool _hasAgreedToWarning = false;

  // Video preview player
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isPlaying = false;

  // Pulse animation for upload button
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── Emoji reaction picker ──────────────────────────────────────────────────
static const List<String> _availableEmojis = [
  '❤️',
  '😂',
  '😍',
  '🔥',
  '😎',
  '🥰',
  '😮',
  '👏',
  '💯',
  '😡',
  '💀',  // <-- added skull
];
  String _selectedEmoji = '❤️';

  // ===========================================================================
  // ERROR LOGGING
  // ===========================================================================

  Future<void> _logError({
    required String operation,
    required dynamic error,
    StackTrace? stack,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      final user = Provider.of<UserProvider>(context, listen: false).user;
      await Supabase.instance.client.from('posts_errors').insert({
        'user_id': user?.uid,
        'operation_type': operation,
        'error_message': error.toString(),
        'stack_trace': stack?.toString(),
        'additional_data': additionalData,
      });
    } catch (_) {}
  }

  // ===========================================================================
  // LIFECYCLE
  // ===========================================================================

  @override
  void initState() {
    super.initState();
    _descriptionController.addListener(() => setState(() {}));

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.07).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.initialFile != null) {
      _file = widget.initialFile;
      _isVideo = false;
    } else if (widget.initialVideoFile != null) {
      _videoFile = widget.initialVideoFile;
      _isVideo = true;
      _initVideoPlayer(widget.initialVideoFile!);
    } else {
      _checkIfUserAgreed();
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _descriptionController.dispose();
    _captionFocusNode.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _initVideoPlayer(File file) async {
    try {
      final c = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await c.initialize();
      await c.setLooping(true);
      if (mounted) {
        setState(() {
          _videoController = c;
          _isVideoInitialized = true;
        });
        await c.play();
        if (mounted) setState(() => _isPlaying = true);
      }
    } catch (e, stack) {
      await _logError(operation: '_initVideoPlayer', error: e, stack: stack);
    }
  }

  Future<void> _toggleVideoPlayback() async {
    if (_videoController == null || !_isVideoInitialized) return;
    if (_isPlaying) {
      await _videoController!.pause();
    } else {
      await _videoController!.play();
    }
    if (mounted) setState(() => _isPlaying = _videoController!.value.isPlaying);
  }

  // ===========================================================================
  // AGREEMENT
  // ===========================================================================

  Future<void> _checkIfUserAgreed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _hasAgreedToWarning =
            prefs.getBool('hasAgreedToPostingWarning') ?? false;
      });
    } catch (e, stack) {
      await _logError(operation: '_checkIfUserAgreed', error: e, stack: stack);
    }
  }

  Future<void> _saveUserAgreement() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('hasAgreedToPostingWarning', true);
      setState(() => _hasAgreedToWarning = true);
    } catch (e, stack) {
      await _logError(operation: '_saveUserAgreement', error: e, stack: stack);
    }
  }

  // ===========================================================================
  // ENTRY POINT
  // ===========================================================================

  Future<void> _onUploadButtonPressed() async {
    if (!_hasAgreedToWarning) {
      final agreed = await _showWarningDialog();
      if (agreed != true) return;
      await _saveUserAgreement();
    }
    await _launchCamera();
  }

  Future<bool?> _showWarningDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: mobileBackgroundColor,
        title: Text(
          'Ratedly Guidelines',
          style: TextStyle(color: primaryColor, fontWeight: FontWeight.bold),
        ),
        content: Text.rich(
          TextSpan(children: [
            TextSpan(
              text: 'Posting inappropriate content will get your device ',
              style: TextStyle(color: primaryColor),
            ),
            TextSpan(
              text: 'permanently banned',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            TextSpan(text: '.', style: TextStyle(color: primaryColor)),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              'I Understand',
              style:
                  TextStyle(color: primaryColor, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _launchCamera() async {
    try {
      await _pickAndProcessImage(ImageSource.camera);
    } catch (e) {
      final String errStr = e.toString().toLowerCase();
      final bool isPermissionError = errStr.contains('permission') ||
          errStr.contains('denied') ||
          errStr.contains('access') ||
          errStr.contains('not authorized');

      if (isPermissionError) {
        final status = await Permission.camera.status;
        await _showPermissionSheet(
          isPermanent: status.isPermanentlyDenied,
          needsMic: false,
        );
      } else {
        await _logError(
          operation: '_launchCamera',
          error: e,
          additionalData: {'errorString': e.toString()},
        );
        if (context.mounted) {
          showSnackBar(context, 'Could not open camera. Please try again.');
        }
      }
    }
  }

  Future<void> _showPermissionSheet({
    required bool isPermanent,
    required bool needsMic,
  }) async {
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _PermissionSheet(
        isPermanent: isPermanent,
        needsMic: needsMic,
        onOpenGallery: () {
          Navigator.pop(ctx);
          if (needsMic) {
            _pickVideoFromGallery();
          } else {
            _pickAndProcessImage(ImageSource.gallery);
          }
        },
        onOpenSettings: isPermanent
            ? () async {
                Navigator.pop(ctx);
                await openAppSettings();
              }
            : null,
      ),
    );
  }

  // ===========================================================================
  // MEDIA PICKING
  // ===========================================================================

  Future<void> _pickAndProcessImage(ImageSource source) async {
    try {
      setState(() {
        _isVideo = false;
        isLoading = true;
        _videoFile = null;
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;
      });

      final pickedFile = await ImagePicker().pickImage(
        source: source,
        preferredCameraDevice: CameraDevice.front,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final int rawSize = await File(pickedFile.path).length();

        Uint8List? compressedImage =
            await FlutterImageCompress.compressWithFile(
          pickedFile.path,
          minWidth: 800,
          minHeight: 800,
          quality: 80,
          format: CompressFormat.jpeg,
        );

        if (compressedImage == null) {
          await _logError(
            operation: '_pickAndProcessImage/compress_returned_null',
            error: 'FlutterImageCompress returned null',
            additionalData: {
              'source': source.toString(),
              'rawFileSizeBytes': rawSize,
            },
          );
        }

        if (compressedImage != null && compressedImage.length > _maxFileSize) {
          compressedImage = await _compressUntilUnderLimit(compressedImage);
        }

        if (compressedImage != null) {
          setState(() {
            _file = compressedImage;
            isLoading = false;
          });
        } else {
          final Uint8List fallback = await pickedFile.readAsBytes();
          setState(() {
            _file = fallback;
            isLoading = false;
          });
        }
      } else {
        setState(() => isLoading = false);
      }
    } catch (e, stack) {
      setState(() => isLoading = false);
      rethrow;
    }
  }

  Future<void> _pickVideoFromGallery() async {
    try {
      setState(() {
        _isVideo = true;
        isLoading = true;
        _file = null;
        _videoController?.dispose();
        _videoController = null;
        _isVideoInitialized = false;
      });

      final pickedFile = await ImagePicker().pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );

      if (pickedFile != null) {
        final File videoFile = File(pickedFile.path);
        final int videoSize = await videoFile.length();

        if (videoSize > _maxVideoSize) {
          if (context.mounted) {
            showSnackBar(context,
                'Video too large (max 50MB). Please choose a shorter video.');
          }
          setState(() => isLoading = false);
          return;
        }

        setState(() {
          _videoFile = videoFile;
          isLoading = false;
        });
        await _initVideoPlayer(videoFile);
      } else {
        setState(() => isLoading = false);
      }
    } catch (e, stack) {
      setState(() => isLoading = false);
      await _logError(
          operation: '_pickVideoFromGallery', error: e, stack: stack);
      if (context.mounted) {
        showSnackBar(context, 'Failed to pick video: $e');
      }
    }
  }

  Future<Uint8List?> _compressUntilUnderLimit(Uint8List imageBytes) async {
    int quality = 75;
    Uint8List? compressedImage = imageBytes;
    try {
      while (quality >= 50 &&
          compressedImage != null &&
          compressedImage.length > _maxFileSize) {
        compressedImage = await FlutterImageCompress.compressWithList(
          compressedImage,
          quality: quality,
          format: CompressFormat.jpeg,
        );
        quality -= 5;
      }
    } catch (e, stack) {
      await _logError(
        operation: '_compressUntilUnderLimit',
        error: e,
        stack: stack,
      );
    }
    return compressedImage;
  }

  // ===========================================================================
  // POST UPLOAD
  // ===========================================================================

  void postMedia(AppUser user) async {
    if (_descriptionController.text.length > 250) {
      if (context.mounted) {
        showSnackBar(
          context,
          'Caption cannot exceed 250 characters. '
          'Your caption is ${_descriptionController.text.length} characters.',
        );
      }
      return;
    }
    if (isLoading) return;
    if (user.uid.isEmpty) {
      if (context.mounted) showSnackBar(context, "User information missing");
      return;
    }
    if (!_isVideo && _file == null) {
      if (context.mounted) showSnackBar(context, "Please select media first.");
      return;
    }
    if (_isVideo && _videoFile == null) {
      if (context.mounted)
        showSnackBar(context, "Please select a video first.");
      return;
    }

    await _videoController?.pause();
    if (mounted)
      setState(() {
        isLoading = true;
        _isPlaying = false;
      });

    try {
      final String res;

      if (_isVideo) {
        final Map<String, dynamic>? editJson = widget.editResult?.toJson();

        res = await SupabasePostsMethods().uploadVideoPostFromFile(
          _descriptionController.text,
          _videoFile!,
          user.uid,
          user.username ?? '',
          user.photoUrl ?? '',
          user.gender ?? '',
          editMetadata: editJson,
          reactionEmoji: _selectedEmoji,
        );
      } else {
        res = await SupabasePostsMethods().uploadPost(
          _descriptionController.text,
          _file!,
          user.uid,
          user.username ?? '',
          user.photoUrl ?? '',
          user.gender ?? '',
          reactionEmoji: _selectedEmoji,
        );
      }

      // ─────────────────────────────────────────────────────────────────
      // ✅ Updated: pop both AddPost and CustomCamera to return to profile
      // ─────────────────────────────────────────────────────────────────
      if (res == "success" && context.mounted) {
        setState(() => isLoading = false);
        showSnackBar(context, _isVideo ? 'Video Posted!' : 'Posted!');
        clearMedia();
        widget.onPostUploaded?.call();         // triggers getData() on profile
        // Pop back to the profile screen (pop AddPost then CustomCamera)
        Navigator.of(context).pop();           // removes AddPostScreen
        Navigator.of(context).pop();           // removes CustomCameraScreen
      } else if (context.mounted) {
        setState(() => isLoading = false);
        showSnackBar(context, 'Error: $res');
      }
    } catch (err, stack) {
      setState(() => isLoading = false);
      await _logError(
        operation: 'postMedia/unexpected_exception',
        error: err,
        stack: stack,
      );
      if (context.mounted) showSnackBar(context, err.toString());
    }
  }

  void clearMedia() {
    _videoController?.dispose();
    setState(() {
      _file = null;
      _videoFile = null;
      _videoController = null;
      _isVideoInitialized = false;
      _isPlaying = false;
      _isVideo = false;
      isLoading = false;
      _selectedEmoji = '❤️';
      _descriptionController.clear();
    });
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// Combined colour matrix from the edit result, or identity if none.
  List<double> get _colorMatrix {
    final r = widget.editResult;
    if (r == null) return _kIdentityMatrix;
    return r.adjustments.combinedMatrix(kFilters[r.filterIndex].matrix);
  }

  // ===========================================================================
  // VIDEO PREVIEW
  // ===========================================================================
  Widget _buildVideoPreview() {
    final VideoEditResult? er = widget.editResult;
    final int quarters = er?.rotationQuarters ?? 0;

    return GestureDetector(
      onTap: _toggleVideoPlayback,
      child: SizedBox(
        width: double.infinity,
        height: MediaQuery.of(context).size.height * 0.5,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final double w = constraints.maxWidth;
            final double h = constraints.maxHeight;

            return Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: Container(color: Colors.black)),
                if (_isVideoInitialized && _videoController != null)
                  ColorFiltered(
                    colorFilter: ColorFilter.matrix(_colorMatrix),
                    child: Transform.rotate(
                      angle: quarters * 3.14159265 / 2,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _videoController!.value.aspectRatio,
                          child: VideoPlayer(_videoController!),
                        ),
                      ),
                    ),
                  )
                else
                  const CircularProgressIndicator(color: Colors.white),
                if (er != null && er.strokes.isNotEmpty)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: DrawingPainter(
                          strokes: er.strokes,
                          currentStroke: null,
                        ),
                      ),
                    ),
                  ),
                if (er != null) ..._buildTextOverlays(er, w, h),
                if (_isVideoInitialized && !_isPlaying)
                  IgnorePointer(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.45),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _buildTextOverlays(VideoEditResult er, double w, double h) {
    return er.overlays.map((o) {
      return Positioned(
        left: (o.position.dx * w).clamp(0.0, w - 10),
        top: (o.position.dy * h).clamp(0.0, h - 10),
        child: IgnorePointer(
          child: Stack(clipBehavior: Clip.none, children: [
            Text(o.text, style: overlayShadowStyle(o)),
            Text(o.text, style: overlayTextStyle(o)),
          ]),
        ),
      );
    }).toList();
  }

  // ===========================================================================
  // IMAGE PREVIEW
  // ===========================================================================
  Widget _buildImagePreview() {
    return SizedBox(
      width: double.infinity,
      height: MediaQuery.of(context).size.height * 0.5,
      child: Image.memory(
        _file!,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    );
  }

  // ===========================================================================
  // EMOJI PICKER
  // ===========================================================================

  Widget _buildEmojiPicker() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reaction',
            style: TextStyle(
              color: Colors.white.withOpacity(0.45),
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _availableEmojis.map((emoji) {
                final isSelected = emoji == _selectedEmoji;
                return GestureDetector(
                  onTap: () => setState(() => _selectedEmoji = emoji),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    curve: Curves.easeOut,
                    margin: const EdgeInsets.only(right: 8),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? Colors.white.withOpacity(0.14)
                          : Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isSelected
                            ? Colors.white.withOpacity(0.55)
                            : Colors.transparent,
                        width: 1.5,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        emoji,
                        style: TextStyle(
                          fontSize: isSelected ? 24 : 20,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // CAPTION SECTION
  // ===========================================================================

  Widget _buildPostButton(bool isLoading, VoidCallback onPressed) {
    return IgnorePointer(
      ignoring: isLoading,
      child: TextButton(
        onPressed: isLoading ? null : onPressed,
        child: Text(
          isLoading ? "Posting..." : "Post",
          style: TextStyle(
            color: isLoading ? primaryColor.withOpacity(0.5) : primaryColor,
            fontWeight: FontWeight.bold,
            fontSize: 16.0,
          ),
        ),
      ),
    );
  }

  Widget _buildCaptionInput(AppUser user) {
    final int charCount = _descriptionController.text.length;
    final bool isNearLimit = charCount > 200;
    final bool isOverLimit = charCount > 250;
    final double progress = (charCount / 250).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isOverLimit
              ? Colors.red.withOpacity(0.6)
              : Colors.white.withOpacity(0.08),
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Avatar + text field row ────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Colors.white.withOpacity(0.12),
                      width: 1.5,
                    ),
                  ),
                  child: ClipOval(
                    child: (user.photoUrl?.isNotEmpty == true &&
                            user.photoUrl != 'default')
                        ? Image.network(user.photoUrl!, fit: BoxFit.cover)
                        : Icon(Icons.account_circle,
                            size: 38, color: primaryColor),
                  ),
                ),

                const SizedBox(width: 10),

                // Username + text field stacked
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.username ?? '',
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      TextField(
                        controller: _descriptionController,
                        focusNode: _captionFocusNode,
                        style: TextStyle(
                          color: primaryColor,
                          fontSize: 14,
                          height: 1.45,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Write a caption…',
                          hintStyle: TextStyle(
                            color: Colors.white.withOpacity(0.28),
                            fontSize: 14,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          counterText: '',
                        ),
                        maxLines: 4,
                        minLines: 2,
                        maxLength: 250,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                      ),
                    ],
                  ),
                ),

                // Dismiss keyboard button
                if (_captionFocusNode.hasFocus)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, top: 2),
                    child: GestureDetector(
                      onTap: () => FocusScope.of(context).unfocus(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.09),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Done',
                          style: TextStyle(
                            color: primaryColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // ── Character counter with progress bar ───────────────────────
          if (isNearLimit) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 2,
                  backgroundColor: Colors.white.withOpacity(0.08),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isOverLimit ? Colors.red : Colors.white.withOpacity(0.55),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 10),

          if (isNearLimit)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$charCount / 250',
                  style: TextStyle(
                    color: isOverLimit
                        ? Colors.red
                        : Colors.white.withOpacity(0.38),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 0),
        ],
      ),
    );
  }

  // ===========================================================================
  // BUILD
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final user = Provider.of<UserProvider>(context).user;

    if (user == null) {
      return Scaffold(
        backgroundColor: mobileBackgroundColor,
        body: Center(child: CircularProgressIndicator(color: primaryColor)),
      );
    }

    return Scaffold(
      backgroundColor: mobileBackgroundColor,
      appBar: AppBar(
        iconTheme: IconThemeData(color: primaryColor),
        backgroundColor: mobileBackgroundColor,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: primaryColor),
          onPressed: () {
            clearMedia();
            Navigator.pop(context);
          },
        ),
        title: Text('New Post', style: TextStyle(color: primaryColor)),
        actions: [
          if ((_file != null && !_isVideo) || (_videoFile != null && _isVideo))
            _buildPostButton(isLoading, () => postMedia(user)),
        ],
      ),
      body: _file == null && _videoFile == null
          ? Center(
              child: ScaleTransition(
                scale: _pulseAnimation,
                child: IconButton(
                  icon: Icon(Icons.upload, color: primaryColor, size: 50),
                  onPressed: _onUploadButtonPressed,
                ),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isLoading)
                    LinearProgressIndicator(
                      color: primaryColor,
                      backgroundColor: primaryColor.withOpacity(0.2),
                    ),
                  if (!_isVideo && _file != null) _buildImagePreview(),
                  if (_isVideo && _videoFile != null) _buildVideoPreview(),
                  _buildEmojiPicker(),
                  _buildCaptionInput(user),
                ],
              ),
            ),
    );
  }
}

// =============================================================================
// PERMISSION DENIED SHEET
// =============================================================================

class _PermissionSheet extends StatelessWidget {
  final bool isPermanent;
  final bool needsMic;
  final VoidCallback onOpenGallery;
  final VoidCallback? onOpenSettings;

  const _PermissionSheet({
    required this.isPermanent,
    required this.needsMic,
    required this.onOpenGallery,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final String title =
        needsMic ? 'Camera & Microphone Access' : 'Camera Access';
    final String description = needsMic
        ? 'To record videos, Ratedly needs access to your camera and microphone.'
        : 'To take photos, Ratedly needs access to your camera.';

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1C1C1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(
          24, 0, 24, MediaQuery.of(context).padding.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.07),
              shape: BoxShape.circle,
            ),
            child: Icon(
              needsMic ? Icons.mic_off_rounded : Icons.no_photography_rounded,
              color: Colors.white.withOpacity(0.55),
              size: 30,
            ),
          ),
          const SizedBox(height: 18),
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
              textAlign: TextAlign.center),
          const SizedBox(height: 10),
          Text(description,
              style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 14,
                  height: 1.55),
              textAlign: TextAlign.center),
          const SizedBox(height: 28),
          if (isPermanent && onOpenSettings != null)
            _Btn(
                label: 'Open Settings', isPrimary: true, onTap: onOpenSettings!)
          else
            _Btn(
                label: 'Allow Access',
                isPrimary: true,
                onTap: () => Navigator.pop(context)),
          const SizedBox(height: 10),
          _Btn(
              label: needsMic
                  ? 'Upload Video from Library'
                  : 'Upload Photo from Library',
              isPrimary: false,
              onTap: onOpenGallery),
          const SizedBox(height: 10),
          _Btn(
              label: 'Not Now',
              isPrimary: false,
              isDim: true,
              onTap: () => Navigator.pop(context)),
        ],
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  final String label;
  final bool isPrimary;
  final bool isDim;
  final VoidCallback onTap;

  const _Btn({
    required this.label,
    required this.isPrimary,
    this.isDim = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(
          color: isPrimary
              ? Colors.white
              : Colors.white.withOpacity(isDim ? 0.05 : 0.1),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isPrimary
                  ? Colors.black
                  : Colors.white.withOpacity(isDim ? 0.45 : 0.9),
              fontSize: 15,
              fontWeight: isPrimary ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
