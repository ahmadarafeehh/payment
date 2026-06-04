// services/analytics_service.dart
import 'dart:ui' as ui;
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart'; // ✅ Added for debugPrint
import 'package:supabase_flutter/supabase_flutter.dart';

class AnalyticsService {
  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  static Future<void> init() async {
    final country = ui.PlatformDispatcher.instance.locale.countryCode;
    if (country != null) {
      await _analytics.setUserProperty(
        name: 'country',
        value: country,
      );
    }
  }

  static Future<void> logEvent(
    String name, {
    Map<String, Object>? params,
  }) async {
    await _analytics.logEvent(
      name: name,
      parameters: params,
    );
  }

  /// Logs a follow/unfollow/request action to Supabase `follow_pressed` table.
  /// [action] must be one of: 'follow', 'unfollow', 'request'.
  static void logFollowPress({
    required String followerUid,
    required String followedUid,
    required String sourceScreen,
    required String action, // 'follow', 'unfollow', or 'request'
  }) {
    // Basic validation to prevent bad data
    if (!['follow', 'unfollow', 'request'].contains(action)) {
      debugPrint('Invalid action provided to logFollowPress: $action');
      return;
    }

    try {
      Supabase.instance.client
          .from('follow_pressed')
          .insert({
            'follower_uid': followerUid,
            'followed_uid': followedUid,
            'source_screen': sourceScreen,
            'action_type': action,
          })
          .then((_) {})
          .catchError((error) {
            debugPrint('Failed to insert follow_pressed: $error');
          });
    } catch (e) {
      debugPrint('Exception in logFollowPress: $e');
    }
  }
}
