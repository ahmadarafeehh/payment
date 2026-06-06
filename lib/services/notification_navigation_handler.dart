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
  // navigator isn't mounted yet.  We store the data here and consume it once
  // executePendingNavigation() is called from NotificationService.init() after
  // getInitialMessage() resolves (at which point the navigator is guaranteed
  // to be attached).
  static Map<String, dynamic>? _pendingData;

  /// Call this from NotificationService.init() when getInitialMessage() returns
  /// a non-null message (app launched by a notification tap from terminated state).
  static void storePendingNavigation(Map<String, dynamic> data) {
    _pendingData = Map<String, dynamic>.from(data);
  }

  /// Consumes any stored cold-start navigation data and executes the navigation.
  ///
  /// Called from two places:
  ///   1. NotificationService.init(), immediately after storePendingNavigation()
  ///      — this is the primary, reliable call site.
  ///   2. _OptimizedMyAppState.initState() via addPostFrameCallback
  ///      — kept as a harmless fallback; it is a no-op if _pendingData has
  ///        already been consumed in (1).
  static Future<void> executePendingNavigation() async {
    final data = _pendingData;
    if (data == null) return;
    _pendingData = null; // consume before awaiting to prevent double-execution
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
    // ── Wait for the navigator to be ready ───────────────────────────────
    //
    // FIX: The original code returned immediately if currentState was null.
    // In practice this can happen on very fast cold-starts (the key is set
    // but the navigator hasn't processed its first frame yet).  Retry up to
    // 5 times (1.5 s total) before giving up.
    NavigatorState? navState;
    for (var attempt = 0; attempt < 5; attempt++) {
      navState = notificationNavigatorKey.currentState;
      if (navState != null) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }
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

      // 5. Re-read navState — it may have been reassigned during the awaits
      //    above if the widget tree rebuilt. Fetch it fresh before pushing.
      final currentNavState = notificationNavigatorKey.currentState;
      if (currentNavState == null) return;

      // 6. Push the feed screen
      currentNavState.push(
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
