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
  static const _postLinkedTypes = {
    'post_rating',
    'comment',
    'comment_like',
    'reply',
    'reply_like',
  };

  static Map<String, dynamic>? _pendingData;

  // ── Logging helper ──────────────────────────────────────────────────────
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
    } catch (_) {
      // Never let logging crash the app.
    }
  }

  // ---------------------------------------------------------------------------
  // Cold-start support
  // ---------------------------------------------------------------------------
  static void storePendingNavigation(Map<String, dynamic> data) {
    _pendingData = Map<String, dynamic>.from(data);
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

    // ── Log every tap so we know the handler was reached ──────────────────
    await _log(
      eventType: 'tap_received',
      notificationType: type,
      rawData: data,
    );

    if (type == null || !_postLinkedTypes.contains(type)) {
      await _log(
        eventType: 'type_not_post_linked',
        notificationType: type,
        rawData: data,
        additionalData: {'reason': type == null ? 'type_is_null' : 'type_not_in_set'},
      );
      return;
    }

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
      return;
    }

    await _navigateToPost(postId, type, data);
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
    // ── Wait for the navigator ─────────────────────────────────────────────
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

      // 1. Fetch the target post
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

      final ownerUid = postRow['uid']?.toString() ?? '';
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

      // 2. Fetch the post owner's profile
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

      final userData = Map<String, dynamic>.from(userRow as Map);

      // 3. Fetch the first page of the owner's posts
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

      // 4. Locate target post; prepend if not in page 1
      int targetIndex =
          posts.indexWhere((p) => p['postId']?.toString() == postId);
      if (targetIndex == -1) {
        posts.insert(0, Map<String, dynamic>.from(postRow as Map));
        targetIndex = 0;
      }

      // 5. Re-read navState after all the awaits
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

      // ✅ Log success
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
}
