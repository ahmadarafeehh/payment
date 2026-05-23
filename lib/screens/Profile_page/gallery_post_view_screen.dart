import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/screens/feed/post_card.dart';
import 'package:Ratedly/screens/comment_screen.dart';

// Use the same color scheme as your profile screen
class _ColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;

  _ColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
  });
}

class _DarkColors extends _ColorSet {
  _DarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
        );
}

class _LightColors extends _ColorSet {
  _LightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.grey[100]!,
          cardColor: Colors.white,
          iconColor: Colors.grey[700]!,
        );
}

class GalleryPostViewScreen extends StatefulWidget {
  final List<Map<String, dynamic>> posts;
  final int initialIndex;
  final String galleryName;

  const GalleryPostViewScreen({
    Key? key,
    required this.posts,
    required this.initialIndex,
    required this.galleryName,
  }) : super(key: key);

  @override
  State<GalleryPostViewScreen> createState() => _GalleryPostViewScreenState();
}

class _GalleryPostViewScreenState extends State<GalleryPostViewScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  final Map<String, bool> _postVisibility = {};
  String? _currentPlayingPostId;

  // Floating back button visibility
  bool _showBackButton = true;
  double _lastScrollOffset = 0;

  // Video player controllers cache
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  // Helper method to get the appropriate color scheme
  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
  }

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);

    // Initialize video controllers for all posts
    _initializeAllVideoControllers();

    // Set initial post as visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updatePostVisibility(_currentPage);
    });
  }

  // Helper method to detect video files by extension
  bool _isVideoFile(String url) {
    if (url.isEmpty) return false;

    final lowerUrl = url.toLowerCase();
    return lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.endsWith('.avi') ||
        lowerUrl.endsWith('.wmv') ||
        lowerUrl.endsWith('.flv') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.webm') ||
        lowerUrl.endsWith('.m4v') ||
        lowerUrl.endsWith('.3gp') ||
        lowerUrl.contains('/video/') ||
        lowerUrl.contains('video=true');
  }

  /// Initialize video controller for a video URL - only loads first second
  Future<void> _initializeVideoController(String videoUrl) async {
    if (_videoControllers.containsKey(videoUrl) ||
        _videoControllersInitialized[videoUrl] == true) {
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      // Store controller immediately to prevent duplicate initializations
      _videoControllers[videoUrl] = controller;
      _videoControllersInitialized[videoUrl] = false;

      // Set up listener for initialization
      controller.addListener(() {
        if (controller.value.isInitialized &&
            !_videoControllersInitialized[videoUrl]!) {
          _videoControllersInitialized[videoUrl] = true;

          // Configure the video to play only the first second on loop
          _configureVideoLoop(controller);

          if (mounted) {
            setState(() {});
          }
        }
      });

      // Initialize the controller but don't wait for full load
      await controller.initialize();

      // Mute the video
      await controller.setVolume(0.0);
    } catch (e) {
      // Clean up on error
      _videoControllers.remove(videoUrl)?.dispose();
      _videoControllersInitialized.remove(videoUrl);
    }
  }

  /// Initialize video controllers for all posts
  void _initializeAllVideoControllers() {
    for (final post in widget.posts) {
      final postUrl = post['postUrl'] ?? '';
      if (_isVideoFile(postUrl)) {
        _initializeVideoController(postUrl);
      }
    }
  }

  /// Configure video to play only first second on loop
  void _configureVideoLoop(VideoPlayerController controller) {
    final duration = controller.value.duration;

    // Determine the end position (1 second or video duration if shorter)
    final endPosition =
        duration.inSeconds > 0 ? const Duration(seconds: 1) : duration;

    // Set up position listener to create loop effect for first second
    controller.addListener(() {
      if (controller.value.isInitialized && controller.value.isPlaying) {
        final currentPosition = controller.value.position;
        if (currentPosition >= endPosition) {
          // Loop back to start
          controller.seekTo(Duration.zero);
        }
      }
    });

    // Start playing
    controller.play();
  }

  void _pauseCurrentVideo() {
    for (final controller in _videoControllers.values) {
      if (controller.value.isPlaying) {
        controller.pause();
      }
    }
    _currentPlayingPostId = null;
  }

  void _playCurrentVideo(String postId) {
    _pauseCurrentVideo();
    _currentPlayingPostId = postId;
  }

  void _updatePostVisibility(int page) {
    if (!mounted || widget.posts.isEmpty) return;

    final previouslyPlayingPostId = _currentPlayingPostId;
    String? newPlayingPostId;

    setState(() {
      // Reset all visibility first
      for (final post in widget.posts) {
        final postId = post['postId']?.toString() ?? '';
        if (postId.isNotEmpty) {
          _postVisibility[postId] = false;
        }
      }

      // Set current post as visible and playing
      if (page < widget.posts.length) {
        final currentPost = widget.posts[page];
        final postId = currentPost['postId']?.toString() ?? '';
        if (postId.isNotEmpty) {
          _postVisibility[postId] = true;
          newPlayingPostId = postId;
        }
      }

      // Keep previous post visible but not playing (for smooth transitions)
      if (page > 0) {
        final previousPost = widget.posts[page - 1];
        final previousPostId = previousPost['postId']?.toString() ?? '';
        if (previousPostId.isNotEmpty) {
          _postVisibility[previousPostId] = true;
        }
      }

      // Keep next post visible but not playing (for smooth transitions)
      if (page < widget.posts.length - 1) {
        final nextPost = widget.posts[page + 1];
        final nextPostId = nextPost['postId']?.toString() ?? '';
        if (nextPostId.isNotEmpty) {
          _postVisibility[nextPostId] = true;
        }
      }
    });

    // Only update current playing post if it actually changed
    if (newPlayingPostId != null &&
        newPlayingPostId != previouslyPlayingPostId) {
      _playCurrentVideo(newPlayingPostId!);
    }
  }

  void _onPageChanged(int page) {
    setState(() {
      _currentPage = page;
    });
    _updatePostVisibility(page);
  }

  bool _shouldPostPlayVideo(String postId) {
    return postId == _currentPlayingPostId && (_postVisibility[postId] == true);
  }

  void _openComments(BuildContext context, Map<String, dynamic> post) {
    final postId = post['postId']?.toString() ?? '';
    final isVideo = _isVideoFile(post['postUrl'] ?? '');
    final postImage = post['postUrl']?.toString() ?? '';

    // Ensure we have valid values before opening comments
    if (postId.isEmpty) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.4),
      isDismissible: true,
      enableDrag: true,
      builder: (context) => CommentsBottomSheet(
        postId: postId,
        postImage: postImage,
        isVideo: isVideo,
        onClose: () {},
      ),
    );
  }

  @override
  void dispose() {
    _pauseCurrentVideo();
    _pageController.dispose();

    // Dispose all video controllers
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      // Remove the app bar completely
      appBar: null,
      body: Stack(
        children: [
          // Main content
          _buildPostsPageView(colors),

          // Floating back button
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: AnimatedOpacity(
              opacity: _showBackButton ? 1.0 : 0.0,
              duration: Duration(milliseconds: 300),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(Icons.arrow_back, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPostsPageView(_ColorSet colors) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification scrollInfo) {
        if (scrollInfo is ScrollUpdateNotification) {
          final currentOffset = scrollInfo.metrics.pixels;
          final scrollDifference = currentOffset - _lastScrollOffset;

          // Hide back button when scrolling down, show when scrolling up
          if (scrollDifference > 5 && _showBackButton) {
            setState(() {
              _showBackButton = false;
            });
          } else if (scrollDifference < -5 && !_showBackButton) {
            setState(() {
              _showBackButton = true;
            });
          }

          _lastScrollOffset = currentOffset;
        }
        return false;
      },
      child: widget.posts.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.collections,
                    size: 64,
                    color: colors.textColor.withOpacity(0.5),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Posts in Gallery',
                    style: TextStyle(
                      color: colors.textColor,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            )
          : PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: widget.posts.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (ctx, index) {
                final post = widget.posts[index];
                final postId = post['postId']?.toString() ?? '';
                final isVisible = _shouldPostPlayVideo(postId);

                // Convert gallery post format to match PostCard expected format
                final formattedPost = _convertToPostCardFormat(post);

                return Container(
                  width: double.infinity,
                  height: double.infinity,
                  color: colors.backgroundColor,
                  child: PostCard(
                    snap: formattedPost,
                    isVisible: isVisible,
                    onCommentTap: () => _openComments(context, post),
                    onPostSeen: () {
                      // Optional: Track post views in gallery if needed
                    },
                  ),
                );
              },
            ),
    );
  }

  // Convert gallery post format to match PostCard expected format
  Map<String, dynamic> _convertToPostCardFormat(
      Map<String, dynamic> galleryPost) {
    // If the post is already in the correct format (from posts table), return as is
    if (galleryPost.containsKey('posts')) {
      final postData = galleryPost['posts'];
      return {
        'postId': postData['postId']?.toString() ?? '',
        'postUrl': postData['postUrl']?.toString() ?? '',
        'description': postData['description']?.toString() ?? '',
        'uid': postData['uid']?.toString() ?? '',
        'datePublished': postData['datePublished']?.toString() ?? '',
        'username': postData['username']?.toString() ?? '',
        'profImage': postData['profImage']?.toString() ?? '',
        // Add any other fields that PostCard might expect
      };
    }

    // Otherwise, assume it's already in the correct format
    return {
      'postId': galleryPost['postId']?.toString() ?? '',
      'postUrl': galleryPost['postUrl']?.toString() ?? '',
      'description': galleryPost['description']?.toString() ?? '',
      'uid': galleryPost['uid']?.toString() ?? '',
      'datePublished': galleryPost['datePublished']?.toString() ?? '',
      'username': galleryPost['username']?.toString() ?? '',
      'profImage': galleryPost['profImage']?.toString() ?? '',
    };
  }
}
