import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/Profile_page/profile_post_feed_screen.dart';
import 'package:Ratedly/screens/Profile_page/other_user_profile.dart';

final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

// ---------------------------------------------------------------------------
// Pre-fetched data holder (post navigation only)
// ---------------------------------------------------------------------------
class _PreFetchedPostData {
  final List<Map<String, dynamic>> posts;
  final int targetIndex;
  final Map<String, dynamic> userData;
  final String ownerUid;

  _PreFetchedPostData({
    required this.posts,
    required this.targetIndex,
    required this.userData,
    required this.ownerUid,
  });
}

// ---------------------------------------------------------------------------
// NotificationNavigationHandler
// ---------------------------------------------------------------------------
class NotificationNavigationHandler {
  // Notification types that navigate to a specific post
  static const _postLinkedTypes = {
    'post_rating',
    'comment',
    'comment_like',
    'reply',
    'reply_like',
  };

  // Notification types that navigate to a user profile
  static const _profileLinkedTypes = {
    'follow',
  };

  // ── Overlay control ──────────────────────────────────────────────────────
  static final isNavigatingToPost = ValueNotifier<bool>(false);

  // ── Cold-start support ───────────────────────────────────────────────────
  static Map<String, dynamic>? _pendingData;
  static _PreFetchedPostData? _prefetchedPostData;

  /// Called from NotificationService.handleColdStart() — after Supabase is
  /// ready but BEFORE _appInitState switches out of the skeleton screen.
  static Future<void> prefetchNavigationData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();

    // Profile navigation (follow): no Supabase pre-fetch needed —
    // OtherUserProfileScreen loads its own data. The overlay is already
    // active from storePendingNavigation(), so nothing else to do here.
    if (type != null && _profileLinkedTypes.contains(type)) return;

    if (type == null || !_postLinkedTypes.contains(type)) return;

    final postId = _extractPostId(data);
    if (postId == null || postId.isEmpty) return;

    try {
      final supabase = Supabase.instance.client;

      final postRow = await supabase
          .from('posts')
          .select()
          .eq('postId', postId)
          .maybeSingle();
      if (postRow == null) return;

      final ownerUid = postRow['uid']?.toString() ?? '';
      if (ownerUid.isEmpty) return;

      final userRow = await supabase
          .from('users')
          .select('uid, username, photoUrl')
          .eq('uid', ownerUid)
          .maybeSingle();
      if (userRow == null) return;

      const pageSize = 20;
      final rawPosts = await supabase
          .from('posts')
          .select()
          .eq('uid', ownerUid)
          .order('datePublished', ascending: false)
          .limit(pageSize);

      final posts = List<Map<String, dynamic>>.from(
        (rawPosts as List).map((p) => Map<String, dynamic>.from(p as Map)),
      );

      int targetIndex =
          posts.indexWhere((p) => p['postId']?.toString() == postId);
      if (targetIndex == -1) {
        posts.insert(0, Map<String, dynamic>.from(postRow as Map));
        targetIndex = 0;
      }

      _prefetchedPostData = _PreFetchedPostData(
        posts: posts,
        targetIndex: targetIndex,
        userData: Map<String, dynamic>.from(userRow as Map),
        ownerUid: ownerUid,
      );
    } catch (_) {}
  }

  static void storePendingNavigation(Map<String, dynamic> data) {
    _pendingData = Map<String, dynamic>.from(data);
    isNavigatingToPost.value = true;
  }

  static Future<void> executePendingNavigation() async {
    final data = _pendingData;
    if (data == null) return;
    _pendingData = null;
    await handleNotificationData(data);
  }

  // ---------------------------------------------------------------------------
  // Main entry point
  // ---------------------------------------------------------------------------
  static Future<void> handleNotificationData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();

    final bool isPostLinked = type != null && _postLinkedTypes.contains(type);
    final bool isProfileLinked =
        type != null && _profileLinkedTypes.contains(type);
    final bool willNavigate = isPostLinked || isProfileLinked;

    // Activate opaque overlay synchronously — before any await.
    if (willNavigate) {
      isNavigatingToPost.value = true;
    }

    await _log(
      eventType: 'tap_received',
      notificationType: type,
      rawData: data,
    );

    if (!willNavigate) {
      await _log(
        eventType: 'type_not_handled',
        notificationType: type,
        rawData: data,
        additionalData: {
          'reason': type == null ? 'type_is_null' : 'type_not_in_set',
        },
      );
      isNavigatingToPost.value = false;
      return;
    }

    try {
      if (isPostLinked) {
        final postId = _extractPostId(data);
        if (postId == null || postId.isEmpty) {
          await _log(
            eventType: 'post_id_missing',
            notificationType: type,
            rawData: data,
            additionalData: {
              'customData_raw': data['customData'],
              'top_level_keys': data.keys.toList(),
            },
          );
          isNavigatingToPost.value = false;
          return;
        }
        await _navigateToPost(postId, type!, data);
      } else {
        // isProfileLinked (follow)
        final followerUid = _extractFollowerUid(data);
        if (followerUid == null || followerUid.isEmpty) {
          await _log(
            eventType: 'follower_uid_missing',
            notificationType: type,
            rawData: data,
            additionalData: {
              'customData_raw': data['customData'],
              'top_level_keys': data.keys.toList(),
            },
          );
          isNavigatingToPost.value = false;
          return;
        }
        await _navigateToProfile(followerUid, type!, data);
      }
    } finally {
      isNavigatingToPost.value = false;
      _prefetchedPostData = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Extracts postId — handles top-level, nested map, and JSON-string customData.
  static String? _extractPostId(Map<String, dynamic> data) {
    String? id = data['postId']?.toString() ?? data['post_id']?.toString();
    if (id != null && id.isNotEmpty) return id;

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

  /// Extracts the follower's UID from a follow notification payload.
  /// Handles top-level, nested map, and JSON-string customData.
  static String? _extractFollowerUid(Map<String, dynamic> data) {
    // Try common top-level key names first
    // ADDED 'followerId' to support your Cloud Function's customData key
    String? uid = data['followerUid']?.toString() ??
        data['follower_uid']?.toString() ??
        data['followerId']?.toString() ?? // <-- ADDED THIS LINE
        data['fromUid']?.toString() ??
        data['from_uid']?.toString();
    if (uid != null && uid.isNotEmpty) return uid;

    final raw = data['customData'];
    if (raw is Map) {
      uid = raw['followerUid']?.toString() ??
          raw['follower_uid']?.toString() ??
          raw['followerId']?.toString() ??
          raw['fromUid']?.toString() ??
          raw['from_uid']?.toString();
    } else if (raw is String && raw.isNotEmpty) {
      try {
        final parsed = jsonDecode(raw) as Map<String, dynamic>;
        uid = parsed['followerUid']?.toString() ??
            parsed['follower_uid']?.toString() ??
            parsed['followerId']?.toString() ??
            parsed['fromUid']?.toString() ??
            parsed['from_uid']?.toString();
      } catch (_) {}
    }
    return uid;
  }

  // ---------------------------------------------------------------------------
  // Navigate to post (existing logic)
  // ---------------------------------------------------------------------------
  static Future<void> _navigateToPost(
    String postId,
    String notificationType,
    Map<String, dynamic> rawData,
  ) async {
    NavigatorState? navState;
    int attempts = 0;
    for (; attempts < 5; attempts++) {
      navState = notificationNavigatorKey.currentState;
      if (navState != null) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (navState == null) {
      await _log(
        eventType: 'navigator_not_ready',
        notificationType: notificationType,
        postId: postId,
        navigatorReady: false,
        navigatorAttempts: attempts,
        rawData: rawData,
      );
      return;
    }

    try {
      final supabase = Supabase.instance.client;
      const pageSize = 20;

      List<Map<String, dynamic>> posts;
      int targetIndex;
      Map<String, dynamic> userData;
      String ownerUid;

      final cached = _prefetchedPostData;
      if (cached != null) {
        posts = cached.posts;
        targetIndex = cached.targetIndex;
        userData = cached.userData;
        ownerUid = cached.ownerUid;
      } else {
        final postRow = await supabase
            .from('posts')
            .select()
            .eq('postId', postId)
            .maybeSingle();
        if (postRow == null) {
          await _log(
            eventType: 'post_not_found',
            notificationType: notificationType,
            postId: postId,
            navigatorReady: true,
            navigatorAttempts: attempts,
            rawData: rawData,
          );
          return;
        }

        ownerUid = postRow['uid']?.toString() ?? '';
        if (ownerUid.isEmpty) {
          await _log(
            eventType: 'post_owner_uid_empty',
            notificationType: notificationType,
            postId: postId,
            navigatorReady: true,
            navigatorAttempts: attempts,
            rawData: rawData,
          );
          return;
        }

        final userRow = await supabase
            .from('users')
            .select('uid, username, photoUrl')
            .eq('uid', ownerUid)
            .maybeSingle();
        if (userRow == null) {
          await _log(
            eventType: 'user_not_found',
            notificationType: notificationType,
            postId: postId,
            navigatorReady: true,
            navigatorAttempts: attempts,
            rawData: rawData,
          );
          return;
        }

        userData = Map<String, dynamic>.from(userRow as Map);

        final rawPosts = await supabase
            .from('posts')
            .select()
            .eq('uid', ownerUid)
            .order('datePublished', ascending: false)
            .limit(pageSize);

        posts = List<Map<String, dynamic>>.from(
          (rawPosts as List).map((p) => Map<String, dynamic>.from(p as Map)),
        );

        targetIndex =
            posts.indexWhere((p) => p['postId']?.toString() == postId);
        if (targetIndex == -1) {
          posts.insert(0, Map<String, dynamic>.from(postRow as Map));
          targetIndex = 0;
        }
      }

      final currentNavState = notificationNavigatorKey.currentState;
      if (currentNavState == null) {
        await _log(
          eventType: 'navigator_lost_after_fetch',
          notificationType: notificationType,
          postId: postId,
          navigatorReady: false,
          navigatorAttempts: attempts,
          rawData: rawData,
        );
        return;
      }

      final String resolvedOwnerUid = ownerUid;
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
                  .eq('uid', resolvedOwnerUid)
                  .order('datePublished', ascending: false)
                  .range(currentCount, currentCount + pageSize - 1);
              return List<Map<String, dynamic>>.from(
                (more as List).map((p) => Map<String, dynamic>.from(p as Map)),
              );
            },
          ),
        ),
      );

      await _log(
        eventType: 'navigation_success',
        notificationType: notificationType,
        postId: postId,
        navigatorReady: true,
        navigatorAttempts: attempts,
        rawData: rawData,
        additionalData: {
          'target_index': targetIndex,
          'total_posts_loaded': posts.length,
          'owner_uid': ownerUid,
          'used_prefetch': cached != null,
        },
      );
    } catch (e, st) {
      await _log(
        eventType: 'error',
        notificationType: notificationType,
        postId: postId,
        navigatorReady: navState != null,
        navigatorAttempts: attempts,
        errorMessage: e.toString(),
        stackTrace: st.toString(),
        rawData: rawData,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Navigate to profile (follow notification)
  // ---------------------------------------------------------------------------
  static Future<void> _navigateToProfile(
    String followerUid,
    String notificationType,
    Map<String, dynamic> rawData,
  ) async {
    NavigatorState? navState;
    int attempts = 0;
    for (; attempts < 5; attempts++) {
      navState = notificationNavigatorKey.currentState;
      if (navState != null) break;
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (navState == null) {
      await _log(
        eventType: 'navigator_not_ready',
        notificationType: notificationType,
        navigatorReady: false,
        navigatorAttempts: attempts,
        rawData: rawData,
        additionalData: {'follower_uid': followerUid},
      );
      return;
    }

    try {
      navState.push(
        MaterialPageRoute(
          builder: (_) => OtherUserProfileScreen(uid: followerUid),
        ),
      );

      await _log(
        eventType: 'navigation_success',
        notificationType: notificationType,
        navigatorReady: true,
        navigatorAttempts: attempts,
        rawData: rawData,
        additionalData: {'follower_uid': followerUid},
      );
    } catch (e, st) {
      await _log(
        eventType: 'error',
        notificationType: notificationType,
        navigatorReady: navState != null,
        navigatorAttempts: attempts,
        errorMessage: e.toString(),
        stackTrace: st.toString(),
        rawData: rawData,
        additionalData: {'follower_uid': followerUid},
      );
    }
  }

  // ── Logging helper ────────────────────────────────────────────────────────
  static Future<void> _log({
    required String eventType,
    String? notificationType,
    String? postId,
    bool? navigatorReady,
    int? navigatorAttempts,
    String? errorMessage,
    String? stackTrace,
    Map<String, dynamic>? rawData,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await Supabase.instance.client.from('notification_tap_logs').insert({
        'event_type': eventType,
        'notification_type': notificationType,
        'post_id': postId,
        'navigator_ready': navigatorReady,
        'navigator_attempts': navigatorAttempts,
        'error_message': errorMessage,
        'stack_trace': stackTrace,
        'raw_data': rawData,
        'additional_data': additionalData,
      });
    } catch (_) {}
  }
}
