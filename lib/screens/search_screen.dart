import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/widgets/flutter_rating_bar.dart';
import 'package:Ratedly/screens/comment_screen.dart';
import 'package:Ratedly/widgets/postshare.dart';
import 'package:Ratedly/widgets/rating_list_screen_postcard.dart';
import 'package:Ratedly/resources/supabase_posts_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/screens/Profile_page/edit_shared.dart';
import 'package:Ratedly/screens/Profile_page/video_edit_screen.dart';
import 'package:timeago/timeago.dart' as timeago;

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
      c * s, 0, 0, 0, b,
      0, c * s, 0, 0, b,
      0, 0, c * s, 0, b,
      0, 0, 0, 1, 0,
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
    1, 0, 0, 0, 0,
    0, 1, 0, 0, 0,
    0, 0, 1, 0, 0,
    0, 0, 0, 1, 0,
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

  // Search related state
  List<Map<String, dynamic>> _searchResults = [];
  bool _isSearching = false;
  Timer? _debounceTimer;

  List<Map<String, dynamic>> _allPosts = [];
  Set<String> blockedUsersSet = {};
  bool _isLoading = true;

  bool _hasLoadError = false;

  int _offset = 0;
  bool _isLoadingMore = false;
  bool _hasMorePosts = true;
  bool _isFirstLoad = true;

  final int _initialPostsLimit = 12;
  final int _subsequentPostsLimit = 6;

  final ScrollController _scrollController = ScrollController();

  List<String> _rotatedSuggestedUsers = [];
  final math.Random _random = math.Random();

  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  final Map<String, VideoPlayerController> _avatarVideoControllers = {};
  final Map<String, bool> _avatarVideoControllersInitialized = {};

  // Cache of uid → {username, photoUrl, isVerified, country}
  final Map<String, Map<String, dynamic>> _userDataCache = {};

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
    final double fontScale = math.min(scaleX, scaleY);

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
      final position = _scrollController.position;
      // ── CHANGE: trigger at 70% scrolled so next page is ready before
      //            the user reaches the bottom — no visible loading gap.
      final trigger = position.maxScrollExtent * 0.70;
      if (position.pixels >= trigger &&
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
    _debounceTimer?.cancel();
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
                  angle: quarters * math.pi / 2,
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

  // ── CHANGED: uses CachedNetworkImage so images are stored to memory + disk.
  //             Shows a skeleton-coloured container while loading instead of
  //             a spinner so cells never visually "pop" when they appear.
  Widget _buildPostImage(String imageUrl, _SearchColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = _buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    Widget networkImage = CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
      // Skeleton placeholder — same colour as the loading skeleton grid,
      // so there is no spinner and no layout jump when the image arrives.
      placeholder: (_, __) => Container(color: colors.skeletonColor),
      errorWidget: (_, __, ___) => Container(
        color: colors.gridItemBackgroundColor,
        child: Icon(Icons.broken_image, color: colors.iconColor),
      ),
    );

    if (editResult != null) {
      networkImage = ColorFiltered(
        colorFilter: ColorFilter.matrix(matrix),
        child: Transform.rotate(
          angle: quarters * math.pi / 2,
          child: networkImage,
        ),
      );
    }

    Widget baseImage = ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: networkImage,
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
    // ── CHANGED: use CachedNetworkImage for avatars too so they're
    //             served from cache on re-renders.
    return CircleAvatar(
      backgroundColor: colors.avatarBackgroundColor,
      radius: 20,
      backgroundImage: CachedNetworkImageProvider(url),
    );
  }

  // ── NEW: kicks off a background download for every image in a batch
  //         the moment we receive the data from Supabase.  By the time
  //         the user scrolls to those cells the bytes are already in the
  //         CachedNetworkImage memory/disk cache → instant display.
  void _precacheImages(List<Map<String, dynamic>> posts) {
    for (final post in posts) {
      final url = post['postUrl']?.toString() ?? '';
      if (url.isNotEmpty && !_isVideoFile(url)) {
        precacheImage(CachedNetworkImageProvider(url), context);
      }
    }
  }

  // ========== DATA LOADING ==========
  Future<void> _initData() async {
    if (currentUserId == null) {
      setState(() {
        _isLoading = false;
        _hasLoadError = false;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _hasLoadError = false;
    });

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

  Map<String, dynamic> _normalisePost(dynamic raw) {
    final Map<String, dynamic> post = {};
    (raw as Map).forEach((k, v) => post[k.toString()] = v);
    return post;
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
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        await _enrichPostsWithUserData(newPosts);

        // ── CHANGED: pre-download all image thumbnails into cache immediately
        //             so they are ready before the user scrolls to them.
        _precacheImages(newPosts);

        for (final post in newPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }

        setState(() {
          _allPosts = newPosts;
          _offset = _allPosts.length;
          _hasMorePosts = _allPosts.length == postsLimit;
          _isFirstLoad = false;
          _hasLoadError = false;
        });
      } else {
        setState(() {
          _allPosts = [];
          _hasMorePosts = false;
          _isFirstLoad = false;
          _hasLoadError = false;
        });
      }
    } catch (_) {
      setState(() {
        _allPosts = [];
        _hasMorePosts = false;
        _isFirstLoad = false;
        _hasLoadError = true;
      });
    }
  }

  Future<void> _loadMorePosts() async {
    if (!_hasMorePosts || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final pageNumber = _offset ~/ _subsequentPostsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': pageNumber,
        'page_limit': _subsequentPostsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        await _enrichPostsWithUserData(newPosts);

        // ── CHANGED: pre-download the next batch before user scrolls to it.
        _precacheImages(newPosts);

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

  Future<List<Map<String, dynamic>>> _loadMorePostsForFeed(
      int currentCount) async {
    if (currentCount < _allPosts.length) {
      return List<Map<String, dynamic>>.from(_allPosts.sublist(currentCount));
    }

    if (!_hasMorePosts) return [];
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];
      final pageNumber = currentCount ~/ _subsequentPostsLimit;

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': pageNumber,
        'page_limit': _subsequentPostsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();
        await _enrichPostsWithUserData(newPosts);

        // ── CHANGED: pre-download feed images too.
        _precacheImages(newPosts);

        for (final post in newPosts) {
          final url = post['postUrl']?.toString() ?? '';
          if (_isVideoFile(url)) _initializeVideoController(url);
        }
        if (mounted) {
          setState(() {
            _allPosts.addAll(newPosts);
            _offset += newPosts.length;
            _hasMorePosts = newPosts.length == _subsequentPostsLimit;
          });
        }
        return newPosts;
      }
      return [];
    } catch (_) {
      return [];
    }
  }

  Future<void> _enrichPostsWithUserData(
      List<Map<String, dynamic>> posts) async {
    final missing = posts
        .map((p) => p['uid']?.toString() ?? '')
        .where((uid) => uid.isNotEmpty && !_userDataCache.containsKey(uid))
        .toSet()
        .toList();

    if (missing.isNotEmpty) {
      try {
        final rows = await _supabase
            .from('users')
            .select('uid, username, photoUrl, isVerified, country')
            .inFilter('uid', missing);
        for (final row in rows) {
          final uid = row['uid']?.toString() ?? '';
          if (uid.isNotEmpty) {
            _userDataCache[uid] = {
              'uid': uid,
              'username': row['username']?.toString() ?? '',
              'photoUrl': row['photoUrl']?.toString() ?? '',
              'isVerified': row['isVerified'] ?? false,
              'country': row['country']?.toString() ?? '',
            };
          }
        }
      } catch (_) {}
    }

    for (final post in posts) {
      final uid = post['uid']?.toString() ?? '';
      final cached = _userDataCache[uid];
      if (cached != null) {
        post['username'] ??= cached['username'];
        post['photoUrl'] ??= cached['photoUrl'];
        post['isVerified'] ??= cached['isVerified'];
        post['country'] ??= cached['country'];
      }
    }
  }

  Future<Map<String, dynamic>> _resolveUserData(
      Map<String, dynamic> post) async {
    final uid = post['uid']?.toString() ?? '';

    if ((post['username'] ?? '').toString().isNotEmpty) {
      return {
        'uid': uid,
        'username': post['username']?.toString() ?? '',
        'photoUrl': post['photoUrl']?.toString() ?? '',
        'isVerified': post['isVerified'] ?? false,
        'country': post['country']?.toString() ?? '',
      };
    }

    if (_userDataCache.containsKey(uid)) return _userDataCache[uid]!;

    final user = await _fetchUserById(uid);
    if (user != null) {
      final data = {
        'uid': uid,
        'username': user['username']?.toString() ?? '',
        'photoUrl': user['photoUrl']?.toString() ?? '',
        'isVerified': user['isVerified'] ?? false,
        'country': user['country']?.toString() ?? '',
      };
      _userDataCache[uid] = data;
      return data;
    }
    return {
      'uid': uid,
      'username': '',
      'photoUrl': '',
      'isVerified': false,
      'country': ''
    };
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
          _searchResults = [];
        });
      }
    });
  }

  // ========== USER SEARCH ==========
  Future<List<Map<String, dynamic>>> _searchUsers(String query) async {
    if (query.trim().isEmpty || currentUserId == null) return [];

    try {
      final response = await _supabase
          .from('users')
          .select('uid, username, photoUrl, isVerified, country')
          .ilike('username', '%$query%')
          .limit(20);

      final List<Map<String, dynamic>> users =
          List<Map<String, dynamic>>.from(response);

      final filtered = users.where((user) {
        final uid = user['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(uid) && uid != currentUserId;
      }).toList();
      return filtered;
    } catch (_) {
      return [];
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      isShowUsers = value.trim().isNotEmpty;
      _isSearchFocused = false;
    });

    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.trim().isNotEmpty) {
        _performSearch(value.trim());
      } else {
        setState(() {
          _searchResults = [];
          _isSearching = false;
        });
      }
    });
  }

  Future<void> _performSearch(String query) async {
    setState(() => _isSearching = true);
    final results = await _searchUsers(query);
    if (mounted) {
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    }
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

  // ========== SKELETONS ==========
  Widget _buildPostsGridSkeleton(_SearchColorSet colors) {
    return GridView.builder(
      padding: const EdgeInsets.all(8.0),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8.0,
        mainAxisSpacing: 8.0,
        childAspectRatio: 0.75,
      ),
      itemCount: 12,
      itemBuilder: (_, __) => _buildPostSkeleton(colors),
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
              onChanged: _onSearchChanged,
              onFieldSubmitted: (_) {
                setState(() {
                  isShowUsers = true;
                  _isSearchFocused = false;
                });
                _performSearch(searchController.text.trim());
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
      Expanded(child: _buildPostsGridSkeleton(colors)),
    ]);
  }

  Widget _buildUserSearch(_SearchColorSet colors) {
    if (_isSearching) {
      return _buildUserSearchSkeleton(colors);
    }

    if (_searchResults.isEmpty) {
      return Center(
        child: Text(
          'No users found.',
          style: TextStyle(color: colors.textColor),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final user = _searchResults[index];
        final uid = user['uid']?.toString() ?? '';
        final username = user['username']?.toString() ?? '';
        final photoUrl = user['photoUrl']?.toString() ?? '';
        final isVerified = user['isVerified'] ?? false;
        final country = user['country']?.toString() ?? '';

        return ListTile(
          leading: _buildUserAvatar(photoUrl, colors),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  username,
                  style: TextStyle(
                    color: colors.textColor,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isVerified) ...[
                const SizedBox(width: 4),
                const Icon(Icons.verified, color: Colors.blue, size: 16),
              ],
            ],
          ),
          subtitle: country.isNotEmpty
              ? Text(
                  country,
                  style: TextStyle(color: colors.hintTextColor, fontSize: 12),
                )
              : null,
          onTap: () => _navigateToProfile(uid),
        );
      },
    );
  }

  Widget _buildPostsGrid(_SearchColorSet colors) {
    if (_hasLoadError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: colors.iconColor, size: 48),
            const SizedBox(height: 12),
            Text('Something went wrong.',
                style: TextStyle(color: colors.textColor)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _initData,
              child: Text('Retry', style: TextStyle(color: colors.textColor)),
            ),
          ],
        ),
      );
    }

    if (_allPosts.isEmpty) {
      return Center(
          child: Text('No posts found.',
              style: TextStyle(color: colors.textColor)));
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (scrollInfo) {
        // ── CHANGED: mirrors the 70% threshold from the scroll controller
        //             so both triggers fire at the same point.
        final extent = scrollInfo.metrics.maxScrollExtent;
        if (scrollInfo.metrics.pixels >= extent * 0.70 &&
            !_isLoadingMore &&
            _hasMorePosts &&
            !isShowUsers) {
          _loadMorePosts();
        }
        return false;
      },
      child: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: const EdgeInsets.all(8.0),
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.75,
                  crossAxisSpacing: 8.0,
                  mainAxisSpacing: 8.0,
                ),
                itemCount: _allPosts.length,
                itemBuilder: (context, index) {
                  final post = _allPosts[index];
                  return _buildPostItem(
                      post, post['postUrl']?.toString() ?? '', index, colors);
                },
              ),
            ],
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
        ],
      ),
    );
  }

  Widget _buildPostItem(Map<String, dynamic> post, String postUrl, int index,
      _SearchColorSet colors) {
    final isVideo = _isVideoFile(postUrl);
    if (isVideo) _initializeVideoController(postUrl);

    final editResult = _parseEditResult(post);

    return InkWell(
      onTap: () async {
        _pauseAllVideos();

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SearchResultFeedScreen(
              initialPosts: List<Map<String, dynamic>>.from(_allPosts),
              initialIndex: index,
              onLoadMore: _loadMorePostsForFeed,
              initialHasMore: _hasMorePosts,
            ),
          ),
        ).then((_) {
          if (mounted) {
            for (final c in _videoControllers.values) {
              if (c.value.isInitialized && !c.value.isPlaying) c.play();
            }
          }
        });
      },
      child: Container(
        decoration: BoxDecoration(
          color: isVideo ? colors.gridItemBackgroundColor : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(children: [
          if (postUrl.isNotEmpty)
            isVideo
                ? _buildVideoPlayer(postUrl, colors, editResult)
                : _buildPostImage(postUrl, colors, editResult)
          else
            Container(
              color: colors.gridItemBackgroundColor,
              child: Icon(Icons.broken_image, color: colors.iconColor),
            ),
        ]),
      ),
    );
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

// =============================================================================
// SearchResultFeedScreen
// =============================================================================
class SearchResultFeedScreen extends StatefulWidget {
  final List<Map<String, dynamic>> initialPosts;
  final int initialIndex;
  final Future<List<Map<String, dynamic>>> Function(int currentCount)
      onLoadMore;
  final bool initialHasMore;

  const SearchResultFeedScreen({
    Key? key,
    required this.initialPosts,
    required this.initialIndex,
    required this.onLoadMore,
    required this.initialHasMore,
  }) : super(key: key);

  @override
  State<SearchResultFeedScreen> createState() => _SearchResultFeedScreenState();
}

class _SearchResultFeedScreenState extends State<SearchResultFeedScreen> {
  late List<Map<String, dynamic>> _posts;
  late PageController _pageController;
  late int _currentIndex;
  bool _hasMore = false;
  bool _loadingMore = false;
  final String _sessionId = DateTime.now().microsecondsSinceEpoch.toString();

  bool _isVideoUrl(String url) {
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

  @override
  void initState() {
    super.initState();
    _posts = List.from(widget.initialPosts);
    _hasMore = widget.initialHasMore;
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final rawPage = _pageController.page ?? _currentIndex.toDouble();
    final page = rawPage.round();
    if (page != _currentIndex) {
      setState(() => _currentIndex = page);
    }
    if (page >= _posts.length - 3 && _hasMore && !_loadingMore) {
      _triggerLoadMore();
    }
  }

  Future<void> _triggerLoadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final batch = await widget.onLoadMore(_posts.length);
      if (mounted) {
        setState(() {
          _posts.addAll(batch);
          _hasMore = batch.isNotEmpty;
          _loadingMore = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;

    final itemCount = _posts.length + (_hasMore || _loadingMore ? 1 : 0);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        title: const Text('Search Results'),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        itemCount: itemCount,
        itemBuilder: (context, index) {
          if (index >= _posts.length) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: CircularProgressIndicator(color: textColor),
              ),
            );
          }
          final post = _posts[index];
          final Map<String, dynamic> userData = {
            'uid': post['uid']?.toString() ?? '',
            'username': post['username']?.toString() ?? '',
            'photoUrl': post['photoUrl']?.toString() ?? '',
            'isVerified': post['isVerified'] ?? false,
            'country': post['country']?.toString() ?? '',
          };
          return _FeedPostPage(
            key: ValueKey(post['postId']),
            post: post,
            userData: userData,
            isActive: index == _currentIndex,
            sessionId: _sessionId,
            onPostDeleted: null,
          );
        },
      ),
    );
  }
}

// =============================================================================
// _FeedPostPage
// =============================================================================
class _FeedPostPage extends StatefulWidget {
  final Map<String, dynamic> post;
  final Map<String, dynamic> userData;
  final bool isActive;
  final String sessionId;
  final VoidCallback? onPostDeleted;

  const _FeedPostPage({
    Key? key,
    required this.post,
    required this.userData,
    required this.isActive,
    required this.sessionId,
    this.onPostDeleted,
  }) : super(key: key);

  @override
  State<_FeedPostPage> createState() => _FeedPostPageState();
}

class _FeedPostPageState extends State<_FeedPostPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();

  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoLoading = false;
  bool _isMuted = false;

  double _averageRating = 0.0;
  int _totalRatingsCount = 0;
  double? _userRating;
  bool _isLoadingRatings = true;
  String _reactionEmoji = '❤️';
  int _commentCount = 0;

  VideoEditResult? _editResult;
  bool _dataFetched = false;

  String get _postUrl => widget.post['postUrl']?.toString() ?? '';
  String get _postId => widget.post['postId']?.toString() ?? '';

  bool get _isVideo {
    final u = _postUrl.toLowerCase();
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

  @override
  void initState() {
    super.initState();
    _parseEditMetadata();
    _fetchAllData();
    if (widget.isActive) _onBecomeActive();
  }

  @override
  void didUpdateWidget(_FeedPostPage old) {
    super.didUpdateWidget(old);
    if (widget.isActive && !old.isActive) {
      _onBecomeActive();
    } else if (!widget.isActive && old.isActive) {
      _onBecomeInactive();
    }
  }

  @override
  void dispose() {
    _videoController?.pause();
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  void _onBecomeActive() {
    if (_isVideo) {
      if (_isVideoInitialized) {
        _videoController?.play();
      } else if (!_isVideoLoading) {
        _initVideo();
      }
    }
  }

  void _onBecomeInactive() {
    _videoController?.pause();
  }

  void _parseEditMetadata() {
    final raw = widget.post['video_edit_metadata'];
    if (raw == null) return;
    try {
      final map = raw is Map<String, dynamic>
          ? raw
          : Map<String, dynamic>.from(raw as Map);
      _editResult = VideoEditResult.fromJson(map, File(''));
    } catch (e) {
      // ignore
    }
  }

  Future<void> _fetchAllData() async {
    if (_dataFetched) return;
    _dataFetched = true;
    await Future.wait(
        [_fetchRatings(), _fetchReactionEmoji(), _fetchCommentsCount()]);
  }

  Future<void> _fetchRatings() async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    try {
      final ratings = await _supabase
          .from('post_rating')
          .select()
          .eq('postid', _postId) as List<dynamic>;

      double avg = 0;
      double? userRating;
      if (ratings.isNotEmpty) {
        final total = ratings.fold<double>(
            0, (s, r) => s + (r['rating'] as num).toDouble());
        avg = total / ratings.length;
        if (user != null) {
          for (final r in ratings) {
            if (r['userid'] == user.uid) {
              userRating = (r['rating'] as num).toDouble();
              break;
            }
          }
        }
      }
      if (mounted) {
        setState(() {
          _totalRatingsCount = ratings.length;
          _averageRating = avg;
          _userRating = userRating;
          _isLoadingRatings = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingRatings = false);
    }
  }

  Future<void> _fetchReactionEmoji() async {
    try {
      final resp = await _supabase
          .from('posts')
          .select('reaction_emoji')
          .eq('postId', _postId)
          .maybeSingle();
      if (mounted && resp != null) {
        final emoji = resp['reaction_emoji']?.toString();
        if (emoji != null && emoji.isNotEmpty) {
          setState(() => _reactionEmoji = emoji);
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _fetchCommentsCount() async {
    try {
      final comments = await _supabase
          .from('comments')
          .select('id')
          .eq('postid', _postId) as List<dynamic>;
      final replies = await _supabase
          .from('replies')
          .select('id')
          .eq('postid', _postId) as List<dynamic>;
      if (mounted) {
        setState(() => _commentCount = comments.length + replies.length);
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _initVideo() async {
    if (_isVideoLoading || _isVideoInitialized || _postUrl.isEmpty) return;

    setState(() => _isVideoLoading = true);

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(_postUrl),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
      );

      await controller.initialize();

      controller.setLooping(true);
      if (mounted) {
        setState(() {
          _videoController = controller;
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        if (widget.isActive) {
          controller.play();
        }
      } else {
        controller.dispose();
      }
    } catch (e) {
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  void _togglePlayback() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      if (_videoController!.value.isPlaying) {
        _videoController!.pause();
      } else {
        _videoController!.play();
      }
    });
  }

  void _toggleMute() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      _isMuted = !_isMuted;
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  void _handleRatingSubmitted(double rating) async {
    final user = Provider.of<UserProvider>(context, listen: false).user;
    if (user == null) return;

    final oldRating = _userRating;
    final isUpdating = oldRating != null;

    setState(() {
      _userRating = rating;
      final currentTotal = _averageRating * _totalRatingsCount;
      if (isUpdating) {
        _averageRating =
            (currentTotal - oldRating + rating) / _totalRatingsCount;
      } else {
        _totalRatingsCount++;
        _averageRating = (currentTotal + rating) / _totalRatingsCount;
      }
    });

    try {
      final res = await _postsMethods.ratePost(_postId, user.uid, rating);
      if (res != 'success' && mounted) _fetchRatings();
    } catch (_) {
      if (mounted) _fetchRatings();
    }
  }

  List<double> _buildColorMatrix() {
    if (_editResult == null) {
      return [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0];
    }
    return _editResult!.adjustments
        .combinedMatrix(kFilters[_editResult!.filterIndex].matrix);
  }

  void _goToProfile() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ProfileScreen(uid: widget.userData['uid']?.toString() ?? ''),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDark = themeProvider.themeMode == ThemeMode.dark;
    final bgColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? const Color(0xFFd9d9d9) : Colors.black;
    final cardColor = isDark ? const Color(0xFF333333) : Colors.grey[200]!;
    final iconColor = textColor;

    final user = Provider.of<UserProvider>(context).user;
    final isOwner = user != null &&
        (user.uid == widget.userData['uid']?.toString() ||
            user.uid == widget.post['uid']?.toString());

    final dateRaw = widget.post['datePublished'];
    final date = dateRaw is DateTime
        ? dateRaw
        : (dateRaw is String ? DateTime.tryParse(dateRaw) : null);
    final timeStr = date != null ? timeago.format(date) : '';

    final photoUrl = widget.userData['photoUrl']?.toString() ?? '';
    final uid = widget.userData['uid']?.toString() ?? '';
    final matrix = _buildColorMatrix();
    final quarters = _editResult?.rotationQuarters ?? 0;
    final description = widget.post['description']?.toString() ?? '';

    final bool preventInnerScroll = _isVideo && _isVideoInitialized;

    return SingleChildScrollView(
      physics: preventInnerScroll
          ? const NeverScrollableScrollPhysics()
          : const ClampingScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _goToProfile,
                  child: _buildAvatar(
                      photoUrl, uid, user?.uid ?? '', cardColor, textColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: _goToProfile,
                        child: VerifiedUsernameWidget(
                          username:
                              widget.userData['username']?.toString() ?? '',
                          uid: uid,
                          style: TextStyle(
                              fontWeight: FontWeight.bold, color: textColor),
                        ),
                      ),
                      if (timeStr.isNotEmpty)
                        Text(timeStr,
                            style: TextStyle(
                                color: textColor.withOpacity(0.6),
                                fontSize: 12)),
                    ],
                  ),
                ),
                if (isOwner && widget.onPostDeleted != null)
                  IconButton(
                    icon: Icon(Icons.more_vert, color: iconColor),
                    onPressed: () =>
                        _showOptionsMenu(context, bgColor, textColor),
                  ),
              ],
            ),
          ),
          _buildMedia(matrix, quarters, cardColor, textColor),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(description,
                  style: TextStyle(color: textColor, fontSize: 15)),
            ),
          if (!_isLoadingRatings)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: RatingBar(
                averageRating: _averageRating,
                reactionEmoji: _reactionEmoji,
                initialThumbPosition:
                    _userRating == null ? 5.0 : _averageRating,
                onRatingEnd: _handleRatingSubmitted,
                hasUserRated: _userRating != null,
              ),
            )
          else
            const SizedBox(height: 48),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: Icon(Icons.comment_outlined,
                          color: iconColor, size: 28),
                      onPressed: () => _showComments(context),
                    ),
                    if (_commentCount > 0)
                      Positioned(
                        top: -6,
                        left: -6,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          constraints:
                              const BoxConstraints(minWidth: 20, minHeight: 20),
                          decoration: BoxDecoration(
                              color: cardColor, shape: BoxShape.circle),
                          child: Center(
                            child: Text(
                              _commentCount.toString(),
                              style: TextStyle(
                                  color: textColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                IconButton(
                  icon: Icon(Icons.send, color: iconColor),
                  onPressed: () {
                    if (user != null) {
                      showDialog(
                        context: context,
                        builder: (_) =>
                            PostShare(currentUserId: user.uid, postId: _postId),
                      );
                    }
                  },
                ),
                const Spacer(),
                GestureDetector(
                  onTap: isOwner
                      ? () => Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) =>
                                    RatingListScreen(postId: _postId)),
                          )
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(4)),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text(
                      _totalRatingsCount == 0
                          ? 'Be the first to react'
                          : '$_totalRatingsCount '
                              '${_totalRatingsCount == 1 ? 'voter' : 'voters'}',
                      style: TextStyle(
                          fontSize: 13,
                          color: textColor,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildAvatar(String photoUrl, String uid, String currentUserId,
      Color cardColor, Color textColor) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    // ── CHANGED: use CachedNetworkImageProvider for cached avatar loading.
    return CircleAvatar(
      radius: 20,
      backgroundColor: cardColor,
      backgroundImage:
          !isDefault ? CachedNetworkImageProvider(photoUrl) : null,
      child: isDefault
          ? Icon(Icons.account_circle, size: 40, color: textColor)
          : null,
    );
  }

  Widget _buildMedia(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    if (_isVideo)
      return _buildVideoPlayer(matrix, quarters, cardColor, textColor);
    return _buildImage(matrix, quarters, cardColor, textColor);
  }

  Widget _buildVideoPlayer(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    final double aspect = (_isVideoInitialized && _videoController != null)
        ? _videoController!.value.aspectRatio
        : 1.0;

    return AspectRatio(
      aspectRatio: aspect,
      child: GestureDetector(
        onTap: _togglePlayback,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Colors.black),
            if (_isVideoInitialized && _videoController != null)
              ColorFiltered(
                colorFilter: ColorFilter.matrix(matrix),
                child: Transform.rotate(
                  angle: quarters * math.pi / 2,
                  child: VideoPlayer(_videoController!),
                ),
              )
            else if (_isVideoLoading)
              Center(child: CircularProgressIndicator(color: textColor))
            else
              Center(child: Icon(Icons.videocam, color: textColor, size: 48)),
            if (_editResult != null && _editResult!.strokes.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: DrawingPainter(
                        strokes: _editResult!.strokes, currentStroke: null),
                  ),
                ),
              ),
            if (_editResult != null && _editResult!.overlays.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: LayoutBuilder(
                    builder: (_, constraints) => Stack(
                      children: _editResult!.overlays.map((o) {
                        return Positioned(
                          left: (o.position.dx * constraints.maxWidth)
                              .clamp(0.0, constraints.maxWidth - 10),
                          top: (o.position.dy * constraints.maxHeight)
                              .clamp(0.0, constraints.maxHeight - 10),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Text(o.text, style: overlayShadowStyle(o)),
                            Text(o.text, style: overlayTextStyle(o)),
                          ]),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            if (_isVideoInitialized)
              Positioned(
                bottom: 16,
                right: 16,
                child: GestureDetector(
                  onTap: _toggleMute,
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(
                        color: Colors.black54, shape: BoxShape.circle),
                    child: Icon(_isMuted ? Icons.volume_off : Icons.volume_up,
                        size: 18, color: Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── CHANGED: full-screen feed image now uses CachedNetworkImage too.
  Widget _buildImage(
      List<double> matrix, int quarters, Color cardColor, Color textColor) {
    return AspectRatio(
      aspectRatio: 1,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            panEnabled: true,
            scaleEnabled: true,
            minScale: 1.0,
            maxScale: 4.0,
            child: ColorFiltered(
              colorFilter: ColorFilter.matrix(matrix),
              child: Transform.rotate(
                angle: quarters * math.pi / 2,
                child: CachedNetworkImage(
                  imageUrl: _postUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  // Re-uses whatever the grid already pre-cached — instant.
                  placeholder: (_, __) => Container(color: cardColor),
                  errorWidget: (_, __, ___) => Container(
                    color: cardColor,
                    child: Icon(Icons.broken_image,
                        color: textColor, size: 48),
                  ),
                ),
              ),
            ),
          ),
          if (_editResult != null &&
              (_editResult!.strokes.isNotEmpty ||
                  _editResult!.overlays.isNotEmpty))
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (_, constraints) => Stack(
                    children: [
                      if (_editResult!.strokes.isNotEmpty)
                        Positioned.fill(
                          child: CustomPaint(
                            painter: DrawingPainter(
                                strokes: _editResult!.strokes,
                                currentStroke: null),
                          ),
                        ),
                      ..._editResult!.overlays.map((o) {
                        return Positioned(
                          left: (o.position.dx * constraints.maxWidth)
                              .clamp(0.0, constraints.maxWidth - 10),
                          top: (o.position.dy * constraints.maxHeight)
                              .clamp(0.0, constraints.maxHeight - 10),
                          child: Stack(clipBehavior: Clip.none, children: [
                            Text(o.text, style: overlayShadowStyle(o)),
                            Text(o.text, style: overlayTextStyle(o)),
                          ]),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showComments(BuildContext context) {
    _videoController?.pause();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsBottomSheet(
        postId: _postId,
        postImage: _postUrl,
        isVideo: _isVideo,
        onClose: () {
          if (widget.isActive) _videoController?.play();
        },
        videoController: _videoController,
      ),
    ).then((_) => _fetchCommentsCount());
  }

  void _showOptionsMenu(BuildContext context, Color bgColor, Color textColor) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: bgColor,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          shrinkWrap: true,
          children: [
            InkWell(
              onTap: () async {
                Navigator.of(context).pop();
                await _deletePost(context);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Text('Delete',
                    style: TextStyle(color: Colors.red[400], fontSize: 15)),
              ),
            ),
            InkWell(
              onTap: () => Navigator.of(context).pop(),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                child: Text('Cancel',
                    style: TextStyle(color: textColor, fontSize: 15)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deletePost(BuildContext context) async {
    try {
      await _postsMethods.deletePost(_postId);
      widget.onPostDeleted?.call();
    } catch (e) {
      if (mounted) showSnackBar(context, 'Failed to delete post: $e');
    }
  }
}
