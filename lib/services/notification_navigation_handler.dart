import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/Profile_page/profile_post_feed_screen.dart';

final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

// ---------------------------------------------------------------------------
// NotificationNavigationHandler
// ---------------------------------------------------------------------------
class NotificationNavigationHandler {
  // Notification types that are linked to a specific post
  static const _postLinkedTypes = {
    'post_rating',
    'comment',
    'comment_like',
    'reply',
    'reply_like',
  };

  // ---------------------------------------------------------------------------
  // Cold-start support
  // ---------------------------------------------------------------------------
  // When the app is fully terminated and the user taps a notification, the
  // navigator isn't mounted yet. We store the data here and consume it once
  // the root widget calls executePendingNavigation().
  static Map<String, dynamic>? _pendingData;

  /// Call this from NotificationService.init() when getInitialMessage() returns
  /// a non-null message (app launched by a notification tap from terminated state).
  static void storePendingNavigation(Map<String, dynamic> data) {
    _pendingData = Map<String, dynamic>.from(data);
  }

  /// Call this from your root widget's initState (or didChangeDependencies)
  /// after MaterialApp has been built, so the navigator key is fully attached.
  ///
  /// Example in your root StatefulWidget:
  ///
  ///   @override
  ///   void initState() {
  ///     super.initState();
  ///     WidgetsBinding.instance.addPostFrameCallback((_) {
  ///       NotificationNavigationHandler.executePendingNavigation();
  ///     });
  ///   }
  static Future<void> executePendingNavigation() async {
    final data = _pendingData;
    if (data == null) return;
    _pendingData = null;
    await handleNotificationData(data);
  }

  // ---------------------------------------------------------------------------
  // Main entry point
  // ---------------------------------------------------------------------------
  /// Parses [data] (the FCM message.data map or a decoded local-notification
  /// payload) and pushes ProfilePostFeedScreen when the type is post-linked.
  static Future<void> handleNotificationData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();
    if (type == null || !_postLinkedTypes.contains(type)) return;

    final postId = _extractPostId(data);
    if (postId == null || postId.isEmpty) return;

    await _navigateToPost(postId);
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Extracts the postId from an FCM data map.
  ///
  /// Handles three layouts that Cloud Functions commonly produce:
  ///   1. Top-level  { "postId": "..." }
  ///   2. Nested map { "customData": { "postId": "..." } }
  ///   3. JSON string { "customData": "{\"postId\":\"...\"}" }
  static String? _extractPostId(Map<String, dynamic> data) {
    // 1. Top-level key (flattened FCM data payload)
    String? id = data['postId']?.toString() ?? data['post_id']?.toString();
    if (id != null && id.isNotEmpty) return id;

    // 2 & 3. Nested inside customData
    final raw = data['customData'];
    if (raw is Map) {
      id = raw['postId']?.toString() ?? raw['post_id']?.toString();
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        id = parsed['postId']?.toString() ?? parsed['post_id']?.toString();
      } catch (_) {}
    }
    return id;
  }

  static Future<void> _navigateToPost(String postId) async {
    final navState = notificationNavigatorKey.currentState;
    if (navState == null) return;

    try {
      final supabase = Supabase.instance.client;

      // 1. Fetch the target post
      final postRow = await supabase
          .from('posts')
          .select()
          .eq('postId', postId)
          .maybeSingle();
      if (postRow == null) return;

      final ownerUid = postRow['uid']?.toString() ?? '';
      if (ownerUid.isEmpty) return;

      // 2. Fetch the post owner's profile
      final userRow = await supabase
          .from('users')
          .select('uid, username, photoUrl')
          .eq('uid', ownerUid)
          .maybeSingle();
      if (userRow == null) return;

      final userData = Map<String, dynamic>.from(userRow as Map);

      // 3. Fetch the first page of the owner's posts (newest first)
      const int pageSize = 20;
      final rawPosts = await supabase
          .from('posts')
          .select()
          .eq('uid', ownerUid)
          .order('datePublished', ascending: false)
          .limit(pageSize);

      final posts = List<Map<String, dynamic>>.from(
        (rawPosts as List).map((p) => Map<String, dynamic>.from(p as Map)),
      );

      // 4. Find the target post; prepend it when it falls outside page 1
      //    (e.g. an older post linked from a notification).
      int targetIndex =
          posts.indexWhere((p) => p['postId']?.toString() == postId);
      if (targetIndex == -1) {
        posts.insert(0, Map<String, dynamic>.from(postRow as Map));
        targetIndex = 0;
      }

      // 5. Push the feed screen
      navState.push(
        MaterialPageRoute(
          builder: (_) => ProfilePostFeedScreen(
            initialPosts: posts,
            initialIndex: targetIndex,
            userData: userData,
            initialHasMore: posts.length == pageSize,
            onLoadMore: (currentCount) async {
              final more = await supabase
                  .from('posts')
                  .select()
                  .eq('uid', ownerUid)
                  .order('datePublished', ascending: false)
                  .range(currentCount, currentCount + pageSize - 1);
              return List<Map<String, dynamic>>.from(
                (more as List).map((p) => Map<String, dynamic>.from(p as Map)),
              );
            },
          ),
        ),
      );
    } catch (_) {
      // Fail silently – navigation errors must never crash the app
    }
  }
}
