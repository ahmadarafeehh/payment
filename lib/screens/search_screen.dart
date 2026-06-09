// lib/screens/search_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math; // ← ADD THIS LINE
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/screens/Search/search_posts.dart';
import 'package:Ratedly/services/analytics_service.dart';

import 'package:Ratedly/utils/colors.dart'; // shared colours
import 'package:Ratedly/utils/video_utils.dart'; // shared video helpers + service

// ─────────────────────────────────────────────────────────────────────────────
// SearchScreen  (the main search tab)
// ─────────────────────────────────────────────────────────────────────────────

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
  String? _currentUserIdForTracking;

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

  final Map<String, Map<String, dynamic>> _userDataCache = {};

  // ── Shared media service (replaces all thumbnail caches & loop controllers) ──
  late final VideoMediaService _mediaService = VideoMediaService()
    ..onRebuild = () {
      if (mounted) setState(() {});
    };

  // ── Avatar video controllers (still separate, for user search results) ──
  final Map<String, VideoPlayerController> _avatarVideoControllers = {};
  final Map<String, bool> _avatarVideoControllersInitialized = {};

  // ── Unified colour provider ─────────────────────────────────────────
  AppColorSet _getColors(ThemeProvider themeProvider) {
    return themeProvider.themeMode == ThemeMode.dark
        ? AppColorSet.dark()
        : AppColorSet.light();
  }

  // ── Error logging ─────────────────────────────────────────────────────
  Future<void> _logSearchError({
    required String operationType,
    String? userId,
    String? postId,
    Map<String, dynamic>? additionalData,
    required dynamic error,
    StackTrace? stackTrace,
  }) async {
    try {
      await _supabase.from('search_errors').insert({
        'user_id': userId ?? currentUserId,
        'operation_type': operationType,
        'error_message': error.toString(),
        'stack_trace': stackTrace?.toString(),
        'additional_data': {
          if (postId != null) 'postId': postId,
          ...?additionalData,
        },
      });
    } catch (_) {}
  }

  // ── Avatar video controller (unchanged) ─────────────────────────────
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
          if (mounted) setState(() {});
        }
      });

      await controller.initialize();
      await controller.setVolume(0.0);
      _configureAvatarLoop(controller);
      if (mounted) setState(() {});
    } catch (_) {
      _avatarVideoControllers.remove(videoUrl)?.dispose();
      _avatarVideoControllersInitialized.remove(videoUrl);
    }
  }

  void _configureAvatarLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;
    final end = duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        if (controller.value.position >= end) controller.seekTo(Duration.zero);
      }
    });
    controller.play();
  }

  // ── Pause / resume helpers ──────────────────────────────────────────
  void _pauseAllVideos() {
    _mediaService.pauseAll(); // pauses looping post controllers
    for (final c in _avatarVideoControllers.values) {
      if (c.value.isPlaying) c.pause();
    }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    AnalyticsService.screenEnter('search');
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(() {
      final position = _scrollController.position;
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
      _currentUserIdForTracking = currentUserId;
      if (!_isLoading) _initData();
    } else if (userProvider.firebaseUid == null &&
        userProvider.supabaseUid != null &&
        currentUserId == null) {
      currentUserId = userProvider.supabaseUid;
      _currentUserIdForTracking = currentUserId;
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

  @override
  void dispose() {
    if (_currentUserIdForTracking != null) {
      AnalyticsService.screenExit(
        screenName: 'search',
        uid: _currentUserIdForTracking!,
      );
    }
    _debounceTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    searchController.dispose();
    _scrollController.dispose();
    for (final c in _avatarVideoControllers.values) {
      c.dispose();
    }
    _avatarVideoControllers.clear();
    _avatarVideoControllersInitialized.clear();
    _mediaService.dispose();
    super.dispose();
  }

  // ── Data loading ────────────────────────────────────────────────────
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

    _isFirstLoad = true;
    _offset = 0;
    _allPosts = [];

    await Future.wait([_loadBlockedUsers(), _fetchPosts()]);
    setState(() => _isLoading = false);
    _ensureSufficientPosts();
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
    } catch (e, st) {
      await _logSearchError(
        operationType: 'load_blocked_users',
        error: e,
        stackTrace: st,
      );
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
        'page_offset': _offset,
        'page_limit': postsLimit,
      });

      if (response is List) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        await _enrichPostsWithUserData(newPosts);
        if (!mounted) return;
        _precacheImages(newPosts);

        _mediaService.preloadMedia(newPosts);

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
          _hasLoadError = true;
        });
      }
    } catch (e, st) {
      await _logSearchError(
        operationType: 'fetch_posts',
        additionalData: {'offset': _offset, 'isFirstLoad': _isFirstLoad},
        error: e,
        stackTrace: st,
      );
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

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': _offset,
        'page_limit': _subsequentPostsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();

        await _enrichPostsWithUserData(newPosts);
        if (!mounted) return;
        _precacheImages(newPosts);

        _mediaService.preloadMedia(newPosts);

        setState(() {
          _allPosts.addAll(newPosts);
          _offset += newPosts.length;
          _hasMorePosts = newPosts.length == _subsequentPostsLimit;
        });
      } else {
        setState(() => _hasMorePosts = false);
      }
    } catch (e, st) {
      await _logSearchError(
        operationType: 'load_more_posts',
        additionalData: {'offset': _offset},
        error: e,
        stackTrace: st,
      );
      setState(() => _hasMorePosts = false);
    } finally {
      setState(() => _isLoadingMore = false);
      _ensureSufficientPosts();
    }
  }

  void _ensureSufficientPosts() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final position = _scrollController.position;
      if (position.maxScrollExtent <= position.viewportDimension &&
          _hasMorePosts &&
          !_isLoadingMore) {
        _loadMorePosts();
      }
    });
  }

  Future<List<Map<String, dynamic>>> _loadMorePostsForFeed(
      int currentCount) async {
    if (currentCount < _allPosts.length) {
      return List<Map<String, dynamic>>.from(_allPosts.sublist(currentCount));
    }

    if (!_hasMorePosts) return [];
    try {
      final excludedUsers = [...blockedUsersSet, currentUserId!];

      final response = await _supabase.rpc('get_search_feed', params: {
        'current_user_id': currentUserId!,
        'excluded_users': excludedUsers,
        'page_offset': currentCount,
        'page_limit': _subsequentPostsLimit,
      });

      if (response is List && response.isNotEmpty) {
        final newPosts =
            response.map<Map<String, dynamic>>(_normalisePost).toList();
        await _enrichPostsWithUserData(newPosts);
        if (!mounted) return [];
        _precacheImages(newPosts);

        _mediaService.preloadMedia(newPosts);

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
    } catch (e, st) {
      await _logSearchError(
        operationType: 'load_more_posts_for_feed',
        additionalData: {'currentCount': currentCount},
        error: e,
        stackTrace: st,
      );
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
      } catch (e, st) {
        await _logSearchError(
          operationType: 'enrich_posts_with_user_data',
          additionalData: {'missingCount': missing.length},
          error: e,
          stackTrace: st,
        );
      }
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

  // ── Image caching (unchanged) ─────────────────────────────────────
  void _precacheImages(List<Map<String, dynamic>> posts) {
    for (final post in posts) {
      final url = post['postUrl']?.toString() ?? '';
      if (url.isNotEmpty && !isVideoFile(url)) {
        precacheImage(CachedNetworkImageProvider(url), context);
      }
    }
  }

  // ── Search ──────────────────────────────────────────────────────────
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

      return users.where((user) {
        final uid = user['uid']?.toString() ?? '';
        return !blockedUsersSet.contains(uid) && uid != currentUserId;
      }).toList();
    } catch (e, st) {
      await _logSearchError(
        operationType: 'search_users',
        additionalData: {'query': query},
        error: e,
        stackTrace: st,
      );
      return [];
    }
  }

  void _onSearchChanged(String value) {
    setState(() {
      isShowUsers = value.trim().isNotEmpty;
      _isSearchFocused = false;
    });

    _debounceTimer?.cancel();
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

  // ── Skeleton loaders ────────────────────────────────────────────────
  Widget _buildPostsGridSkeleton(AppColorSet colors) {
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

  Widget _buildPostSkeleton(AppColorSet colors) => Container(
        decoration: BoxDecoration(
            color: colors.skeletonColor,
            borderRadius: BorderRadius.circular(8)),
      );

  Widget _buildUserSkeleton(AppColorSet colors) {
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

  Widget _buildUserSearchSkeleton(AppColorSet colors) {
    return ListView.builder(
      padding: const EdgeInsets.only(top: 8),
      itemCount: 5,
      itemBuilder: (_, __) => _buildUserSkeleton(colors),
    );
  }

  // ── Main build ──────────────────────────────────────────────────────
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

  Widget _buildEnhancedSkeletonLoading(AppColorSet colors) {
    return Column(children: [
      Expanded(child: _buildPostsGridSkeleton(colors)),
    ]);
  }

  Widget _buildUserSearch(AppColorSet colors) {
    if (_isSearching) return _buildUserSearchSkeleton(colors);

    if (_searchResults.isEmpty) {
      return Center(
        child:
            Text('No users found.', style: TextStyle(color: colors.textColor)),
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
                child: Text(username,
                    style: TextStyle(
                        color: colors.textColor, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
              ),
              if (isVerified) ...[
                const SizedBox(width: 4),
                const Icon(Icons.verified, color: Colors.blue, size: 16),
              ],
            ],
          ),
          subtitle: country.isNotEmpty
              ? Text(country,
                  style: TextStyle(color: colors.hintTextColor, fontSize: 12))
              : null,
          onTap: () => _navigateToProfile(uid),
        );
      },
    );
  }

  Widget _buildPostsGrid(AppColorSet colors) {
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
      AppColorSet colors) {
    final isVideo = isVideoFile(postUrl);
    final postId = post['postId']?.toString() ?? '';
    final editResult = parseEditResult(post);

    // Ensure media is loaded (service takes care of loop vs thumbnail)
    if (isVideo) {
      if (shouldShowVideoLoop(postId)) {
        _mediaService.initializeController(postUrl);
      } else {
        _mediaService.getThumbnailFuture(postUrl);
      }
    }

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
            // resume only the service's looping controllers
            _mediaService.resumeAll();
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
                ? (shouldShowVideoLoop(postId)
                    ? _buildVideoPlayer(postUrl, colors, editResult)
                    : _buildVideoThumbnail(postUrl, colors, editResult))
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

  // ── Video player (using service) ───────────────────────────────────
  Widget _buildVideoPlayer(String videoUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final controller = _mediaService.getController(videoUrl);
    final isInitialized = _mediaService.isControllerInitialized(videoUrl);
    if (!isInitialized || controller == null) {
      return Container(
        color: colors.gridItemBackgroundColor,
        child: Center(
            child: CircularProgressIndicator(
                color: colors.progressIndicatorColor)),
      );
    }

    final List<double> matrix = buildColorMatrix(editResult);
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
                    builder: (context, constraints) => buildEditOverlayLayer(
                      editResult: editResult,
                      constraints: constraints,
                      screenSize: MediaQuery.of(context).size,
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _buildVideoThumbnail(String videoUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    return AspectRatio(
      aspectRatio: 0.75,
      child: FutureBuilder<Uint8List?>(
        future: _mediaService.getThumbnailFuture(videoUrl),
        builder: (context, snapshot) {
          final haveImage = snapshot.connectionState == ConnectionState.done &&
              snapshot.data != null;

          Widget imageLayer = haveImage
              ? Image.memory(snapshot.data!, fit: BoxFit.cover)
              : Container(color: colors.gridItemBackgroundColor);

          imageLayer = ColorFiltered(
            colorFilter: ColorFilter.matrix(matrix),
            child: Transform.rotate(
              angle: quarters * math.pi / 2,
              child: imageLayer,
            ),
          );

          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Stack(fit: StackFit.expand, children: [
              Positioned.fill(child: imageLayer),
              if (editResult != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: LayoutBuilder(
                      builder: (context, constraints) => buildEditOverlayLayer(
                        editResult: editResult,
                        constraints: constraints,
                        screenSize: MediaQuery.of(context).size,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: const Icon(
                    Icons.play_arrow,
                    color: Colors.white,
                    size: 14,
                  ),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }

  Widget _buildPostImage(String imageUrl, AppColorSet colors,
      [VideoEditResult? editResult]) {
    final List<double> matrix = buildColorMatrix(editResult);
    final int quarters = editResult?.rotationQuarters ?? 0;

    Widget networkImage = CachedNetworkImage(
      imageUrl: imageUrl,
      fit: BoxFit.cover,
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
                builder: (context, constraints) => buildEditOverlayLayer(
                  editResult: editResult,
                  constraints: constraints,
                  screenSize: MediaQuery.of(context).size,
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildUserAvatar(String? photoUrl, AppColorSet colors) {
    final url = photoUrl?.toString() ?? '';
    final isDefault = url.isEmpty || url == 'default';
    final isVideo = !isDefault && isVideoFile(url);

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
      backgroundImage: CachedNetworkImageProvider(url),
    );
  }

  Widget _buildAvatarVideoPlayer(String videoUrl, AppColorSet colors) {
    final controller = _avatarVideoControllers[videoUrl];
    final isInitialized = _avatarVideoControllersInitialized[videoUrl] == true;
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
}
