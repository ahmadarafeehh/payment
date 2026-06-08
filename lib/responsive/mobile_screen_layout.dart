import 'dart:async';
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:Ratedly/utils/global_variable.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/resources/notification_read.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/screens/feed/post_card.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:Ratedly/screens/Profile_page/custom_camera_screen.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';

// ============================================================================
// Color schemes (unchanged)
// ============================================================================
class _NavColorSet {
  final Color backgroundColor;
  final Color iconColor;
  final Color indicatorColor;
  final Color badgeBackgroundColor;
  final Color badgeTextColor;

  _NavColorSet({
    required this.backgroundColor,
    required this.iconColor,
    required this.indicatorColor,
    required this.badgeBackgroundColor,
    required this.badgeTextColor,
  });
}

class _NavDarkColors extends _NavColorSet {
  _NavDarkColors()
      : super(
          backgroundColor: const Color(0xFF121212),
          iconColor: Colors.white,
          indicatorColor: Colors.white,
          badgeBackgroundColor: const Color(0xFF333333),
          badgeTextColor: const Color(0xFFd9d9d9),
        );
}

class _NavLightColors extends _NavColorSet {
  _NavLightColors()
      : super(
          backgroundColor: Colors.white,
          iconColor: Colors.black,
          indicatorColor: Colors.black,
          badgeBackgroundColor: Colors.grey[300]!,
          badgeTextColor: Colors.black,
        );
}

// ============================================================================
// Main screen
// ============================================================================
class MobileScreenLayout extends StatefulWidget {
  const MobileScreenLayout({Key? key}) : super(key: key);

  @override
  State<MobileScreenLayout> createState() => _MobileScreenLayoutState();
}

class _MobileScreenLayoutState extends State<MobileScreenLayout> {
  int _page = 0;
  late PageController pageController;

  @override
  void initState() {
    super.initState();
    pageController = PageController();
  }

  @override
  void dispose() {
    pageController.dispose();
    super.dispose();
  }

  void onPageChanged(int page) {
    setState(() {
      _page = page;
    });
  }

  void _pauseCurrentVideo() {
    VideoManager().pauseCurrentVideo();
  }

  void navigationTapped(int page) async {
    _pauseCurrentVideo();

    if (page == 2) {
      final userProvider = Provider.of<UserProvider>(context, listen: false);
      final currentUserUid =
          userProvider.firebaseUid ?? FirebaseAuth.instance.currentUser?.uid;
      if (currentUserUid != null) {
        // Mark only notifications as read – messages are untouched
        await NotificationService.markNotificationsAsRead(currentUserUid);
        // Immediately remove the app icon badge (it will be recalculated later)
        FlutterAppBadger.removeBadge();
      }
    }
    pageController.jumpToPage(page);
  }

  void _openCamera() {
    _pauseCurrentVideo();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const CustomCameraScreen(),
      ),
    );
  }

  _NavColorSet _getColors(ThemeProvider themeProvider) {
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    return isDarkMode ? _NavDarkColors() : _NavLightColors();
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colors = _getColors(themeProvider);
    final userProvider = Provider.of<UserProvider>(context);
    final currentUserUid = userProvider.firebaseUid ??
        FirebaseAuth.instance.currentUser?.uid ??
        '';

    return Scaffold(
      // ── FIX: Prevent the root Scaffold from shrinking its body when the
      //    keyboard opens.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          SafeArea(
            top: false,
            bottom: false,
            child: PageView(
              controller: pageController,
              onPageChanged: onPageChanged,
              children: homeScreenItems(context),
              physics: const NeverScrollableScrollPhysics(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _buildBottomNavBar(currentUserUid, colors),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNavBar(String currentUserId, _NavColorSet colors) {
    return SafeArea(
      top: false,
      child: Container(
        height: 50,
        margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildNavItem(Icons.home, 0, colors),
            _buildNavItem(Icons.search, 1, colors),
            _buildPlusButton(colors),
            _buildNotificationNavItem(currentUserId, 2, colors),
            _buildNavItem(Icons.person, 3, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem(IconData icon, int index, _NavColorSet colors) {
    final isActive = _page == index;

    return InkWell(
      onTap: () => navigationTapped(index),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isActive
              ? colors.indicatorColor.withOpacity(0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: isActive
                  ? colors.indicatorColor
                  : colors.iconColor.withOpacity(0.9),
              size: 20,
            ),
            if (isActive) ...[
              const SizedBox(height: 2),
              Container(
                height: 2,
                width: 4,
                decoration: BoxDecoration(
                  color: colors.indicatorColor,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlusButton(_NavColorSet colors) {
    return GestureDetector(
      onTap: _openCamera,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          border: Border.all(
            color: colors.iconColor.withOpacity(0.7),
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          Icons.add,
          color: colors.iconColor.withOpacity(0.9),
          size: 20,
        ),
      ),
    );
  }

  Widget _buildNotificationNavItem(
      String userId, int index, _NavColorSet colors) {
    final isActive = _page == index;

    return InkWell(
      onTap: () => navigationTapped(index),
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isActive
              ? colors.indicatorColor.withOpacity(0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _UltraCompactNotificationBadgeIcon(
              currentUserId: userId,
              currentPage: _page,
              pageIndex: index,
              badgeBackgroundColor: colors.badgeBackgroundColor,
              badgeTextColor: colors.badgeTextColor,
              isActive: isActive,
              iconColor: colors.iconColor,
              indicatorColor: colors.indicatorColor,
            ),
            if (isActive) ...[
              const SizedBox(height: 2),
              Container(
                height: 2,
                width: 4,
                decoration: BoxDecoration(
                  color: colors.indicatorColor,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// Notification badge icon – in‑app shows only notifications,
// while the home‑screen app badge shows notifications + messages.
// ============================================================================
class _UltraCompactNotificationBadgeIcon extends StatefulWidget {
  final String currentUserId;
  final int currentPage;
  final int pageIndex;
  final Color badgeBackgroundColor;
  final Color badgeTextColor;
  final bool isActive;
  final Color iconColor;
  final Color indicatorColor;

  const _UltraCompactNotificationBadgeIcon({
    Key? key,
    required this.currentUserId,
    required this.currentPage,
    required this.pageIndex,
    required this.badgeBackgroundColor,
    required this.badgeTextColor,
    required this.isActive,
    required this.iconColor,
    required this.indicatorColor,
  }) : super(key: key);

  @override
  State<_UltraCompactNotificationBadgeIcon> createState() =>
      _UltraCompactNotificationBadgeIconState();
}

class _UltraCompactNotificationBadgeIconState
    extends State<_UltraCompactNotificationBadgeIcon>
    with WidgetsBindingObserver {
  int _totalUnreadCount = 0; // in‑app badge shows only notifications
  bool _hasLoaded = false;

  StreamSubscription<List<Map<String, dynamic>>>? _notificationStream;
  StreamSubscription<List<Map<String, dynamic>>>? _messageStream;
  Timer? _pollingTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadCounts();
    _setupStreams();
    _startPolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadCounts();
    }
  }

  Future<void> _loadCounts() async {
    try {
      if (widget.currentUserId.isEmpty) return;
      final supabase = Supabase.instance.client;

      // 1. Unread notifications (exclude messages)
      final notifs = await supabase
          .from('notifications')
          .select('id, is_read, type')
          .eq('target_user_id', widget.currentUserId)
          .eq('is_read', false)
          .neq('type', 'message');

      // 2. Unread messages
      final msgs = await supabase
          .from('messages')
          .select('id, is_read')
          .eq('receiver_id', widget.currentUserId)
          .eq('is_read', false);

      final notificationsCount = notifs.length;
      final messagesCount = msgs.length;

      if (mounted) {
        setState(() {
          // In‑app badge shows notifications only
          _totalUnreadCount = notificationsCount;
          _hasLoaded = true;
        });

        // App icon badge shows combined total
        FlutterAppBadger.updateBadgeCount(notificationsCount + messagesCount);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _totalUnreadCount = 0;
          _hasLoaded = true;
        });
      }
    }
  }

  void _setupStreams() {
    if (widget.currentUserId.isEmpty) return;
    final supabase = Supabase.instance.client;

    // Stream for notifications
    _notificationStream = supabase
        .from('notifications')
        .stream(primaryKey: ['id'])
        .eq('target_user_id', widget.currentUserId)
        .listen((_) => _loadCounts());

    // Stream for messages
    _messageStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('receiver_id', widget.currentUserId)
        .listen((_) => _loadCounts());
  }

  void _startPolling() {
    _pollingTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && widget.currentUserId.isNotEmpty) {
        _loadCounts();
      }
    });
  }

  @override
  void didUpdateWidget(_UltraCompactNotificationBadgeIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUserId != widget.currentUserId) {
      _loadCounts();
    }
    // 👇 This is the fix: when the user taps the notification tab,
    // the badge counts are reloaded immediately.
    if (widget.currentPage == widget.pageIndex &&
        oldWidget.currentPage != widget.pageIndex) {
      _loadCounts();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationStream?.cancel();
    _messageStream?.cancel();
    _pollingTimer?.cancel();
    super.dispose();
  }

  String _formatCount(int count) {
    if (count <= 0) return '0';
    if (count < 1000) return count.toString();
    if (count < 10000) return '${(count / 1000).toStringAsFixed(1)}k';
    return '9+';
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;

    final badgeBackgroundColor =
        isDarkMode ? const Color(0xFF333333) : Colors.white;
    final badgeTextColor = isDarkMode ? const Color(0xFFd9d9d9) : Colors.black;

    final shouldShowBadge = _totalUnreadCount > 0;
    final displayCount = _formatCount(_totalUnreadCount);

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Icon(
          Icons.favorite,
          color: widget.isActive
              ? widget.indicatorColor
              : widget.iconColor.withOpacity(0.9),
          size: 20,
        ),
        Positioned(
          top: -4,
          right: -5,
          child: AnimatedOpacity(
            opacity: shouldShowBadge ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 200),
            child: Container(
              padding: const EdgeInsets.all(2),
              constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
              decoration: BoxDecoration(
                color: badgeBackgroundColor,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  displayCount.length > 2 ? '9+' : displayCount,
                  style: TextStyle(
                    color: badgeTextColor,
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                    height: 1.0,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
