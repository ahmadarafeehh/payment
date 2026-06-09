// lib/screens/Search/search_posts.dart
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
import 'package:Ratedly/resources/reactions_methods.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:Ratedly/services/analytics_service.dart';

// ✅ Shared utilities
import 'package:Ratedly/utils/colors.dart';
import 'package:Ratedly/utils/video_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Global video manager – ensures only one video plays at a time
// ─────────────────────────────────────────────────────────────────────────────
void unawaited(Future<void> future) {}

class VideoManager {
  static final VideoManager _instance = VideoManager._internal();
  factory VideoManager() => _instance;
  VideoManager._internal();

  VideoPlayerController? _currentPlayingController;
  String? _currentPostId;
  final Map<String, VideoPlayerController> _activeControllers = {};

  static void pauseAllVideos() => _instance._pauseAllVideos();

  void playVideo(VideoPlayerController controller, String postId) {
    if (_currentPlayingController != null &&
        _currentPlayingController != controller) {
      _currentPlayingController!.pause();
    }
    _currentPlayingController = controller;
    _currentPostId = postId;
    _activeControllers[postId] = controller;
    controller.play();
  }

  void pauseVideo(VideoPlayerController controller) {
    if (_currentPlayingController == controller) {
      controller.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.removeWhere((key, value) => value == controller);
  }

  void disposeController(VideoPlayerController controller, String postId) {
    if (_currentPlayingController == controller) {
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.remove(postId);
    controller.pause();
    controller.dispose();
  }

  bool isCurrentlyPlaying(VideoPlayerController controller) =>
      _currentPlayingController == controller;

  void onPostInvisible(String postId) {
    if (_currentPostId == postId && _currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.remove(postId);
  }

  String? get currentPlayingPostId => _currentPostId;

  void pauseCurrentVideo() {
    if (_currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
  }

  void _pauseAllVideos() {
    if (_currentPlayingController != null) {
      _currentPlayingController!.pause();
      _currentPlayingController = null;
      _currentPostId = null;
    }
    _activeControllers.forEach((postId, controller) {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        controller.pause();
      }
    });
    _activeControllers.clear();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SearchResultFeedScreen  (full-screen vertical PageView)
// ─────────────────────────────────────────────────────────────────────────────

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
  String? _currentUserId;

  @override
  void initState() {
    super.initState();
    AnalyticsService.screenEnter('search_feed');
    final userProvider = Provider.of<UserProvider>(context, listen: false);
    _currentUserId = userProvider.firebaseUid ?? userProvider.supabaseUid;
    _posts = List.from(widget.initialPosts);
    _hasMore = widget.initialHasMore;
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    _pageController.addListener(_onPageScroll);
  }

  @override
  void dispose() {
    if (_currentUserId != null && _currentUserId!.isNotEmpty) {
      AnalyticsService.screenExit(
        screenName: 'search_feed',
        uid: _currentUserId!,
      );
    }
    _pageController.removeListener(_onPageScroll);
    _pageController.dispose();
    super.dispose();
  }

  void _onPageScroll() {
    final rawPage = _pageController.page ?? _currentIndex.toDouble();
    final page = rawPage.round();
    if (page != _currentIndex) {
      VideoManager.pauseAllVideos();
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
    final colors = themeProvider.themeMode == ThemeMode.dark
        ? AppColorSet.dark()
        : AppColorSet.light();

    final itemCount = _posts.length + (_hasMore || _loadingMore ? 1 : 0);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        backgroundColor: colors.appBarBackgroundColor,
        elevation: 0,
        iconTheme: IconThemeData(color: colors.iconColor),
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
                child: CircularProgressIndicator(color: colors.textColor),
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

// ─────────────────────────────────────────────────────────────────────────────
// _FeedPostPage  (single post in the vertical feed)
// ─────────────────────────────────────────────────────────────────────────────

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
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  final SupabaseClient _supabase = Supabase.instance.client;
  final SupabasePostsMethods _postsMethods = SupabasePostsMethods();
  final VideoManager _videoManager = VideoManager();

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

  bool get _isVideo => isVideoFile(_postUrl);

  bool get _isVideoPlaying =>
      _videoController != null &&
      _videoManager.isCurrentlyPlaying(_videoController!);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _editResult = parseEditResult(widget.post); // ✅ shared helper
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
    WidgetsBinding.instance.removeObserver(this);
    _disposeVideoController();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _pauseVideo();
    }
  }

  void _onBecomeActive() {
    if (_isVideo) {
      if (_isVideoInitialized) {
        _playVideo();
      } else if (!_isVideoLoading) {
        _initVideo();
      }
    }
  }

  void _onBecomeInactive() {
    _pauseVideo();
  }

  void _playVideo() {
    if (_videoController != null &&
        _isVideoInitialized &&
        mounted &&
        widget.isActive) {
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
      _videoManager.playVideo(_videoController!, _postId);
      setState(() {});
    }
  }

  void _pauseVideo() {
    if (_videoController != null && _isVideoInitialized && mounted) {
      _videoManager.pauseVideo(_videoController!);
      setState(() {});
    }
  }

  void _togglePlayback() {
    if (!_isVideoInitialized || _videoController == null) return;
    if (_isVideoPlaying) {
      _pauseVideo();
    } else {
      _playVideo();
    }
    setState(() {});
  }

  void _toggleMute() {
    if (!_isVideoInitialized || _videoController == null) return;
    setState(() {
      _isMuted = !_isMuted;
      _videoController!.setVolume(_isMuted ? 0.0 : 1.0);
    });
  }

  void _disposeVideoController() {
    if (_videoController != null) {
      _videoController!.removeListener(_videoListener);
      if (_isVideoPlaying) {
        _videoManager.pauseVideo(_videoController!);
      }
      _videoController!.pause();
      _videoController!.dispose();
      _videoController = null;
    }
    _isVideoInitialized = false;
    _isVideoLoading = false;
  }

  void _videoListener() {
    if (!mounted) return;
    if (_videoController != null &&
        _videoController!.value.position == _videoController!.value.duration &&
        _videoController!.value.duration != Duration.zero) {
      _videoController!.seekTo(Duration.zero);
      if (widget.isActive && !_isVideoPlaying) {
        _videoController!.play();
      }
    }
    if (_videoController != null && _isVideoInitialized) {
      final actuallyPlaying = _videoController!.value.isPlaying;
      final shouldBePlaying =
          _videoManager.isCurrentlyPlaying(_videoController!);
      if (actuallyPlaying != shouldBePlaying && widget.isActive) {
        if (shouldBePlaying && !actuallyPlaying) {
          _videoController!.play();
        } else if (!shouldBePlaying && actuallyPlaying) {
          _videoController!.pause();
        }
      }
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
      controller.addListener(_videoListener);
      if (mounted) {
        setState(() {
          _videoController = controller;
          _isVideoInitialized = true;
          _isVideoLoading = false;
        });
        if (widget.isActive) _playVideo();
      } else {
        controller.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  // ── Data fetching ─────────────────────────────────────────
  Future<void> _fetchAllData() async {
    if (_dataFetched) return;
    _dataFetched = true;
    await Future.wait(<Future<void>>[
      _fetchRatings(),
      _fetchReactionEmoji(),
      _fetchCommentsCount(),
    ]);
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
    } catch (_) {}
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
    } catch (_) {}
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
            (currentTotal - oldRating! + rating) / _totalRatingsCount;
      } else {
        _totalRatingsCount++;
        _averageRating = (currentTotal + rating) / _totalRatingsCount;
      }
    });

    try {
      final res = await SupabaseReactionsMethods()
          .reactToPost(_postId, user.uid, rating);
      if (res != 'success' && mounted) _fetchRatings();
    } catch (_) {
      if (mounted) _fetchRatings();
    }
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

  void _openRatingsPanel() {
    _pauseVideo();
    RatingListScreen.show(
      context,
      postId: _postId,
      isVideo: _isVideo,
      videoController: _videoController,
      onClose: () {
        if (widget.isActive) _playVideo();
      },
    );
  }

  // ── BUILD ─────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    super.build(context);

    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = themeProvider.themeMode == ThemeMode.dark
        ? AppColorSet.dark()
        : AppColorSet.light();

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
    final matrix = buildColorMatrix(_editResult); // ✅ shared
    final quarters = _editResult?.rotationQuarters ?? 0;
    final description = widget.post['description']?.toString() ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              GestureDetector(
                onTap: _goToProfile,
                child: _buildAvatar(photoUrl, uid, user?.uid ?? '', colors),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onTap: _goToProfile,
                      child: VerifiedUsernameWidget(
                        username: widget.userData['username']?.toString() ?? '',
                        uid: uid,
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: colors.textColor),
                      ),
                    ),
                    if (timeStr.isNotEmpty)
                      Text(timeStr,
                          style: TextStyle(
                              color: colors.textColor.withOpacity(0.6),
                              fontSize: 12)),
                  ],
                ),
              ),
              if (isOwner && widget.onPostDeleted != null)
                IconButton(
                  icon: Icon(Icons.more_vert, color: colors.iconColor),
                  onPressed: () => _showOptionsMenu(context, colors),
                ),
            ],
          ),
        ),
        // Media
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return _buildMedia(matrix, quarters, colors,
                  maxHeight: constraints.maxHeight);
            },
          ),
        ),
        // Description
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              description,
              style: TextStyle(color: colors.textColor, fontSize: 15),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        // Ratings
        if (!_isLoadingRatings)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: RatingBar(
              averageRating: _averageRating,
              reactionEmoji: _reactionEmoji,
              initialThumbPosition: _userRating == null ? 5.0 : _averageRating,
              onRatingEnd: _handleRatingSubmitted,
              hasUserRated: _userRating != null,
              userRating: _userRating,
              userProfilePhoto: user?.photoUrl ?? '',
            ),
          )
        else
          const SizedBox(height: 48),
        // Action bar
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
                        color: colors.iconColor, size: 28),
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
                            color: colors.cardColor, shape: BoxShape.circle),
                        child: Center(
                          child: Text(
                            _commentCount.toString(),
                            style: TextStyle(
                                color: colors.textColor,
                                fontSize: 10,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              IconButton(
                icon: Icon(Icons.send, color: colors.iconColor),
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
                onTap: isOwner ? () => _openRatingsPanel() : null,
                child: Container(
                  decoration: BoxDecoration(
                      color: colors.cardColor,
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
                        color: colors.textColor,
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
    );
  }

  Widget _buildAvatar(
      String photoUrl, String uid, String currentUserId, AppColorSet colors) {
    final isDefault = photoUrl.isEmpty || photoUrl == 'default';
    return CircleAvatar(
      radius: 20,
      backgroundColor: colors.cardColor,
      backgroundImage: !isDefault ? CachedNetworkImageProvider(photoUrl) : null,
      child: isDefault
          ? Icon(Icons.account_circle, size: 40, color: colors.textColor)
          : null,
    );
  }

  Widget _buildMedia(List<double> matrix, int quarters, AppColorSet colors,
      {double? maxHeight}) {
    if (_isVideo)
      return _buildVideoPlayer(matrix, quarters, colors, maxHeight: maxHeight);
    return _buildImage(matrix, quarters, colors, maxHeight: maxHeight);
  }

  Widget _buildVideoPlayer(
      List<double> matrix, int quarters, AppColorSet colors,
      {double? maxHeight}) {
    final double videoAspect = (_isVideoInitialized && _videoController != null)
        ? _videoController!.value.aspectRatio
        : 1.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double naturalHeight = width / videoAspect;
        final double containerHeight = maxHeight != null
            ? math.min(naturalHeight, maxHeight)
            : naturalHeight;
        final bool needsCropping =
            maxHeight != null && naturalHeight > maxHeight;

        return SizedBox(
          width: width,
          height: containerHeight,
          child: ClipRect(
            child: Container(
              color: Colors.black,
              child: GestureDetector(
                onTap: _togglePlayback,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (_isVideoInitialized && _videoController != null)
                      ColorFiltered(
                        colorFilter: ColorFilter.matrix(matrix),
                        child: Transform.rotate(
                          angle: quarters * math.pi / 2,
                          child: needsCropping
                              ? FittedBox(
                                  fit: BoxFit.cover,
                                  child: SizedBox(
                                    width: _videoController!.value.size.width,
                                    height: _videoController!.value.size.height,
                                    child: VideoPlayer(_videoController!),
                                  ),
                                )
                              : VideoPlayer(_videoController!),
                        ),
                      )
                    else if (_isVideoLoading)
                      Center(
                          child: CircularProgressIndicator(
                              color: colors.textColor))
                    else
                      Center(
                          child: Icon(Icons.videocam,
                              color: colors.textColor, size: 48)),

                    // ✅ Shared edit overlays
                    if (_editResult != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: LayoutBuilder(
                            builder: (context, overlayConstraints) =>
                                buildEditOverlayLayer(
                              editResult: _editResult!,
                              constraints: overlayConstraints,
                              screenSize: MediaQuery.of(context).size,
                            ),
                          ),
                        ),
                      ),

                    // Play overlay
                    if (_isVideoInitialized && !_isVideoPlaying)
                      Center(
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.play_arrow,
                              size: 40, color: Colors.white),
                        ),
                      ),

                    // Mute button
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
                            child: Icon(
                              _isMuted ? Icons.volume_off : Icons.volume_up,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildImage(List<double> matrix, int quarters, AppColorSet colors,
      {double? maxHeight}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double width = constraints.maxWidth;
        final double naturalHeight = width;
        final double containerHeight = maxHeight != null
            ? math.min(naturalHeight, maxHeight)
            : naturalHeight;
        final bool needsCropping =
            maxHeight != null && naturalHeight > maxHeight;

        return SizedBox(
          width: width,
          height: containerHeight,
          child: ClipRect(
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
                      child: needsCropping
                          ? FittedBox(
                              fit: BoxFit.cover,
                              child: CachedNetworkImage(
                                imageUrl: _postUrl,
                                width: width,
                                height: width,
                                fit: BoxFit.cover,
                                placeholder: (_, __) =>
                                    Container(color: colors.cardColor),
                                errorWidget: (_, __, ___) => Container(
                                  color: colors.cardColor,
                                  child: Icon(Icons.broken_image,
                                      color: colors.textColor, size: 48),
                                ),
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: _postUrl,
                              width: width,
                              height: width,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: colors.cardColor),
                              errorWidget: (_, __, ___) => Container(
                                color: colors.cardColor,
                                child: Icon(Icons.broken_image,
                                    color: colors.textColor, size: 48),
                              ),
                            ),
                    ),
                  ),
                ),
                // ✅ Shared edit overlays for images
                if (_editResult != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: LayoutBuilder(
                        builder: (context, overlayConstraints) =>
                            buildEditOverlayLayer(
                          editResult: _editResult!,
                          constraints: overlayConstraints,
                          screenSize: MediaQuery.of(context).size,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showComments(BuildContext context) {
    _pauseVideo();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CommentsBottomSheet(
        postId: _postId,
        postImage: _postUrl,
        isVideo: _isVideo,
        onClose: () {
          if (widget.isActive) _playVideo();
        },
        videoController: _videoController,
      ),
    ).then((_) => _fetchCommentsCount());
  }

  void _showOptionsMenu(BuildContext context, AppColorSet colors) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: colors.backgroundColor,
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
                    style: TextStyle(color: colors.textColor, fontSize: 15)),
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
