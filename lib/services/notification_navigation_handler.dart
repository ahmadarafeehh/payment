import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/Profile_page/profile_post_feed_screen.dart';

final GlobalKey<NavigatorState> notificationNavigatorKey =
    GlobalKey<NavigatorState>();

// ---------------------------------------------------------------------------
// Pre-fetched data holder
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
  static const _postLinkedTypes = {
    'post_rating',
    'comment',
    'comment_like',
    'reply',
    'reply_like',
  };

  // ── Overlay control ──────────────────────────────────────────────────────
  /// Drives the full-screen opaque cover in MaterialApp.builder.
  /// Set synchronously before any async work so the feed is hidden
  /// the moment a notification tap is handled.
  static final isNavigatingToPost = ValueNotifier<bool>(false);

  // ── Cold-start support ───────────────────────────────────────────────────
  static Map<String, dynamic>? _pendingData;
  static _PreFetchedPostData? _prefetchedPostData;

  /// Called from NotificationService.handleColdStart() — after Supabase is
  /// ready but BEFORE _appInitState switches out of the skeleton screen.
  /// Eagerly fetches post + user rows so executePendingNavigation() can
  /// push the route with zero additional Supabase delay.
  static Future<void> prefetchNavigationData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();
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
    } catch (_) {
      // If pre-fetch fails, _navigateToPost will re-fetch normally.
    }
  }

  /// Stores cold-start data and immediately activates the overlay so the
  /// feed is never visible, even on the very first rendered frame.
  static void storePendingNavigation(Map<String, dynamic> data) {
    _pendingData = Map<String, dynamic>.from(data);
    isNavigatingToPost.value = true;
  }

  static Future<void> executePendingNavigation() async {
    final data = _pendingData;
    if (data == null) return;
    _pendingData = null; // consume before awaiting — prevents double execution
    await handleNotificationData(data);
  }

  // ---------------------------------------------------------------------------
  // Main entry point
  // ---------------------------------------------------------------------------
  static Future<void> handleNotificationData(Map<String, dynamic> data) async {
    final type = data['type']?.toString();

    // ── Validate synchronously, before any await ─────────────────────────
    final bool isPostLinked =
        type != null && _postLinkedTypes.contains(type);
    final String? postId = isPostLinked ? _extractPostId(data) : null;
    final bool willNavigate =
        isPostLinked && postId != null && postId.isNotEmpty;

    // Show the opaque cover NOW — synchronous, fires before the first await.
    // For cold-start this is a no-op (storePendingNavigation already set it).
    // For background→foreground this hides the feed immediately.
    if (willNavigate) {
      isNavigatingToPost.value = true;
    }

    // ── Async work starts here ────────────────────────────────────────────
    await _log(
      eventType: 'tap_received',
      notificationType: type,
      rawData: data,
    );

    if (!isPostLinked) {
      await _log(
        eventType: 'type_not_post_linked',
        notificationType: type,
        rawData: data,
        additionalData: {
          'reason': type == null ? 'type_is_null' : 'type_not_in_set',
        },
      );
      isNavigatingToPost.value = false;
      return;
    }

    if (!willNavigate) {
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

    try {
      await _navigateToPost(postId!, type!, data);
    } finally {
      // Always clear — whether navigation succeeded, failed, or the route
      // was popped later. The overlay must never be left open permanently.
      isNavigatingToPost.value = false;
      _prefetchedPostData = null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
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

      // ── Use pre-fetched data when available (cold-start fast path) ──────
      final cached = _prefetchedPostData;
      if (cached != null) {
        posts = cached.posts;
        targetIndex = cached.targetIndex;
        userData = cached.userData;
        ownerUid = cached.ownerUid;
      } else {
        // ── Normal fetch (background → foreground path) ──────────────────
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
            additionalData: {'postRow_keys': postRow.keys.toList()},
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
            additionalData: {'owner_uid': ownerUid},
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

      // Re-read navState after all awaits
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
