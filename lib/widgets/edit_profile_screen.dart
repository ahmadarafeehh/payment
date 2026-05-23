// lib/screens/edit_profile_screen.dart
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/services/firebase_supabase_service.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/Profile_page/media_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:Ratedly/screens/Profile_page/custom_camera_screen.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';

// =============================================================================
// COLOUR SCHEME (unchanged)
// =============================================================================

class _EditProfileColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color buttonBackgroundColor;
  final Color buttonTextColor;
  final Color borderColor;
  final Color hintTextColor;
  final Color progressIndicatorColor;
  final Color dialogBackgroundColor;
  final Color dialogTextColor;

  _EditProfileColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.buttonBackgroundColor,
    required this.buttonTextColor,
    required this.borderColor,
    required this.hintTextColor,
    required this.progressIndicatorColor,
    required this.dialogBackgroundColor,
    required this.dialogTextColor,
  });
}

class _EditProfileDarkColors extends _EditProfileColorSet {
  _EditProfileDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          buttonBackgroundColor: const Color(0xFF333333),
          buttonTextColor: const Color(0xFFd9d9d9),
          borderColor: const Color(0xFFd9d9d9),
          hintTextColor: const Color(0xFFd9d9d9).withOpacity(0.7),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          dialogBackgroundColor: const Color(0xFF333333),
          dialogTextColor: const Color(0xFFd9d9d9),
        );
}

class _EditProfileLightColors extends _EditProfileColorSet {
  _EditProfileLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.white,
          cardColor: Colors.grey[200]!,
          iconColor: Colors.black,
          buttonBackgroundColor: Colors.grey[300]!,
          buttonTextColor: Colors.black,
          borderColor: Colors.black,
          hintTextColor: Colors.black.withOpacity(0.7),
          progressIndicatorColor: Colors.black,
          dialogBackgroundColor: Colors.grey[200]!,
          dialogTextColor: Colors.black,
        );
}

// =============================================================================
// SCREEN
// =============================================================================

class EditProfileScreen extends StatefulWidget {
  final String? uid;
  const EditProfileScreen({Key? key, this.uid}) : super(key: key);

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final TextEditingController _bioController = TextEditingController();
  final supabase.SupabaseClient _supabase = supabase.Supabase.instance.client;

  // ── Pending media ──────────────────────────────────────────────────────────
  Uint8List? _pendingImageBytes;
  File? _pendingVideoFile;
  VideoEditResult? _pendingVideoEditResult;

  // ── Existing profile data ──────────────────────────────────────────────────
  String? _initialPhotoUrl;
  String? _currentPhotoUrl;
  String? _username;
  String? _countryCode;
  bool _isVerified = false;
  bool _shouldRemoveCurrentMedia = false;

  // ── Profile-video preview player ──────────────────────────────────────────
  VideoPlayerController? _profileVideoController;
  bool _isProfileVideoInitialized = false;

  bool _isLoading = false;
  bool _hasAgreedToWarning = false;

  // ── Resolved UID ──────────────────────────────────────────────────────────
  String? get _resolvedUid {
    if (widget.uid != null && widget.uid!.isNotEmpty) return widget.uid;
    final p = Provider.of<UserProvider>(context, listen: false);
    final id = p.firebaseUid ?? p.supabaseUid;
    if (id != null && id.isNotEmpty) return id;
    return _supabase.auth.currentUser?.id;
  }

  _EditProfileColorSet _getColors(ThemeProvider tp) =>
      tp.themeMode == ThemeMode.dark
          ? _EditProfileDarkColors()
          : _EditProfileLightColors();

  // ==========================================================================
  // HELPERS
  // ==========================================================================

  bool _isVideoUrl(String? url) {
    if (url == null || url == 'default') return false;
    final u = url.toLowerCase();
    return u.endsWith('.mp4') ||
        u.endsWith('.mov') ||
        u.endsWith('.avi') ||
        u.endsWith('.wmv') ||
        u.endsWith('.flv') ||
        u.endsWith('.mkv') ||
        u.endsWith('.webm') ||
        u.endsWith('.m4v') ||
        u.endsWith('.3gp') ||
        u.contains('/video/') ||
        u.contains('video=true');
  }

  /// True when the user has real media set — either a pending pick that hasn't
  /// been saved yet, or a previously saved photo/video URL.
  bool get _hasMedia {
    if (_pendingImageBytes != null) return true;
    if (_pendingVideoFile != null) return true;
    return _currentPhotoUrl != null && _currentPhotoUrl != 'default';
  }

  Widget _buildDefaultAvatar(_EditProfileColorSet colors) => Center(
        child: Icon(Icons.account_circle, size: 96, color: colors.iconColor),
      );

  // ==========================================================================
  // LIFECYCLE
  // ==========================================================================

  @override
  void initState() {
    super.initState();
    _loadUserData();
    _checkIfUserAgreed();
  }

  @override
  void dispose() {
    _bioController.dispose();
    _profileVideoController?.dispose();
    super.dispose();
  }

  // ==========================================================================
  // AGREEMENT
  // ==========================================================================

  Future<void> _checkIfUserAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _hasAgreedToWarning =
        prefs.getBool('hasAgreedToProfileWarning') ?? false);
  }

  Future<void> _saveUserAgreement() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hasAgreedToProfileWarning', true);
    setState(() => _hasAgreedToWarning = true);
  }

  // ==========================================================================
  // DATA LOADING
  // ==========================================================================

  void _loadUserData() async {
    setState(() => _isLoading = true);
    try {
      final uid = _resolvedUid;
      if (uid == null || uid.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('User not authenticated')));
        }
        setState(() => _isLoading = false);
        return;
      }

      final data =
          await _supabase.from('users').select().eq('uid', uid).single();

      setState(() {
        _bioController.text = data['bio'] ?? '';
        _initialPhotoUrl = data['photoUrl'];
        _currentPhotoUrl = _initialPhotoUrl ?? 'default';
        _username = data['username'] ?? 'User';
        _countryCode = data['country']?.toString();
        _isVerified = data['isVerified'] == true;
      });

      if (_currentPhotoUrl != null &&
          _currentPhotoUrl != 'default' &&
          _isVideoUrl(_currentPhotoUrl)) {
        _initializeProfileVideoFromUrl(_currentPhotoUrl!);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error loading profile: $e')));
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _initializeProfileVideoFromUrl(String url) async {
    await _profileVideoController?.dispose();
    try {
      final c = VideoPlayerController.networkUrl(Uri.parse(url),
          videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true));
      await c.initialize();
      await c.setLooping(true);
      await c.play();
      if (mounted) {
        setState(() {
          _profileVideoController = c;
          _isProfileVideoInitialized = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isProfileVideoInitialized = false);
    }
  }

  // ==========================================================================
  // DIRECT CAMERA LAUNCH (photo & video via the same CustomCameraScreen)
  // ==========================================================================

  Future<void> _openCamera() async {
    if (!_hasAgreedToWarning) {
      final agreed = await _showWarningDialog();
      if (agreed != true) return;
      await _saveUserAgreement();
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CustomCameraScreen(
          onImageResult: (Uint8List renderedImage) {
            setState(() {
              _pendingImageBytes = renderedImage;
              _pendingVideoFile = null;
              _pendingVideoEditResult = null;
              _shouldRemoveCurrentMedia = false;
              _profileVideoController?.dispose();
              _profileVideoController = null;
              _isProfileVideoInitialized = false;
            });
          },
          onVideoResult: (VideoEditResult result) {
            setState(() {
              _pendingVideoFile = result.videoFile;
              _pendingVideoEditResult = result;
              _pendingImageBytes = null;
              _shouldRemoveCurrentMedia = false;
              _profileVideoController?.dispose();
              _profileVideoController = null;
              _isProfileVideoInitialized = false;
            });
          },
        ),
      ),
    );
  }

  Future<bool?> _showWarningDialog() async {
    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.cardColor,
        title: Text('Profile Picture Guidelines',
            style: TextStyle(
                color: colors.textColor, fontWeight: FontWeight.bold)),
        content: Text.rich(TextSpan(children: [
          TextSpan(
              text:
                  'Using inappropriate content as your profile picture will get your device ',
              style: TextStyle(color: colors.textColor)),
          const TextSpan(
              text: 'permanently banned',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          TextSpan(text: '.', style: TextStyle(color: colors.textColor)),
        ])),
        actions: [
          TextButton(
            child: Text('I Understand',
                style: TextStyle(
                    color: colors.textColor, fontWeight: FontWeight.bold)),
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // REMOVE MEDIA
  // ==========================================================================

  /// Only called from the edit badge when [_hasMedia] is true.
  void _showRemoveOptions() {
    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.cardColor,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.delete, color: colors.iconColor),
              title: Text('Remove profile media',
                  style: TextStyle(color: colors.textColor)),
              onTap: () {
                Navigator.pop(ctx);
                _removePhoto();
              },
            ),
            ListTile(
              leading: Icon(Icons.cancel, color: colors.iconColor),
              title: Text('Cancel', style: TextStyle(color: colors.textColor)),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  void _removePhoto() {
    final isVideo = _currentPhotoUrl != null &&
        _currentPhotoUrl != 'default' &&
        _isVideoUrl(_currentPhotoUrl!);

    setState(() {
      _pendingImageBytes = null;
      _pendingVideoFile = null;
      _pendingVideoEditResult = null;
      _currentPhotoUrl = 'default';
      _shouldRemoveCurrentMedia = true;
      _profileVideoController?.dispose();
      _profileVideoController = null;
      _isProfileVideoInitialized = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          'Profile ${isVideo ? 'video' : 'picture'} removed. Save to update.'),
      duration: const Duration(seconds: 2),
    ));
  }

  // ==========================================================================
  // SAVE
  // ==========================================================================

  Future<void> _saveProfile() async {
    final uid = _resolvedUid;
    if (uid == null || uid.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('User not authenticated')));
      return;
    }

    if (_bioController.text.length > 250) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Bio cannot exceed 250 characters. Your bio is ${_bioController.text.length} characters.')));
      return;
    }

    setState(() => _isLoading = true);

    final colors =
        _getColors(Provider.of<ThemeProvider>(context, listen: false));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => WillPopScope(
        onWillPop: () async => false,
        child: Dialog(
          backgroundColor: colors.dialogBackgroundColor,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: colors.progressIndicatorColor),
                const SizedBox(height: 16),
                Text('Saving profile…',
                    style:
                        TextStyle(color: colors.dialogTextColor, fontSize: 16)),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final Map<String, dynamic> updatedData = {
        'bio': _bioController.text,
      };

      String? oldMediaToDelete;

      if (_shouldRemoveCurrentMedia &&
          _initialPhotoUrl != null &&
          _initialPhotoUrl != 'default') {
        oldMediaToDelete = _initialPhotoUrl;
      }

      if (_pendingImageBytes != null) {
        final fileName = 'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
        final photoUrl = await StorageMethods().uploadImageToSupabase(
          _pendingImageBytes!,
          fileName,
          useUserFolder: true,
        );
        updatedData['photoUrl'] = photoUrl;
        if (_initialPhotoUrl != null &&
            _initialPhotoUrl != 'default' &&
            _initialPhotoUrl!.contains('supabase.co/storage')) {
          oldMediaToDelete = _initialPhotoUrl;
        }
      } else if (_pendingVideoFile != null) {
        final fileName =
            'profile_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        final videoBytes = await _pendingVideoFile!.readAsBytes();
        final videoUrl = await StorageMethods().uploadVideoToSupabase(
          videoBytes,
          fileName,
          useUserFolder: true,
        );
        updatedData['photoUrl'] = videoUrl;
        if (_initialPhotoUrl != null &&
            _initialPhotoUrl != 'default' &&
            _initialPhotoUrl!.contains('supabase.co/storage')) {
          oldMediaToDelete = _initialPhotoUrl;
        }
      } else if (_shouldRemoveCurrentMedia) {
        updatedData['photoUrl'] = 'default';
      }

      await FirebaseSupabaseService.update(
        'users',
        updates: updatedData,
        filters: {'uid': uid},
      );

      if (oldMediaToDelete != null &&
          oldMediaToDelete.contains('supabase.co/storage')) {
        _deleteOldMediaInBackground(oldMediaToDelete);
      }

      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog

        setState(() {
          if (updatedData.containsKey('photoUrl')) {
            _initialPhotoUrl = updatedData['photoUrl'];
          }
          _currentPhotoUrl = _initialPhotoUrl;
          _pendingImageBytes = null;
          _pendingVideoFile = null;
          _pendingVideoEditResult = null;
          _shouldRemoveCurrentMedia = false;
        });

        if (updatedData.containsKey('photoUrl') &&
            updatedData['photoUrl'] != 'default' &&
            _isVideoUrl(updatedData['photoUrl'])) {
          await _initializeProfileVideoFromUrl(updatedData['photoUrl']);
        }

        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile updated successfully!')));

        Navigator.pop(context, {
          'bio': _bioController.text,
          'photoUrl': updatedData['photoUrl'] ?? _initialPhotoUrl,
        });
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to update profile: $e')));
      }
    }

    if (mounted) setState(() => _isLoading = false);
  }

  void _deleteOldMediaInBackground(String mediaUrl) {
    Future.delayed(Duration.zero, () async {
      try {
        if (_isVideoUrl(mediaUrl)) {
          final uri = Uri.parse(mediaUrl);
          final segs = uri.pathSegments;
          final idx = segs.indexOf('videos');
          if (idx != -1 && idx < segs.length - 1) {
            final path = segs.sublist(idx + 1).join('/');
            await StorageMethods().deleteVideoFromSupabase('videos', path);
          }
        } else {
          await StorageMethods().deleteImage(mediaUrl);
        }
      } catch (_) {}
    });
  }

  // ==========================================================================
  // PROFILE IMAGE PREVIEW
  // ==========================================================================

  Widget _buildProfileImage(_EditProfileColorSet colors) {
    if (_pendingImageBytes != null) {
      return ClipOval(
        child: Image.memory(_pendingImageBytes!,
            width: 100, height: 100, fit: BoxFit.cover),
      );
    }

    if (_pendingVideoFile != null && _pendingVideoEditResult != null) {
      return ClipOval(
        child: ColorFiltered(
          colorFilter: ColorFilter.matrix(
            _pendingVideoEditResult!.adjustments.combinedMatrix(
                kFilters[_pendingVideoEditResult!.filterIndex].matrix),
          ),
          child: Container(
            width: 100,
            height: 100,
            color: Colors.black,
            child: const Center(
              child: Icon(Icons.videocam, size: 40, color: Colors.white54),
            ),
          ),
        ),
      );
    }

    if (_currentPhotoUrl != null && _currentPhotoUrl != 'default') {
      if (_isVideoUrl(_currentPhotoUrl)) {
        return _buildExistingVideoPreview(colors);
      }
      return ClipOval(
        child: Image.network(
          _currentPhotoUrl!,
          width: 100,
          height: 100,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _buildDefaultAvatar(colors),
          loadingBuilder: (_, child, progress) => progress == null
              ? child
              : Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle, color: colors.cardColor),
                  child: Center(
                      child: CircularProgressIndicator(
                          color: colors.progressIndicatorColor)),
                ),
        ),
      );
    }

    return _buildDefaultAvatar(colors);
  }

  Widget _buildExistingVideoPreview(_EditProfileColorSet colors) {
    if (_profileVideoController == null || !_isProfileVideoInitialized) {
      return Container(
        width: 100,
        height: 100,
        decoration:
            BoxDecoration(shape: BoxShape.circle, color: colors.cardColor),
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 100,
        height: 100,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _profileVideoController!.value.size.width,
            height: _profileVideoController!.value.size.height,
            child: VideoPlayer(_profileVideoController!),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // BUILD
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final uid = _resolvedUid;

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        iconTheme: IconThemeData(color: colors.iconColor),
        title: Text('Edit Profile', style: TextStyle(color: colors.textColor)),
        centerTitle: true,
        backgroundColor: colors.backgroundColor,
        elevation: 0,
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor))
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (uid != null && _username != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 20),
                      child: VerifiedUsernameWidget(
                        username: _username!,
                        uid: uid,
                        countryCode: _countryCode,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: colors.textColor,
                        ),
                      ),
                    ),

                  // ── Avatar / media selector ──────────────────────────────
                  Center(
                    child: Stack(
                      children: [
                        // Tap the avatar to open camera directly.
                        GestureDetector(
                          onTap: _openCamera,
                          child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              color: colors.cardColor,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: colors.borderColor, width: 2),
                            ),
                            child: ClipOval(child: _buildProfileImage(colors)),
                          ),
                        ),

                        // Edit badge:
                        //   • No media set  → opens camera (same as tapping avatar)
                        //   • Media is set  → shows remove-media sheet
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onTap: _hasMedia ? _showRemoveOptions : _openCamera,
                            child: Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: colors.cardColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: colors.backgroundColor, width: 2),
                              ),
                              child: Icon(Icons.edit,
                                  size: 14, color: colors.iconColor),
                            ),
                          ),
                        ),

                        // Video badge on existing profile video.
                        if (_currentPhotoUrl != null &&
                            _currentPhotoUrl != 'default' &&
                            _isVideoUrl(_currentPhotoUrl) &&
                            _pendingImageBytes == null &&
                            _pendingVideoFile == null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.videocam,
                                  size: 12, color: Colors.white),
                            ),
                          ),

                        // Video badge on pending video.
                        if (_pendingVideoFile != null)
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(
                                  color: Colors.black54,
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.videocam,
                                  size: 12, color: Colors.white),
                            ),
                          ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // ── Bio field ────────────────────────────────────────────
                  TextField(
                    controller: _bioController,
                    decoration: InputDecoration(
                      labelText: 'Bio',
                      labelStyle: TextStyle(color: colors.textColor),
                      hintText: 'Write something about yourself…',
                      hintStyle: TextStyle(color: colors.hintTextColor),
                      border: OutlineInputBorder(
                          borderSide: BorderSide(color: colors.borderColor)),
                      enabledBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: colors.borderColor)),
                      focusedBorder: OutlineInputBorder(
                          borderSide: BorderSide(color: colors.borderColor)),
                      filled: true,
                      fillColor: colors.cardColor,
                    ),
                    style: TextStyle(color: colors.textColor),
                    maxLines: 3,
                    maxLength: 250,
                  ),

                  const SizedBox(height: 20),

                  ElevatedButton(
                    onPressed: _saveProfile,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.buttonBackgroundColor,
                      foregroundColor: colors.buttonTextColor,
                    ),
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
    );
  }
}
