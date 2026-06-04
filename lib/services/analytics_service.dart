import 'dart:ui' as ui;
import 'package:firebase_analytics/firebase_analytics.dart';
import 'dart:async'; // ✅ needed for unawaited

class AnalyticsService {
  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  /// Initializes analytics and sets the user's country once.
  static Future<void> init() async {
    final country = ui.PlatformDispatcher.instance.locale.countryCode;
    if (country != null) {
      await _analytics.setUserProperty(
        name: 'country',
        value: country,
      );
    }
  }

  /// Log a custom event with optional params. Avoid frequent calls.
  static Future<void> logEvent(
    String name, {
    Map<String, Object>? params,
  }) async {
    await _analytics.logEvent(
      name: name,
      parameters: params,
    );
  }

  /// Log a follow button press on another user's profile.
  /// This method is fire‑and‑forget and never throws (safe to call without await).
  static void logFollowPress({
    required String followerUid,
    required String followedUid,
    required String sourceScreen, // e.g., 'other_user_profile'
  }) {
    // Use unawaited to avoid blocking the UI
    unawaited(
      _analytics.logEvent(
        name: 'follow_pressed',
        parameters: {
          'follower_uid': followerUid,
          'followed_uid': followedUid,
          'source_screen': sourceScreen,
        },
      ),
    );
  }
}
