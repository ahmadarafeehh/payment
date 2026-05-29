import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlatformService {
  static const _platformPrefKey = 'platform_saved_v1';
  static const _notifPrefKey    = 'notif_status_saved_v1';
  static const _versionPrefKey  = 'app_version_saved_v1';

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

  static Future<String> _getAppVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      // e.g. "1.2.3+45"  (version+buildNumber)
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Saves platform exactly once per install.
  /// Saves app version on every launch if it changed (handles updates).
  static Future<void> saveOnce(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final platformKey = '${_platformPrefKey}_$uid';
      final versionKey  = '${_versionPrefKey}_$uid';

      final platform   = detectPlatform();
      final appVersion = await _getAppVersion();

      final platformAlreadySaved = prefs.getBool(platformKey) == true;
      final lastSavedVersion     = prefs.getString(versionKey);
      final versionChanged       = lastSavedVersion != appVersion;

      // Build update payload — only include what needs updating
      final Map<String, dynamic> updates = {};
      if (!platformAlreadySaved) updates['platform']    = platform;
      if (versionChanged)        updates['app_version'] = appVersion;

      if (updates.isNotEmpty) {
        await Supabase.instance.client
            .from('users')
            .update(updates)
            .eq('uid', uid);
      }

      if (!platformAlreadySaved) await prefs.setBool(platformKey, true);
      if (versionChanged)        await prefs.setString(versionKey, appVersion);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Notification permission
  // ---------------------------------------------------------------------------
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

  static Future<void> saveNotificationStatus(String uid) async {
    try {
      final prefs   = await SharedPreferences.getInstance();
      final prefKey = '${_notifPrefKey}_$uid';
      final enabled = await _checkNotificationsEnabled();
      final newValue = enabled.toString();

      final lastSaved = prefs.getString(prefKey);
      if (lastSaved == newValue) return;

      await Supabase.instance.client
          .from('users')
          .update({'notifications_enabled': enabled}).eq('uid', uid);

      await prefs.setString(prefKey, newValue);
    } catch (_) {}
  }
}
