import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:provider/provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:video_player/video_player.dart';
import 'package:Ratedly/screens/Profile_page/gallery_post_view_screen.dart';

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

class GalleryDetailScreen extends StatefulWidget {
  final String galleryId;
  final String galleryName;
  final String uid;

  const GalleryDetailScreen({
    Key? key,
    required this.galleryId,
    required this.galleryName,
    required this.uid,
  }) : super(key: key);

  @override
  State<GalleryDetailScreen> createState() => _GalleryDetailScreenState();
}

class _GalleryDetailScreenState extends State<GalleryDetailScreen> {
  final SupabaseClient _supabase = Supabase.instance.client;
  List<dynamic> _galleryPosts = [];
  List<dynamic> _availablePosts = [];
  bool _isLoading = true;
  bool _showAddPosts = false;

  // Video player controllers cache
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  // Helper method to get the appropriate color scheme
  _ColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _DarkColors() : _LightColors();
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

  /// Get video controller for a URL, initializing if needed
  VideoPlayerController? _getVideoController(String videoUrl) {
    return _videoControllers[videoUrl];
  }

  /// Check if video controller is initialized
  bool _isVideoControllerInitialized(String videoUrl) {
    return _videoControllersInitialized[videoUrl] == true;
  }

  // UPDATED: Video player that properly fills the entire square space WITHOUT play button
  Widget _buildVideoPlayer(String videoUrl, _ColorSet colors) {
    final controller = _getVideoController(videoUrl);
    final isInitialized = _isVideoControllerInitialized(videoUrl);

    if (!isInitialized || controller == null) {
      return Container(
        color: colors.cardColor,
        child: Center(
          child: CircularProgressIndicator(
            color: colors.textColor,
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      height: double.infinity,
      color: colors.cardColor,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: FittedBox(
          fit: BoxFit.cover, // Ensures video covers the entire square
          child: SizedBox(
            width: controller.value.size.width,
            height: controller.value.size.height,
            child: VideoPlayer(controller),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _loadGalleryData();
  }

  @override
  void dispose() {
    // Dispose all video controllers
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    super.dispose();
  }

  Future<void> _loadGalleryData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Load posts in this gallery
      final galleryPostsResponse =
          await _supabase.from('gallery_posts').select('''
            post_id,
            posts!inner(postId, postUrl, description, datePublished)
          ''').eq('gallery_id', widget.galleryId);

      // Load user's available posts (not in this gallery)
      final userPostsResponse = await _supabase
          .from('posts')
          .select('postId, postUrl, description, datePublished')
          .eq('uid', widget.uid)
          .order('datePublished', ascending: false);

      // Get posts that are already in the gallery
      final galleryPostIds = (galleryPostsResponse as List)
          .map((item) => item['posts']['postId'] as String)
          .toList();

      // Filter available posts to exclude those already in the gallery
      final availablePosts = (userPostsResponse as List)
          .where((post) => !galleryPostIds.contains(post['postId']))
          .toList();

      // Pre-initialize video controllers for video posts in both lists
      for (final post in galleryPostsResponse) {
        final postUrl = post['posts']['postUrl'] ?? '';
        if (_isVideoFile(postUrl)) {
          _initializeVideoController(postUrl);
        }
      }

      for (final post in availablePosts) {
        final postUrl = post['postUrl'] ?? '';
        if (_isVideoFile(postUrl)) {
          _initializeVideoController(postUrl);
        }
      }

      if (mounted) {
        setState(() {
          _galleryPosts = galleryPostsResponse;
          _availablePosts = availablePosts;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        showSnackBar(context, 'Failed to load gallery: $e');
      }
    }
  }

  Future<void> _addPostToGallery(String postId) async {
    try {
      await _supabase.from('gallery_posts').insert({
        'gallery_id': widget.galleryId,
        'post_id': postId,
        'added_by': widget.uid,
      });

      // Reload data
      await _loadGalleryData();

      if (mounted) {
        showSnackBar(context, 'Post added to gallery');
      }
    } catch (e) {
      if (mounted) {
        showSnackBar(context, 'Failed to add post: $e');
      }
    }
  }

  Future<void> _removePostFromGallery(String postId) async {
    try {
      await _supabase
          .from('gallery_posts')
          .delete()
          .eq('gallery_id', widget.galleryId)
          .eq('post_id', postId);

      // Reload data
      await _loadGalleryData();

      if (mounted) {
        showSnackBar(context, 'Post removed from gallery');
      }
    } catch (e) {
      if (mounted) {
        showSnackBar(context, 'Failed to remove post: $e');
      }
    }
  }

  void _updateGalleryCover(String postId) async {
    try {
      await _supabase
          .from('galleries')
          .update({'cover_post_id': postId}).eq('id', widget.galleryId);

      if (mounted) {
        showSnackBar(context, 'Cover image updated');
        // You might want to refresh the parent screen here
      }
    } catch (e) {
      if (mounted) {
        showSnackBar(context, 'Failed to update cover: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.galleryName),
        backgroundColor: colors.backgroundColor,
        foregroundColor: colors.textColor,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(_showAddPosts ? Icons.collections : Icons.add),
            onPressed: () {
              setState(() {
                _showAddPosts = !_showAddPosts;
              });
            },
            tooltip: _showAddPosts ? 'View Gallery' : 'Add Posts',
          ),
        ],
      ),
      backgroundColor: colors.backgroundColor,
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(color: colors.textColor),
            )
          : _showAddPosts
              ? _buildAddPostsView(colors)
              : _buildGalleryView(colors),
    );
  }

  Widget _buildGalleryView(_ColorSet colors) {
    if (_galleryPosts.isEmpty) {
      return Center(
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
            const SizedBox(height: 8),
            Text(
              'Tap the + button to add posts to this gallery',
              style: TextStyle(
                color: colors.textColor.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: _galleryPosts.length,
      itemBuilder: (context, index) {
        final galleryPost = _galleryPosts[index];
        final post = galleryPost['posts'];
        final postUrl = post['postUrl'] ?? '';
        final isVideo = _isVideoFile(postUrl);

        return GestureDetector(
          onTap: () {
            // Convert gallery posts to the format needed for the post view screen
            final List<Map<String, dynamic>> postsForView =
                _galleryPosts.map<Map<String, dynamic>>((galleryPost) {
              return {
                'postId': galleryPost['posts']['postId']?.toString() ?? '',
                'postUrl': galleryPost['posts']['postUrl']?.toString() ?? '',
                'description':
                    galleryPost['posts']['description']?.toString() ?? '',
                'uid': galleryPost['posts']['uid']?.toString() ?? '',
                'datePublished':
                    galleryPost['posts']['datePublished']?.toString() ?? '',
              };
            }).toList();

            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => GalleryPostViewScreen(
                  posts: postsForView,
                  initialIndex: index,
                  galleryName: widget.galleryName,
                ),
              ),
            );
          },
          child: Stack(
            children: [
              // Video or Image content - wrapped in Container to ensure consistent sizing
              Container(
                width: double.infinity,
                height: double.infinity,
                child: isVideo
                    ? _buildVideoPlayer(postUrl, colors)
                    : Image.network(
                        postUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: colors.cardColor,
                            child: Icon(
                              Icons.broken_image,
                              color: colors.iconColor,
                            ),
                          );
                        },
                      ),
              ),

              // Menu button
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, color: Colors.white, size: 16),
                    onSelected: (value) {
                      if (value == 'remove') {
                        _removePostFromGallery(post['postId']);
                      } else if (value == 'set_cover') {
                        _updateGalleryCover(post['postId']);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'set_cover',
                        child: Text('Set as Cover',
                            style: TextStyle(fontSize: 14)),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Remove from Gallery',
                            style: TextStyle(fontSize: 14)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAddPostsView(_ColorSet colors) {
    if (_availablePosts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.photo_library,
              size: 64,
              color: colors.textColor.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No Available Posts',
              style: TextStyle(
                color: colors.textColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'All your posts are already in this gallery\nor you haven\'t created any posts yet',
              style: TextStyle(
                color: colors.textColor.withOpacity(0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
        childAspectRatio: 1,
      ),
      itemCount: _availablePosts.length,
      itemBuilder: (context, index) {
        final post = _availablePosts[index];
        final postUrl = post['postUrl'] ?? '';
        final isVideo = _isVideoFile(postUrl);

        return GestureDetector(
          onTap: () => _addPostToGallery(post['postId']),
          child: Stack(
            children: [
              // Video or Image content - wrapped in Container
              Container(
                width: double.infinity,
                height: double.infinity,
                child: isVideo
                    ? _buildVideoPlayer(postUrl, colors)
                    : Image.network(
                        postUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            color: colors.cardColor,
                            child: Icon(
                              Icons.broken_image,
                              color: colors.iconColor,
                            ),
                          );
                        },
                      ),
              ),

              // Add overlay
              Container(
                color: Colors.black54,
                child: Center(
                  child: Icon(
                    Icons.add,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
