// services/analytics_service.dart
import 'dart:ui' as ui;
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart'; // for debugPrint
import 'package:supabase_flutter/supabase_flutter.dart';

class AnalyticsService {
  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  // Tracks the currently active screen name (last screenEnter called)
  static String? _currentScreen;

  // Stores data for each screen session: key = screenName, value = {enterTime, navigatedFrom}
  static final Map<String, _ScreenSessionData> _screenSessions = {};

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

  // =========================================================================
  // Screen time tracking with navigated_from
  // =========================================================================

  /// Call when a screen becomes visible (e.g., in initState).
  /// [screenName] should be a constant identifier, e.g. 'feed', 'profile'.
  /// The method automatically captures the previous screen (the one that was
  /// active before this one) based on the last screenEnter call.
  static void screenEnter(String screenName) {
    // Determine the screen we are coming from (if any)
    final navigatedFrom = _currentScreen;

    // Store the entry time and the previous screen for this new screen
    _screenSessions[screenName] = _ScreenSessionData(
      enterTime: DateTime.now(),
      navigatedFrom: navigatedFrom,
    );

    // Update the current screen tracker
    _currentScreen = screenName;
  }

  /// Call when the screen is closed (e.g., in dispose).
  /// [uid] is the current user's ID (obtained from your UserProvider).
  static void screenExit({
    required String screenName,
    required String uid,
  }) {
    try {
      final sessionData = _screenSessions.remove(screenName);
      if (sessionData == null) return;

      final durationSeconds =
          DateTime.now().difference(sessionData.enterTime).inSeconds;
      if (durationSeconds <= 0) return;

      Supabase.instance.client
          .from('screen_time')
          .insert({
            'uid': uid,
            'screen_name': screenName,
            'navigated_from': sessionData.navigatedFrom,
            'duration_seconds': durationSeconds,
          })
          .then((_) {})
          .catchError((error) {
            debugPrint('Failed to insert screen_time: $error');
          });
    } catch (e) {
      debugPrint('Exception in screenExit: $e');
    }
  }
}

/// Helper class to store screen session data.
class _ScreenSessionData {
  final DateTime enterTime;
  final String? navigatedFrom;

  _ScreenSessionData({
    required this.enterTime,
    required this.navigatedFrom,
  });
}
