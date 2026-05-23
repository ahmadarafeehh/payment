import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/Profile_page/profile_page.dart';
import 'package:timeago/timeago.dart' as timeago;
import 'package:provider/provider.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/widgets/verified_username_widget.dart';
import 'package:video_player/video_player.dart';

// VIDEO UTILS CLASS - Add this at the top
class VideoUtils {
  static bool isVideoFile(String url) {
    if (url.isEmpty) return false;
    final lowerUrl = url.toLowerCase();
    return url.isNotEmpty &&
        url != 'default' &&
        (lowerUrl.endsWith('.mp4') ||
            lowerUrl.endsWith('.mov') ||
            lowerUrl.endsWith('.avi') ||
            lowerUrl.endsWith('.mkv') ||
            lowerUrl.contains('video'));
  }
}

// VIDEO PROFILE AVATAR WIDGET - Add this after VideoUtils
class VideoProfileAvatar extends StatefulWidget {
  final String videoUrl;
  final double radius;
  final Color backgroundColor;
  final Color iconColor;
  final bool forcedTransparent;

  const VideoProfileAvatar({
    Key? key,
    required this.videoUrl,
    required this.radius,
    required this.backgroundColor,
    required this.iconColor,
    this.forcedTransparent = false,
  }) : super(key: key);

  @override
  State<VideoProfileAvatar> createState() => _VideoProfileAvatarState();
}

class _VideoProfileAvatarState extends State<VideoProfileAvatar> {
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isVideoMuted = true;

  @override
  void initState() {
    super.initState();
    if (VideoUtils.isVideoFile(widget.videoUrl)) {
      _initializeVideo();
    }
  }

  Future<void> _initializeVideo() async {
    try {
      _videoController = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      await _videoController!.initialize();
      await _videoController!.setVolume(0.0);
      await _videoController!.setLooping(true);
      await _videoController!.play();

      if (mounted) {
        setState(() {
          _isVideoInitialized = true;
          _isVideoMuted = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isVideoInitialized = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isVideoInitialized || _videoController == null) {
      return Container(
        width: widget.radius * 2,
        height: widget.radius * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.backgroundColor,
        ),
        child: Center(
          child: CircularProgressIndicator(
            color: widget.iconColor,
            strokeWidth: 2.0,
          ),
        ),
      );
    }

    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: _videoController!.value.size.width,
            height: _videoController!.value.size.height,
            child: VideoPlayer(_videoController!),
          ),
        ),
      ),
    );
  }
}

// Define color schemes for both themes at top level
class _UserListColorSet {
  final Color textColor;
  final Color backgroundColor;
  final Color cardColor;
  final Color iconColor;
  final Color appBarBackgroundColor;
  final Color appBarIconColor;

  _UserListColorSet({
    required this.textColor,
    required this.backgroundColor,
    required this.cardColor,
    required this.iconColor,
    required this.appBarBackgroundColor,
    required this.appBarIconColor,
  });
}

class _UserListDarkColors extends _UserListColorSet {
  _UserListDarkColors()
      : super(
          textColor: const Color(0xFFd9d9d9),
          backgroundColor: const Color(0xFF121212),
          cardColor: const Color(0xFF333333),
          iconColor: const Color(0xFFd9d9d9),
          appBarBackgroundColor: const Color(0xFF121212),
          appBarIconColor: const Color(0xFFd9d9d9),
        );
}

class _UserListLightColors extends _UserListColorSet {
  _UserListLightColors()
      : super(
          textColor: Colors.black,
          backgroundColor: Colors.white,
          cardColor: Colors.grey[100]!,
          iconColor: Colors.black,
          appBarBackgroundColor: Colors.white,
          appBarIconColor: Colors.black,
        );
}

class UserListScreen extends StatelessWidget {
  final String title;
  final List<dynamic> userEntries;

  const UserListScreen({
    Key? key,
    required this.title,
    required this.userEntries,
  }) : super(key: key);

  // Helper method to get the appropriate color scheme
  _UserListColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _UserListDarkColors() : _UserListLightColors();
  }

  List<Map<String, dynamic>> _getValidEntries() {
    final Set<String> uniqueUserIds = {};
    return userEntries
        .map((entry) {
          final userId = entry['userId'] ?? entry['raterUserId'];
          if (userId == null) return null;
          final userIdStr = userId.toString();

          if (uniqueUserIds.contains(userIdStr)) return null;
          uniqueUserIds.add(userIdStr);

          return {
            'userId': userIdStr,
            'timestamp': entry['timestamp'] ?? DateTime.now(),
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final currentUser = Provider.of<UserProvider>(context).user;
    final entries = _getValidEntries();

    if (currentUser == null) {
      return Scaffold(
        backgroundColor: colors.backgroundColor,
        body: Center(child: CircularProgressIndicator(color: colors.textColor)),
      );
    }

    return Scaffold(
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        title: Text(title, style: TextStyle(color: colors.textColor)),
        backgroundColor: colors.appBarBackgroundColor,
        iconTheme: IconThemeData(color: colors.appBarIconColor),
        centerTitle: true,
      ),
      body: _PaginatedUserList(
        title: title,
        entries: entries,
        colors: colors,
      ),
    );
  }
}

class _PaginatedUserList extends StatefulWidget {
  final String title;
  final List<Map<String, dynamic>> entries;
  final _UserListColorSet colors;

  const _PaginatedUserList({
    required this.title,
    required this.entries,
    required this.colors,
  });

  @override
  State<_PaginatedUserList> createState() => _PaginatedUserListState();
}

class _PaginatedUserListState extends State<_PaginatedUserList> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final List<Map<String, dynamic>> _loadedUsers = [];
  final Set<String> _loadedUserIds = {};

  // Video controllers for profile pictures
  final Map<String, VideoPlayerController> _videoControllers = {};
  final Map<String, bool> _videoControllersInitialized = {};

  bool _isLoading = false;
  bool _hasMore = true;
  int _nextIndex = 0;
  final ScrollController _scrollController = ScrollController();
  bool _initialLoadComplete = false;

  @override
  void initState() {
    super.initState();
    _loadNextBatch();
    _scrollController.addListener(_scrollListener);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // Dispose all video controllers
    for (final controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _videoControllersInitialized.clear();
    super.dispose();
  }

  void _scrollListener() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        _hasMore) {
      _loadNextBatch();
    }
  }

  Future<void> _loadNextBatch() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final batchSize = _initialLoadComplete ? 5 : 10;
      final startIndex = _nextIndex;
      final endIndex = (_nextIndex + batchSize).clamp(0, widget.entries.length);

      if (startIndex >= endIndex) {
        setState(() {
          _isLoading = false;
          _hasMore = false;
        });
        return;
      }

      final batchEntries = widget.entries.sublist(startIndex, endIndex);
      final newBatchEntries = batchEntries.where((entry) {
        final userId = entry['userId'] as String;
        return !_loadedUserIds.contains(userId);
      }).toList();

      if (newBatchEntries.isEmpty) {
        setState(() {
          _nextIndex = endIndex;
          _hasMore = _nextIndex < widget.entries.length;
          _isLoading = false;
        });
        return;
      }

      final batchUserIds =
          newBatchEntries.map((e) => e['userId'] as String).toList();

      String orCondition = batchUserIds.map((id) => 'uid.eq.$id').join(',');

      final usersResponse =
          await _supabase.from('users').select().or(orCondition);

      final usersMap = {for (var user in usersResponse) user['uid']: user};

      setState(() {
        for (var entry in newBatchEntries) {
          final userId = entry['userId'] as String;

          if (_loadedUserIds.contains(userId)) continue;

          final userData =
              usersMap[userId] ?? {'username': 'UserNotFound', 'photoUrl': ''};
          _loadedUsers.add({
            'id': userId,
            'data': userData,
            'entry': entry,
          });
          _loadedUserIds.add(userId);

          // Initialize video controller if profile picture is a video
          final photoUrl = userData['photoUrl'] ?? '';
          if (VideoUtils.isVideoFile(photoUrl)) {
            _initializeVideoController(userId, photoUrl);
          }
        }

        _nextIndex = endIndex;
        _hasMore = _nextIndex < widget.entries.length;
        _isLoading = false;
        _initialLoadComplete = true;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _initializeVideoController(
      String userId, String videoUrl) async {
    if (_videoControllers.containsKey(userId) ||
        _videoControllersInitialized[userId] == true) {
      return;
    }

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(videoUrl),
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
        ),
      );

      _videoControllers[userId] = controller;
      _videoControllersInitialized[userId] = false;

      await controller.initialize();
      await controller.setVolume(0.0);
      await controller.setLooping(true);
      await controller.play();

      _videoControllersInitialized[userId] = true;

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      _videoControllers.remove(userId)?.dispose();
      _videoControllersInitialized.remove(userId);
    }
  }

  Widget _buildUserAvatar(String userId, String photoUrl, bool isPlaceholder) {
    final hasValidPhoto =
        photoUrl.isNotEmpty && photoUrl != "default" && photoUrl != "null";
    final isVideo = hasValidPhoto && VideoUtils.isVideoFile(photoUrl);

    if (isPlaceholder || !hasValidPhoto) {
      return CircleAvatar(
        backgroundColor: widget.colors.cardColor,
        radius: 21,
        child: Icon(
          Icons.account_circle,
          size: 42,
          color: widget.colors.iconColor,
        ),
      );
    }

    if (isVideo) {
      final controller = _videoControllers[userId];
      final isInitialized = _videoControllersInitialized[userId] == true;

      if (!isInitialized || controller == null) {
        return Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.colors.cardColor,
          ),
          child: Center(
            child: CircularProgressIndicator(
              color: widget.colors.iconColor,
              strokeWidth: 2.0,
            ),
          ),
        );
      }

      return ClipOval(
        child: SizedBox(
          width: 42,
          height: 42,
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

    // Regular image
    return CircleAvatar(
      backgroundColor: widget.colors.cardColor,
      radius: 21,
      backgroundImage: NetworkImage(photoUrl),
    );
  }

  Widget _buildListItem(int index) {
    if (index >= _loadedUsers.length) return const SizedBox.shrink();

    final user = _loadedUsers[index];
    final userId = user['id'] as String;
    final userData = user['data'] as Map<String, dynamic>;
    final entry = user['entry'] as Map<String, dynamic>;

    DateTime timestamp;
    if (entry['timestamp'] is DateTime) {
      timestamp = entry['timestamp'] as DateTime;
    } else if (entry['timestamp'] is String) {
      timestamp = DateTime.parse(entry['timestamp'] as String);
    } else {
      timestamp = DateTime.now();
    }

    final isPlaceholder = userData['username'] == 'UserNotFound';
    final photoUrl = userData['photoUrl'] ?? '';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: widget.colors.cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: ListTile(
        leading: _buildUserAvatar(userId, photoUrl, isPlaceholder),
        title: VerifiedUsernameWidget(
          username: isPlaceholder
              ? 'UserNotFound'
              : userData['username'] ?? 'Anonymous',
          uid: userId,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: widget.colors.textColor,
          ),
        ),
        subtitle: Text(
          timeago.format(timestamp),
          style: TextStyle(color: widget.colors.textColor.withOpacity(0.6)),
        ),
        onTap: isPlaceholder
            ? null
            : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ProfileScreen(uid: userId),
                  ),
                ),
      ),
    );
  }

  Widget _buildLoadMoreButton() {
    if (!_hasMore) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        child: _isLoading
            ? CircularProgressIndicator(color: widget.colors.textColor)
            : TextButton(
                onPressed: _loadNextBatch,
                child: Text(
                  'Load more',
                  style: TextStyle(
                    color: widget.colors.textColor,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_alt_outlined,
              size: 40, color: widget.colors.textColor.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            'No data available',
            style: TextStyle(
              color: widget.colors.textColor.withOpacity(0.8),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return _buildEmptyState();
    }

    return Column(
      children: [
        Expanded(
          child: ListView.separated(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            separatorBuilder: (context, index) =>
                Divider(color: widget.colors.cardColor, height: 1),
            itemCount: _loadedUsers.length,
            itemBuilder: (context, index) => _buildListItem(index),
          ),
        ),
        _buildLoadMoreButton(),
      ],
    );
  }
}
