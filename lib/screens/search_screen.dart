import 'dart:io'; // For File class used in VideoEditResult.fromJson
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/screens/Profile_page/image_screen.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/providers/user_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// INLINE DEFINITIONS (normally from edit_shared.dart)
// ─────────────────────────────────────────────────────────────────────────────

class FilterAdjustments {
  final double brightness;
  final double contrast;
  final double saturation;

  FilterAdjustments({
    this.brightness = 0.0,
    this.contrast = 1.0,
    this.saturation = 1.0,
  });

  List<double> combinedMatrix(List<double> baseMatrix) {
    final b = brightness;
    final c = contrast;
    final s = saturation;

    return [
      c * s,
      0,
      0,
      0,
      b,
      0,
      c * s,
      0,
      0,
      b,
      0,
      0,
      c * s,
      0,
      b,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
      };

  factory FilterAdjustments.fromJson(Map<String, dynamic> json) =>
      FilterAdjustments(
        brightness: (json['brightness'] as num?)?.toDouble() ?? 0.0,
        contrast: (json['contrast'] as num?)?.toDouble() ?? 1.0,
        saturation: (json['saturation'] as num?)?.toDouble() ?? 1.0,
      );
}

class FilterInfo {
  final String name;
  final List<double> matrix;
  const FilterInfo({required this.name, required this.matrix});
}

const List<FilterInfo> kFilters = [
  FilterInfo(name: 'Original', matrix: [
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
  ]),
];

class DrawStroke {
  final List<Offset> points;
  final Color color;
  final double width;
  final bool isEraser;

  DrawStroke({
    required this.points,
    required this.color,
    required this.width,
    this.isEraser = false,
  });

  Map<String, dynamic> toJson() => {
        'points': points.map((p) => {'dx': p.dx, 'dy': p.dy}).toList(),
        'color': color.value,
        'width': width,
        'isEraser': isEraser,
      };

  factory DrawStroke.fromJson(Map<String, dynamic> json) => DrawStroke(
        points: (json['points'] as List)
            .map((p) => Offset(p['dx'] as double, p['dy'] as double))
            .toList(),
        color: Color(json['color'] as int),
        width: (json['width'] as num).toDouble(),
        isEraser: json['isEraser'] as bool? ?? false,
      );
}

class TextOverlay {
  final String text;
  final Offset position;
  final Color color;
  final double fontSize;
  final String fontFamily;

  TextOverlay({
    required this.text,
    required this.position,
    required this.color,
    required this.fontSize,
    this.fontFamily = 'Roboto',
  });

  TextOverlay copyWith({double? fontSize}) => TextOverlay(
        text: text,
        position: position,
        color: color,
        fontSize: fontSize ?? this.fontSize,
        fontFamily: fontFamily,
      );

  Map<String, dynamic> toJson() => {
        'text': text,
        'dx': position.dx,
        'dy': position.dy,
        'color': color.value,
        'fontSize': fontSize,
        'fontFamily': fontFamily,
      };

  factory TextOverlay.fromJson(Map<String, dynamic> json) => TextOverlay(
        text: json['text'] as String,
        position: Offset(
            (json['dx'] as num).toDouble(), (json['dy'] as num).toDouble()),
        color: Color(json['color'] as int),
        fontSize: (json['fontSize'] as num).toDouble(),
        fontFamily: json['fontFamily'] as String? ?? 'Roboto',
      );
}

class VideoEditResult {
  final FilterAdjustments adjustments;
  final int filterIndex;
  final int rotationQuarters;
  final List<DrawStroke> strokes;
  final List<TextOverlay> overlays;
  final File file;

  VideoEditResult({
    required this.adjustments,
    required this.filterIndex,
    required this.rotationQuarters,
    required this.strokes,
    required this.overlays,
    required this.file,
  });

  Map<String, dynamic> toJson() => {
        'adjustments': adjustments.toJson(),
        'filterIndex': filterIndex,
        'rotationQuarters': rotationQuarters,
        'strokes': strokes.map((s) => s.toJson()).toList(),
        'overlays': overlays.map((o) => o.toJson()).toList(),
      };

  factory VideoEditResult.fromJson(Map<String, dynamic> json, File file) =>
      VideoEditResult(
        adjustments: FilterAdjustments.fromJson(
            json['adjustments'] as Map<String, dynamic>),
        filterIndex: json['filterIndex'] as int,
        rotationQuarters: json['rotationQuarters'] as int? ?? 0,
        strokes: (json['strokes'] as List? ?? [])
            .map((s) => DrawStroke.fromJson(s as Map<String, dynamic>))
            .toList(),
        overlays: (json['overlays'] as List? ?? [])
            .map((o) => TextOverlay.fromJson(o as Map<String, dynamic>))
            .toList(),
        file: file,
      );
}

TextStyle overlayTextStyle(TextOverlay overlay) => TextStyle(
      color: overlay.color,
      fontSize: overlay.fontSize,
      fontFamily: overlay.fontFamily,
    );

TextStyle overlayShadowStyle(TextOverlay overlay) => TextStyle(
      color: Colors.black.withOpacity(0.5),
      fontSize: overlay.fontSize,
      fontFamily: overlay.fontFamily,
    );

class DrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final DrawStroke? currentStroke;

  DrawingPainter({required this.strokes, this.currentStroke});

  @override
  void paint(Canvas canvas, Size size) {
    for (final stroke in strokes) {
      _drawStroke(canvas, stroke);
    }
    if (currentStroke != null) {
      _drawStroke(canvas, currentStroke!);
    }
  }

  void _drawStroke(Canvas canvas, DrawStroke stroke) {
    if (stroke.points.isEmpty) return;
    final paint = Paint()
      ..color = stroke.isEraser ? Colors.transparent : stroke.color
      ..strokeWidth = stroke.width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..blendMode = stroke.isEraser ? BlendMode.clear : BlendMode.srcOver;
    for (int i = 0; i < stroke.points.length - 1; i++) {
      canvas.drawLine(stroke.points[i], stroke.points[i + 1], paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrawingPainter oldDelegate) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// END INLINE DEFINITIONS
// ─────────────────────────────────────────────────────────────────────────────

class _SearchColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color dividerColor;
  final Color progressIndicatorColor;
  final Color errorColor;
  final Color gridBackgroundColor;
  final Color gridItemBackgroundColor;
  final Color appBarBackgroundColor;
  final Color hintTextColor;
  final Color borderColor;
  final Color focusedBorderColor;
  final Color skeletonColor;
  final Color avatarBackgroundColor;

  _SearchColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.dividerColor,
    required this.progressIndicatorColor,
    required this.errorColor,
    required this.gridBackgroundColor,
    required this.gridItemBackgroundColor,
    required this.appBarBackgroundColor,
    required this.hintTextColor,
    required this.borderColor,
    required this.focusedBorderColor,
    required this.skeletonColor,
    required this.avatarBackgroundColor,
  });
}

class _SearchDarkColors extends _SearchColorSet {
  _SearchDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF121212),
          iconColor: const Color(0xFFd9d9d9),
          dividerColor: const Color(0xFF333333),
          progressIndicatorColor: const Color(0xFFd9d9d9),
          errorColor: Colors.red,
          gridBackgroundColor: const Color(0xFF121212),
          gridItemBackgroundColor: const Color(0xFF333333),
          appBarBackgroundColor: const Color(0xFF121212),
          hintTextColor: const Color(0xFF666666),
          borderColor: const Color(0xFF333333),
          focusedBorderColor: const Color(0xFFd9d9d9),
          skeletonColor: const Color(0xFF333333).withOpacity(0.6),
          avatarBackgroundColor: const Color(0xFF333333),
        );
}

class _SearchLightColors extends _SearchColorSet {
  _SearchLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
          dividerColor: Colors.grey[300]!,
          progressIndicatorColor: Colors.grey[700]!,
          errorColor: Colors.red,
          gridBackgroundColor: Colors.grey[100]!,
          gridItemBackgroundColor: Colors.grey[300]!,
          appBarBackgroundColor: Colors.grey[100]!,
          hintTextColor: Colors.grey[600]!,
          borderColor: Colors.grey[400]!,
          focusedBorderColor: Colors.black,
          skeletonColor: Colors.grey[300]!.withOpacity(0.6),
          avatarBackgroundColor: Colors.grey[300]!,
        );
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({Key? key}) : super(key: key);

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with WidgetsBindingObserver {
  final TextEditingController searchController = TextEditingController();
  final _supabase = Supabase.instance.client;
  bool isShowUsers = false;
  bool _isSearchFocused = false;
  String? currentUserId;

  List<Map<String, dynamic>> _allPosts = [];
  Set<String> blockedUsersSet = {};
  bool _isLoading = true;

  int _offset = 0;
  bool _isLoadingMore = false;
  bool _hasMorePosts = true;
  bool _isFirstLoad = true;

  final int _initialPostsLimit = 12;
  final int _subsequentPostsLimit = 6;
  final int _initialPostsToShow = 12;

  final ScrollController _scrollController = ScrollController();

  List<String> _rotatedSuggestedUsers = [];
  final Random _random = Random();

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  final Map<String, VideoPlayerController> _avatarVideoControllers = {};
  final Map<String, bool> _avatarVideoControllersInitialized = {};

  _SearchColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? _SearchDarkColors()
        : _SearchLightColors();
  }

  Map<String, dynamic>? _extractEditMetadata(dynamic raw) {
    if (raw == null) return null;
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return null;
  }

  VideoEditResult? _parseEditResult(Map<String, dynamic> post) {
    final meta = _extractEditMetadata(post['video_edit_metadata']);
    if (meta == null) return null;
    try {
      return VideoEditResult.fromJson(meta, File(''));
    } catch (_) {
      return null;
    }
  }

  List<double> _buildColorMatrix(VideoEditResult? er) {
    if (er == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return er.adjustments.combinedMatrix(kFilters[er.filterIndex].matrix);
  }

  Widget _buildEditOverlayLayer(
      VideoEditResult editResult, BoxConstraints constraints) {
    if (editResult.strokes.isEmpty && editResult.overlays.isEmpty) {
      return const SizedBox.shrink();
    }

    final double previewW = constraints.maxWidth;
    final double previewH = constraints.maxHeight;
    final double screenW = MediaQuery.of(context).size.width;
    final double screenH = MediaQuery.of(context).size.height;
    final double scaleX = previewW / screenW;
    final double scaleY = previewH / screenH;
    final double fontScale = min(scaleX, scaleY);

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        if (editResult.strokes.isNotEmpty)
          Positioned.fill(
            child: CustomPaint(
              painter: _ScaledDrawingPainter(
                strokes: editResult.strokes,
                scaleX: scaleX,
                scaleY: scaleY,
              ),
            ),
          ),
        ...editResult.overlays.map((o) {
          final scaledOverlay = o.copyWith(fontSize: o.fontSize * fontScale);
          return Positioned(
            left: (o.position.dx * previewW).clamp(0.0, previewW - 10),
            top: (o.position.dy * previewH).clamp(0.0, previewH - 10),
            child: Stack(clipBehavior: Clip.none, children: [
              Text(o.text, style: overlayShadowStyle(scaledOverlay)),
              Text(o.text, style: overlayTextStyle(scaledOverlay)),
            ]),
          );
        }),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoadingMore &&
          _hasMorePosts &&
          !isShowUsers) {
        _loadMorePosts();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    if (userProvider.firebaseUid != null && currentUserId == null) {
      currentUserId = userProvider.firebaseUid;
      if (!_isLoading) _initData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        currentUserId == null) {
      currentUserId = userProvider.supabaseUid;
      if (!_isLoading) _initData();
    }

    if (currentUserId != null && _isLoading) _initData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseAllVideos();
    }
  }

  void _pauseAllVideos() {
    for (final c in _videoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
    for (final c in _avatarVideoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    searchController.dispose();
    _scrollController.dispose();
    for (final c in _videoControllers.values) {
      c.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    for (final c in _avatarVideoControllers.values) {
      c.dispose();
    }
    _avatarVideoControllers.clear();
    _avatarVideoControllersInitialized.clear();
    super.dispose();
  }

  // ========== VIDEO CONTROLLERS ==========
  Future<void> _initializeVideoController(String videoUrl) async {
    if (_videoControllers.containsKey(videoUrl) ||
        _videoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _videoControllers[videoUrl] = controller;
      _videoControllersInitialized[videoUrl] = false;
      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_videoControllersInitialized[videoUrl]!) {
          _videoControllersInitialized[videoUrl] = true;
          _configureVideoLoop(controller);
          if (mounted) setState(() {});
        }
      });
      await controller.initialize();
      await controller.setVolume(0.0);
    } catch (_) {
      _videoControllers.remove(videoUrl)?.dispose();
      _videoControllersInitialized.remove(videoUrl);
    }
  }

  Future<void> _initializeAvatarVideoController(String videoUrl) async {
    if (_avatarVideoControllers.containsKey(videoUrl) ||
        _avatarVideoControllersInitialized[videoUrl] == true) return;
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      _avatarVideoControllers[videoUrl] = controller;
      _avatarVideoControllersInitialized[videoUrl] = false;
      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_avatarVideoControllersInitialized[videoUrl]!) {
          _avatarVideoControllersInitialized[videoUrl] = true;
          _configureVideoLoop(controller);
          if (mounted) setState(() {});
        }
      });
      await controller.initialize();
      await controller.setVolume(0.0);
    } catch (_) {
      _avatarVideoControllers.remove(videoUrl)?.dispose();
      _avatarVideoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureVideoLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) controller.seekTo(Duration.zero);
      }
    });
    controller.play();
  }

  VideoPlayerController? _getVideoController(String url) =>
      _videoControllers[url];
  bool _isVideoControllerInitialized(String url) =>
      _videoControllersInitialized[url] == true;
  VideoPlayerController? _getAvatarVideoController(String url) =>
      _avatarVideoControllers[url];
  bool _isAvatarVideoControllerInitialized(String url) =>
      _avatarVideoControllersInitialized[url] == true;

  bool _isVideoFile(String url) {
    if (url.isEmpty) return false;
    final l = url.toLowerCase();
    return l.endsWith('.mp4') ||
        l.endsWith('.mov') ||
        l.endsWith('.avi') ||
        l.endsWith('.wmv') ||
        l.endsWith('.flv') ||
        l.endsWith('.mkv') ||
        l.endsWith('.webm') ||
        l.endsWith('.m4v') ||
        l.endsWith('.3gp') ||
        l.contains('/video/') ||
        l.contains('video=true');
  }

  Widget _buildVideoPlayer(String videoUrl, _SearchColorSet colors,
      [VideoEditResult? editResult]) {
    if (!_videoControllers.containsKey(videoUrl)) {
      _initializeVideoController(videoUrl);
    }
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        color: colors.gridItemBackgroundColor,
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }

    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return AspectRatio(
      aspectRatio: 0.75,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: colors.gridItemBackgroundColor,
          child: Stack(fit: StackFit.expand, children: [
            Positioned.fill(
              child: ColorFiltered(
                colorFilter: ColorFilter.matrix(matrix),
                child: Transform.rotate(
                  angle: quarters * pi / 2,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: controller.value.size.width,
                      height: controller.value.size.height,
                      child: VideoPlayer(controller),
                    ),
                  ),
                ),
              ),
            ),
            if (editResult != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        _buildEditOverlayLayer(editResult, constraints),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildPostImage(String imageUrl, _SearchColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    Widget baseImage = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: editResult == null
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return Center(
                    child: CircularProgressIndicator(
                        color: colors.progressIndicatorColor));
              },
              errorBuilder: (_, __, ___) => Container(
                color: colors.gridItemBackgroundColor,
                child: Icon(Icons.broken_image, color: colors.iconColor),
              ),
            )
          : ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: Transform.rotate(
                angle: quarters * pi / 2,
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.cover,
                  loadingBuilder: (_, child, progress) {
                    if (progress == null) return child;
                    return Center(
                        child: CircularProgressIndicator(
                            color: colors.progressIndicatorColor));
                  },
                  errorBuilder: (_, __, ___) => Container(
                    color: colors.gridItemBackgroundColor,
                    child: Icon(Icons.broken_image, color: colors.iconColor),
                  ),
                ),
              ),
            ),
    );

    if (editResult == null) {
      return AspectRatio(aspectRatio: 0.75, child: baseImage);
    }

    return AspectRatio(
      aspectRatio: 0.75,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(fit: StackFit.expand, children: [
          Positioned.fill(child: baseImage),
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _buildEditOverlayLayer(editResult, constraints),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildAvatarVideoPlayer(String videoUrl, _SearchColorSet colors) {
    final controller = _getAvatarVideoController(videoUrl);
    final isInitialized = _isAvatarVideoControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        decoration: BoxDecoration(
            shape: BoxShape.circle, color: colors.avatarBackgroundColor),
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor, strokeWidth: 2.0)),
      );
    }
    return ClipOval(
      child: SizedBox(
        width: 40,
        height: 40,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  Widget _buildUserAvatar(String? photoUrl, _SearchColorSet colors) {
    final url = photoUrl?.toString() ?? '';
    final isDefault = url.isEmpty || url == 'default';
    final isVideo = !isDefault && _isVideoFile(url);

    if (isDefault) {
      return CircleAvatar(
        backgroundColor: colors.avatarBackgroundColor,
        radius: 20,
        child: Icon(Icons.account_circle, size: 40, color: colors.iconColor),
      );
    }
    if (isVideo) {
      if (!_avatarVideoControllers.containsKey(url)) {
        _initializeAvatarVideoController(url);
      }
      return _buildAvatarVideoPlayer(url, colors);
    }
    return CircleAvatar(
      backgroundColor: colors.avatarBackgroundColor,
      radius: 20,
      backgroundImage: NetworkImage(url),
    );
  }

  // ========== DATA LOADING ==========
  Future<void> _initData() async {
    if (currentUserId == null) {
      setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);

    await Future.wait([
      _loadBlockedUsers(),
      _fetchPosts(),
    ]);
    _rotateSuggestedUsers();
    setState(() => _isLoading = false);
  }

  Future<void> _loadBlockedUsers() async {
    if (currentUserId == null) {
      blockedUsersSet = {};
      return;
    }
    try {
      final response = await _supabase
          .from('users')
          .select('blockedUsers')
          .eq('uid', currentUserId!)
          .single();
      final blockedUsers = response['blockedUsers'] as List<dynamic>?;
      blockedUsersSet = Set<String>.from(blockedUsers ?? []);
    } catch (_) {
      blockedUsersSet = {};
    }
  }

  Future<void> _fetchPosts() async {
    if (currentUserId == null) {
      _allPosts = [];
      _hasMorePosts = false;
      _isFirstLoad = false;
      return;
    }
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final postsLimit =
          _isFirstLoad ? _initialPostsLimit : _subsequentPostsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': 0,
        'page_limit': postsLimit,
      });

      if (response is List && response.isNotEmpty) {
        _allPosts = response.map<Map<String, dynamic>>((post) {
          final Map<String, dynamic> converted = {};
          (post as Map).forEach((k, v) => converted[k.toString()] = v);
          return converted;
        }).toList();

        for (final post in _allPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }

        _offset = _allPosts.length;
        _hasMorePosts = _allPosts.length == postsLimit;
        _isFirstLoad = false;
      } else {
        _allPosts = [];
        _hasMorePosts = false;
        _isFirstLoad = false;
      }
    } catch (_) {
      _allPosts = [];
      _hasMorePosts = false;
      _isFirstLoad = false;
    }
  }

  Future<void> _loadMorePosts() async {
    if (!_hasMorePosts || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final postsLimit = _subsequentPostsLimit;
      final pageNumber = _offset ~/ postsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': pageNumber,
        'page_limit': postsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts = response.map<Map<String, dynamic>>((post) {
          final Map<String, dynamic> converted = {};
          (post as Map).forEach((k, v) => converted[k.toString()] = v);
          return converted;
        }).toList();

        for (final post in newPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }

        setState(() {
          _allPosts.addAll(newPosts);
          _offset += newPosts.length;
          _hasMorePosts = newPosts.length == _subsequentPostsLimit;
        });
      } else {
        setState(() => _hasMorePosts = false);
      }
    } catch (_) {
      setState(() => _hasMorePosts = false);
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  void _rotateSuggestedUsers() {
    if (currentUserId == null) {
      _rotatedSuggestedUsers = [];
      return;
    }
    final suggestedUserIds = _allPosts
        .map((p) => p['uid']?.toString())
        .whereType<String>()
        .where((uid) => !blockedUsersSet.contains(uid) && uid != currentUserId)
        .toSet()
        .toList();

    if (suggestedUserIds.isEmpty) {
      _rotatedSuggestedUsers = [];
      return;
    }
    suggestedUserIds.shuffle(_random);
    _rotatedSuggestedUsers = suggestedUserIds.take(5).toList();
  }

  void _navigateToProfile(String uid) {
    if (uid.isEmpty) return;
    _pauseAllVideos();
    Navigator.push(
            context, MaterialPageRoute(builder: (_) => ProfileScreen(uid: uid)))
        .then((_) {
      if (mounted) {
        setState(() {
          isShowUsers = false;
          searchController.clear();
        });
      }
    });
  }

  Future<List<Map<String, dynamic>>> _fetchUsersByIds(
      List<String> userIds) async {
    if (userIds.isEmpty) return [];
    try {
      final response =
          await _supabase.from('users').select().inFilter('uid', userIds);
      return List<Map<String, dynamic>>.from(response).where((u) {
        final id = u['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(id) && id != currentUserId;
      }).toList();
    } catch (_) {
      return [];
    }
  }

  // ========== USER SEARCH DISABLED ==========
  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    return [];
  }

  // ========== SKELETONS ==========
  Widget _buildPostsGridSkeleton(_SearchColorSet colors) {
    return ListView(
      padding: const EdgeInsets.all(8.0),
      children: [
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8.0,
              mainAxisSpacing: 8.0,
              childAspectRatio: 0.75),
          itemCount: _initialPostsToShow,
          itemBuilder: (_, __) => _buildPostSkeleton(colors),
        ),
      ],
    );
  }

  Widget _buildPostSkeleton(_SearchColorSet colors) => Container(
        decoration: BoxDecoration(
            color: colors.skeletonColor,
            borderRadius: BorderRadius.circular(8)),
      );

  Widget _buildUserSkeleton(_SearchColorSet colors) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: CircleAvatar(backgroundColor: colors.skeletonColor, radius: 20),
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
            height: 14,
            width: 120,
            decoration: BoxDecoration(
                color: colors.skeletonColor,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(
            height: 12,
            width: 80,
            decoration: BoxDecoration(
                color: colors.skeletonColor.withOpacity(0.7),
                borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }

  Widget _buildUserSearchSkeleton(_SearchColorSet colors) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 5,
      itemBuilder: (_, __) => _buildUserSkeleton(colors),
    );
  }

  // ========== BUILD ==========
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    if (currentUserId == null) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      if (userProvider.firebaseUid != null && currentUserId == null) {
        currentUserId = userProvider.firebaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      } else if (userProvider.firebaseUid == null &&
          userProvider.supabaseUid != null &&
          currentUserId == null) {
        currentUserId = userProvider.supabaseUid;
        if (!_isLoading) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _initData();
          });
        }
      }
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        backgroundColor: colors.appBarBackgroundColor,
        toolbarHeight: 80,
        elevation: 0,
        iconTheme: IconThemeData(color: colors.iconColor),
        title: Padding(
          padding: const EdgeInsets.only(top: 8.0),
          child: SizedBox(
            height: 48,
            child: TextFormField(
              controller: searchController,
              style: TextStyle(color: colors.textColor),
              decoration: InputDecoration(
                hintText: 'Search for a user...',
                hintStyle: TextStyle(color: colors.hintTextColor),
                filled: true,
                fillColor: colors.cardColor,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.borderColor),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide:
                      BorderSide(color: colors.focusedBorderColor, width: 2),
                  borderRadius: const BorderRadius.all(Radius.circular(4)),
                ),
              ),
              onTap: () {
                if (searchController.text.trim().isEmpty) {
                  setState(() {
                    isShowUsers = false;
                    _isSearchFocused = true;
                  });
                }
              },
              onChanged: (value) {
                setState(() {
                  isShowUsers = value.trim().isNotEmpty;
                  _isSearchFocused = false;
                });
              },
              onFieldSubmitted: (_) {
                setState(() {
                  isShowUsers = true;
                  _isSearchFocused = false;
                });
              },
            ),
          ),
        ),
      ),
      body: _isLoading
          ? _buildEnhancedSkeletonLoading(colors)
          : Column(children: [
              Expanded(
                child: _isSearchFocused && searchController.text.trim().isEmpty
                    ? _buildPostsGrid(colors)
                    : isShowUsers
                        ? _buildUserSearch(colors)
                        : _buildPostsGrid(colors),
              ),
            ]),
    );
  }

  Widget _buildEnhancedSkeletonLoading(_SearchColorSet colors) {
    return Column(children: [
      Expanded(
        child: _buildPostsGridSkeleton(colors),
      ),
    ]);
  }

  // ========== USER SEARCH DISABLED - returns no results ==========
  Widget _buildUserSearch(_SearchColorSet colors) {
    return Center(
      child: Text(
        'No users found.',
        style: TextStyle(color: colors.textColor),
      ),
    );
  }

  // ========== SIMPLIFIED POSTS GRID - NO TOP POSTS SECTION ==========
  Widget _buildPostsGrid(_SearchColorSet colors) {
    if (_allPosts.isEmpty) {
      return Center(
          child: Text('No posts found.',
              style: TextStyle(color: colors.textColor)));
    }

    return Stack(children: [
      NotificationListener<ScrollNotification>(
        onNotification: (scrollInfo) {
          if (scrollInfo.metrics.extentAfter < 500 &&
              !_isLoadingMore &&
              _hasMorePosts &&
              !isShowUsers) {
            _loadMorePosts();
          }
          return false;
        },
        child: GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(8.0),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 0.75,
              crossAxisSpacing: 8.0,
              mainAxisSpacing: 8.0),
          itemCount: _allPosts.length,
          itemBuilder: (context, index) {
            final post = _allPosts[index];
            final postUrl = post['postUrl']?.toString() ?? '';
            return _buildPostItem(post, postUrl, colors);
          },
        ),
      ),
      if (_isLoadingMore)
        Positioned(
          bottom: 8,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: colors.backgroundColor.withOpacity(0.8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: CircularProgressIndicator(
                  color: colors.progressIndicatorColor),
            ),
          ),
        ),
    ]);
  }

  Widget _buildPostItem(Map<String, dynamic> post, String postUrl,
      _SearchColorSet colors) {
    final isVideo = _isVideoFile(postUrl);
    if (isVideo) _initializeVideoController(postUrl);

    final editResult = _parseEditResult(post);

    return InkWell(
      onTap: () async {
        final userId = post['uid']?.toString() ?? '';
        if (userId.isEmpty) return;
        _pauseAllVideos();
        final user = await _fetchUserById(userId);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ImageViewScreen(
              imageUrl: postUrl,
              postId: post['postId']?.toString() ?? '',
              description: post['description']?.toString() ?? '',
              userId: userId,
              username: user?['username']?.toString() ?? '',
              profImage: user?['photoUrl']?.toString() ?? '',
              datePublished: post['datePublished']?.toString() ?? '',
              videoEditMetadata:
                  _extractEditMetadata(post['video_edit_metadata']),
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: isVideo ? colors.gridItemBackgroundColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.hardEdge,
        child: postUrl.isNotEmpty
            ? (isVideo
                ? _buildVideoPlayer(postUrl, colors, editResult)
                : _buildPostImage(postUrl, colors, editResult))
            : Container(
                color: colors.gridItemBackgroundColor,
                child: Icon(Icons.broken_image, color: colors.iconColor),
              ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _fetchUserById(String userId) async {
    if (userId.isEmpty) return null;
    try {
      final response = await _supabase
          .from('users')
          .select()
          .eq('uid', userId)
          .maybeSingle();
      return response as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }
}

// =============================================================================
// SCALED DRAWING PAINTER
// =============================================================================
class _ScaledDrawingPainter extends CustomPainter {
  final List<DrawStroke> strokes;
  final double scaleX;
  final double scaleY;

  const _ScaledDrawingPainter({
    required this.strokes,
    required this.scaleX,
    required this.scaleY,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(scaleX, scaleY);
    DrawingPainter(strokes: strokes, currentStroke: null)
        .paint(canvas, Size(size.width / scaleX, size.height / scaleY));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScaledDrawingPainter old) =>
      old.strokes != strokes || old.scaleX != scaleX || old.scaleY != scaleY;
}
