import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlatformService {
  static const _platformPrefKey = 'platform_saved_v1';
  static const _notifPrefKey    = 'notif_status_saved_v1';

  // ---------------------------------------------------------------------------
  // Platform detection
  // ---------------------------------------------------------------------------

  static String detectPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Saves the platform to the DB exactly once per device install.
  static Future<void> saveOnce(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = '${_platformPrefKey}_$uid';
      if (prefs.getBool(savedKey) == true) return;

      final platform = detectPlatform();
      await Supabase.instance.client
          .from('users')
          .update({'platform': platform}).eq('uid', uid);

      await prefs.setBool(savedKey, true);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Notification permission detection
  // ---------------------------------------------------------------------------

  /// Checks whether the user has granted push notification permission.
  /// Uses Firebase Messaging which works on iOS, Android, and Web.
  static Future<bool> _checkNotificationsEnabled() async {
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (_) {
      return false;
    }
  }

  /// Saves notification permission status to the DB once per device install.
  ///
  /// Unlike platform (which never changes), notification permission CAN change
  /// if the user goes to Settings and toggles it. So this uses a lighter gate:
  /// - First call: always saves to DB and caches locally.
  /// - Subsequent calls within the same app session: skipped via pref.
  /// - On next app launch: re-checks and updates DB only if the value changed,
  ///   so the DB stays accurate without hammering it on every open.
  static Future<void> saveNotificationStatus(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefKey = '${_notifPrefKey}_$uid';

      final enabled = await _checkNotificationsEnabled();
      final newValue = enabled.toString(); // 'true' or 'false'

      // Only write to DB if the value has changed since last save.
      final lastSaved = prefs.getString(prefKey);
      if (lastSaved == newValue) return;

      await Supabase.instance.client
          .from('users')
          .update({'notifications_enabled': enabled}).eq('uid', uid);

      await prefs.setString(prefKey, newValue);
    } catch (_) {}
  }
}
